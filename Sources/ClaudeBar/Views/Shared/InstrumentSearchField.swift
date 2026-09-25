import SwiftUI

/// Shared search affordance for every page that filters a list — connectors,
/// the help reader, traffic inspectors, the proxy log.
///
/// It is `InstrumentField` plus a glyph and a clear button, so a search box is
/// literally the one field surface the app has. Focus is explicit; clearing
/// keeps the keyboard in the same field (clearing then having to click back in
/// is the small tax that makes a search field feel like a form).
struct InstrumentSearchField: View {
    let prompt: String
    @Binding var text: String
    var radius: CGFloat = Theme.Radius.md
    @FocusState private var focused: Bool

    var body: some View {
        InstrumentField(radius: radius, focused: focused) {
            HStack(spacing: Theme.Space.s8) {
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
            .padding(.vertical, 8)
        }
    }
}


/// The compact form of `InstrumentField`, for the small numeric and single-line
/// fields that live inside a tile or a sheet row (a rate, a port, a filter box).
///
/// Same well, same focus rim, just tighter padding — so a field never reverts to
/// Aqua's `roundedBorder` box, which was the last stock control left in the app
/// and read as a foreign object inside a machined tile.
struct InstrumentFieldStyle: TextFieldStyle {
    var focused: Bool = false
    var onCard: Bool = true

    func _body(configuration: TextField<Self._Label>) -> some View {
        InstrumentField(radius: Theme.Radius.sm, focused: focused, onCard: onCard) {
            configuration
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
    }
}
