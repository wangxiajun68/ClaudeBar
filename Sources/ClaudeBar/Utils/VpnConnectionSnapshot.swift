import Foundation

/// Decode the entire controller payload off-main. No JSON dictionaries cross
/// back to the UI actor, including the old-core fallback totals loop.
struct VpnConnectionSnapshot: Sendable {
    let rows: [VpnDomainConnection]
    let activeCount: Int
    let totalUp: Int64
    let totalDown: Int64
    let hasRootTotals: Bool

    nonisolated static func decode(_ data: Data) -> Self? {
        guard !Task.isCancelled,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let connections = root["connections"] as? [[String: Any]] else { return nil }
        let rows = VpnDomainLog.preparedConnections(connections)
        guard !Task.isCancelled else { return nil }
        let hasRoot = root["downloadTotal"] != nil || root["uploadTotal"] != nil
        var up: Int64 = 0, down: Int64 = 0
        if hasRoot {
            up = max(0, JSONCoerce.int64Val(root["uploadTotal"]))
            down = max(0, JSONCoerce.int64Val(root["downloadTotal"]))
        } else {
            for connection in connections {
                if Task.isCancelled { return nil }
                up = VpnFormat.saturatingAdd(up, max(0, JSONCoerce.int64Val(connection["upload"])))
                down = VpnFormat.saturatingAdd(down, max(0, JSONCoerce.int64Val(connection["download"])))
            }
        }
        return .init(rows: rows, activeCount: connections.count,
                     totalUp: up, totalDown: down, hasRootTotals: hasRoot)
    }
}
