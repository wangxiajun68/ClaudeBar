import Foundation
import Combine

/// The desktop toy owns only its bundle-isolated preferences. Automatic
/// striking is deliberately session-only: relaunching never starts audio.
@MainActor
final class WoodenFishModel: ObservableObject {
    static let shared = WoodenFishModel()
    private let defaults: UserDefaults
    private var day: String

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "woodenFishEnabled") } }
    @Published var muted: Bool { didSet { defaults.set(muted, forKey: "woodenFishMuted") } }
    @Published var volume: Double {
        didSet { defaults.set(volume, forKey: "woodenFishVolume") }
    }
    @Published var interval: Double {
        didSet { defaults.set(interval, forKey: "woodenFishInterval") }
    }
    @Published var size: WoodenFishSize {
        didSet { defaults.set(size.rawValue, forKey: "woodenFishSize") }
    }
    @Published var isAutomatic = false
    @Published private(set) var today: Int
    @Published private(set) var total: Int
    @Published private(set) var strikeID: UInt = 0
    @Published var soundAvailable = true

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        day = Self.dayKey(now)
        enabled = defaults.bool(forKey: "woodenFishEnabled")
        muted = defaults.bool(forKey: "woodenFishMuted")
        let savedVolume = defaults.object(forKey: "woodenFishVolume") as? Double ?? 0.55
        volume = savedVolume.isFinite ? min(1, max(0, savedVolume)) : 0.55
        let savedInterval = defaults.double(forKey: "woodenFishInterval")
        interval = Self.intervals.contains(savedInterval) ? savedInterval : 1
        size = WoodenFishSize(rawValue: defaults.string(forKey: "woodenFishSize") ?? "") ?? .regular
        let counts = defaults.dictionary(forKey: "woodenFishCounts") ?? [:]
        let savedTotal = max(0, counts["total"] as? Int ?? 0)
        total = savedTotal
        today = counts["day"] as? String == day ? min(savedTotal, max(0, counts["today"] as? Int ?? 0)) : 0
    }

    static let intervals: [Double] = [0.5, 1, 2, 3]

    func strike(at now: Date = Date()) {
        refreshDay(at: now)
        if total < Int.max { total += 1 }
        if today < total { today += 1 }
        strikeID &+= 1
        saveCounts()
    }

    func refreshDay(at now: Date = Date()) {
        let newDay = Self.dayKey(now)
        guard newDay != day else { return }
        day = newDay
        today = 0
        saveCounts()
    }

    func resetCounts(at now: Date = Date()) {
        day = Self.dayKey(now)
        today = 0
        total = 0
        saveCounts()
    }

    var savedOrigin: CGPoint? {
        guard let values = defaults.array(forKey: "woodenFishOrigin") as? [Double],
              values.count == 2, values.allSatisfy(\.isFinite) else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }

    func saveOrigin(_ origin: CGPoint) {
        guard origin.x.isFinite, origin.y.isFinite else { return }
        defaults.set([Double(origin.x), Double(origin.y)], forKey: "woodenFishOrigin")
    }

    private func saveCounts() {
        defaults.set(["day": day, "today": today, "total": total], forKey: "woodenFishCounts")
    }

    private static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.era, .year, .month, .day], from: date)
        return "\(components.era ?? 0)-\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
}

enum WoodenFishSize: String, CaseIterable, Identifiable {
    case small, regular, large
    var id: String { rawValue }
    var label: String {
        switch self { case .small: return "小巧"; case .regular: return "标准"; case .large: return "大号" }
    }
    var scale: CGFloat {
        switch self { case .small: return 0.85; case .regular: return 1; case .large: return 1.2 }
    }
    var panelSize: CGSize { CGSize(width: 260 * scale, height: 330 * scale) }
}

enum WoodenFishPlacement {
    /// Keep the entire grip and controls reachable after monitor removal,
    /// resolution changes, or restoring a position on another display.
    static func frame(origin: CGPoint?, size: CGSize, screens: [CGRect]) -> CGRect {
        guard let first = screens.first else { return CGRect(origin: .zero, size: size) }
        let proposed = origin ?? CGPoint(x: first.maxX - size.width - 28, y: first.minY + 32)
        let center = CGPoint(x: proposed.x + size.width / 2, y: proposed.y + size.height / 2)
        let screen = screens.min { distance(center, $0) < distance(center, $1) } ?? first
        return CGRect(x: min(max(proposed.x, screen.minX), max(screen.minX, screen.maxX - size.width)),
                      y: min(max(proposed.y, screen.minY), max(screen.minY, screen.maxY - size.height)),
                      width: size.width, height: size.height)
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
