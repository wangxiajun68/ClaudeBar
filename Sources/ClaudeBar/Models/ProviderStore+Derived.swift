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

    // MARK: - Usage derivation

    /// Total tokens for the current period — the one reduce.
    var totalUsageTokens: Int { usageStats.reduce(0) { $0 + $1.totalTokens } }

    /// Formatted total ("12.3K").
    var totalUsageLabel: String { UsageStats.formatTokens(totalUsageTokens) }

    /// Max per-model total in the current period (bar scale denominator).
    var maxUsageTokens: Int { max(usageStats.first?.totalTokens ?? 1, 1) }

    // MARK: - Active provider

    /// The currently active provider, if any.
    var activeProvider: Provider? { providers.first { $0.id == activeProviderID } }

    /// Its active model, if any.
    var activeModel: ModelConfig? { activeProvider?.activeModel }
}
