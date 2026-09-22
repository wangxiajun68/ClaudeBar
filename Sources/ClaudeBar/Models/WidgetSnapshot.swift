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
        var status: String       // "busy", "idle"
        var model: String
        var contextTokens: Int
        var contextLimit: Int
        var contextRatio: Double
        var projectFolder: String
        var currentActivity: String
    }

    /// A Cursor (IDE) session summary. Cursor identifies sessions by
    /// composerId (String) rather than pid (Int), and exposes a context
    /// fill percentage rather than absolute token counts — hence a separate
    /// type instead of reusing `SessionSummary`.
    struct CursorSessionSummary: Codable {
        var composerId: String
        var status: String           // "active" / "idle"
        var contextRatio: Double     // 0...1 (from contextPercent / 100)
        var contextPercent: Double   // -1 if unknown
        var projectFolder: String
        var currentActivity: String
        var relativeUpdated: String  // "5m" etc., precomputed by the host app
    }

    /// An external-agent (Codex) session. `status` uses the same vocabulary as
    /// the other summaries so the widget renders all three with one row style.
    struct ExternalSessionSummary: Codable {
        var id: String
        var status: String           // "busy" / "idle"
        var model: String
        var contextTokens: Int
        var contextLimit: Int
        var contextRatio: Double
        var projectFolder: String
        var relativeUpdated: String
    }
}
