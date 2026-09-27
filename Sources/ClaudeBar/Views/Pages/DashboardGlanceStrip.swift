import SwiftUI

/// The dashboard's 1×4 glance row: **Codex 额度 · 当前模型 · 今日花费 · 今日 Token**.
///
/// Why it is its own view with its own `@ProviderState` scope, rather than four
/// tiles inside `DashboardView`'s body: `DashboardView` deliberately subscribes
/// to `.sessions` only, because `.configuration` publishes on every balance
/// fetch and re-derived the session grid for an account that page does not
/// show (see its own doc comment). The two figures here *are* configuration —
/// the active models — so reading them from the dashboard's wrapper would undo
/// that. A child view carries its own invalidation, so the row costs the page
/// nothing.
struct DashboardGlanceStrip: View {
    /// `.configuration` for the active models, `.usage` for today's figures.
    /// Not `.sessions`: nothing on this row moves when a session starts.
    @ProviderState([.usage, .configuration]) var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore

    var body: some View {
        // Derived once. The four tiles would otherwise each re-walk the
        // provider lists and re-run the date/format passes in their own body.
        let cc = ClaudeRoute.of(providerStore)
        let codex = codexStore.activeProvider
        let today = providerStore.todayUsage

        return TileGrid(.pageMetric) {
            quotaCard
            modelCard(cc: cc, codex: codex)
            costCard(today)
            tokenCard(today)
        }
        // The one preference this row renders, subscribed individually. The
        // money card is the only reader, and observing `AppPreferences.shared`
        // wholesale re-evaluated all four tiles for a VPN port commit or a
        // token-unit toggle.
        .onReceive(AppPreferences.shared.$costDisplay.removeDuplicates()) { costDisplay = $0 }
    }

    // MARK: Codex 额度

    /// The two ChatGPT rate-limit windows, drawn with the same `OrbitGauge`
    /// meters the popup chip uses — one shape, so "how much allowance is left"
    /// looks the same in both surfaces. Tap refreshes, exactly like the chip.
    private var quotaCard: some View {
        GlanceCard(title: "Codex 额度", kind: .quota,
                   tint: Theme.codex, ink: Theme.Ink.codex,
                   help: codexStore.quotaWindows.isEmpty
                       ? (codexStore.quotaNote ?? "点击获取 Codex 额度")
                       : codexStore.quotaWindows
                           .map { "\($0.label)：剩余 \(Int((100 - $0.usedPercent).rounded()))%，\($0.resetText)" }
                           .joined(separator: "\n"),
                   action: { codexStore.refreshQuota() }) {
            if codexStore.quotaLoading {
                RollingNumberText("额度…")
                    .font(Theme.Font.tileValueSmall)
                    .foregroundColor(Theme.textTertiary())
            } else if codexStore.quotaWindows.isEmpty {
                // The reason, not a blank: an empty gauge reads as "loading",
                // and the fetcher's note distinguishes "未登录" from "没有窗口"
                // from a transient failure.
                Text(codexStore.quotaNote ?? "点击刷新")
                    .font(Theme.Font.tileLabel)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                CodexQuotaGauges(windows: codexStore.quotaWindows, compact: false)
            }
        }
    }

    // MARK: 当前模型

