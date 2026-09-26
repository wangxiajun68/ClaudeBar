import SwiftUI

/// Fixed-height popup summary: matching token/cost figures, a heatmap and
/// the three leading models. Full breakdowns live on the usage page.
struct UsagePanel: View {
    @ProviderState(.usage) var providerStore: ProviderStore
    @State private var showCustomDatePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
                .overlay(alignment: .bottomLeading) { datePickerAnchor }
            usageSummary
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

            if providerStore.usageStats.isEmpty && !providerStore.usageLoading {
                Text("暂无用量")
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
            } else {
                ForEach(Array(providerStore.usageStats.prefix(3))) { stat in
                    HStack(spacing: 8) {
                        Text(stat.model)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        RollingNumberText(UsageStats.formatTokens(stat.totalTokens)).monospacedDigit()
                    }
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 244, alignment: .top)
    }

    /// The date picker hangs off an empty sibling of the header, not off the
    /// header itself.
    ///
    /// `PeriodTabs` and 重新统计 both live *inside* `header`. SwiftUI anchors a
    /// popover's click-outside dismissal to the whole subtree of whatever it is
    /// attached to, so attaching it to `header` puts the two controls that are
    /// supposed to drive the picker inside the region that dismisses it: the
    /// period chips' first click while the picker was open would close it
    /// without reaching `selectPeriod`. The probe in
    /// `docs/technical/17-ui-audit-backlog.md` §6 could not drive a synthetic
    /// click far enough to confirm the symptom, but the anchoring rule is
    /// documented and the fix is free, so the anchor is kept out of the controls
    /// either way. Zero-size and inert: nothing here draws or hit-tests.
    private var datePickerAnchor: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .popover(isPresented: $showCustomDatePicker) {
                DatePicker("选择日期", selection: $providerStore.usageReferenceDate,
                           displayedComponents: [.date])
                    .datePickerStyle(.graphical)
                    .padding(12)
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

    private var usageSummary: some View {
        let estimate = providerStore.costEstimate
        return HStack(alignment: .top, spacing: 16) {
            summaryMetric("Token 用量", value: providerStore.totalUsageLabel,
                          detail: "所选时段累计")
            summaryMetric("花费", value: estimate.cost.dominant.map {
                ModelPricing.format($0.amount, currency: $0.currency)
            } ?? "—", detail: costDetail(estimate))
        }
        .padding(.vertical, 6)
    }

    private func summaryMetric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
            RollingNumberText(value)
                .font(.system(size: 21, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail.isEmpty ? " " : detail)
                .rollingNumber()
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.textTertiary())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func costDetail(_ estimate: ModelPricing.Estimate) -> String {
        if let secondary = estimate.cost.secondary {
            return "另有 " + ModelPricing.format(secondary.amount, currency: secondary.currency)
        }
        if estimate.unpricedModels > 0 { return "\(estimate.unpricedModels) 个未计价" }
        return estimate.isEmpty ? "暂无用量" : ""
    }

    private var periodCaption: String {
        let label = UsageStats.label(for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate)
        return label
    }

    private func selectPeriod(_ period: UsagePeriod) {
        if period == .custom {
            // Toggle, not "always open": the same chip closes the picker, and
            // that click used to leave the popup on a 自定义 period the user
            // never chose (the reference date keeps its old value, so the
            // figures silently switched to a single day).
            let opening = !showCustomDatePicker
            withAnimation(Theme.Animation.smooth) { showCustomDatePicker = opening }
            if opening {
                providerStore.usagePeriod = .custom
            } else if providerStore.usagePeriod == .custom {
                providerStore.usagePeriod = .month
                providerStore.usageReferenceDate = Date()
            }
        } else {
            showCustomDatePicker = false
            providerStore.usagePeriod = period
            providerStore.usageReferenceDate = Date()
        }
    }
}
