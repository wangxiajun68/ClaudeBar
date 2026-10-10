import Foundation
import Combine

/// Root counters cover every connection seen by the core. Route and domain
/// counters are sampled separately and may miss a connection between polls.
struct VpnTrafficAmounts: Codable, Equatable, Sendable {
    var upload: Int64 = 0
    var download: Int64 = 0
    var total: Int64 { VpnFormat.saturatingAdd(upload, download) }
    mutating func add(_ other: Self) {
        upload = VpnFormat.saturatingAdd(upload, other.upload)
        download = VpnFormat.saturatingAdd(download, other.download)
    }
    func delta(after old: Self) -> Self {
        .init(upload: max(0, upload - old.upload), download: max(0, download - old.download))
    }
}

struct VpnTrafficSplit: Codable, Equatable, Sendable {
    var core = VpnTrafficAmounts()
    var proxied = VpnTrafficAmounts()
    var direct = VpnTrafficAmounts()
    var unclassified: VpnTrafficAmounts {
        .init(upload: max(0, core.upload - VpnFormat.saturatingAdd(proxied.upload, direct.upload)),
              download: max(0, core.download - VpnFormat.saturatingAdd(proxied.download, direct.download)))
    }
    mutating func add(_ other: Self) {
        core.add(other.core); proxied.add(other.proxied); direct.add(other.direct)
    }
}

enum VpnTrafficPeriod: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "今天"
        case .week: return "7 天"
        case .month: return "30 天"
        case .all: return "全部"
        }
    }
}

struct VpnTrafficPoint: Identifiable, Sendable {
    var date: Date
    var traffic: VpnTrafficSplit
    var id: Date { date }
}

struct VpnTrafficDomain: Identifiable, Sendable {
    var host: String
    var traffic: VpnTrafficSplit
    var id: String { host }
    var total: Int64 { VpnFormat.saturatingAdd(traffic.proxied.total, traffic.direct.total) }
}

struct VpnTrafficActivity: Identifiable, Sendable {
    var day: Date
    var hour: Int
    var bytes: Int64
    var id: String { "\(day.timeIntervalSince1970)-\(hour)" }
}

struct VpnTrafficReport: Sendable {
    var totals = VpnTrafficSplit()
    var lifetime = VpnTrafficSplit()
    var points: [VpnTrafficPoint] = []
    var domains: [VpnTrafficDomain] = []
    var proxyRanking: [VpnTrafficDomain] = []
    var directRanking: [VpnTrafficDomain] = []
    var proxyDomainCount = 0
    var directDomainCount = 0
    var activity: [VpnTrafficActivity] = []
    var startedAt: Date?
    var updatedAt: Date?
    var periodStart: Date?
    var peak: VpnTrafficPoint? { points.max { $0.traffic.core.total < $1.traffic.core.total } }
}

/// Daily aggregates are never evicted by the diagnostic ring. Hourly detail
/// is retained for 31 days; older totals and domain aggregates remain daily.
struct VpnTrafficLedger: Codable, Sendable {
    var version = 1
    var startedAt: Date?
    var updatedAt: Date?
    var days: [String: VpnTrafficSplit] = [:]
    var hours: [String: VpnTrafficSplit] = [:]
    var domains: [String: [String: VpnTrafficSplit]] = [:]

    mutating func record(_ delta: VpnTrafficSplit, hosts: [String: VpnTrafficSplit],
                         at date: Date) {
        guard delta != VpnTrafficSplit() || !hosts.isEmpty else { return }
        if startedAt == nil { startedAt = date }
        updatedAt = date
        let day = Self.dayKey(date)
        days[day, default: .init()].add(delta)
        let hour = String(Int64(Calendar.current.dateInterval(of: .hour, for: date)!.start.timeIntervalSince1970))
        hours[hour, default: .init()].add(delta)
        for (host, traffic) in hosts {
            domains[day, default: [:]][host, default: .init()].add(traffic)
        }
        let oldest = Int64(date.addingTimeInterval(-31 * 86400).timeIntervalSince1970)
        hours = hours.filter { (Int64($0.key) ?? .min) >= oldest }
    }

