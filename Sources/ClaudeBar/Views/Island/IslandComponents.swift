import SwiftUI

// MARK: - Agent mark

/// An agent family's mark in a tinted well. While busy, a short arc orbits
/// it.
///
/// The orbit is `DecorativeMotion(kind: .arc)` — a Core Animation layer the
/// render server interpolates, gated on the window's occlusion state, the same
/// way the fan rotors and the rest of the app's decoration are.
///
/// The version this replaced drove the same arc with SwiftUI `.rotationEffect`
/// under a `repeatForever`, which held an animated transaction open for as long
/// as the badge was busy; while a transaction is in flight *every* display
/// cycle re-runs the whole hosting view's layout, and the island's panel is the
/// full expanded box (640 × 386) even while collapsed. The two were measured
/// against each other rather than against a mutated build — same launcher, same
/// `-g` tree, the bundle swapped under a fixed path and sampled three times
/// each, alternating old / new / old / new so machine load cannot bias one arm:
///
/// | arm | `NSHostingView.layout()` share of main-thread samples | median |
/// |---|---|---|
/// | old, SwiftUI `repeatForever` | 49.5 / 48.7 / 51.4, 41.7 / 44.7 / 49.0 | 48.8 % |
/// | new, Core Animation `.arc`  | 36.3 / 28.9 / 39.0, 28.2 / 34.2 / 29.5 | 31.9 % |
///
/// The ranges are disjoint, and the `runAnimationGroup` sample counts move with
/// them (≈420 while the old arc ran, ≈285 for the new one), which is the
/// transaction count the explanation predicts. What the arc costs on top of
/// that is its layer's presence in the display list, not an animation: forcing
/// `active: false` so the view is still mounted but never animates measures
/// 33.4 %, inside the new arm's range, while taking the badge's orbit out of
/// the tree altogether measures 25.2 %.
///
/// `DecorativeMotion` already checks both gates the old version had — the
/// window's visibility and `accessibilityReduceMotion` — via its callers'
/// `surfaceIsVisible`, so nothing here has to.
struct IslandAgentBadge: View {
    let agent: IslandAgent
    var busy = false
    var size: CGFloat = 26

