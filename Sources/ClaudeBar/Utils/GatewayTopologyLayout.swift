import CoreGraphics
import Foundation

/// Bounded presentation geometry shared by the native map and its probes.
/// The three task tiers retain their coordinates when a request arrives.
enum GatewayTopologyLayout {
    struct Geometry: Equatable {
        var source: CGRect
        var tiers: [CGRect]
        var models: [CGRect]
        var size: CGSize
    }

    static func geometry(width: CGFloat, count: Int) -> Geometry {
        let width = max(320, width)
        let compact = width < 520
        let count = max(1, min(9, count))
        if compact {
            let height = 212 + CGFloat(count) * 78
            return .init(source: CGRect(x: (width - 156) / 2, y: 8, width: 156, height: 56),
                tiers: (0..<3).map { CGRect(x: CGFloat($0) * width / 3 + 8, y: 106, width: width / 3 - 16, height: 62) },
                models: (0..<count).map { CGRect(x: 44, y: 212 + CGFloat($0) * 78, width: width - 60, height: 64) },
                size: CGSize(width: width, height: height))
        }
        let height = max(294, CGFloat(count) * 78 + 8)
        let sourceWidth: CGFloat = width < 660 ? 80 : 106
        let tierX = sourceWidth + 48
        let tierWidth: CGFloat = width < 660 ? 108 : 130
        let modelX = tierX + tierWidth + 60
        return .init(source: CGRect(x: 12, y: height / 2 - 36, width: sourceWidth, height: 72),
            tiers: (0..<3).map { CGRect(x: tierX, y: height / 2 - 118 + CGFloat($0) * 94, width: tierWidth, height: 68) },
            models: (0..<count).map { CGRect(x: modelX, y: (height - CGFloat(count) * 78) / 2 + CGFloat($0) * 78 + 7, width: width - modelX - 12, height: 64) },
            size: CGSize(width: width, height: height))
    }

    /// Pin actual live endpoints (up to admission's eight requests), retain two recent completions, then the
    /// selected model, then a page of the pool. Never draw all 200 endpoints.
    static func visibleIDs(members: [FreeModelPool.Member], flights: [FreeModelGateway.Flight],
                           selected: String?, page: Int, pageSize: Int = 5) -> [String] {
        let available = Set(members.map(\.id))
        var ids: [String] = []
        func append(_ id: String) { if available.contains(id), !ids.contains(id), ids.count < 9 { ids.append(id) } }
        for flight in flights where flight.phase.isActive { append(flight.memberID) }
        for flight in flights.prefix(2) where !flight.phase.isActive { append(flight.memberID) }
        if let selected { append(selected) }
        let start = min(max(0, page) * pageSize, members.count)
        for member in members.dropFirst(start).prefix(pageSize) { append(member.id) }
        let pinned = Set(ids)
        return members.map(\.id).filter { pinned.contains($0) }
    }
}
