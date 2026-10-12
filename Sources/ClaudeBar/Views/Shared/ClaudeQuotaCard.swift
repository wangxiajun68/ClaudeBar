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
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(window.label).font(Theme.Font.caption)
                                Spacer()
                                Text(window.usedText + " 已用").font(Theme.Font.body.weight(.semibold)).monospacedDigit()
                            }
                            ContextBar(ratio: window.usedPercent / 100, height: 6)
                            Text(window.remainingPhrase).font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                            Text(window.resetClock).font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
                        }.accessibilityElement(children: .combine)
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
        .task { await quota.refresh(manual: false) }
    }
}
