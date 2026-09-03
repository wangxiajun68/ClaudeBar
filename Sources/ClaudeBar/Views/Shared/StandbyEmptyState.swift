import SwiftUI

/// Quiet empty placeholder. No terminal motif — the label states the fact.
struct StandbyEmptyState: View {
    var label: String = "暂无数据"

    var body: some View {
        Text(label)
            .font(Theme.Font.bodySmall)
            .foregroundColor(Theme.textTertiary())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .accessibilityLabel(label)
    }
}
