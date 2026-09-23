import SwiftUI

/// Usage analytics page: period tabs, heatmap, quota rows — same CatStatus
/// grammar as the popup, at page scale.
struct UsageView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @State private var showCustomDatePicker = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s16) {
                titleBar

                VStack(alignment: .leading, spacing: Theme.Space.s12) {
                    HStack(alignment: .firstTextBaseline) {
                        GlyphWell(name: "chart.bar", tint: Theme.chartPurple, size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Token 活动")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundColor(Theme.textPrimary)
                            Text(caption)
                                .font(Theme.Font.caption)
                                .foregroundColor(Theme.textSecondary)
                        }
                        Spacer()
                        PeriodTabs(period: providerStore.usagePeriod, onSelect: selectPeriod)
                        Button(action: { providerStore.refreshUsage(rescan: true) }) {
                            GlyphWell(name: "arrow.clockwise", tint: Theme.textSecondary, size: 28)
                        }
                        .buttonStyle(.plain)
                        .help("重新统计本周期用量")
                        .accessibilityLabel("重新统计本周期用量")
                    }

                    HStack(spacing: 8) {
                        Button(action: { shiftUsage(-1) }) {
                            Image(systemName: "chevron.left")
                                .font(Theme.Font.bodySmall.weight(.semibold))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        Text(UsageStats.label(for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(Theme.textPrimary)
                        Button(action: { shiftUsage(1) }) {
                            Image(systemName: "chevron.right")
                                .font(Theme.Font.bodySmall.weight(.semibold))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if providerStore.usageLoading {
                            ProgressView().scaleEffect(0.6)
                        } else {
                            Text(providerStore.totalUsageLabel)
                                .font(Theme.Font.displayMetric)
                                .foregroundColor(Theme.textPrimary)
                                .contentTransition(.numericText())
                        }
                    }

                    if showCustomDatePicker {
                        DatePicker("", selection: $providerStore.usageReferenceDate, displayedComponents: [.date])
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    UsageHeatmap(
                        days: providerStore.usageDays,
                        period: providerStore.usagePeriod,
                        reference: providerStore.usageReferenceDate,
                        onSelectDay: { date in
                            providerStore.usagePeriod = .day
                            providerStore.usageReferenceDate = date
                            showCustomDatePicker = false
                        },
                        onSelectMonth: { date in
                            providerStore.usagePeriod = .month
                            providerStore.usageReferenceDate = date
                            showCustomDatePicker = false
                        }
                    )
                }
                .padding(Theme.Space.s16)
                .panelCard()

                EqualRowGrid(spacing: Theme.Space.s12, minColumnWidth: 0, fixedColumns: 2) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("来源")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(Theme.textPrimary)
                        SourceTriad(totals: providerStore.usageTotalBySource)
                    }
                    .padding(Theme.Space.s16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .panelCard()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("每日")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(Theme.textPrimary)
                        UsageDaySpark(days: providerStore.usageDays)
                        TokenMixStrip(stats: providerStore.usageStats)
                    }
                    .padding(Theme.Space.s16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .panelCard()
                }

                if providerStore.usageStats.contains(where: { $0.cacheReadTokens > 0 || $0.cacheCreationTokens > 0 }) {
                    CacheAnatomyBar(stats: providerStore.usageStats)
                        .padding(Theme.Space.s16)
                        .panelCard()
                }

                breakdown
            }
            .padding(Theme.Space.s24)
        }
        .background(Theme.bgPrimary)
    }

    private var titleBar: some View {
        PageTitle(title: "用量")
    }

    private var caption: String {
        "\(UsageStats.label(for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate)) · \(providerStore.totalUsageLabel)"
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            Text("按模型")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.textPrimary)
            if providerStore.usageStats.isEmpty && !providerStore.usageLoading {
                StandbyEmptyState(label: "暂无用量")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                TileGrid(.pageUsage) {
                    ForEach(providerStore.usageStats) { stat in
                        UsageModelCard(
                            stat: stat,
                            slices: providerStore.usageSourceSlices(for: stat),
                            share: Double(stat.totalTokens) / Double(max(providerStore.maxUsageTokens, 1))
                        )
                    }
                }
            }
        }
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

    private func shiftUsage(_ amount: Int) {
        providerStore.usageReferenceDate = UsageStats.shift(
            providerStore.usagePeriod, reference: providerStore.usageReferenceDate, by: amount
        )
    }

}
