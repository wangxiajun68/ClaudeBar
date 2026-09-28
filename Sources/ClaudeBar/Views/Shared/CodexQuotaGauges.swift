import SwiftUI

/// Filled arc = remaining allowance; the quiet track = consumed allowance; a
/// body rides the arc at the value, which is the weather card's orbit used as a
/// meter (see `OrbitGauge`).
///
/// The track runs 300° starting at -215° so the arc opens at the bottom, which
/// is what makes it read as a gauge rather than a progress ring — and it is the
/// only part of the card that moves, so a quota refresh animates one small
/// shape instead of relaying out the header.
///
/// **Compact vs full is a different reading, not a smaller one.** The full size
/// has room for a third line and prints the reset *clock* under the percentage.
/// The compact size is the popup header's 133pt cell, where two windows share
/// the row: a clock there does not fit — `09-27 21:00` beside both windows
/// pushes the second off the cell — so the reset rides on the percentage's own
/// line in its shortest honest form (`21:00` for a window that resets today,
/// `2天` for one that resets later; see `CodexQuotaWindow.resetCompact`).
/// It is the same reading as the full size's clock line, abbreviated to what the
/// cell can actually hold rather than dropped.
struct CodexQuotaGauges: View {
    let windows: [CodexQuotaWindow]
    var compact = true

