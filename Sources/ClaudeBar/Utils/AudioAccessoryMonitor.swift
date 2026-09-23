import Combine
import CoreAudio
import Foundation
import OSLog
import Observation

/// Bluetooth audio battery readings from system logs and profiler data.
/// Connection state is resolved independently through CoreAudio and Bluetooth topology.
/// Missing battery values remain unknown; device reporting cadence controls freshness.
@MainActor
@Observable
final class AudioAccessoryMonitor {
    static let shared = AudioAccessoryMonitor()

    enum Source: String {
        case bluetoothLog = "CBPowerSource"
        case batteryCenter = "BatteryCenter"
        case profiler = "system_profiler"
        case audioRoute = "CoreAudio"

        /// Lower sorts first — used when merging two readings of one device.
        var rank: Int {
            switch self {
            case .bluetoothLog: return 0
            case .batteryCenter: return 1
            case .profiler: return 2
            case .audioRoute: return 3
            }
        }
    }

    struct Reading: Equatable {
        var percent: Int
        /// nil when the source does not say. `false` and "unknown" are not the
        /// same statement, and the UI draws them differently.
        var charging: Bool?
    }

    struct Accessory: Identifiable, Equatable {
        var id: String
        var name: String
        var category: String = ""
        var productID: UInt16?
        var combined: Reading?
        var left: Reading?
        var right: Reading?
        var caseLevel: Reading?
        var observedAt: Date = .distantPast
        var source: Source = .bluetoothLog
        /// True while `name` is the *case's* localized name rather than the
        /// headset's. The case announces itself as its own accessory under the
        /// body's identifier, so this keeps its name from becoming the label.
        var nameIsCaseName: Bool = false

        /// What the meter shows when it has room for one number: the lower bud,
        /// because that is the one that will run out first.
        var headline: Int? {
            let buds = [left?.percent, right?.percent].compactMap { $0 }
            if let low = buds.min() { return low }
            return combined?.percent
        }

        var isCharging: Bool? {
            if let charging = combined?.charging { return charging }
            let parts = [left?.charging, right?.charging].compactMap { $0 }
            guard !parts.isEmpty else { return nil }
            return parts.allSatisfy { $0 }
        }

        /// A case reading only exists while something is in the case. AirPods
        /// stop broadcasting it with both buds out, and the last value then
        /// sits in the log looking current. Staleness is the honest signal.
        var isStale: Bool { source != .audioRoute && Date().timeIntervalSince(observedAt) > 180 }

        /// Connection is independent of battery availability: in use, nearby, or absent.
        enum Connection: Equatable {
            /// Playing to this Mac, or on the system's connected list.
            case inUse
            /// Announcing levels but not connected — charging in the case, or
            /// paired and within range with the lid open.
            case nearby
            /// Not announcing, or not seen for long enough to trust.
            case absent

            var label: String {
                switch self {
                case .inUse: return "已连接"
                case .nearby: return "未连接"
                case .absent: return "已离开"
                }
            }
        }

        /// Resolved on every poll from the two system-level signals, never from
        /// the power sources. See `ConnectionSource`.
        var connection: Connection = .nearby

        var hasAnyReading: Bool {
            headline != nil || caseLevel != nil
        }
    }

    private(set) var accessories: [Accessory] = []
    /// Set when every source has failed, so the UI can say why the row is empty
    /// rather than looking like there is nothing connected.
    private(set) var unavailableReason: String?

    private var subscribers = 0
    private var wakeObservation: AnyCancellable?

    private let engine = Engine()

    private init() {}

    // MARK: - Lifecycle

    /// Reference-counted observation shared by the dashboard and popup.
    @MainActor
    func start() {
        subscribers += 1
        // The closure is the engine's only route back to `accessories`. Passing
        // it per poll instead (which the timer handler used to do with `nil`)
        // means the periodic path has no way to deliver anything at all.
        engine.start(publish: { [weak self] accessories, reason in
            self?.publish(accessories, reason)
        })
        if wakeObservation == nil {
            // The observer fires on *changes* only, so the launch-time state has
            // to be applied separately or a cold start with no window samples
            // forever.
            wakeObservation = UIWakePolicy.observe { [weak self] in
                guard let self else { return }
                self.engine.setVisible(UIWakePolicy.hasVisibleWindow)
            }
        }
        engine.setVisible(UIWakePolicy.hasVisibleWindow)
    }

    @MainActor
    func stop() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
        wakeObservation = nil
        engine.stop()
    }

    /// Force a refresh, e.g. when a panel opens after being idle.
    @MainActor
    func refreshNow() {
        engine.refreshNow(publish: publish)
    }

    /// Called on the main actor by the engine when a poll has produced a
    /// different picture. The engine owns all the sampling state; this is the
    /// only place it crosses back.
    private func publish(_ accessories: [Accessory], _ reason: String?) {
        if self.accessories != accessories { self.accessories = accessories }
        if unavailableReason != reason { unavailableReason = reason }
    }
}

// MARK: - Engine

