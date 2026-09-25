import SwiftUI

/// A proportional ring: one arc per slice, drawn with `Circle().trim` so it
/// stays crisp at any size and needs no Canvas. Slices are ordered largest
/// first; a zero-total ring renders as an empty track.
///
/// Sits beside model usage: each model tile opens one of these showing where
/// that model's tokens came from (Claude Code / Codex / third-party).
struct SourceRing: View {
    struct Slice: Identifiable {
        var id: String { label }
        let label: String
        let value: Int
        let color: Color
    }

    let slices: [Slice]
    var size: CGFloat = 96
    var thickness: CGFloat = 12
    /// Compact center figure ("12.3K").
    var centerValue: String
    var centerCaption: String

    private var total: Int { slices.reduce(0) { $0 + $1.value } }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.cardFill(0.07), lineWidth: thickness)
            if total > 0 {
                ForEach(Array(arcs.enumerated()), id: \.offset) { _, arc in
                    Circle()
                        .trim(from: arc.start, to: arc.end)
                        .stroke(arc.color.opacity(0.9),
                                style: StrokeStyle(lineWidth: thickness, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
            }
            VStack(spacing: 1) {
                RollingNumberText(centerValue)
                    .font(Theme.Font.captionMono)
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(centerCaption)
                    .font(Theme.Font.tileDetail)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
            }
            .frame(width: size - thickness * 2 - 6)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private struct Arc {
        let start: CGFloat
        let end: CGFloat
        let color: Color
    }

    /// Cumulative fractions. Slices keep a hair of separation so adjacent
    /// arcs never read as one; the trim API is inclusive of both ends.
    private var arcs: [Arc] {
        let visible = slices.filter { $0.value > 0 }
        guard total > 0, !visible.isEmpty else { return [] }
        var cursor: CGFloat = 0
        var out: [Arc] = []
        for slice in visible {
            let fraction = CGFloat(slice.value) / CGFloat(total)
            let start = cursor
            let end = min(1, start + fraction)
            out.append(Arc(start: start, end: end, color: slice.color))
            cursor = end
        }
        return out
    }

    private var accessibilityText: String {
        guard total > 0 else { return "无用量" }
        let parts = slices.filter { $0.value > 0 }.map { slice in
            "\(slice.label) \(Int((Double(slice.value) / Double(total) * 100).rounded()))%"
        }
        return parts.joined(separator: "，")
    }
}

/// Legend under a source ring: one dot + label + share per source.
struct SourceRingLegend: View {
    let slices: [SourceRing.Slice]

    private var total: Int { slices.reduce(0) { $0 + $1.value } }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(slices) { slice in
                HStack(spacing: 5) {
                    Circle()
                        .fill(slice.color)
                        .frame(width: 5, height: 5)
                        .opacity(slice.value > 0 ? 1 : 0.3)
                    Text(slice.label)
                        .font(Theme.Font.tileDetail)
                        .foregroundColor(slice.value > 0 ? Theme.textSecondary : Theme.textTertiary(0.6))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    RollingNumberText(total > 0 ? "\(Int((Double(slice.value) / Double(total) * 100).rounded()))%" : "—")
                        .font(Theme.Font.tileDetail)
                        .monospacedDigit()
                        .foregroundColor(Theme.textTertiary())
                    RollingNumberText(UsageStats.formatTokens(slice.value))
                        .font(Theme.Font.tileDetail)
                        .monospacedDigit()
                        .foregroundColor(Theme.textTertiary())
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
    }
}
