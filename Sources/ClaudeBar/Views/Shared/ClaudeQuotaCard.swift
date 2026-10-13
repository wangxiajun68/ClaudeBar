import SwiftUI

/// Always available, including when no subscription or quota has been reported.
struct ClaudeQuotaCard: View {
    @ObservedObject private var quota = ClaudeQuotaStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("CC 官方额度", systemImage: "gauge.with.dots.needle.50percent")
                    .font(Theme.Font.section)
                Spacer()
                Button {
                    Task { await quota.refresh() }
                } label: {
                    Label(quota.loading ? "查询中" : "查询额度", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain).foregroundColor(Theme.Ink.claude)
                .disabled(quota.loading)
            }
            if !quota.windows.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .top)], alignment: .leading, spacing: 16) {
                    ForEach(quota.windows) { window in
                        let remaining = min(100, max(0, 100 - window.usedPercent))
                        let tint = remaining <= 10 ? Theme.Ink.error
                            : remaining <= 25 ? Theme.Ink.warning : Theme.Ink.success
                        VStack(alignment: .leading, spacing: 6) {
                            Text(window.label).font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                            HStack(spacing: 8) {
                                OrbitGauge(progress: remaining / 100, tint: tint, lineWidth: 3, bodySize: 7)
                                    .frame(width: 32, height: 32)
                                Text("\(Int(remaining.rounded()))%")
                                    .font(Theme.Font.displayMetricSmall).monospacedDigit()
                                    .foregroundColor(Theme.textPrimary)
                                Text("剩余").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                            }
                            Text("已用 \(window.usedText)").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                            Text(window.resetClock).font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let note = quota.note {
                Text(note).font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let date = quota.updatedAt {
                Text("最近查询 \(date.formatted(.dateTime.hour().minute()))")
                    .font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
            }
        }
        .padding(16)
        .panelCard(tint: Theme.claude)
    }
}