/// All mutable polling state is confined to the utility queue.
/// The unchecked Sendable conformance relies on that confinement.
private final class Engine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.claudebar.audioaccessory", qos: .utility)

    private var routeListener: AudioObjectPropertyListenerBlock?
    private var routeRefresh: DispatchWorkItem?
    private let routeSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices
    ]
    private var timer: DispatchSourceTimer?

    private func observeRoutes() {
        guard routeListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.suspended else { return }
            // Publish route changes before slow battery/profile work, so the
            // connected device appears even before it has reported a charge.
            let snapshot = self.assemble()
            if snapshot != self.lastPublished {
                self.lastPublished = snapshot
                self.lastPublishedReason = nil
                let publish = self.publishHandler
                Task { @MainActor in publish?(snapshot, nil) }
            }
            self.routeRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.timer != nil, !self.suspended else { return }
                self.poll(forceProfiler: true, publish: self.publishHandler)
            }
            self.routeRefresh = work
            self.queue.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
        routeListener = listener
        for selector in routeSelectors {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }

    /// Mirrors whether `timer` currently holds a suspend. Only `queue` touches
    /// it, together with the timer itself, so the two cannot drift apart.
    private var suspended = false

    /// Merged per-device state, keyed by accessory identifier. Log lines are
    /// partial (the case announces itself separately from the buds), so
    /// readings accumulate here rather than replacing a whole device.
    private var merged: [String: AudioAccessoryMonitor.Accessory] = [:]
    private var lastProfilerAt: Date = .distantPast
    private var consecutiveLogMisses = 0
    /// The last picture handed to the main actor, so a poll that changes
    /// nothing costs no publish and no re-render.
    private var lastPublished: [AudioAccessoryMonitor.Accessory]?
    private var lastPublishedReason: String?
    /// Names in the system's connected list, refreshed on the profiler's TTL.
    private var connectedNames: Set<String> = []
    /// Where a poll hands its result back. Installed once by `start` so the
    /// timer's own polls can deliver; a per-call parameter would leave the
    /// periodic path with nothing to call.
    private var publishHandler: (@MainActor ([AudioAccessoryMonitor.Accessory], String?) -> Void)?

    func start(publish: @escaping @MainActor ([AudioAccessoryMonitor.Accessory], String?) -> Void) {
        queue.async { [self] in
            publishHandler = publish
            guard timer == nil else { return }
            observeRoutes()
            let t = DispatchSource.makeTimerSource(queue: queue)
            // Poll battery logs every five seconds while visible; route changes are event-driven.
            t.schedule(deadline: .now(), repeating: 5.0, leeway: .seconds(1))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.poll(forceProfiler: false, publish: self.publishHandler)
            }
            t.resume()
            timer = t
            if suspended { t.suspend() }
        }
    }

    func stop() {
        queue.async { [self] in
            if let listener = routeListener {
                for selector in routeSelectors {
                    var address = AudioObjectPropertyAddress(mSelector: selector,
                        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
                }
            }
            routeListener = nil
            routeRefresh?.cancel()
            routeRefresh = nil
            if suspended { timer?.resume() }
            timer?.cancel()
            timer = nil
            suspended = false
            reset()
        }
    }

    /// Called from the main actor on every visibility change, and once at
    /// start to apply the launch-time state — the observer only fires on
    /// changes, so without that a cold start with no window polls forever.
    func setVisible(_ visible: Bool) {
        queue.async { [self] in
            guard let timer, suspended == visible else { return }
            suspended = !visible
            if visible {
                timer.resume()
                poll(forceProfiler: true, publish: publishHandler)
            } else {
                timer.suspend()
            }
        }
    }

    func refreshNow(publish: (@MainActor ([AudioAccessoryMonitor.Accessory], String?) -> Void)?) {
        queue.async { [weak self] in
            self?.poll(forceProfiler: true, publish: publish)
        }
    }

    private func reset() {
        connectedNames.removeAll()
        merged.removeAll()
        lastProfilerAt = .distantPast
        consecutiveLogMisses = 0
        lastPublished = nil
        lastPublishedReason = nil
    }

    func poll(forceProfiler: Bool, publish: (@MainActor ([AudioAccessoryMonitor.Accessory], String?) -> Void)?) {
        let now = Date()

        // Read both subsystems together. A fixed lookback tolerates delayed log availability;
        // records are merged before comparing the published snapshot.
        let since = now.addingTimeInterval(-20 * 60)

        if let entries = LogSource.entries(since: since) {
            consecutiveLogMisses = 0
            for entry in entries {
                switch (entry.subsystem, entry.category) {
                case ("com.apple.bluetooth", "CBPowerSource"):
                    if let parsed = PowerSourceLogParser.parse(entry.message) {
                        merge(parsed, at: entry.date, source: .bluetoothLog)
                    }
                case ("com.apple.BatteryCenter", "PowerSourceController"):
                    if let parsed = BatteryCenterLogParser.parse(entry.message) {
                        merge(parsed, at: entry.date, source: .batteryCenter)
                    }
                default:
                    break
                }
            }
            // A store that answers but holds nothing for this feature is
            // *healthy*: silence is what a machine with no headset nearby looks
            // like. Counting it as a miss would make the meter claim the log is
            // unreadable on every Mac without AirPods.
        } else {
            // Only a *failed* store raises the miss count, and it drives the
            // profiler fallback below.
            consecutiveLogMisses += 1
        }

        // One profiler invocation supplies topology and battery data. Failed
        // logs shorten the fallback interval without spawning on every poll.
        let ttl: TimeInterval = consecutiveLogMisses >= 3 ? 30 : 300
        if forceProfiler || now.timeIntervalSince(lastProfilerAt) >= ttl {
            lastProfilerAt = now
            if let snapshot = ProfilerSource.read() {
                connectedNames = snapshot.connectedNames
                merge(snapshot.accessories, at: now, source: .profiler)
            }
        }

        // Retain idle accessories through reporting gaps; charging cases receive a longer TTL.
        let inUseCutoff = now.addingTimeInterval(-15 * 60)
        let chargingCutoff = now.addingTimeInterval(-60 * 60)
        let expired = merged.filter { _, accessory in
            let cutoff = accessory.isCharging == true ? chargingCutoff : inUseCutoff
            return accessory.observedAt < cutoff
        }.map(\.key)
        for key in expired { merged.removeValue(forKey: key) }

        // Publish only when the assembled device snapshot changes.
        let snapshot = assemble()
        let reason: String? = snapshot.isEmpty && consecutiveLogMisses >= 3 ? "无法读取系统日志" : nil
        guard snapshot != lastPublished || reason != lastPublishedReason else { return }
        lastPublished = snapshot
        lastPublishedReason = reason
        Task { @MainActor in publish?(snapshot, reason) }
    }

    /// Combine separately announced headset and case records into one accessory.
    private func assemble() -> [AudioAccessoryMonitor.Accessory] {
        var bodies: [String: AudioAccessoryMonitor.Accessory] = [:]
        var cases: [String: AudioAccessoryMonitor.Accessory] = [:]
        for (key, accessory) in merged {
            if key.hasSuffix("#case") {
                cases[String(key.dropLast("#case".count))] = accessory
            } else {
                bodies[key] = accessory
            }
        }

        // Resolve "in use" once per poll from the two outside signals. This is
        // the only place the reading is turned into a claim about connection,
        // and it deliberately happens *after* merging: whether a headset is
        // connected has nothing to do with which source reported its levels.
        let route = ConnectionSource.defaultOutputName()

        var out: [AudioAccessoryMonitor.Accessory] = []
        for (identifier, var body) in bodies {
            if let box = cases[identifier] {
                body.caseLevel = box.caseLevel
                // Freshness follows the newest fact about the headset: a case
                // reading that is newer than the buds' keeps the row alive.
                body.observedAt = max(body.observedAt, box.observedAt)
            }
            body.connection = resolveConnection(for: body, route: route)
            out.append(body)
        }
        // Case-only accessories (nothing announced the buds this session).
        for (identifier, box) in cases where bodies[identifier] == nil {
            var orphan = box
            // Name it after the headset rather than the part: strip the
            // localized "充电盒" suffix if the system appended one.
            orphan.name = LogText.strippingCaseSuffix(box.name)
            orphan.id = identifier
            orphan.connection = resolveConnection(for: orphan, route: route)
            out.append(orphan)
        }
        if let route, ConnectionSource.defaultOutputIsBluetooth(),
           !out.contains(where: { ConnectionSource.routeMatches(accessoryName: $0.name, routeName: route) }) {
            var accessory = AudioAccessoryMonitor.Accessory(id: "audio-route:" + route, name: route)
            accessory.source = .audioRoute
            accessory.connection = .inUse
            out.append(accessory)
        }
        return out.sorted {
            if ($0.connection == .inUse) != ($1.connection == .inUse) { return $0.connection == .inUse }
            return $0.name < $1.name
        }
    }

    /// Turn a reading into a statement about connection, from the two outside
    /// signals only. See `Accessory.Connection` for why the power sources
    /// cannot answer this.
    private func resolveConnection(for accessory: AudioAccessoryMonitor.Accessory,
                                   route: String?) -> AudioAccessoryMonitor.Accessory.Connection {
        // Audio routed to it is proof it is in use, and is checked first because
        // it reacts immediately while the connected list lags by its TTL.
        if let route, ConnectionSource.routeMatches(accessoryName: accessory.name, routeName: route) {
            return .inUse
        }
        if connectedNames.contains(ConnectionSource.normalizeName(accessory.name)) {
            return .inUse
        }
        return .nearby
    }

    /// Merge partial readings per field so a slower source cannot erase known values.
    private func merge(_ incoming: [AudioAccessoryMonitor.Accessory],
                       at date: Date,
                       source: AudioAccessoryMonitor.Source) {
        for device in incoming {
            let key = device.id
            guard let existing = merged[key] else {
                var fresh = device
                fresh.observedAt = date
                fresh.source = source
                merged[key] = fresh
                continue
            }
            var next = existing
            // A `#case` sighting carries the case's *localized* name ("大王的
            // AirPods Pro充电盒"). It must never become the body's name — the
            // meter labels the whole headset, not one of its parts. The body
            // name wins whenever it is known; the case name is only a fallback
            // for a device whose buds have never announced themselves.
            if next.name.isEmpty || (next.nameIsCaseName && !device.nameIsCaseName) {
                next.name = device.name
                next.nameIsCaseName = device.nameIsCaseName
            }
            if next.category.isEmpty { next.category = device.category }
            if next.productID == nil { next.productID = device.productID }
            if better(device.combined, over: next.combined, from: source, existing: next.source) {
                next.combined = device.combined
            }
            if better(device.left, over: next.left, from: source, existing: next.source) {
                next.left = device.left
            }
            if better(device.right, over: next.right, from: source, existing: next.source) {
                next.right = device.right
            }
            if better(device.caseLevel, over: next.caseLevel, from: source, existing: next.source) {
                next.caseLevel = device.caseLevel
            }
            next.observedAt = max(next.observedAt, date)
            if source.rank < next.source.rank { next.source = source }
            if next != existing {
                merged[key] = next
            }
        }
    }

    /// Take the new reading when it carries information the old one lacks, or
    /// comes from a source at least as trustworthy. A lower-ranked source must
    /// not overwrite a field the higher-ranked one just reported — that is how
    /// the TTL'd profiler would undo a fresher log reading.
    private func better(_ candidate: AudioAccessoryMonitor.Reading?,
                        over current: AudioAccessoryMonitor.Reading?,
                        from source: AudioAccessoryMonitor.Source,
                        existing: AudioAccessoryMonitor.Source) -> Bool {
        guard let candidate else { return false }
        guard let current else { return true }
        if source.rank > existing.rank { return candidate.charging != nil && current.charging == nil }
        return candidate != current
    }
}

