// Frozen pre-optimization family matching; oracle for routing and token conservation.
struct OriginalFamilyRollups {
    static func sessionFamilyRollups(source: UsageSource, ids: Set<String>, byPath: [String: [ModelUsage]],
                                     pathIDs: [String: String], parents: [String: String]) -> [String: [ModelUsage]] {
        var result: [String: [ModelUsage]] = [:]
        for id in ids {
            var rows: [ModelUsage] = []
            for (path, usage) in byPath {
                let belongs: Bool
                if source == .claude {
                    belongs = path.hasSuffix("/" + id + ".jsonl") || path.contains("/" + id + "/subagents/")
                } else {
                    var current = pathIDs[path]
                    var visited: Set<String> = []
                    var matched = path.hasSuffix("-" + id + ".jsonl")
                    while let child = current, visited.insert(child).inserted {
                        if child == id { matched = true; break }
                        current = parents[child]
                    }
                    belongs = matched
                }
                if belongs { rows += usage }
            }
            result[id] = ModelUsage.merged(rows).filter { $0.totalTokens > 0 }.sorted { $0.totalTokens > $1.totalTokens }
        }
        return result
    }
}
