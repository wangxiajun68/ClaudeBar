import Foundation

/// Lightweight snapshot of data the widget needs. Written by the main app
/// and read by the widget extension.
struct WidgetSnapshot: Codable {
    var todayTotalTokens: Int
    var modelBreakdown: [ModelTokenUsage]
    var activeProviderName: String
    var activeModelName: String
    var balanceText: String?
    var totalSessionCount: Int
    var busySessionCount: Int
    var sessions: [SessionSummary]
    var cursorSessions: [CursorSessionSummary]
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
}