// MARK: - Log access

/// Connection authority combines the default audio route and the connected-device inventory.
private enum ConnectionSource {
    /// Connected device names from the shared profiler response.
    static func parseConnected(_ data: Data) -> Set<String> {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var names = Set<String>()
        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, _) in entry { names.insert(normalizeName(name)) }
            }
        }
        return names
    }

    /// The name of the current default audio output, via `CoreAudio`.
    ///
    /// Read straight from the HAL — no subprocess, so it is cheap enough to
    /// check on every poll and it reacts immediately when audio starts or stops.
    static func defaultOutputName() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &device) == noErr else { return nil }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer -> OSStatus in
            AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, pointer)
        }
        guard status == noErr else { return nil }
        return name as String
    }

    static func defaultOutputIsBluetooth() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        address.mSelector = kAudioDevicePropertyTransportType
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Names differ in whitespace between sources — `system_profiler` emits a
    /// non-breaking space inside "王夏军的Apple\u{a0}Watch" where the log does
    /// not — so comparison collapses the distinction rather than trying to
    /// predict which source will edit it.
    static func normalizeName(_ name: String) -> String {
        name.components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: "\u{a0}", with: "")
    }

    /// Does `accessoryName` name the device the system is routing audio to?
    ///
    /// The route reports the *endpoint* ("大王的AirPods Pro"), which for AirPods
    /// matches the accessory name. A headset whose route name differs is still
    /// caught by the connected list, so a miss here only costs immediacy, never
    /// correctness.
    static func routeMatches(accessoryName: String, routeName: String) -> Bool {
        let a = normalizeName(accessoryName)
        let r = normalizeName(routeName)
        guard !a.isEmpty, !r.isEmpty else { return false }
        return a == r || r.contains(a) || a.contains(r)
    }
}

