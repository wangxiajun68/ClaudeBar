import Foundation

extension ProviderStore {
    // MARK: - Session derivation (single source of truth)
    // Views read these derived values instead of recomputing counts, so the
    // filtering rules cannot drift between screens.

    /// Alive Claude Code sessions.
    var aliveSessions: [SessionInfo] { sessions.filter(\.isAlive) }

    /// Alive sessions currently busy.
    var busySessionCount: Int { aliveSessions.filter { $0.status == .busy }.count }

    /// Alive Cursor sessions.
    var aliveCursorSessions: [CursorSessionInfo] { cursorSessions }

    /// Cursor sessions currently active.
    var activeCursorCount: Int { cursorSessions.filter { $0.status == .active }.count }

    /// Is any Claude session busy (drives brand pulse / status icon).
    var anyClaudeBusy: Bool { sessions.contains { $0.isAlive && $0.status == .busy } }

    /// Visible Codex sessions (unarchived main threads when indexed).
    var aliveExternalSessions: [ExternalSessionInfo] { externalSessions.filter(\.isAlive) }

    /// External sessions currently mid-turn.
    var activeExternalCount: Int { externalSessions.filter(\.isActive).count }

    /// Any external session busy.
    var anyExternalBusy: Bool { externalSessions.contains { $0.isActive } }

    /// One node of the Codex session tree: a user session plus the sub-agents
    /// it spawned (recursively, though Codex currently only nests one level).
    struct ExternalSessionNode: Identifiable {
        var id: String { session.id }
        let session: ExternalSessionInfo
        let depth: Int
        let children: [ExternalSessionNode]
        /// This node's session plus every descendant's, in pre-order.
        ///
        /// Stored, not computed: the tree is already cached per kind, and this
        /// used to be `[self] + children.flatMap(\.flattened)` evaluated on
        /// every access from `body` — a fresh `O(subtree)` allocation per node,
        /// per call, so a wide tree cost `O(n²)` per render.
        let flattened: [ExternalSessionInfo]

        /// How many descendants are mid-turn. Counted once at build time so a
        /// page that only needs the number does not allocate the descendant
        /// array to count it (see `SessionsView`).
        let activeDescendantCount: Int

        init(session: ExternalSessionInfo, depth: Int, children: [ExternalSessionNode]) {
            self.session = session
            self.depth = depth
            self.children = children
            self.flattened = [session] + children.flatMap(\.flattened)
            self.activeDescendantCount = children.reduce(0) {
                $0 + $1.activeDescendantCount + ($1.session.isActive ? 1 : 0)
            }
        }

        /// Every sub-agent below this node, at any depth.
        var descendantCount: Int { flattened.count - 1 }
    }

    /// Visible main threads, including idle unarchived Codex tasks. Helpers
    /// are never promoted to main cards; any supplied active children stay
    /// attached to their parent.
    func externalSessionTree(kind: ExternalAgentKind) -> [ExternalSessionNode] {
        if let cached = externalTreeCache[kind] { return cached }
        let alive = externalSessions.filter { $0.kind == kind && $0.isAlive }
        var childrenOf: [String: [ExternalSessionInfo]] = [:]
        for session in alive where session.isSubagent {
            if let parent = session.parentThreadId { childrenOf[parent, default: []].append(session) }
        }
        func roots() -> [ExternalSessionInfo] {
            // Orphaned or completed helpers must never become main cards.
            alive.filter { !$0.isSubagent }
        }
        func build(_ session: ExternalSessionInfo, depth: Int, ancestors: Set<String> = []) -> ExternalSessionNode {
            let visited = ancestors.union([session.sessionId])
            let children = (childrenOf[session.sessionId] ?? [])
                .filter { $0.isActive && !visited.contains($0.sessionId) }
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { build($0, depth: depth + 1, ancestors: visited) }
            return ExternalSessionNode(session: session, depth: depth, children: children)
        }
        let result = roots()
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { build($0, depth: 0) }
        externalTreeCache[kind] = result
        return result
    }

    // MARK: - Usage derivation

    /// Total tokens for the current period — the one reduce.
    var totalUsageTokens: Int { usageStats.reduce(0) { $0 + $1.totalTokens } }

    /// Formatted total ("12.3K").
    var totalUsageLabel: String { UsageStats.formatTokens(totalUsageTokens) }

    /// Max per-model total in the current period (bar scale denominator).
    var maxUsageTokens: Int { max(usageStats.first?.totalTokens ?? 1, 1) }

    /// Per-model origin breakdown for the ring popover, in a fixed source
    /// order so CC / Codex / 第三方 keep their color and row position.
    /// `usageTokensByModel` is keyed by model name; models that only appear in
    /// one source get zeroed slices for the others.
    func usageSourceSlices(for stat: ModelUsage) -> [SourceRing.Slice] {
        let slices = UsageSource.allCases.map { source in
            SourceRing.Slice(label: source.label,
                             value: usageTokensByModel[source]?[stat.model] ?? 0,
                             color: source.color)
        }
        return slices.contains { $0.value > 0 } ? slices : []
    }

    /// Totals per source for the whole period — the river's legend and the
    /// popup total line.
    var usageTotalBySource: [(source: UsageSource, tokens: Int)] {
        UsageSource.allCases.map { source in
            (source, (usageBySource[source] ?? []).reduce(0) { $0 + $1.totalTokens })
        }
    }

    /// Estimated list-price spend for the selected period.
    ///
    /// Derived from `usageStats`, which is already the period's per-model
    /// rollup — so this moves with the period chips for free. The estimate is
    /// computed once in `publishUsage` (alongside `usageCostLines`) rather than
    /// per read: `ModelPricing.estimate` canonicalises every model slug — two
    /// regex compilations per model — and it was being re-run from `body` on
    /// every publish and every animation frame. The app never sees an invoice
    /// (subscriptions are not metered, relays do not return cost), so this is
    /// explicitly an estimate at published API prices; `ModelPricing` owns the
    /// table and the caveats.
    var costEstimate: ModelPricing.Estimate { usageEstimate }

    /// The price of one model, for a usage tile. A dictionary hit — the
    /// estimate's lines are rebuilt with `usageStats`, not per call.
    func costLine(for model: String) -> ModelPricing.Estimate.Line? { usageCostLines[model] }

    // MARK: - Active provider

    /// The currently active provider, if any.
    var activeProvider: Provider? { providers.first { $0.id == activeProviderID } }

    /// Its active model, if any.
    var activeModel: ModelConfig? { activeProvider?.activeModel }
}
