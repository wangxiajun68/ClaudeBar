import SwiftUI

/// Thin alias kept for call-site stability — the real implementation lives in
/// `UsageBar.swift` (`UsageBarRow`). Popup density matches the old default.
///
/// A single per-model usage bar row shared between the menu-bar popup and the
/// main-window Usage page.
struct UsageRowView: View {
    let stat: ModelUsage
    let maxTokens: Int
    var barWidth: CGFloat? = 70   // nil → fill available space

    var body: some View {
        UsageBarRow(stat: stat, maxTokens: maxTokens, density: .popup, barWidth: barWidth)
    }
}