/// Thin wrapper over `OSLogStore`. Returns nil on failure so callers can count
/// misses and fall back, rather than treating an outage as "no devices".
private enum LogSource {
    struct Entry {
        var subsystem: String
        var category: String
        var date: Date
        var message: String
    }

    /// The two subsystems this feature reads, in one predicate.
    ///
    /// `com.apple.bluetooth` / `CBPowerSource` is `bluetoothd` announcing a
    /// power source. `com.apple.BatteryCenter` / `PowerSourceController` is the
    /// service behind System Settings' battery list.
    ///
    /// They are asked for together because `OSLogStore` charges roughly the
    /// same for either query — 0.067 s combined vs 0.072 s for one of them
    /// alone, so a second call is nearly the whole cost again.
    private static let predicate = NSPredicate(
        format: "(subsystem == %@ AND category == %@) OR (subsystem == %@ AND category == %@)",
        "com.apple.bluetooth", "CBPowerSource",
        "com.apple.BatteryCenter", "PowerSourceController")

    private static let lock = NSLock()
    private static var store: OSLogStore?

    /// Everything both subsystems logged since `since`, oldest first.
    static func entries(since: Date) -> [Entry]? {
        lock.lock()
        defer { lock.unlock() }
        let logStore: OSLogStore
        if let cached = store {
            logStore = cached
        } else {
            guard let fresh = try? OSLogStore.local() else { return nil }
            store = fresh
            logStore = fresh
        }
        guard let position = logStore.position(date: since) as OSLogPosition?,
              let sequence = try? logStore.getEntries(at: position, matching: predicate) else {
            // A store that has gone bad stays bad; drop it so the next call
            // builds a new one. The pid-based local store can be invalidated
            // when the log daemon rotates.
            store = nil
            return nil
        }
        var out: [Entry] = []
        for case let entry as OSLogEntryLog in sequence {
            out.append(Entry(subsystem: entry.subsystem,
                             category: entry.category,
                             date: entry.date,
                             message: entry.composedMessage))
        }
        out.sort { $0.date < $1.date }
        return out
    }
}

