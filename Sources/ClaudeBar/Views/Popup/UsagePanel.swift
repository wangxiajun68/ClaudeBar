import SwiftUI

/// Popup usage: heatmap + source triad + token mix + model bars. Model
/// tokens only — VPN quota lives on the VPN page.
struct UsagePanel: View {
    @EnvironmentObject var providerStore: ProviderStore
    @State private var showCustomDatePicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
            header
            if showCustomDatePicker {
                DatePicker("", selection: $providerStore.usageReferenceDate, displayedComponents: [.date])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.opacity)
            }
            UsageHeatmap(
                days: providerStore.usageDays,
                period: providerStore.usagePeriod,
                reference: providerStore.usageReferenceDate,
                compact: true,
                onSelectDay: { date in
                    providerStore.usagePeriod = .day
                    providerStore.usageReferenceDate = date
                },
                onSelectMonth: { date in
                    providerStore.usagePeriod = .month
                    providerStore.usageReferenceDate = date
                }
            )

            EqualRowGrid(spacing: 10, minColumnWidth: 0, fixedColumns: 2) {
                SourceTriad(totals: providerStore.usageTotalBySource)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 6) {
                    Text("构成")
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textTertiary())
                    TokenMixStrip(stats: providerStore.usageStats, compact: true)
                    UsageDaySpark(days: providerStore.usageDays)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if providerStore.usageStats.isEmpty && !providerStore.usageLoading {
                Text("暂无用量")
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
            } else {
                ForEach(Array(providerStore.usageStats.prefix(3))) { stat in
                    QuotaRow(
                        title: stat.model,
                        subtitle: "\(stat.calls) 次",
                        used: share(of: stat),
                        remainingLabel: UsageStats.formatTokens(stat.totalTokens),
                        trailing: "用量 \(Int((share(of: stat) * 100).rounded()))%",
                        mode: .share
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("用量")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(periodCaption)
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary())
                .lineLimit(1)
            Spacer(minLength: 6)
            PeriodTabs(period: providerStore.usagePeriod, compact: true, onSelect: selectPeriod)
            Button(action: { providerStore.refreshUsage(rescan: true) }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("重新统计本周期用量")
        }
    }

    private var periodCaption: String {
        let label = UsageStats.label(for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate)
        if providerStore.usageLoading { return label }
        return "\(label) · \(providerStore.totalUsageLabel)"
    }

    private func share(of stat: ModelUsage) -> Double {
        let peak = max(providerStore.maxUsageTokens, 1)
        return min(1, Double(stat.totalTokens) / Double(peak))
    }

    private func selectPeriod(_ period: UsagePeriod) {
        if period == .custom {
            withAnimation(Theme.Animation.smooth) { showCustomDatePicker.toggle() }
            providerStore.usagePeriod = .custom
        } else {
            showCustomDatePicker = false
            providerStore.usagePeriod = period
            providerStore.usageReferenceDate = Date()
        }
    }
}