    /// One row per client: eyebrow, model, vendor. The two stacks are
    /// independent stores with their own active selection, so they get one row
    /// each rather than one "current model" that silently means Claude Code.
    ///
    /// The Claude row reads `currentEnv` (settings.json) rather than the
    /// provider list, because that is what Claude Code will actually run — the
    /// same source the widget snapshot and `buildEnv` use. The list is the
    /// fallback for a provider that has never been activated.
    private func modelCard(cc: ClaudeRoute, codex: CodexProvider?) -> some View {
        GlanceCard(title: "当前模型", kind: .config,
                   tint: Theme.claude, ink: Theme.Ink.claude,
                   help: "Claude Code：\(cc.model) · \(cc.vendor)\nCodex：\(codex?.activeModel?.name ?? "未配置") · \(codex?.name ?? "添加供应商")") {
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                GlanceRouteRow(eyebrow: "CC", tint: Theme.claude, ink: Theme.Ink.claude,
                               model: cc.model, vendor: cc.vendor)
                GlanceRouteRow(eyebrow: "Codex", tint: Theme.codex, ink: Theme.Ink.codex,
                               model: codex?.activeModel?.name ?? "未配置",
                               vendor: codex?.name ?? "添加供应商")
            }
        }
    }

    // MARK: 今日花费

    /// Today's list-price estimate, through the same `ModelPricing.present`
    /// path as every other money figure in the app — so the 分列 / 折算
    /// preference and the "no rate, showing two currencies" fallback behave
    /// here identically, instead of this card inventing its own arithmetic.
    private func costCard(_ today: TodayUsage) -> some View {
        let shown = presented(today.cost.cost)
        let primary = shown.primary.map { ModelPricing.format($0.amount, currency: $0.currency) }
        return GlanceCard(title: "今日花费", kind: .cost,
                   tint: Theme.chartAmber, ink: Theme.Ink.warning,
                   help: Self.costHelp(today, shown: shown)) {
            VStack(alignment: .leading, spacing: 2) {
                RollingNumberText(primary ?? "—")
                    .font(Theme.Font.tileValueSmall)
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(Self.costCaption(today, shown: shown))
                    .font(Theme.Font.tileDetail)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
            }
        }
    }

    // MARK: 今日 Token

    /// Today's tokens with the day-over-day pace. The caption is what makes a
    /// single day's number readable: 3.28亿 is neither good nor bad without
    /// yesterday's 3.4亿 beside it.
    private func tokenCard(_ today: TodayUsage) -> some View {
        let pace = today.pace
        return GlanceCard(title: "今日 Token", kind: .tokens,
                   tint: Theme.chartPurple, ink: Theme.Ink.cursor,
                   help: "今天 \(UsageStats.formatTokens(today.tokens)) tokens · \(today.calls.formatted()) 次请求"
                       + (pace.map { "\n昨日 \(UsageStats.formatTokens(today.yesterdayTokens))（\(Int(($0 * 100).rounded()))%）" } ?? "")) {
            VStack(alignment: .leading, spacing: 2) {
                RollingNumberText(UsageStats.formatTokens(today.tokens))
                    .font(Theme.Font.tileValueSmall)
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let pace {
                    RollingNumberText("昨日的 \(Int((pace * 100).rounded()))%")
                        .font(Theme.Font.tileDetail)
                        .foregroundColor(pace >= 1 ? Theme.Ink.warning : Theme.textTertiary())
                        .lineLimit(1)
                } else {
                    Text(today.calls > 0 ? "暂无昨日对照" : "暂无用量")
                        .font(Theme.Font.tileDetail)
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: Money presentation

    /// The presentation preferences this card renders, subscribed individually
    /// — observing `AppPreferences.shared` wholesale re-evaluated the row for
    /// every unrelated write.
    @State private var costDisplay = AppPreferences.shared.costDisplay
    @ObservedObject private var fx = ExchangeRate.shared

    private func presented(_ cost: ModelPricing.Cost) -> ModelPricing.Presented {
        ModelPricing.present(cost, display: costDisplay, rate: fx.effectiveRate)
    }

    /// The second line under the headline: the other currency (分列), or the
    /// reason there is no money at all. Never a blank next to a figure — see
    /// `UsageModelCard.costLabel` for the same rule.
    private static func costCaption(_ today: TodayUsage, shown: ModelPricing.Presented) -> String {
        if let secondary = shown.secondary {
            return "另有 " + ModelPricing.format(secondary.amount, currency: secondary.currency)
        }
        if let reason = shown.fallbackReason { return reason }
        if today.cost.unpricedModels > 0 { return "\(today.cost.unpricedModels) 个模型未计价" }
        return today.cost.isEmpty ? "暂无用量" : ""
    }

    private static func costHelp(_ today: TodayUsage, shown: ModelPricing.Presented) -> String {
        var lines = ["按官方刊例价估算（非账单）"]
        if let primary = shown.primary {
            lines.append("今日 " + ModelPricing.format(primary.amount, currency: primary.currency))
        }
        if today.cost.unpricedModels > 0 {
            lines.append("\(today.cost.unpricedModels) 个模型没有刊例价，未计入合计")
        }
        lines.append("\(today.cost.pricedModels) 个模型已计价")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Route row

/// One client's active route inside 当前模型: eyebrow, model, vendor.
///
/// Truncation is on the model, not the vendor: a relay name is short and
/// identifying ("AiBox"), a model slug is long and its tail is the version —
/// `.middle` keeps both ends. The row is also the reason this card cannot be a
/// plain metric tile: two independent stacks share it.
private struct GlanceRouteRow: View {
    let eyebrow: String
    let tint: Color
    let ink: Color
    let model: String
    let vendor: String

    var body: some View {
        HStack(spacing: Theme.Space.s8) {
            Text(eyebrow)
                .font(Theme.Font.eyebrow)
                .foregroundColor(ink)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(model)
                    .font(Theme.Font.rowTitle)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(vendor)
                    .font(Theme.Font.tileDetail)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Circle().fill(tint.opacity(0.7)).frame(width: 6, height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(eyebrow) \(model)，\(vendor)")
    }
}

/// What Claude Code is actually running. A tiny value type because the model
/// name has two candidate sources and the fallback rule should be written once.
struct ClaudeRoute {
    var model: String
    var vendor: String

    static func of(_ store: ProviderStore) -> ClaudeRoute {
        let active = store.activeProvider
        // settings.json wins when it names a model: that is what the CLI will
        // launch with, and it is what `buildEnv` writes. The provider list is
        // the fallback for a vendor that has never been activated (so
        // `currentEnv` is still the official one).
        let live = store.currentEnv?.ANTHROPIC_MODEL.trimmingCharacters(in: .whitespaces) ?? ""
        let model = live.isEmpty ? (active?.activeModel?.name ?? "") : live
        return ClaudeRoute(model: model.isEmpty ? "未配置" : model,
                           vendor: active?.name ?? "添加供应商")
    }
}

// MARK: - Card surface

/// One cell of the glance row.
///
/// Built on `.tile()` rather than `MetricTile`: the four cards have four
/// different shapes (a gauge pair, two route rows, two money figures), and a
/// metric-tile primitive that took all four as opaque content would be that
/// same surface with an empty label. What they *do* share is the surface
/// language — accent wash, inner frame ring, depth lens, hover edge — which is
/// what `.tile()` is for.
///
/// No `lift:` opt-out and no `@State` hover flag of its own: a hovered tile is
/// a pointer *state* change, not a loop (see DESIGN.md), and the flag is unused
/// by the content, so `.hoverTile()` owns it.
private struct GlanceCard<Content: View>: View {
    let title: String
    let kind: InstrumentGlyph.Kind
    let tint: Color
    let ink: Color
    var help: String? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        let card = VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: Theme.Space.s8) {
                InstrumentBadge(kind: kind, size: 26, tint: ink)
                Text(title)
                    .font(Theme.Font.tileLabel)
                    .tracking(Theme.Tracking.caption)
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 4)
                if action != nil {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.s16)
        .frame(maxWidth: .infinity, minHeight: 118, maxHeight: .infinity, alignment: .topLeading)
        .hoverTile(tint: tint, dense: false,
                   // The header mark sits top-leading, so the depth rings keep
                   // the free top-trailing corner.
                   lens: DepthLensSpec(tint: tint, size: 118))
        .help(help ?? title)

        if let action {
            Button(action: action) { card }
                .buttonStyle(.pressable)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            card
        }
    }
}