    var body: some View {
        HStack(spacing: compact ? 6 : 16) {
            ForEach(windows.prefix(2)) { window in
                let remaining = max(0, min(100, 100 - window.usedPercent))
                let tint = remaining <= 10 ? Theme.Ink.error
                    : remaining <= 25 ? Theme.Ink.warning : Theme.Ink.success
                HStack(spacing: 3) {
                    OrbitGauge(progress: remaining / 100,
                               tint: tint,
                               lineWidth: compact ? 2.5 : 4,
                               bodySize: compact ? 7 : 11)
                        .frame(width: compact ? 15 : 30, height: compact ? 15 : 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(window.label.replacingOccurrences(of: " 小时", with: "h").replacingOccurrences(of: " 天", with: "d") + " 剩余")
                            .font(.system(size: compact ? 8 : 10, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                        if compact {
                            // Percentage and reset share the line — see the
                            // type's note for why the compact size abbreviates
                            // the clock instead of dropping it.
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                RollingNumberText("\(Int(remaining.rounded()))%")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(Theme.textPrimary)
                                if !window.resetCompact.isEmpty {
                                    RollingNumberText(window.resetCompact)
                                        .font(.system(size: 8, weight: .medium, design: .rounded))
                                        .foregroundColor(Theme.textTertiary())
                                        .lineLimit(1)
                                }
                            }
                        } else {
                            RollingNumberText("\(Int(remaining.rounded()))%")
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(Theme.textPrimary)
                            RollingNumberText(window.resetClock)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(Theme.textTertiary())
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                }
                .fixedSize()
                .help("\(window.label)：剩余 \(Int(remaining.rounded()))%，已用 \(window.usedText) · \(window.resetText)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(window.label)，剩余 \(Int(remaining.rounded()))%，已用 \(window.usedText)，\(window.resetText)")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Directory-style allowance readout for a `HeaderSwitchChip`.
///
/// The chip reserves ~26pt under its model name, and this is what fills it when
/// a family has more than one thing worth saying: up to two small labelled
/// gauges side by side, plus one quiet line beneath for the money. The Codex
/// chip needs only the two gauges; a family with a spend figure as well (Cursor)
/// passes `detail`.
///
/// **Each cell is `[arc over reset] [label over percentage]`.** The three facts
/// are which window, how much is used and when it resets; the first two are
/// short ("7 天", "37%") and the reset is the wide one ("13:34"). Putting the
/// reset on the label's line — where it sat until 2026-09-28 — made that line
/// the widest thing in the cell and pushed two of them past a 133pt chip:
/// measured, the pair needed ~139pt against the ~119pt the chip leaves, so the
/// second window's reset was clipped mid-glyph and the Cursor chip's pair
/// spilled across the panel's right border (`EqualRowGrid` places a child at the
/// column width; a `fixedSize()` child simply draws past it).
///
/// The free space under the arc is the fix. The arc is 15pt of a 26pt row and
/// the text beside it is two lines, so the reset drops under the arc — it costs
/// vertical room the cell already had instead of horizontal room the row did
/// not. Measured at the popup's real 119pt the pair then needs ~108pt, so
/// nothing shrinks, truncates or disappears.
///
/// `width` is the host chip's own content width (see
/// `HeaderSwitchChip.contentWidth`). A `GeometryReader` alone was not enough:
/// it only knows the width it is *proposed*, and inside the chip's VStack that
/// collapsed to the row's own ideal, so the Codex chip (no money line under its
/// gauges) measured a different width from the Cursor chip and the two rendered
/// at different scales. Zero keeps the reader path for hosts that cannot supply
/// a width (a preview), which is honest if less exact.
struct QuotaSwayGauge: View {
    /// One window: an eyebrow label and how much is **used**, 0–100.
    ///
    /// The popup's own reading is the *complement* — 20% used is "80% left" —
    /// and `GaugeCell` does that subtraction. The type still carries `used`
    /// because that is what every source reports (Cursor's `totalPercentUsed`,
    /// Codex's `usedPercent`); inverting at the source would put the arithmetic
    /// in three callers instead of one reader.
    struct Metric: Identifiable {
        var label: String
        var usedPercent: Double
        /// Short trailing text under the arc (a reset time, "—", …).
        var resetCompact: String = ""
        var id: String { label }
    }

    let metrics: [Metric]
    /// One quiet line under the gauges — e.g. "$492.45 / $20". Empty hides it.
    var detail: String = ""
    var onRefresh: (() -> Void)?
    var loading = false
    /// The width the row may occupy, supplied by the host chip. Zero = measure
    /// myself with a `GeometryReader`.
    var width: CGFloat = 0

    var body: some View {
        if loading {
            ProgressView().controlSize(.mini)
        } else if metrics.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise").font(.system(size: 10))
                Text(detail.isEmpty ? "额度" : detail)
                    .font(Theme.Font.meta).foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .contain)
        } else if width > 0 {
            row(in: width)
        } else {
            GeometryReader { geo in
                row(in: geo.size.width)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            }
            .frame(height: Self.height)
            .accessibilityElement(children: .contain)
        }
    }

    /// The row itself, laid out for an exact width.
    private func row(in available: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(metrics) { metric in
                GaugeCell(metric: metric, help: help(metric))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: available, height: Self.height, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// The row's height: the arc (15pt) with the reset under it (an 8pt line
    /// plus a 1pt gap) is 26pt, which is taller than the label/percentage column
    /// beside it and so is what sets the row. Fixed so a refresh never resizes
    /// the chip — the header row's height staying put is what keeps the three
    /// switchers on one baseline.
    static var height: CGFloat { 26 }

    private func help(_ metric: Metric) -> String {
        let used = Int(min(100, max(0, metric.usedPercent)).rounded())
        var parts = ["\(metric.label)：剩余 \(100 - used)%（已用 \(used)%）"]
        if !metric.resetCompact.isEmpty { parts.append(metric.resetCompact) }
        if !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: " · ")
    }
}

/// One labelled allowance cell inside `QuotaSwayGauge`.
///
/// Two columns: the arc (remaining, so a fuller arc is more allowance left) with
/// its reset beneath, and the window's name over its **remaining** percentage.
/// The figures carry the weight (primary ink, semibold); the name and the reset
/// are secondary and tertiary — so the eye reads the figure first and the
/// qualifiers after, which is the same ranking the chip's own headline uses.
///
/// **The arc and the figure run the same direction now.** This cell used to pair
/// a *used* arc with a *used* figure, both rising toward the cap; the popup now
/// reads the headroom ("还剩多少"), so the figure is `100 - used` — and the arc
/// has to move with it or the fuller arc would sit beside the smaller number.
/// The arc is therefore *remaining* too: it starts empty at a fresh window and
/// fills as allowance is handed back by the reset, not as it is consumed. A
/// rising arc still means "this number is growing", and the ink simply moved to
/// the low end (a shrinking remainder is the alarming one).
private struct GaugeCell: View {
    let metric: QuotaSwayGauge.Metric
    let help: String

    var body: some View {
        // Gauge = *remaining*: the complement of what the account reports, so a
        // fuller arc is more allowance left. The tint keys off the same figure,
        // because a remainder near zero is the state worth flagging.
        let remaining = min(100, max(0, 100 - metric.usedPercent))
        let tint = remaining <= 10 ? Theme.Ink.error
            : remaining <= 25 ? Theme.Ink.warning : Theme.Ink.success
        HStack(alignment: .top, spacing: 3) {
            VStack(spacing: 1) {
                OrbitGauge(progress: remaining / 100, tint: tint, lineWidth: 2.5, bodySize: 7)
                    .frame(width: 15, height: 15)
                if !metric.resetCompact.isEmpty {
                    RollingNumberText(metric.resetCompact)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                        // Shrink before it clips. The reset is the *qualifier*
                        // under the arc and it is also the widest fixed run in
                        // the cell ("09-27 21:00"), so `fixedSize()` here was
                        // the thing that pushed the whole window past its column
                        // and left the percentage beside it reading "10…". It
                        // scales first and truncates only as the last resort,
                        // the same ordering the chip's model name uses.
                        .minimumScaleFactor(0.7)
                        .truncationMode(.tail)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                // The window's *name*. It scales before it truncates, for the
                // same reason the model name in the chip above does: a family
                // can name its pools with more than one word ("Cursor Models",
                // "Other Models" — Cursor's own pool names), and at the popup's
                // ~119pt the two of them together are ~58pt against the ~51pt
                // the name column gets. Dropping the size a point or two reads
                // the whole name; `lineLimit(1)` alone read "Cursor…" / "Other…",
                // which is a different, worse statement than the label it
                // abbreviates. It still truncates as the last resort, so a
                // genuinely overlong label cannot push its neighbour out.
                Text(metric.label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
                RollingNumberText("\(Int(remaining.rounded()))%")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    // The headline figure: a hair of shrink is better than a
                    // "10…" that reads as a different number.
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }
}
