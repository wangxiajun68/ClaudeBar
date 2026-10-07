import Foundation

/// Compact token-count formatting, shared by the app and the widget
/// extension. The widget target cannot see the app's code and the app cannot
/// see the widget's, so this used to exist twice — and the second copy's
/// thresholds could drift from `UsageStats.formatTokens` with no compile
/// error, no test and a widget number that silently disagreed with the popup.
/// The widget compiles this file through `Sources/Widget/TokenMagnitude.swift`,
/// the same symlink shape `WidgetSnapshot.swift` uses.
///
/// `style` is `TokenUnitStyle`'s raw value ("chinese" / "metric"). Anything
/// else — including the widget placeholder's nil — renders the 万/亿 default,
/// exactly as the widget's own copy always did.
enum TokenMagnitude {
    static func format(_ n: Int, style: String?) -> String {
        if style == "metric" {
            if n >= 1_000_000_000 {
                return String(format: "%.2fB", Double(n) / 1_000_000_000)
            } else if n >= 1_000_000 {
                return String(format: "%.1fM", Double(n) / 1_000_000)
            } else if n >= 1_000 {
                return String(format: "%dK", Int(round(Double(n) / 1_000)))
            } else {
                return "\(n)"
            }
        }
        if n >= 100_000_000 {
            return String(format: "%.1f亿", Double(n) / 100_000_000)
        } else if n >= 10_000 {
            return String(format: "%.1f万", Double(n) / 10_000)
        } else if n >= 1_000 {
            return String(format: "%dK", Int(round(Double(n) / 1_000)))
        } else {
            return "\(n)"
        }
    }
}
