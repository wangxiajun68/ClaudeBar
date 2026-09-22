import SwiftUI

/// Shared search affordance for the help reader and traffic inspectors.
/// Focus is explicit; clearing keeps the keyboard in the same field.
struct InstrumentSearchField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            SignatureGlyph(name: "magnifyingglass",
                           tint: focused ? Theme.Ink.claude : Theme.textSecondary,
                           size: 16, engaged: focused)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Font.bodySmall)
                .foregroundColor(Theme.textPrimary)
                .focused($focused)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(focused ? Theme.Ink.claude.opacity(0.65) : Theme.hairline,
                              lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}