    var body: some View {
        let tint = IslandStyle.color(agent)
        ZStack {
            Circle().fill(tint.opacity(0.16))
            IslandAgentMark(agent: agent)
                .frame(width: size * 0.56, height: size * 0.56)
            if busy {
                IslandOrbit(color: tint, lineWidth: max(1.5, size * 0.075))
                    .padding(-size * 0.1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(agent.label + (busy ? " 运行中" : ""))
    }
}

struct IslandAgentMark: View {
    let agent: IslandAgent

    var body: some View {
        switch agent {
        case .claude:
            ProductBrandMark(codex: false)
        case .codex:
            ProductBrandMark(codex: true)
        case .cursor:
            Image(systemName: "cursorarrow.rays")
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
                .foregroundStyle(IslandStyle.color(.cursor))
        }
    }
}

/// A 100°, gradient-tailed arc spinning once every 1.1 s.
///
/// The shape lives in `DecorativeMotion(kind: .arc)` and is drawn by Core
/// Animation, so this view does no per-frame work and never holds an animated
/// transaction open. `active` carries the "busy" gate; the render-server layer
/// stops itself when its window is hidden.
struct IslandOrbit: View {
    let color: Color
    var lineWidth: CGFloat = 2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DecorativeMotion(kind: .arc, tint: color, active: !reduceMotion, lineWidth: lineWidth)
    }
}

// MARK: - Session row

/// One live session: badge, project, what it is doing, context fuel, and a
/// hover affordance that says what a click does.
struct IslandSessionRow: View {
    let session: IslandSession
    let cost: ModelPricing.Estimate?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                IslandAgentBadge(agent: session.agent, busy: session.isBusy)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.project.isEmpty ? session.agent.label : session.project)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(IslandStyle.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if hovered {
                            Image(systemName: "arrow.up.forward")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(IslandStyle.color(session.agent))
                        }
                    }
                    HStack(spacing: 6) {
                        subtitle
                            .frame(maxWidth: .infinity, alignment: .leading)
                        RollingNumberText(costLabel)
                            .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(hasPricedCost ? IslandStyle.amber : IslandStyle.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .layoutPriority(1)
                        if session.contextRatio > 0 {
                            IslandContextGauge(ratio: session.contextRatio, compact: true)
                                .fixedSize()
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: IslandStyle.sessionRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.07 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { if hovered != $0 { hovered = $0 } }
        .animation(IslandStyle.hoverSpring, value: hovered)
        .help("\(session.cwd)\n\(costDetail)")
    }

    private var costLabel: String {
        if let dominant = cost?.cost.dominant {
            return ModelPricing.format(dominant.amount, currency: dominant.currency)
        }
        if let cost, cost.unpricedModels > 0 { return "未计价" }
        return "—"
    }

    private var hasPricedCost: Bool { cost?.cost.dominant != nil }

    private var costDetail: String {
        guard let cost else {
            return session.agent == .cursor ? "Cursor 暂无独立会话 token 用量" : "该会话暂无可计价用量"
        }
        var parts: [String] = []
        if let dominant = cost.cost.dominant {
            parts.append(ModelPricing.format(dominant.amount, currency: dominant.currency))
        }
        if let secondary = cost.cost.secondary {
            parts.append(ModelPricing.format(secondary.amount, currency: secondary.currency))
        }
        if cost.unpricedModels > 0 { parts.append("\(cost.unpricedModels) 个模型未计价") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var subtitle: some View {
        if session.isBusy {
            Text(busyLine)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(IslandStyle.color(session.agent).opacity(0.95))
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            // Coarse relative time; a 30 s tick is plenty and keeps the
            // timeline from waking every second.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("等待输入 · " + IslandFormat.ago(session.updatedAt, now: context.date))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(IslandStyle.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var busyLine: String {
        if !session.activity.isEmpty { return session.activity }
        if !session.model.isEmpty { return session.model + " · 运行中" }
        return "思考中…"
    }
}

/// Context-window fuel: a 36pt capsule and the percentage, amber past 60 %,
/// red past 85 % — the same thresholds as `Theme.contextColor`.
struct IslandContextGauge: View {
    let ratio: Double
    var compact = false

    private var color: Color {
        if ratio < 0.6 { return IslandStyle.mint }
        if ratio < 0.85 { return IslandStyle.amber }
        return IslandStyle.coral
    }

    var body: some View {
        HStack(spacing: 6) {
            if !compact {
                Capsule()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 36, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(color).frame(width: max(4, 36 * min(1, ratio)), height: 4)
                    }
            }
            RollingNumberText("\(Int((ratio * 100).rounded()))%")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(compact ? color : IslandStyle.textSecondary)
                .frame(width: 30, alignment: .trailing)
        }
        .help("上下文窗口占用")
    }
}

/// One module's icon well. Its geometry is a constant so a `Canvas`-drawn
/// product mark and an instrument glyph reserve exactly the same square — that
/// equality is what lets a route page and a hardware page share one grid.
///
/// Instrument glyphs are drawn at 0.62 of the well, the same fraction the
/// product marks use, so the two mark families carry the same optical weight.
struct IslandMarkWell: View {
    let kind: InstrumentGlyph.Kind?
    let mark: IslandAgent?
    let tint: Color

    init(kind: InstrumentGlyph.Kind, tint: Color) {
        self.kind = kind
        self.mark = nil
        self.tint = tint
    }

    init(mark: IslandAgent, tint: Color) {
        self.kind = nil
        self.mark = mark
        self.tint = tint
    }

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.16))
            if let mark {
                IslandAgentMark(agent: mark)
                    .frame(width: IslandStyle.markWellSize * 0.62, height: IslandStyle.markWellSize * 0.62)
            } else if let kind {
                InstrumentGlyph(kind: kind, tint: tint)
                    .frame(width: IslandStyle.markWellSize * 0.62, height: IslandStyle.markWellSize * 0.62)
            }
        }
        .frame(width: IslandStyle.markWellSize, height: IslandStyle.markWellSize)
        .accessibilityHidden(true)
    }
}

// MARK: - Usage card

/// Today's number, a 30-day histogram you can scrub by hovering, and the
/// month's pace with its source split underneath.
struct IslandUsageCard: View {
    let usage: IslandUsage
    @State private var scrubIndex: Int?
    @State private var histogramWidth: CGFloat = 1
    /// Re-identifies this card's figures when the token unit style changes —
    /// see `TokenStyleGenerationKey`.
    @Environment(\.tokenStyleGeneration) private var tokenStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                hero
                    .frame(maxWidth: .infinity, alignment: .leading)
                costHero
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 64, alignment: .top)
            IslandHistogram(days: usage.days, highlighted: scrubIndex)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let next = index(at: point.x)
                        if next != scrubIndex { scrubIndex = next }
                    case .ended: if scrubIndex != nil { scrubIndex = nil }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { histogramWidth = $0 }
            monthLine
                .frame(height: 14)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        // Scoped to this card's own figures: the identity change that re-renders
        // them must not reach the session strip or the header beside it.
        .id(tokenStyle)
    }

    private func index(at x: CGFloat) -> Int? {
        guard !usage.days.isEmpty, histogramWidth > 0 else { return nil }
        let slot = histogramWidth / CGFloat(usage.days.count)
        return max(0, min(usage.days.count - 1, Int(x / slot)))
    }

    private var scrubbed: IslandDay? {
        guard let scrubIndex, usage.days.indices.contains(scrubIndex) else { return nil }
        return usage.days[scrubIndex]
    }

    private var hero: some View {
        let day = scrubbed
        let value = day?.tokens ?? usage.today
        return VStack(alignment: .leading, spacing: 2) {
            Text(day.map { IslandFormat.dayLabel($0.date) } ?? "今日 Token")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(IslandStyle.textTertiary)
                .contentTransition(.opacity)
            RollingNumberText(UsageStats.formatTokens(value))
                .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(day == nil ? IslandStyle.mint : IslandStyle.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            RollingNumberText(heroCaption(day))
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(IslandStyle.textSecondary)
                .lineLimit(1)
        }
        .animation(.snappy(duration: 0.18), value: value)
    }

    private var costHero: some View {
        let day = scrubbed
        let estimate = day?.cost ?? usage.todayCost
        return VStack(alignment: .leading, spacing: 2) {
            Text(day.map { IslandFormat.dayLabel($0.date) + " 花费" } ?? "今日花费")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(IslandStyle.textTertiary)
            RollingNumberText(estimate.cost.dominant.map { ModelPricing.format($0.amount, currency: $0.currency) } ?? "—")
                .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(IslandStyle.amber)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if !costCaption(estimate).isEmpty {
                RollingNumberText(costCaption(estimate))
                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(IslandStyle.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func costCaption(_ estimate: ModelPricing.Estimate) -> String {
        if let secondary = estimate.cost.secondary {
            return "另有 " + ModelPricing.format(secondary.amount, currency: secondary.currency)
        }
        if estimate.unpricedModels > 0 { return "\(estimate.unpricedModels) 个模型未计价" }
        return estimate.isEmpty ? "暂无用量" : ""
    }

    private func heroCaption(_ day: IslandDay?) -> String {
        if let day {
            let peak = usage.days.map(\.tokens).max() ?? 0
            guard peak > 0, day.tokens > 0 else { return "无用量" }
            return "峰值的 \(Int((Double(day.tokens) / Double(peak) * 100).rounded()))%"
        }
        let calls = "\(usage.todayCalls.formatted()) 次"
        guard let pace = IslandUsage.pace(usage.today, usage.yesterday) else { return calls }
        return "昨日的 \(Int((pace * 100).rounded()))% · " + calls
    }

    private var monthLine: some View {
        HStack(spacing: 10) {
            Text("本月")
                .foregroundStyle(IslandStyle.textTertiary)
            RollingNumberText(UsageStats.formatTokens(usage.month))
                .foregroundStyle(IslandStyle.textPrimary)
            if let pace = IslandUsage.pace(usage.month, usage.lastMonthSameSpan) {
                Text("上月同期 \(Int((pace * 100).rounded()))%")
                    .foregroundStyle(pace >= 1 ? IslandStyle.amber : IslandStyle.textSecondary)
            }
            Spacer(minLength: 8)
            IslandSourceSplit(values: usage.monthBySource)
                .frame(width: 100, height: 6)
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
        .lineLimit(1)
    }
}

/// 30 bars in one `Canvas` pass: one view, one draw, regardless of count.
struct IslandHistogram: View {
    let days: [IslandDay]
    let highlighted: Int?

    var body: some View {
        Canvas { context, size in
            guard !days.isEmpty else { return }
            let peak = CGFloat(max(days.map(\.tokens).max() ?? 0, 1))
            let slot = size.width / CGFloat(days.count)
            let barWidth = max(2, slot * 0.62)
            for (index, day) in days.enumerated() {
                let fraction = CGFloat(day.tokens) / peak
                let height = day.tokens > 0 ? max(3, size.height * fraction) : 2
                let rect = CGRect(x: CGFloat(index) * slot + (slot - barWidth) / 2,
                                  y: size.height - height, width: barWidth, height: height)
                let isToday = index == days.count - 1
                let color: Color
                if index == highlighted {
                    color = .white
                } else if isToday {
                    color = IslandStyle.mint
                } else {
                    color = Color.white.opacity(day.tokens > 0 ? 0.24 : 0.08)
                }
                context.fill(Path(roundedRect: rect, cornerRadius: min(barWidth / 2, 2)), with: .color(color))
            }
        }
        .accessibilityLabel("近 30 天用量")
    }
}

/// Month-to-date share per source as one segmented capsule.
struct IslandSourceSplit: View {
    let values: [Int]

    var body: some View {
        let total = max(values.reduce(0, +), 1)
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(Array(UsageSource.allCases.enumerated()), id: \.element) { index, source in
                    let value = index < values.count ? values[index] : 0
                    if value > 0 {
                        Capsule()
                            .fill(IslandStyle.color(source))
                            .frame(width: max(3, (proxy.size.width - 4) * CGFloat(value) / CGFloat(total)))
                    }
                }
            }
        }
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .clipShape(Capsule())
        .help(helpText(total: total))
    }

    private func helpText(total: Int) -> String {
        UsageSource.allCases.enumerated().map { index, source in
            let value = index < values.count ? values[index] : 0
            return "\(source.label) \(UsageStats.formatTokens(value)) · \(Int((Double(value) / Double(total) * 100).rounded()))%"
        }.joined(separator: "\n")
    }
}

// MARK: - Formatting

enum IslandFormat {
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86400)) 天前"
    }

    static func dayLabel(_ date: Date) -> String {
        UsageStats.formatter("M月d日 EEE").string(from: date)
    }
}
