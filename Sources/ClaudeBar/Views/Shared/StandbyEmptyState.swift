import SwiftUI

/// A parked instrument keeps an empty surface intentional and readable.
///
/// Two forms, one object:
///
/// - the default **inline row** — a leading mark and a muted line, for a
///   section inside a populated page (a model list with no matches, a tool
///   list that came back empty);
/// - `block: true` — the same mark centred with an optional caption and an
///   action, for a surface that is *entirely* empty and has to hold a panel's
///   worth of space by itself.
///
/// Both exist because the app had five different empty states: this one, two
/// native `ContentUnavailableView`s, a bespoke `Image`-on-a-rectangle in the
/// connectors grid, and a bare `Text` with `padding(.vertical, 20)`. An empty
/// state is where a surface admits it has nothing to show, so it should be the
/// most considered thing on the page rather than the least drawn.
struct StandbyEmptyState: View {
    var label: String = "暂无数据"
    /// The mark. Defaults to the generic parked-stack glyph; pass the surface's
    /// own symbol so the empty state names what is missing.
    var symbol: String = "rectangle.stack"
    var tint: Color = Theme.textSecondary
    /// A second line, for a block that has something useful to add ("换一个平台
    /// 或清掉搜索再看").
    var caption: String? = nil
    /// Fill the space and centre, instead of sitting inline.
    var block: Bool = false
    /// The row's action, drawn under a block.
    var action: (label: String, run: () -> Void)? = nil

    var body: some View {
        if block {
            VStack(spacing: Theme.Space.s12) {
                mark(size: 52)
                Text(label)
                    .font(Theme.Font.chromeEmph)
                    .foregroundStyle(Theme.textPrimary)
                if let caption {
                    Text(caption)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                if let action {
                    Button(action.label, action: action.run)
                        .adaptiveGlassButton()
                        .padding(.top, Theme.Space.s2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200)
            .accessibilityElement(children: .contain)
        } else {
            HStack(spacing: Theme.Space.s10) {
                mark(size: 30)
                Text(label)
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Space.s8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        }
    }

    private func mark(size: CGFloat) -> some View {
        GlyphWell(name: symbol, tint: tint, size: size)
    }
}
