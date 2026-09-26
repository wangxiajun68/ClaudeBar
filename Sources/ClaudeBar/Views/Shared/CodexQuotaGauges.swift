import SwiftUI

/// Filled arc = remaining allowance; the quiet track = consumed allowance; a
/// body rides the arc at the value, which is the weather card's orbit used as a
/// meter (see `OrbitGauge`).
///
/// The track runs 300° starting at -215° so the arc opens at the bottom, which
/// is what makes it read as a gauge rather than a progress ring — and it is the
/// only part of the card that moves, so a quota refresh animates one small
/// shape instead of relaying out the header.
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
                        RollingNumberText("\(Int(remaining.rounded()))%")
                            .font(.system(size: compact ? 10 : 20, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(Theme.textPrimary)
                        if !compact {
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
