import Foundation

/// Presentation values prepared off-main from an immutable usage window.
/// Ownership stays source-specific; ambiguous vendor names remain unassigned.
enum UsageProviderInventory {
    struct Owner: Equatable {
        let source: UsageSource
        let name: String
        let models: [String]
    }

    static func groups(sources: [UsageSource: [ModelUsage]], owners: [Owner],
                       officialCodex: [ModelUsage]) -> [UsageProviderGroup] {
        // Keyed by provider *name*, not id: the two stores hand out different
        // ids for the same vendor (`Provider.profileID` is what links them), and
        // all this needs is a stable label per bucket.
        var keys: [UsageSource: [String: Set<String>]] = [:]
        var canonicalNames: [String: String] = [:]
        func canonical(_ name: String) -> String {
            if let cached = canonicalNames[name] { return cached }
            let key = ModelPricing.canonical(name)
            canonicalNames[name] = key
            return key
        }
        for owner in owners {
            guard !Task.isCancelled else { return [] }
            for model in owner.models {
                keys[owner.source, default: [:]][canonical(model), default: []].insert(owner.name)
            }
        }
        /// Third-party traffic has no platform of its own, so it may be served
        /// by any vendor; a platform's own traffic only by that platform's.
        func candidates(for source: UsageSource, key: String) -> Set<String> {
            switch source {
            case .claude: return keys[.claude]?[key] ?? []
            case .codex: return keys[.codex]?[key] ?? []
            case .thirdParty: return (keys[.claude]?[key] ?? []).union(keys[.codex]?[key] ?? [])
            }
        }

        var grouped: [String: [String: ModelUsage]] = [:]
        func add(_ stat: ModelUsage, to name: String) {
            guard stat.totalTokens > 0 else { return }
            var model = grouped[name]?[stat.model] ?? ModelUsage(model: stat.model)
            model.merge(stat)
            grouped[name, default: [:]][stat.model] = model
        }
        let official = Dictionary(officialCodex.map { ($0.model, $0) }, uniquingKeysWith: { first, _ in first })
        for source in UsageSource.allCases {
            for stat in sources[source] ?? [] {
                guard !Task.isCancelled else { return [] }
                let parts = UsageProviderAttribution.split(stat, official: source == .codex ? official[stat.model] : nil)
                add(parts.official, to: "OpenAI 官方")
                let owners = candidates(for: source, key: canonical(stat.model))
                add(parts.remaining, to: owners.count == 1 ? (owners.first ?? "未归属") : "未归属")
            }
        }
        return grouped.map { name, models in
            UsageProviderGroup(name: name, models: models.values.sorted { $0.totalTokens == $1.totalTokens ? $0.model < $1.model : $0.totalTokens > $1.totalTokens })
        }
        .sorted { lhs, rhs in
            if lhs.name == "未归属" { return false }
            if rhs.name == "未归属" { return true }
            if lhs.total.totalTokens == rhs.total.totalTokens { return lhs.name < rhs.name }
            return lhs.total.totalTokens > rhs.total.totalTokens
        }
    }
}

struct UsageProviderGroup: Identifiable, Equatable {
    let name: String
    let models: [ModelUsage]
    var id: String { name }
    let total: ModelUsage

    init(name: String, models: [ModelUsage]) {
        self.name = name
        self.models = models
        total = models.reduce(into: ModelUsage(model: name)) { $0.merge($1) }
    }
}
