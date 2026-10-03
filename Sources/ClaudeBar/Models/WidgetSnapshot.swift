import Foundation

/// Lightweight snapshot of data the widget needs. Written by the main app
/// and read by the widget extension.
struct WidgetSnapshot: Codable {
    /// Tokens for `usagePeriodLabel`'s window — **not** necessarily today.
    /// The popup lets the user page back through months, and this field is
    /// filled from the selected period, so the widget must read the label
    /// rather than assume "Token = today".
    var todayTotalTokens: Int
    /// Human label for the period `todayTotalTokens` covers, e.g. "今天".
    /// Optional so a snapshot written by an older build still decodes.
    var usagePeriodLabel: String?
    /// `TokenUnitStyle.rawValue` ("chinese" / "metric"). Carried in the
    /// payload because the widget process has its own `UserDefaults.standard`
    /// — the app's domain is not visible to it, so reading the key over there
    /// always returned nil and every widget silently used the 万/亿 default.
    /// Optional so older snapshots still decode (they get the default).
    var unitStyle: String?
    /// The app's *authored* appearance (`AppearanceMode`), which is a manual
    /// toggle rather than "follow system" — the widget cannot infer it from
    /// `colorScheme`. Falls back to the system appearance when absent.
    var isDark: Bool?
    var modelBreakdown: [ModelTokenUsage]
    var activeProviderName: String
    var activeModelName: String
    var balanceText: String?
    var totalSessionCount: Int
    var busySessionCount: Int
    var sessions: [SessionSummary]
    var cursorSessions: [CursorSessionSummary]
    /// Codex (and other external-agent) sessions. Empty for older snapshots —
    /// a user running only Codex used to see "暂无数据" while the app listed
    /// their sessions, because this was never carried across.
    var externalSessions: [ExternalSessionSummary]
    var updatedAt: Date

    struct ModelTokenUsage: Codable {
        var model: String
        var totalTokens: Int
    }

    struct SessionSummary: Codable {
        var pid: Int
        var status: String       // "busy", "waiting", "idle"
        var model: String
        var contextTokens: Int
        var contextLimit: Int
        var contextRatio: Double
        var projectFolder: String
        var currentActivity: String
        /// A session parked on the user — a permission prompt or a question
        /// dialog. Optional so a snapshot written by an older build still
        /// decodes; `status == "waiting"` carries the same fact for readers
        /// that only look at the string.
        var waiting: Bool?
    }

    /// A Cursor (IDE) session summary. Cursor identifies sessions by
    /// composerId (String) rather than pid (Int), and exposes a context
    /// fill percentage rather than absolute token counts — hence a separate
    /// type instead of reusing `SessionSummary`.
    struct CursorSessionSummary: Codable {
        var composerId: String
        var status: String           // "active" / "waiting" / "idle"
        var contextRatio: Double     // 0...1 (from contextPercent / 100)
        var contextPercent: Double   // -1 if unknown
        var projectFolder: String
        var currentActivity: String
        var relativeUpdated: String  // "5m" etc., precomputed by the host app
        var waiting: Bool?
    }

    /// An external-agent (Codex) session. `status` uses the same vocabulary as
    /// the other summaries so the widget renders all three with one row style.
    struct ExternalSessionSummary: Codable {
        var id: String
        var status: String           // "busy" / "waiting" / "idle"
        var model: String
        var contextTokens: Int
        var contextLimit: Int
        var contextRatio: Double
        var projectFolder: String
        var relativeUpdated: String
        /// Last tool of an open turn. Optional so a snapshot from an older
        /// build still decodes; empty means the row falls back to the model.
        var currentActivity: String?
        /// A Codex thread parked on the user. Codex journals no such state today
        /// (see `ExternalSessionInfo.isWaiting`), so this is `false` for every
        /// snapshot a current build writes — it is here so the widget reads one
        /// shape for all three agents and a future signal needs no format bump.
        /// Optional so older snapshots still decode.
        var waiting: Bool?
    }
}

/// The hand-written half of `Codable`.
///
/// A property's default value is invisible to the synthesized decoder — it is
/// an initializer's promise, not a payload's — so every field added after the
/// first snapshot shipped has to be read with `decodeIfPresent ?? default` or
/// the widget fails on the *old* payload still sitting in the App Group
/// container after an app update (it shows its empty state until the host app
/// happens to write a fresh one). `externalSessions` is the one that actually
/// got out: it was added non-optional while the fields added beside it
/// (`usagePeriodLabel`, `unitStyle`, `isDark`) were optional, and a payload
/// written before that commit decodes as a `keyNotFound` throw — the widget
/// has no second reader to fall back to. This initializer pins the whole
/// contract: a key present but null and a key absent both take the default.
///
/// The encoder stays synthesized, so the on-disk shape is unchanged: no format
/// version or bump is needed. A bump would not help either — it is the *old*
/// payload that has to decode — and nothing reads one.
extension WidgetSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        todayTotalTokens = try c.decode(Int.self, forKey: .todayTotalTokens)
        usagePeriodLabel = try c.decodeIfPresent(String.self, forKey: .usagePeriodLabel)
        unitStyle = try c.decodeIfPresent(String.self, forKey: .unitStyle)
        isDark = try c.decodeIfPresent(Bool.self, forKey: .isDark)
        modelBreakdown = try c.decode([ModelTokenUsage].self, forKey: .modelBreakdown)
        activeProviderName = try c.decode(String.self, forKey: .activeProviderName)
        activeModelName = try c.decode(String.self, forKey: .activeModelName)
        balanceText = try c.decodeIfPresent(String.self, forKey: .balanceText)
        totalSessionCount = try c.decode(Int.self, forKey: .totalSessionCount)
        busySessionCount = try c.decode(Int.self, forKey: .busySessionCount)
        sessions = try c.decode([SessionSummary].self, forKey: .sessions)
        cursorSessions = try c.decode([CursorSessionSummary].self, forKey: .cursorSessions)
        // Absent in snapshots written before the Codex half was carried
        // across: the app listed the user's sessions while the widget said
        // "暂无数据". Empty is that older snapshot's honest reading.
        externalSessions = try c.decodeIfPresent([ExternalSessionSummary].self, forKey: .externalSessions) ?? []
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}
