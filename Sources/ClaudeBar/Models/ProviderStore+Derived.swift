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

    /// Codex sessions currently alive.
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

        /// Every sub-agent below this node, at any depth.
        var descendantCount: Int {
            children.reduce(0) { $0 + 1 + $1.descendantCount }
        }

        /// Nodes in pre-order — what the flat tree list renders.
        var flattened: [ExternalSessionNode] {
            [self] + children.flatMap(\.flattened)
        }
    }

    /// Codex sessions as a parent/child forest, children always included.
    ///
    /// Codex writes one rollout per sub-agent and links it by
    /// `parent_thread_id`. Left flat, 66 children of one session render as 66
    /// near-identical cards; grouped, the tree reads as "one session, N
    /// agents". Sub-agents whose parent fell outside the recency window are
    /// promoted to roots rather than dropped — an orphan is still live work.
    func externalSessionTree(kind: ExternalAgentKind) -> [ExternalSessionNode] {
        let alive = externalSessions.filter { $0.kind == kind && $0.isAlive }
        var childrenOf: [String: [ExternalSessionInfo]] = [:]
        for session in alive where session.isSubagent {
            if let parent = session.parentThreadId { childrenOf[parent, default: []].append(session) }
        }
        func roots() -> [ExternalSessionInfo] {
            // Orphaned or completed helpers must never become main cards.
            alive.filter { !$0.isSubagent }
        }
        func build(_ session: ExternalSessionInfo, depth: Int) -> ExternalSessionNode {
            let children = (childrenOf[session.sessionId] ?? [])
                .filter(\.isActive)
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { build($0, depth: depth + 1) }
            return ExternalSessionNode(session: session, depth: depth, children: children)
        }
        return roots()
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { build($0, depth: 0) }
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
    /// `stat.tokenTotalBySource` is keyed by model name; models that only
    /// appear in one source get zeroed slices for the others.
    func usageSourceSlices(for stat: ModelUsage) -> [SourceRing.Slice] {
        let bySource = usageTokensBySource
        let slices = UsageSource.allCases.map { source in
            SourceRing.Slice(label: source.label,
                             value: bySource[source]?.first { $0.model == stat.model }?.totalTokens ?? 0,
                             color: source.color)
        }
        return slices.contains { $0.value > 0 } ? slices : []
    }

    /// `usageBySource` flattened to per-model totals per source.
    var usageTokensBySource: [UsageSource: [ModelUsage]] { usageBySource }

    /// Totals per source for the whole period — the river's legend and the
    /// popup total line.
    var usageTotalBySource: [(source: UsageSource, tokens: Int)] {
        UsageSource.allCases.map { source in
            (source, (usageBySource[source] ?? []).reduce(0) { $0 + $1.totalTokens })
        }
    }

    // MARK: - Active provider

    /// The currently active provider, if any.
    var activeProvider: Provider? { providers.first { $0.id == activeProviderID } }

    /// Its active model, if any.
    var activeModel: ModelConfig? { activeProvider?.activeModel }
}
