import SwiftUI

/// Usage analytics page: period selector (日/月/年/指定), date navigation,
/// a prominent total, and per-model breakdown bars at full width. Reuses the
/// same `UsageStats` aggregation and period logic as the menu-bar popup.
struct UsageView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @State private var showCustomDatePicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s24) {
                titleBar

                // Period selector chips
                HStack(spacing: Theme.Space.s4) {
                    ForEach(UsagePeriod.allCases) { period in
                        let isOn = providerStore.usagePeriod == period
                        Button(action: { selectPeriod(period) }) {
                            Text(period.label)
                                .font(Theme.Font.labelSection)
                                .foregroundColor(isOn ? .white : Theme.textSecondary)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .glassEffect(
                                    .regular.tint(isOn ? Theme.accent.opacity(0.3) : .clear),
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                )
                        }
                        .buttonStyle(.pressable)
                    }
                    Spacer()
                }

                if showCustomDatePicker {
                    DatePicker("", selection: $providerStore.usageReferenceDate, displayedComponents: [.date])
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Date navigation + total
                HStack(spacing: 8) {
                    Button(action: { shiftUsage(-1) }) {
                        Image(systemName: "chevron.left")
                            .font(Theme.Font.bodySmall.weight(.semibold))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)

                    Text(UsageStats.label(for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate))
                        .font(Theme.Font.titleSmall)
                        .foregroundColor(Theme.textPrimary)
                        .contentTransition(.numericText())
                        .animation(Theme.Animation.smooth, value: providerStore.usageReferenceDate)

                    Button(action: { shiftUsage(1) }) {
                        Image(systemName: "chevron.right")
                            .font(Theme.Font.bodySmall.weight(.semibold))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)

                    Spacer()

                    if providerStore.usageLoading {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Text(totalLabel)
                            .font(Theme.Font.titleMedium)
                            .foregroundColor(Theme.accent)
                            .contentTransition(.numericText())
                            .animation(Theme.Animation.smooth, value: totalLabel)
                    }
                }

                breakdown
            }
            .padding(Theme.Space.s24)
        }
        .background(Theme.base0.opacity(0.35))
    }

    private var titleBar: some View {
        Text("用量")
            .font(Theme.Font.titleLarge)
            .foregroundColor(Theme.textPrimary)
            .lineLimit(1)
            .fixedSize()
    }

    private var totalLabel: String {
        providerStore.totalUsageLabel + " tokens"
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            if providerStore.usageStats.isEmpty && !providerStore.usageLoading {
                StandbyEmptyState(label: "no usage data")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                TileGrid(.pageUsage) {
                    ForEach(providerStore.usageStats) { stat in
                        UsageModelTile(stat: stat,
                                       maxTokens: providerStore.usageStats.first?.totalTokens ?? 1)
                    }
                }
            }
        }
        .padding(Theme.Space.s16)
        .sectionRules()
    }

    private func selectPeriod(_ period: UsagePeriod) {
        if period == .custom {
            withAnimation(Theme.Animation.bouncy) { showCustomDatePicker.toggle() }
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

// MARK: - Usage tiles

// Per-model usage now renders as `UsageModelTile` in a `TileGrid(.pageUsage)`
// — the former `.page` row density is superseded on this page.
