import SwiftUI

/// Filled arc = remaining allowance; the quiet track = consumed allowance.
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
                    ZStack {
                        Circle().stroke(Theme.hairline, lineWidth: 2.5)
                        Circle().trim(from: 0, to: remaining / 100)
                            .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: compact ? 15 : 30, height: compact ? 15 : 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(window.label.replacingOccurrences(of: " 小时", with: "h").replacingOccurrences(of: " 天", with: "d") + " 剩余")
                            .font(.system(size: compact ? 8 : 10, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                        Text("\(Int(remaining.rounded()))%")
                            .font(.system(size: compact ? 10 : 20, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(Theme.textPrimary)
                        if !compact {
                            Text(window.resetClock)
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
