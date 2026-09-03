import SwiftUI

/// Popup usage area: period chips, date navigation, and per-model tiles in a
/// 2-col 宫格.
struct UsagePanel: View {
    @EnvironmentObject var providerStore: ProviderStore
    @State private var showCustomDatePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            periodChips
                .padding(.horizontal, Theme.Space.s16).padding(.bottom, 2)

            if showCustomDatePicker {
                DatePicker("", selection: $providerStore.usageReferenceDate, displayedComponents: [.date])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, Theme.Space.s16).padding(.bottom, 2)
                    .transition(.opacity)
            }

            dateNav
                .padding(.horizontal, Theme.Space.s16).padding(.bottom, 2)

            if providerStore.usageStats.isEmpty && !providerStore.usageLoading {
                StandbyEmptyState(label: "暂无用量")
                    .padding(.horizontal, Theme.Space.s16).padding(.bottom, Theme.Space.s4)
            } else {
                TileGrid(.popupUsage) {
                    ForEach(providerStore.usageStats) { stat in
                        UsageModelTile(stat: stat, maxTokens: providerStore.maxUsageTokens, dense: true)
                    }
                }
                .padding(.horizontal, Theme.Space.s8).padding(.bottom, Theme.Space.s4)
            }
        }
        .padding(.vertical, Theme.Space.s6)
    }

    // MARK: Period chips

    private var periodChips: some View {
        HStack(spacing: Theme.Space.s4) {
            ForEach(UsagePeriod.allCases) { period in
                let isOn = providerStore.usagePeriod == period
                Button(action: {
                    if period == .custom {
                        withAnimation(Theme.Animation.bouncy) { showCustomDatePicker.toggle() }
                        providerStore.usagePeriod = .custom
                    } else {
                        showCustomDatePicker = false
                        providerStore.usagePeriod = period
                        providerStore.usageReferenceDate = Date()
                    }
                }) {
                    Text(period.label)
                        .font(Theme.Font.microSemibold)
                        .foregroundColor(isOn ? .white : Theme.textSecondary)
                        .padding(.horizontal, 7).padding(.vertical, 2.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isOn ? Theme.accent.opacity(0.3) : Color.white.opacity(0.05))
                        )
                }
                .buttonStyle(.pressable)
            }
            Spacer()
        }
    }

    // MARK: Date navigation

    private var dateNav: some View {
        HStack(spacing: Theme.Space.s6) {
            Image(systemName: "chart.bar.xaxis")
                .font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
            Button(action: { shiftUsage(-1) }) {
                Image(systemName: "chevron.left")
                    .font(Theme.Font.microSemibold)
                    .foregroundColor(Theme.textTertiary(0.5))
                    .frame(width: 14, height: 14)
            }
            .adaptiveGlassButton()
            .help("上一个\(providerStore.usagePeriod.label)")

            Text(periodLabel)
                .font(Theme.Font.microSemibold)
                .foregroundColor(Theme.textTertiary(0.6))
                .lineLimit(1)

            Button(action: { shiftUsage(1) }) {
                Image(systemName: "chevron.right")
                    .font(Theme.Font.microSemibold)
                    .foregroundColor(Theme.textTertiary(0.5))
                    .frame(width: 14, height: 14)
            }
            .adaptiveGlassButton()
            .help("下一个\(providerStore.usagePeriod.label)")

            Spacer(minLength: Theme.Space.s8)
            if providerStore.usageLoading {
                ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                    .frame(width: 64, alignment: .trailing)
            } else {
                Text(providerStore.totalUsageLabel)
                    .font(Theme.Font.microMedium)
                    .monospacedDigit()
                    .foregroundColor(Theme.textTertiary(0.6))
                    .frame(width: 64, alignment: .trailing)
                    .contentTransition(.numericText())
                    .animation(Theme.Animation.smooth, value: providerStore.totalUsageLabel)
            }
        }
    }

    private func shiftUsage(_ amount: Int) {
        providerStore.usageReferenceDate = UsageStats.shift(
            providerStore.usagePeriod, reference: providerStore.usageReferenceDate, by: amount
        )
    }

    private var periodLabel: String {
        UsageStats.label(for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate)
    }
}
