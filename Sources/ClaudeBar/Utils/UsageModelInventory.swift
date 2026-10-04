import Foundation

/// All recorded models, independent of provider configuration or list limits.
/// Cursor's window totals remain separate from the selected local period.
enum UsageModelInventory {
    struct Row: Identifiable, Equatable {
        let id: String
        var local: ModelUsage
        var cursor: ModelUsage?
        var sourceTokens: [UsageSource: Int] = [:]
        var recordedNames: Set<String> = []
        var costLine: ModelPricing.Estimate.Line?

        var hasLocal: Bool { !local.isZero }
        var displayed: ModelUsage { hasLocal ? local : (cursor ?? local) }
    }

    static func rows(local: [ModelUsage], sources: [UsageSource: [ModelUsage]],
                     cursor: [ModelUsage], costs: [String: ModelPricing.Estimate.Line]) -> [Row] {
        guard !Task.isCancelled else { return [] }
        var inventory: [String: Row] = [:]
        var tokensByName: [String: Int] = [:]
        // Local totals, source totals and Cursor often repeat the same names.
        // Canonicalization uses regexes; run it only once per distinct raw name.
        var canonicalNames: [String: String] = [:]
        func key(_ name: String) -> String {
            if let cached = canonicalNames[name] { return cached }
            let canonical = ModelPricing.canonical(name)
            let id = canonical.isEmpty ? "unknown" : canonical
            canonicalNames[name] = id
            return id
        }
        for stat in local where !stat.isZero {
            guard !Task.isCancelled else { return [] }
            let id = key(stat.model)
            tokensByName[stat.model, default: 0] += stat.totalTokens
            var row = inventory[id] ?? Row(id: id, local: ModelUsage(model: id))
            row.local.merge(stat)
            row.recordedNames.insert(stat.model)
            inventory[id] = row
        }
        for (source, models) in sources {
            for stat in models {
                guard !Task.isCancelled else { return [] }
                let id = key(stat.model)
                guard var row = inventory[id] else { continue }
                row.sourceTokens[source, default: 0] += stat.totalTokens
                inventory[id] = row
            }
        }
        for stat in cursor {
            guard !Task.isCancelled else { return [] }
            let id = key(stat.model)
            var row = inventory[id] ?? Row(id: id, local: ModelUsage(model: id))
            var usage = row.cursor ?? ModelUsage(model: id)
            usage.merge(stat)
            row.cursor = usage
            inventory[id] = row
        }
        for id in inventory.keys {
            guard !Task.isCancelled else { return [] }
            guard var row = inventory[id], row.hasLocal else { continue }
            let lines = row.recordedNames.sorted().compactMap { costs[$0] }
            var cost = ModelPricing.Cost()
            var missing = 0
            var reason: ModelPricing.Unpriced?
            for line in lines {
                guard !Task.isCancelled else { return [] }
                cost.cny += line.cost.cny
                cost.usd += line.cost.usd
                missing += line.unpricedTokens
                if let unpriced = line.unpriced { reason = unpriced }
            }
            // A missing cost snapshot must not turn an alias into free usage.
            for name in row.recordedNames where costs[name] == nil {
                guard !Task.isCancelled else { return [] }
                missing += tokensByName[name] ?? 0
                reason = .unknownSlug
            }
            row.costLine = .init(model: id, cost: cost, unpriced: reason, unpricedTokens: missing)
            inventory[id] = row
        }
        return inventory.values.sorted {
            let lhs = max($0.local.totalTokens, $0.cursor?.totalTokens ?? 0)
            let rhs = max($1.local.totalTokens, $1.cursor?.totalTokens ?? 0)
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }
}
