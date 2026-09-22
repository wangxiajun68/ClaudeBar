import SwiftUI

/// App-owned instrument marks. Motion follows an interaction rather than a
/// display-link timer, so an idle page costs no animation work.
struct SignatureGlyph: View {
    let name: String
    var tint: Color = Theme.textSecondary
    var size: CGFloat = 18
    var engaged = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let kind = InstrumentGlyph.kind(for: name) {
                InstrumentGlyph(kind: kind, tint: tint,
                                phase: engaged && !reduceMotion ? 1 : 0)
            } else {
                Image(systemName: name)
                    .font(.system(size: size * 0.82, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(tint)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(engaged && !reduceMotion ? 1.06 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.76), value: engaged)
        .accessibilityHidden(true)
    }
}

/// The eight destinations share one visual grammar while keeping their own
/// symbol and readable signal color. No layout or routing state lives here.
enum PageIdentity {
    static func symbol(_ title: String) -> String {
        switch title {
        case "概览": return "square.grid.2x2"
        case "会话": return "rectangle.stack"
        case "模型": return "cube"
        case "用量": return "chart.bar"
        case "流量": return "arrow.left.arrow.right"
        case "VPN": return "globe"
        case "设置": return "slider.horizontal.3"
        case "帮助": return "book.closed"
        default: return "square.grid.2x2"
        }
    }

    static func ink(_ title: String) -> Color {
        switch title {
        case "用量", "模型": return Theme.Ink.cursor
        case "VPN": return Theme.Ink.success
        case "设置", "帮助": return Theme.textSecondary
        default: return Theme.Ink.claude
        }
    }
}
