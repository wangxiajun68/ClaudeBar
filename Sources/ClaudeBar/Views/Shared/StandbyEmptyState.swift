import SwiftUI

/// A parked instrument mark keeps an empty surface intentional and readable.
struct StandbyEmptyState: View {
    var label: String = "暂无数据"

    var body: some View {
        HStack(spacing: 10) {
            GlyphWell(name: "rectangle.stack", tint: Theme.textSecondary, size: 30)
            Text(label)
                .font(Theme.Font.bodySmall)
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
