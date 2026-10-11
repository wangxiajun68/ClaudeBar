import Foundation

/// Lifetime recorded usage, including descendants, distinct from context fill.
struct SessionUsageSummary: Equatable {
    struct Request: Hashable {
        let source: UsageSource
        let sessionId: String
    }

    let input: Int
    let output: Int
    let cache: Int
    let cost: ModelPricing.Estimate
    var total: Int { input + output + cache }

    init(days: [String: [ModelUsage]]) {
        let rows = days.values.flatMap { $0 }
        input = rows.reduce(0) { $0 + $1.inputTokens }
        output = rows.reduce(0) { $0 + $1.outputTokens }
        cache = rows.reduce(0) { $0 + $1.cacheReadTokens + $1.cacheCreationTokens }
        cost = ModelPricing.estimate(days: days)
    }

    /// Run off the main actor; one indexed snapshot per client, no rescanning.
    static func fetch(_ requests: [Request]) -> [Request: SessionUsageSummary] {
        guard BuildChannel.allowsSystemIntegration else { return [:] }
        var result: [Request: SessionUsageSummary] = [:]
        for (source, group) in Dictionary(grouping: Set(requests), by: \.source) where source != .thirdParty {
            let families = UsageIndex.fetchSessionDailyFamilies(source: source, sessionIds: group.map(\.sessionId))
            for request in group {
                let days = families[request.sessionId] ?? [:]
                let summary = SessionUsageSummary(days: days)
                if summary.total > 0 { result[request] = summary }
            }
        }
        return result
    }
}
