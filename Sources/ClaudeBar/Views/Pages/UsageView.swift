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
                GlassEffectContainer(spacing: Theme.Space.s4) {
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
                            .symbolEffect(.bounce, value: isOn)
                        }
                        Spacer()
                    }
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
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)
                    .symbolEffect(.bounce, value: providerStore.usageReferenceDate)

                    Text(UsageStats.label(for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate))
                        .font(Theme.Font.titleSmall)
                        .foregroundColor(Theme.textPrimary)
                        .contentTransition(.numericText())
                        .animation(Theme.Animation.smooth, value: providerStore.usageReferenceDate)

                    Button(action: { shiftUsage(1) }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)
                    .symbolEffect(.bounce, value: providerStore.usageReferenceDate)

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
    }

    private var totalLabel: String {
        let total = providerStore.usageStats.reduce(0) { $0 + $1.totalTokens }
        return UsageStats.formatTokens(total) + " tokens"
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            ForEach(providerStore.usageStats) { stat in
                usageRow(stat)
            }
            if providerStore.usageStats.isEmpty && !providerStore.usageLoading {
                Text("无用量数据")
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textTertiary())
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
        }
        .padding(Theme.Space.s16)
        .panelCard()
        .scrollTransition(.animated(Theme.Animation.smooth)) { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.6)
                .scaleEffect(phase.isIdentity ? 1 : 0.97)
        }
    }

    private func usageRow(_ stat: ModelUsage) -> some View {
        UsageBarRow(stat: stat,
                    maxTokens: providerStore.usageStats.first?.totalTokens ?? 1)
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

// MARK: - Usage bar row

/// A per-model usage row that responds to hover: the bar grows slightly taller
/// and brighter, and the track reveals a percentage label. Hovering a data row
/// to surface its detail is the kind of in-place exploration that replaces a
/// flat listing with an interactive one.
private struct UsageBarRow: View {
    let stat: ModelUsage
    let maxTokens: Int
    @State private var isHovered = false

    var body: some View {
        let ratio = maxTokens > 0 ? CGFloat(stat.totalTokens) / CGFloat(maxTokens) : 0
        let color = Theme.barColor(for: stat.model)
        return HStack(spacing: 12) {
            Text(stat.model)
                .font(Theme.Font.bodySmall)
                .foregroundColor(Theme.textPrimary.opacity(isHovered ? 1 : 0.85))
                .frame(width: 160, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.cardFill(0.08))
                        .frame(height: isHovered ? 10 : 8)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.barGradient(for: stat.model))
                        .frame(width: max(4, geo.size.width * ratio), height: isHovered ? 10 : 8)
                        .opacity(isHovered ? 1 : 0.9)
                }
            }
            .frame(height: 14)
            HStack(spacing: 4) {
                Text(UsageStats.formatTokens(stat.totalTokens))
                    .font(Theme.Font.bodySmall)
                    .foregroundColor(Theme.textSecondary)
                    .contentTransition(.numericText())
                    .animation(Theme.Animation.smooth, value: stat.totalTokens)
                // Percentage reveals on hover — the row "explains itself".
                Text("\(Int(ratio * 100))%")
                    .font(Theme.Font.captionMono)
                    .foregroundColor(color)
                    .opacity(isHovered ? 1 : 0)
                    .frame(width: isHovered ? nil : 0)
            }
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .hoverState($isHovered)
    }
}