/// Strips the `CF 0x1 < Attributes >` capability chunks that `bluetoothd`
/// interleaves between components, then matches `Name ±NN%`.
private enum LogText {
    static let capabilityChunk = try! NSRegularExpression(pattern: "CF 0x[0-9A-Fa-f]+ <[^>]*>")
    static let component = try! NSRegularExpression(pattern: "\\b(Left|Right|Case|Combined)\\s*([+-])(\\d+)%")

    static func strippingCapabilities(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        return capabilityChunk.stringByReplacingMatches(in: line, range: range, withTemplate: "")
    }

    /// `+` is charging, `-` is discharging. The magnitude is the percentage.
    ///
    /// `0` is rejected rather than reported: `bluetoothd` holds a percentage per
    /// battery and leaves the ones it has learned nothing about at zero, so a
    /// zero here is "no reading", not "flat".
    static func reading(sign: String, digits: String) -> AudioAccessoryMonitor.Reading? {
        guard let percent = Int(digits), (1...100).contains(percent) else { return nil }
        return .init(percent: percent, charging: sign == "+")
    }

    static func components(in line: String) -> [String: AudioAccessoryMonitor.Reading] {
        let stripped = strippingCapabilities(line)
        var out: [String: AudioAccessoryMonitor.Reading] = [:]
        for match in component.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) {
            guard let nameRange = Range(match.range(at: 1), in: stripped),
                  let signRange = Range(match.range(at: 2), in: stripped),
                  let digitsRange = Range(match.range(at: 3), in: stripped) else { continue }
            let name = String(stripped[nameRange])
            if let reading = reading(sign: String(stripped[signRange]), digits: String(stripped[digitsRange])) {
                // A repeated component is the "latest wins" case, not an error.
                out[name] = reading
            }
        }
        return out
    }

    /// `Nm '大王的AirPods Pro'` — the quotes are part of the format and a name
    /// containing `'` is not representable, so this stops at the first quote.
    static func quoted(after key: String, in line: String) -> String? {
        guard let start = line.range(of: "\(key) '") else { return nil }
        guard let end = line.range(of: "'", range: start.upperBound..<line.endIndex) else { return nil }
        return String(line[start.upperBound..<end.lowerBound])
    }

    /// `key ValueUpToComma`
    static func token(after key: String, in line: String, upTo terminators: String = ",; ") -> String? {
        guard let start = line.range(of: "\(key) ") else { return nil }
        let rest = line[start.upperBound...]
        let end = rest.firstIndex { terminators.contains($0) } ?? rest.endIndex
        let value = rest[rest.startIndex..<end]
        return value.isEmpty ? nil : String(value)
    }

    /// Whether a `Category` / `Accessory Category` string names an audio
    /// device. The power-source subsystem also reports keyboards, mice and the
    /// Mac's own battery, and "is it audio" is what separates the meter's
    /// subject from the rest.
    static func isAudio(category: String) -> Bool {
        let lowered = category.lowercased()
        return ["headphone", "headset", "earbud", "earphone", "speaker", "audio"].contains {
            lowered.contains($0)
        }
    }

    /// `大王的AirPods Pro充电盒` → `大王的AirPods Pro`.
    ///
    /// The system localizes the case's name by appending a suffix, and the exact
    /// word depends on the UI language, so this matches the known labels rather
    /// than trying to guess a boundary. Used for *identity* (so a case joins its
    /// body) and for the label on a case-only accessory.
    static func strippingCaseSuffix(_ name: String) -> String {
        for suffix in ["充电盒", "充電盒", "Charging Case", "Charging case", "Case"] {
            if name.hasSuffix(suffix) {
                return String(name.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return name
    }

    /// `大王的AirPods Pro 🅛` → `大王的AirPods Pro`.
    ///
    /// BatteryCenter labels the per-bud rows with a trailing enclosed-alphanumeric
    /// glyph (`\u{1F14B}` / `\u{1F141}`) appended to the *same* name the combined
    /// row uses. Left in the identity, each bud became its own accessory that
    /// could never join the headset it belongs to — the meter drew an empty
    /// ghost per bud. Only a trailing glyph is removed, so a genuine name that
    /// happens to contain one is untouched.
    static func strippingPartLabel(_ name: String) -> String {
        var out = name
        while let last = out.last {
            // `🅛` / `🅡` are U+1F15B / U+1F161 — Unicode "enclosed alphanumeric
            // supplement", general category *symbol*, and **not** emoji. Testing
            // `isEmojiPresentation` therefore strips nothing at all, which is how
            // the ghosts survived the first attempt at this fix. The test has to
            // be on the symbol category, with the emoji ranges covered because
            // the system is free to label a part that way instead.
            let isPartGlyph = last.unicodeScalars.allSatisfy { scalar in
                scalar.properties.generalCategory == .otherSymbol
                    || scalar.properties.isEmojiPresentation
                    || (0x1F150...0x1F16F).contains(scalar.value)
                    || (0x1F170...0x1F19A).contains(scalar.value)
            }
            guard isPartGlyph else { break }
            out.removeLast()
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// `Name = "\134U5927\134U738b..."` — `bluetoothd` escapes its non-ASCII as
    /// `\134` (octal for the backslash) followed by a `\Uxxxx` scalar, so one
    /// substitution has to happen before the scalars can be read.
    static func unescape(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: #"\134"#, with: #"\"#)
        guard normalized.contains(#"\U"#) else { return normalized }
        var out = ""
        var index = normalized.startIndex
        while index < normalized.endIndex {
            if normalized[index] == "\\",
               normalized.index(after: index) < normalized.endIndex,
               normalized[normalized.index(after: index)] == "U" {
                let start = normalized.index(index, offsetBy: 2)
                let end = normalized.index(start, offsetBy: 4, limitedBy: normalized.endIndex) ?? normalized.endIndex
                if let scalar = UInt32(normalized[start..<end], radix: 16),
                   let unicode = UnicodeScalar(scalar) {
                    out.append(Character(unicode))
                    index = end
                    continue
                }
            }
            out.append(normalized[index])
            index = normalized.index(after: index)
        }
        return out
    }
}

// MARK: - Parsers

/// `bluetoothd`'s `CBPowerSource` announcements.
///
/// ```
/// Power source updated CBPowerSource Nm '大王的AirPods Pro', AcCa Headphone,
/// AcID 49335F71-…, GID 49335F71-…, PaID Combined, PID 0x200E (AirPodsPro1,1),
/// VID 0x004C (Apple), Type 'Accessory Source', TPT Bluetooth,
/// MaxC 100%, Battery 52% (Unknown),
/// Components (N): Left -56%, Right -55%
/// ```
///
/// The `(Y)`/`(N)` after `Components` tracks whether the case is in the
/// component list, not whether the reading is chargeable — a `(N)` line can
/// still carry `Case`. Parse the components, ignore the flag.
private enum PowerSourceLogParser {
    static func parse(_ message: String) -> [AudioAccessoryMonitor.Accessory]? {
        guard message.contains("Power source updated"),
              let name = LogText.quoted(after: "Nm", in: message) else { return nil }
        // Identity is the **name**, not the AcID: the three sources do not
        // share an AcID (the profiler has none at all) but all three spell the
        // headset the same way, so the name is what makes them one row.
        //
        // The suffix strip matters because the case announces itself under a
        // localized name ("大王的AirPods Pro充电盒"). Whichever source notices
        // the case first must land on the *body's* key so `assemble()` pairs
        // the two halves back into one headset instead of drawing it twice.
        let identifier = LogText.strippingPartLabel(LogText.strippingCaseSuffix(name))

        let components = LogText.components(in: message)
        var accessory = AudioAccessoryMonitor.Accessory(id: identifier, name: name)
        accessory.category = LogText.token(after: "AcCa", in: message) ?? ""

        // **Scope, not just identity.** macOS 26 announces the charging case as
        // its own accessory under the *same* `AcID` as the buds ("大王的AirPods
        // Pro充电盒", `AcCa 'Audio Battery Case'`). Keying purely by `AcID` let
        // that record overwrite the buds' name and fold two subjects into one,
        // which is how the meter ended up showing a case name with bud levels.
        // A case-only sighting therefore gets its own slot; everything else
        // (buds, or a combined announcement) shares the body slot.
        let isCaseOnly = accessory.category.localizedCaseInsensitiveContains("battery case")
            || (components["Case"] != nil && components["Left"] == nil && components["Right"] == nil)
        accessory.id = isCaseOnly ? "\(identifier)#case" : identifier
        accessory.nameIsCaseName = isCaseOnly
        if let raw = LogText.token(after: "PID", in: message, upTo: " ("),
           raw.hasPrefix("0x") {
            accessory.productID = UInt16(raw.dropFirst(2), radix: 16)
        }
        accessory.left = components["Left"]
        accessory.right = components["Right"]
        accessory.caseLevel = components["Case"]

        // `Battery 52% (Unknown)` is the combined level. It carries no sign,
        // so the combined charging state is inferred from the buds: both
        // charging means the accessory is charging.
        if let raw = LogText.token(after: "Battery", in: message, upTo: "%"),
           let percent = Int(raw), (1...100).contains(percent) {
            let budStates = [accessory.left?.charging, accessory.right?.charging].compactMap { $0 }
            let charging: Bool? = budStates.isEmpty ? nil : budStates.allSatisfy { $0 }
            accessory.combined = .init(percent: percent, charging: charging)
        }

        // The same subsystem announces the Mac's own battery and any other
        // power source under this category. Keep only accessories: either the
        // line split out a component, or it says it is an audio device. A
        // combined level alone is not enough — the built-in battery has one.
        let hasComponents = accessory.left != nil || accessory.right != nil || accessory.caseLevel != nil
        return (hasComponents || LogText.isAudio(category: accessory.category))
            && accessory.hasAnyReading ? [accessory] : nil
    }

}

/// `BatteryCenter`'s `Found power source:` / `Found device:` records.
///
/// The message is a multi-line dictionary dump, so it is reassembled into
/// key/value pairs rather than pattern-matched. Two record shapes appear, and
/// **they do not share a schema**:
///
/// - `BCBatteryDevice` — one `;`-separated line with lowercase keys
///   (`percentCharge = 56; parts = left-right; charging = NO`).
/// - `Found power source:` — a `{ … }` block with `IOPSKeys`-style capitalized
///   keys (`"Current Capacity" = 56; "Is Charging" = 1; "Part Identifier" =
///   Right`).
///
/// So the lookup goes through a normalizer that ignores case, spaces and
/// hyphens, and each logical field is asked for under the names both shapes
/// use.
private enum BatteryCenterLogParser {
    static func parse(_ message: String) -> [AudioAccessoryMonitor.Accessory]? {
        let fields = message.contains("BCBatteryDevice")
            ? parseInline(message)
            : parseBlock(message)
        guard !fields.isEmpty else { return nil }

        func value(_ keys: String...) -> String? {
            for key in keys {
                if let found = fields[Self.normalize(key)], found != "(null)", !found.isEmpty {
                    return found
                }
            }
            return nil
        }

        // `Name` / `name` is the *accessory's* name; `Part Name` is a per-part
        // label and is not interchangeable. The per-part records carry
        // `Part Identifier = Right` with `Part Name = "大王的AirPods Pro 🅡"`,
        // while `Name` still holds the clean headset name. Reading `Part Name`
        // as the accessory name is what produced phantom accessories called
        // "… 🅛" / "… 🅡" that could never join their own body.
        guard let rawName = value("name") else { return nil }
        // The record's own `Name`, with any part label already removed: a
        // per-bud row names itself "大王的AirPods Pro 🅛", and that name must not
        // become the accessory's label or its identity.
        let name = LogText.strippingPartLabel(LogText.unescape(rawName))

        // Identity is the group the system itself uses: every record about one
        // headset — both buds, the combined row and the case — repeats the same
        // `matchIdentifier` / `accessoryIdentifier` UUID and the same `Name`.
        // Deriving the key from the name keeps this in step with the other two
        // sources, which only ever spell the name.
        //
        // The case is the one record whose `Name` is the *case's* localized name
        // ("大王的AirPods Pro充电盒"), so the suffix comes off before the key is
        // formed and the scope is added instead — otherwise the same headset
        // answered twice, once per source.
        let identifier = LogText.strippingPartLabel(LogText.strippingCaseSuffix(name))

        guard let rawCharge = value("percentCharge", "Current Capacity"),
              let percent = Int(rawCharge), (1...100).contains(percent) else { return nil }

        // The dump spells booleans YES/NO; it has also printed 1/0.
        let charging: Bool? = value("charging", "Is Charging").map {
            $0 == "YES" || $0 == "true" || $0 == "1"
        }

        // What the record covers, expressed differently by the two shapes:
        // `parts = case` / `parts = left-right`, or `Part Identifier = Case` /
        // `Left` / `Right` (in which case the record is one component, not the
        // whole accessory).
        let parts = value("parts") ?? ""
        let part = value("Part Identifier", "Part Name") ?? ""
        let category = value("Accessory Category", "accessoryCategory") ?? ""
        var accessory = AudioAccessoryMonitor.Accessory(id: identifier, name: name)
        accessory.category = category
        let reading = AudioAccessoryMonitor.Reading(percent: percent, charging: charging)

        // This subsystem also reports the Mac's own battery under the same
        // identifier domain, and it has a combined percentage just like the
        // buds do. `internal` / a non-Bluetooth transport is what separates
        // them; the per-part records (`Part Identifier = Left`) are always
        // accessories and skip the check.
        let transport = value("Transport Type", "transportType") ?? ""
        let isInternal = (value("internal") ?? "NO") == "YES" || transport.caseInsensitiveCompare("Internal") == .orderedSame
        let describesComponent = parts.contains("case") || parts.contains("left-right")
            || !part.isEmpty || LogText.isAudio(category: category)
        if isInternal && !describesComponent { return nil }

        // `parts` is the record's scope, and it is the field that decides which
        // slot a reading belongs in: `case`, `left-right` (the combined row), or
        // empty with a `Part Identifier` naming one bud. `accessoryCategory`
        // says `Headphone` even for the case record, so it cannot be the test.
        let isCaseRecord = parts.contains("case")
            || part.caseInsensitiveCompare("Case") == .orderedSame
            || category.lowercased().contains("battery case")

        if isCaseRecord {
            accessory.caseLevel = reading
            // The case is its own accessory on this side, so it gets its own
            // slot and `assemble()` re-attaches it to the body. Without the
            // split it would overwrite the body's name with the case's.
            accessory.id = "\(identifier)#case"
            accessory.nameIsCaseName = true
        } else if part.caseInsensitiveCompare("Left") == .orderedSame {
            accessory.left = reading
        } else if part.caseInsensitiveCompare("Right") == .orderedSame {
            accessory.right = reading
        } else {
            accessory.combined = reading
            // BatteryCenter collapses the buds into one percentage; the log
            // source is the only one that splits them, so leave them unset
            // rather than guessing both buds equal the combined value.
            if let left = value("leftPercentCharge"), let value = Int(left), (0...100).contains(value) {
                accessory.left = .init(percent: value, charging: charging)
            }
            if let right = value("rightPercentCharge"), let value = Int(right), (0...100).contains(value) {
                accessory.right = .init(percent: value, charging: charging)
            }
        }
        return accessory.hasAnyReading ? [accessory] : nil
    }

    /// `"Accessory Category"` / `accessoryCategory` / `Current Capacity` all
    /// collapse to the same lookup key.
    private static func normalize(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// `… productIdentifier = 8206; parts = left-right; identifier = …; name = 王夏军的MacBook Pro; percentCharge = 80; …`
    private static func parseInline(_ message: String) -> [String: String] {
        var fields: [String: String] = [:]
        guard let range = message.range(of: "BCBatteryDevice") else { return fields }
        for pair in message[range.upperBound...].components(separatedBy: ";") {
            let halves = pair.components(separatedBy: " = ")
            guard halves.count == 2 else { continue }
            fields[normalize(halves[0].trimmingCharacters(in: .whitespaces))] =
                halves[1].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    /// The `{ "Key" = value; … }` block shape, one pair per line.
    private static func parseBlock(_ message: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in message.components(separatedBy: .newlines) {
            let trimmed = line
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "{};"))
            let halves = trimmed.components(separatedBy: " = ")
            guard halves.count == 2 else { continue }
            let key = halves[0].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            fields[normalize(key)] = halves[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        return fields
    }
}

/// `system_profiler SPBluetoothDataType -json`, the public interface.
///
/// Only reachable devices appear under `device_connected`; each is a
/// single-key dictionary keyed by its display name, and the battery fields sit
/// inside. `device_batteryLevelMain` / `device_batteryLevel` cover the
/// single-cell devices (AirPods Max, most Beats).
private enum ProfilerSource {
    static func read() -> (accessories: [AudioAccessoryMonitor.Accessory], connectedNames: Set<String>)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        // Bounding the subprocess matters more than completeness here: this
        // runs on the polling queue and a wedged system_profiler would hold
        // the timer's queue indefinitely.
        process.arguments = ["SPBluetoothDataType", "-json", "-timeout", "3"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting so a large payload cannot deadlock on a full pipe.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let accessories = parse(data) else { return nil }
        return (accessories, ConnectionSource.parseConnected(data))
    }

    /// Split out from `read()` so the wire format can be tested without
    /// spawning anything.
    static func parse(_ data: Data) -> [AudioAccessoryMonitor.Accessory]? {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }

        var out: [AudioAccessoryMonitor.Accessory] = []
        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, raw) in entry {
                    guard let fields = raw as? [String: Any] else { continue }
                    out.append(contentsOf: accessory(name: name, fields: fields) ?? [])
                }
            }
        }
        return out
    }

    private static func accessory(name: String, fields: [String: Any]) -> [AudioAccessoryMonitor.Accessory]? {
        // **The profiler cannot key by MAC.** The log paths key a headset by
        // the system's accessory identifier (a UUID), because that is what
        // `bluetoothd` announces. This source only has the Bluetooth address, so
        // leaving it as the id made the same physical headset merge into two
        // rows — one per source — and the meter drew it twice. The name is the
        // one field all three sources agree on, so it is the join key.
        var accessory = AudioAccessoryMonitor.Accessory(id: name, name: name)
        accessory.category = fields["device_minorType"] as? String ?? ""
        if let raw = fields["device_productID"] as? String, raw.hasPrefix("0x") {
            accessory.productID = UInt16(raw.dropFirst(2), radix: 16)
        }
        accessory.left = reading(fields["device_batteryLevelLeft"],
                                 charging: fields["device_batteryLevelLeftCharging"])
        accessory.right = reading(fields["device_batteryLevelRight"],
                                  charging: fields["device_batteryLevelRightCharging"])
        accessory.caseLevel = reading(fields["device_batteryLevelCase"],
                                      charging: fields["device_batteryLevelCaseCharging"])
        accessory.combined = reading(fields["device_batteryLevelMain"] ?? fields["device_batteryLevel"],
                                     charging: fields["device_batteryLevelMainCharging"]
                                         ?? fields["device_batteryLevelCharging"])
        guard accessory.hasAnyReading else { return nil }

        // `system_profiler` hands back the whole headset at once, so the case
        // is a *field* here rather than its own announcement. Emitting it under
        // its own scoped key as well keeps this source consistent with the two
        // log sources, where the case is genuinely a separate record — one
        // shape coming out of `assemble()` regardless of which source answered.
        if accessory.caseLevel != nil {
            var box = AudioAccessoryMonitor.Accessory(id: "\(name)#case", name: name)
            box.caseLevel = accessory.caseLevel
            box.category = "Audio Battery Case"
            return [accessory, box]
        }
        return [accessory]
    }

    /// Values arrive as `"56 %"` — sometimes with a non-breaking space — and as
    /// plain integers depending on the build. The charging flag is a separate
    /// `"Yes"`/`"No"` string.
    private static func reading(_ raw: Any?, charging: Any? = nil) -> AudioAccessoryMonitor.Reading? {
        var percent: Int?
        if let number = raw as? NSNumber { percent = number.intValue }
        if let string = raw as? String { percent = Int(string.filter(\.isNumber)) }
        guard let value = percent, (0...100).contains(value) else { return nil }
        var flag: Bool?
        if let string = charging as? String {
            let normalized = string.lowercased()
            flag = normalized.contains("yes") || normalized.contains("true")
        } else if let number = charging as? NSNumber {
            flag = number.boolValue
        }
        return .init(percent: value, charging: flag)
    }
}