    static func dayKey(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    static func dayDate(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Local day labels stay stable across launches. Hourly detail uses absolute
    /// timestamps, so daylight-saving transitions retain distinct hours.
    func report(period: VpnTrafficPeriod, now: Date, calendar: Calendar = .current) -> VpnTrafficReport {
        let today = calendar.startOfDay(for: now)
        let start: Date
        switch period {
        case .today: start = today
        case .week: start = calendar.date(byAdding: .day, value: -6, to: today)!
        case .month: start = calendar.date(byAdding: .day, value: -29, to: today)!
        case .all: start = startedAt.map { calendar.startOfDay(for: $0) } ?? today
        }
        var result = VpnTrafficReport(startedAt: startedAt, updatedAt: updatedAt, periodStart: start)
        for value in days.values { result.lifetime.add(value) }
        let useHours = period == .today
        var points: [Date: VpnTrafficSplit] = [:]
        if useHours {
            for (key, value) in hours {
                guard let hour = Int64(key) else { continue }
                let date = Date(timeIntervalSince1970: Double(hour))
                guard date >= start, date <= now else { continue }
                points[date, default: .init()].add(value)
            }
        } else {
            for (key, value) in days {
                guard let date = Self.dayDate(key), date >= start, date <= now else { continue }
                let localDay = calendar.startOfDay(for: date)
                guard localDay >= start else { continue }
                points[localDay, default: .init()].add(value)
            }
        }
        // All-time charts use months after 90 days, without dropping bytes.
        let monthly = period == .all && (calendar.dateComponents([.day], from: start, to: today).day ?? 0) > 90
        if monthly {
            var months: [Date: VpnTrafficSplit] = [:]
            for (date, value) in points {
                let month = calendar.dateInterval(of: .month, for: date)!.start
                months[month, default: .init()].add(value)
            }
            points = months
        }
        let component: Calendar.Component = useHours ? .hour : monthly ? .month : .day
        var cursor = monthly ? calendar.dateInterval(of: .month, for: start)!.start : start
        // Empty buckets preserve time spacing. DST days contain 23/25 hours.
        while cursor <= now {
            let value = points[cursor] ?? .init()
            result.points.append(.init(date: cursor, traffic: value))
            result.totals.add(value)
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        if period == .all { result.totals = result.lifetime }
        var hosts: [String: VpnTrafficSplit] = [:]
        for (day, values) in domains {
            guard let date = Self.dayDate(day) else { continue }
            let localDay = calendar.startOfDay(for: date)
            guard localDay >= start, localDay <= today else { continue }
            for (host, traffic) in values { hosts[host, default: .init()].add(traffic) }
        }
        result.domains = hosts.map { .init(host: $0.key, traffic: $0.value) }
            .sorted { $0.total == $1.total ? $0.host < $1.host : $0.total > $1.total }
        let proxy = result.domains.filter { $0.traffic.proxied.total > 0 }
        let direct = result.domains.filter { $0.traffic.direct.total > 0 }
        result.proxyDomainCount = proxy.count
        result.directDomainCount = direct.count
        result.proxyRanking = Array(proxy.sorted {
            $0.traffic.proxied.total == $1.traffic.proxied.total ? $0.host < $1.host : $0.traffic.proxied.total > $1.traffic.proxied.total
        }.prefix(20))
        result.directRanking = Array(direct.sorted {
            $0.traffic.direct.total == $1.traffic.direct.total ? $0.host < $1.host : $0.traffic.direct.total > $1.traffic.direct.total
        }.prefix(20))
        let activityStart = max(start, calendar.date(byAdding: .day, value: -6, to: today)!)
        var activityByDay: [Date: [Int: Int64]] = [:]
        for (key, traffic) in hours {
            guard let timestamp = Double(key) else { continue }
            let date = Date(timeIntervalSince1970: timestamp)
            guard date >= activityStart, date <= now else { continue }
            let day = calendar.startOfDay(for: date)
            let hour = calendar.component(.hour, from: date)
            activityByDay[day, default: [:]][hour] = VpnFormat.saturatingAdd(
                activityByDay[day]?[hour] ?? 0, traffic.core.total)
        }
        var activityDay = activityStart
        while activityDay <= today {
            for hour in 0..<24 {
                result.activity.append(.init(day: activityDay, hour: hour, bytes: activityByDay[activityDay]?[hour] ?? 0))
            }
            activityDay = calendar.date(byAdding: .day, value: 1, to: activityDay)!
        }
        return result
    }
}

/// Separate baselines make log clear and ring eviction irrelevant to history.
struct VpnTrafficHistorySampler {
    private var previous: [String: VpnDomainConnection] = [:]
    private var previousRoot = VpnTrafficAmounts()
    private var hasRootTotals = false

    mutating func beginCoreSession() {
        previous.removeAll(keepingCapacity: true)
        previousRoot = .init()
        hasRootTotals = false
    }

    mutating func sample(_ connections: [VpnDomainConnection], root: VpnTrafficAmounts?)
        -> (traffic: VpnTrafficSplit, hosts: [String: VpnTrafficSplit]) {
        var delta = VpnTrafficSplit()
        var hosts: [String: VpnTrafficSplit] = [:]
        var next: [String: VpnDomainConnection] = [:]
        for connection in connections {
            guard next[connection.id] == nil else { continue }
            let old = previous[connection.id]
            next[connection.id] = VpnDomainConnection(
                id: connection.id, endpoint: connection.endpoint, process: connection.process,
                route: connection.route, rule: connection.rule, outbound: connection.outbound,
                upload: max(0, connection.upload, old?.upload ?? 0),
                download: max(0, connection.download, old?.download ?? 0))
            guard connection.route != .reject else { continue }
            let bytes = VpnTrafficAmounts(upload: max(0, connection.upload), download: max(0, connection.download))
                .delta(after: .init(upload: max(0, old?.upload ?? 0), download: max(0, old?.download ?? 0)))
            guard bytes.total > 0 else { continue }
            if connection.route == .proxied {
                delta.proxied.add(bytes)
                hosts[connection.host, default: .init()].proxied.add(bytes)
            } else {
                delta.direct.add(bytes)
                hosts[connection.host, default: .init()].direct.add(bytes)
            }
        }
        previous = next
        if let root {
            hasRootTotals = true
            let clean = VpnTrafficAmounts(upload: max(0, root.upload), download: max(0, root.download))
            delta.core = clean.delta(after: previousRoot)
            previousRoot.upload = max(previousRoot.upload, clean.upload)
            previousRoot.download = max(previousRoot.download, clean.download)
        } else if !hasRootTotals {
            // Older cores without root counters can only offer sampled totals.
            delta.core.add(delta.proxied); delta.core.add(delta.direct)
            previousRoot.add(delta.core)
        }
        return (delta, hosts)
    }
}

/// One atomic file per day bounds write cost independently of archive age.
struct VpnTrafficArchiveDay: Codable, Sendable {
    var version = 1
    var day: String
    var totals: VpnTrafficSplit
    var hours: [String: VpnTrafficSplit]
    var domains: [String: VpnTrafficSplit]
    var firstRecord: Date
    var lastRecord: Date
}

/// All loading, aggregation and atomic writes execute off the main actor.
/// A damaged/unknown archive is retained; recovery requires explicit deletion.
actor VpnTrafficHistoryArchive {
    private let url: URL
    private var ledger = VpnTrafficLedger()
    private var sampler = VpnTrafficHistorySampler()
    private var loaded = false
    private var loadFailure: String?
    private var dirtyDays: Set<String> = []
    private var firstRecordByDay: [String: Date] = [:]
    private var lastRecordByDay: [String: Date] = [:]
    init(url: URL) { self.url = url }

    private func load() throws {
        if loaded {
            if let loadFailure { throw NSError(domain: "VPN 流量历史", code: 1, userInfo: [NSLocalizedDescriptionKey: loadFailure]) }
            return
        }
        loaded = true
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            var restored = VpnTrafficLedger()
            let oldest = Date().addingTimeInterval(-31 * 86400).timeIntervalSince1970
            for file in files where file.pathExtension == "json" {
                let day = try JSONDecoder().decode(VpnTrafficArchiveDay.self, from: Data(contentsOf: file))
                let splits = [day.totals] + Array(day.hours.values) + Array(day.domains.values)
                guard day.version == 1, day.day == file.deletingPathExtension().lastPathComponent,
                      VpnTrafficLedger.dayDate(day.day) != nil,
                      splits.allSatisfy({ split in
                          [split.core, split.proxied, split.direct].allSatisfy { $0.upload >= 0 && $0.download >= 0 }
                      }) else { throw CocoaError(.coderReadCorrupt) }
                restored.days[day.day] = day.totals
                restored.domains[day.day] = day.domains
                for (hour, value) in day.hours where Double(hour).map({ $0 >= oldest }) == true {
                    restored.hours[hour] = value
                }
                firstRecordByDay[day.day] = day.firstRecord
                lastRecordByDay[day.day] = day.lastRecord
                restored.startedAt = min(restored.startedAt ?? day.firstRecord, day.firstRecord)
                restored.updatedAt = max(restored.updatedAt ?? day.lastRecord, day.lastRecord)
            }
            ledger = restored
        } catch {
            loadFailure = "历史文件无法读取，已保留原文件。请备份后清除历史以重新开始。"
            throw error
        }
    }

    func beginCoreSession() { sampler.beginCoreSession() }

    func record(_ connections: [VpnDomainConnection], root: VpnTrafficAmounts?, at date: Date) throws -> Bool {
        try load()
        let delta = sampler.sample(connections, root: root)
        if delta.traffic != VpnTrafficSplit() || !delta.hosts.isEmpty {
            ledger.record(delta.traffic, hosts: delta.hosts, at: date)
            let day = VpnTrafficLedger.dayKey(date)
            firstRecordByDay[day] = min(firstRecordByDay[day] ?? date, date)
            lastRecordByDay[day] = max(lastRecordByDay[day] ?? date, date)
            dirtyDays.insert(day)
        }
        guard !dirtyDays.isEmpty else { return false }
        try save()
        return true
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for day in dirtyDays.sorted() {
            let hours = ledger.hours.filter { key, _ in
                guard let timestamp = Double(key) else { return false }
                return VpnTrafficLedger.dayKey(Date(timeIntervalSince1970: timestamp)) == day
            }
            let record = VpnTrafficArchiveDay(day: day, totals: ledger.days[day] ?? .init(),
                hours: hours, domains: ledger.domains[day] ?? [:],
                firstRecord: firstRecordByDay[day]!, lastRecord: lastRecordByDay[day]!)
            try PrivateFileWriter.write(JSONEncoder().encode(record), to: url.appendingPathComponent(day + ".json"))
            dirtyDays.remove(day)
        }
    }

    func report(period: VpnTrafficPeriod, now: Date) throws -> VpnTrafficReport {
        try load()
        return ledger.report(period: period, now: now)
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        ledger = .init()
        loaded = true
        loadFailure = nil
        dirtyDays.removeAll()
        firstRecordByDay.removeAll()
        lastRecordByDay.removeAll()
        // Keep live baselines: clearing must not recount the same bytes.
    }
}

@MainActor
final class VpnTrafficHistory: ObservableObject {
    static let shared = VpnTrafficHistory()
    @Published private(set) var revision = 0
    @Published private(set) var storageError: String?
    private let archive: VpnTrafficHistoryArchive
    private var sessionNeedsReset = true
    private init() {
        archive = VpnTrafficHistoryArchive(url: FilePaths.vpnDir.appendingPathComponent("traffic-history", isDirectory: true))
    }
    func beginCoreSession() { sessionNeedsReset = true }
    func record(_ connections: [VpnDomainConnection], root: VpnTrafficAmounts?, at date: Date = Date()) async {
        do {
            if sessionNeedsReset {
                sessionNeedsReset = false
                await archive.beginCoreSession()
            }
            if try await archive.record(connections, root: root, at: date) { revision &+= 1 }
            storageError = nil
        } catch { storageError = "流量历史未能保存：\(error.localizedDescription)" }
    }
    func report(period: VpnTrafficPeriod) async -> VpnTrafficReport? {
        do { let result = try await archive.report(period: period, now: Date()); storageError = nil; return result }
        catch { storageError = "流量历史未能读取：\(error.localizedDescription)"; return nil }
    }
    func clear() async {
        do { try await archive.clear(); storageError = nil; revision &+= 1 }
        catch { storageError = "流量历史未能清除：\(error.localizedDescription)" }
    }
}
