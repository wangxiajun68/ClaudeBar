import SwiftUI

/// Section heading: tinted glyph well + title, optional live count.
///
/// `tint` is a *shape* hue (glyph well, dot). The count pill renders as text,
/// so it uses `ink` when one is supplied — the raw signal hues are 1.8–3.4:1
/// on the light canvas.
struct SectionHeader: View {
    let icon: String
    let title: String
    /// Accent used for the icon well.
    var tint: Color = Theme.textSecondary
    /// Readable counterpart of `tint` for the count pill. Defaults to `tint`
    /// so a call site that already picked an ink color keeps working.
    var ink: Color? = nil
    var count: Int? = nil
    /// Second component of the count, e.g. busy/active split ("● 1B · 2I").
    ///
    /// Must be a *subset* of `count`: the pill is rendered as
    /// `"\(activeCount)B · \(count - activeCount)I"`, so a value drawn from a
    /// wider population (sessions plus their sub-agents, say) reads as a
    /// negative idle figure.
    var activeCount: Int? = nil
    var activeSymbol: String = "B"
    /// Muted text laid out immediately before the count pill — for a tally that
    /// belongs to the same section but is not the count itself (the sub-agents
    /// beside the sessions that spawned them).
    ///
    /// It sits *in* this row rather than as an overlay on the header so it can
    /// never overlap the pill: an overlay cannot know the pill's width, and a
    /// fixed trailing inset was correct only for one session count.
    var note: String? = nil
    var noteTint: Color = Theme.textTertiary()
    /// Shown instead of a count when `count` is zero.
    var emptyLabel: String = "无"

    var body: some View {
        HStack(spacing: Theme.Space.s8) {
            GlyphWell(name: icon, tint: tint, size: 18)
            Text(title)
                .font(Theme.Font.section)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            if let note {
                Text(note)
                    .font(Theme.Font.microMedium)
                    .foregroundStyle(noteTint)
                    .lineLimit(1)
                    .fixedSize()
            }
            trailingView
        }
    }

    @ViewBuilder private var trailingView: some View {
        if let count {
            if count == 0 {
                Text(emptyLabel)
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
            } else if let activeCount {
                // No implicit `.animation(value: ...)` here either, and for
                // the same reason as the branch below: `activeCount` / `count`
                // are session-poll outputs, so a value-keyed modifier opens a
                // new animated transaction every poll. It bought nothing —
                // `StatusPill` is plain `Text`, there is no transition for an
                // implicit animation to interpolate.
                StatusPill(
                    label: "\(activeCount)\(activeSymbol) · \(count - activeCount)I",
                    tint: activeCount > 0 ? tint : Theme.textSecondary,
                    ink: activeCount > 0 ? (ink ?? tint) : Theme.textSecondary
                )
            } else {
                // No implicit `.animation(value: count)`: the count is one of
                // the session poll's outputs (2.5-5 s), so the modifier opened
                // a new animated transaction every poll, and an in-flight
                // transaction makes every display cycle re-layout the whole
                // hosting view. The digits roll via `.numericText` inside
                // `RollingNumberText` — that transition *is* the animation.
                RollingNumberText("\(count)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }
}
