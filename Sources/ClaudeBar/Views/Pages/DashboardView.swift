import SwiftUI

/// Dashboard page: the Dispatch world's command view. A live radar renders
/// running agents in orbit; a telemetry readout panel carries the four key
/// numbers; the signal history traces activity over time; the channel list
/// and usage Top finish the picture. All data flows from `ProviderStore`.
struct DashboardView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @State private var refreshTick = 0
    @State private var selectedBlip: RadarBlip?
    /// Injected by the window so a readout/radar tap navigates to the page.
    var onNavigate: (AppPage) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s24) {
                titleBar

                HStack(alignment: .top, spacing: Theme.Space.s16) {
                    radarCard
                    readoutPanel
                }

                GlassEffectContainer(spacing: Theme.Space.s24) {
                    VStack(alignment: .leading, spacing: Theme.Space.s24) {
                        signalHistory
                        activityFeed
                        miniUsage
                    }
                }
            }
            .padding(Theme.Space.s24)
        }
        .background(Theme.base0.opacity(0.30))
    }

    // MARK: Title

    private var titleBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("概览")
                .font(Theme.Font.titleLarge)
                .tracking(Theme.Tracking.titleLarge)
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Button(action: {
                refreshTick += 1
                providerStore.refresh()
            }) {
                Label("刷新", systemImage: "arrow.clockwise")
                    .font(Theme.Font.bodySmall)
            }
            .buttonStyle(.glass)
            .tint(Theme.claude)
            .symbolEffect(.bounce, value: refreshTick)
            .sensoryFeedback(.selection, trigger: refreshTick)
        }
    }

    // MARK: Radar hero

    /// The signature: a live radar of running agents. Tapping a blip jumps to
    /// the sessions page; the legend maps the two signals.
    private var radarCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            Text("活动雷达")
                .font(Theme.Font.titleSmall)
                .tracking(Theme.Tracking.titleSmall)
                .foregroundColor(Theme.textPrimary)
            LiveRadar { blip in
                withAnimation(Theme.Animation.smooth) { selectedBlip = blip }
            }
            .frame(width: 348, height: 348)
            if let blip = selectedBlip {
                RadarAgentDetail(blip: blip,
                                 onClose: { withAnimation(Theme.Animation.smooth) { selectedBlip = nil } },
                                 onOpenSessions: { onNavigate(.sessions) })
            }
            HStack(spacing: 14) {
                legendDot(Theme.claude, "Claude")
                legendDot(Theme.cursor, "Cursor")
                Spacer()
                Text("\(runningCount) 运行")
                    .font(Theme.Font.captionMono)
                    .foregroundColor(Theme.claudeHi)
                    .contentTransition(.numericText())
                    .animation(Theme.Animation.smooth, value: runningCount)
            }
        }
        .padding(Theme.Space.s16)
        .panelCard()
        .frame(width: 396)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(label)
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textSecondary)
        }
    }

    // MARK: Telemetry readout panel

    /// The four key numbers as an instrument register: label + mono value,
    /// hairline-divided. Each reading carries its signal's dot; tap navigates.
    private var readoutPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("系统遥测")
                .font(Theme.Font.titleSmall)
                .tracking(Theme.Tracking.titleSmall)
                .foregroundColor(Theme.textPrimary)
                .padding(.bottom, Theme.Space.s8)
            Divider().overlay(Theme.divider)

            readout("活跃配置", value: activeConfigLabel, font: Theme.Font.bodyLarge.weight(.semibold)) { onNavigate(.providers) }
            Divider().overlay(Theme.divider)
            readout("余额", value: balanceLabel) { onNavigate(.providers) }
            Divider().overlay(Theme.divider)
            readout("会话", value: sessionReadout) { onNavigate(.sessions) }
            Divider().overlay(Theme.divider)
            readout("Token 总量", value: tokenTotalLabel) { onNavigate(.usage) }
        }
        .padding(Theme.Space.s16)
        .panelCard()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readout(_ label: String, value: String,
                         font: Font = Theme.Font.displayMetricSmall,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(Theme.Font.caption)
                    .tracking(Theme.Tracking.caption)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Text(value)
                    .font(font)
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                    .animation(Theme.Animation.smooth, value: value)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help("跳转")
    }

    // MARK: Readout values

    private var activeConfigLabel: String {
        let p = providerStore.providers.first(where: { $0.id == providerStore.activeProviderID })?.name
        let m = providerStore.currentEnv?.ANTHROPIC_MODEL
        if let p { return m.map { "\(p) / \($0)" } ?? p }
        return "未配置"
    }

    private var balanceLabel: String {
        if providerStore.balanceLoading { return "⋯" }
        if let b = providerStore.balanceText { return "¥\(b)" }
        return "—"
    }

    private var sessionReadout: String {
        let alive = providerStore.sessions.filter(\.isAlive).count
        let cursor = providerStore.cursorSessions.count
        return "\(runningCount)/\(alive + cursor)"
    }

    private var tokenTotalLabel: String {
        UsageStats.formatTokens(providerStore.usageStats.reduce(0) { $0 + $1.totalTokens })
    }

    private var runningCount: Int {
        providerStore.sessions.filter { $0.isAlive && $0.status == .busy }.count
            + providerStore.cursorSessions.filter { $0.status == .active }.count
    }

    // MARK: Signal history

    /// The live activity heartbeat: a Canvas waveform whose amplitude tracks
    /// how many sessions are busy right now.
    private var signalHistory: some View {
        let busy = Double(runningCount)
        let level = min(1, busy / 4)
        return VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack {
                Text("信号历史")
                    .font(Theme.Font.titleSmall)
                    .tracking(Theme.Tracking.titleSmall)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(level > 0.05 ? Theme.claude : Theme.statusIdle)
                        .frame(width: 5, height: 5)
                        .symbolEffect(.pulse, options: .repeating, isActive: level > 0.05)
                    Text(level > 0.05 ? "\(Int(busy)) 运行中" : "空闲")
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.textSecondary)
                        .contentTransition(.numericText())
                        .animation(Theme.Animation.smooth, value: busy)
                }
            }
            LivePulseGraph(level: level, label: "\(Int(busy)) busy")
        }
        .padding(Theme.Space.s16)
        .panelCard()
    }

    // MARK: Activity feed — live channels

    private var activityFeed: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            Text("活跃频道")
                .font(Theme.Font.titleSmall)
                .tracking(Theme.Tracking.titleSmall)
                .foregroundColor(Theme.textPrimary)
            let alive = providerStore.sessions.filter(\.isAlive)
            if alive.isEmpty && providerStore.cursorSessions.isEmpty {
                Text("暂无活跃会话")
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textTertiary())
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 28)
            } else {
                LazyVStack(spacing: Theme.Space.s4) {
                    ForEach(alive.prefix(5)) { session in
                        ActivityFeedItem(
                            session: session,
                            kind: .claude,
                            text: "\(session.projectFolder) · \(session.currentActivity.isEmpty ? "idle" : session.currentActivity)"
                        )
                    }
                    ForEach(providerStore.cursorSessions.prefix(3)) { session in
                        ActivityFeedItem(
                            session: session,
                            kind: .cursor,
                            text: "\(session.projectFolder) · \(session.currentActivity.isEmpty ? "idle" : session.currentActivity)"
                        )
                    }
                }
                .animation(Theme.Animation.smooth, value: alive.map(\.pid))
            }
        }
        .padding(Theme.Space.s16)
        .panelCard()
    }

    // MARK: Mini usage

    private var miniUsage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            HStack {
                Text("用量 Top")
                    .font(Theme.Font.titleSmall)
                    .tracking(Theme.Tracking.titleSmall)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(UsageStats.label(for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate))
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textSecondary)
            }
            ForEach(Array(providerStore.usageStats.prefix(5).enumerated()), id: \.element.id) { _, stat in
                MiniUsageRow(stat: stat)
            }
            if providerStore.usageStats.isEmpty && !providerStore.usageLoading {
                Text("无用量数据")
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textTertiary())
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
        }
        .padding(Theme.Space.s16)
        .panelCard()
    }
}

// MARK: - Activity feed item

/// A single line in the Dashboard activity feed. Clicking expands it in place
/// to reveal session detail — no page navigation, the detail unfolds in place.
private struct ActivityFeedItem<S: Identifiable>: View {
    enum Kind { case claude, cursor }
    let session: S
    let kind: Kind
    let text: String
    var tint: Color { kind == .cursor ? Theme.cursor : Theme.claude }

    @State private var isHovered = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
                    .opacity(isHovered || isExpanded ? 1 : 0)
                Circle().fill(tint.opacity(0.8)).frame(width: 4, height: 4)
                Text(text)
                    .font(Theme.Font.bodySmall)
                    .foregroundColor(isHovered ? Theme.textPrimary.opacity(0.95) : Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(tint.opacity(isHovered ? 0.08 : 0))
            )
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(Theme.Animation.bouncy) { isExpanded.toggle() }
            }
            .hoverState($isHovered)

            if isExpanded {
                ActivityDetail(session: session, kind: kind, tint: tint)
                    .padding(.leading, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity))
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity),
            removal: .opacity))
    }
}

// MARK: - Activity detail (expanded)

private struct ActivityDetail<S: Identifiable>: View {
    let session: S
    let kind: ActivityFeedItem<S>.Kind
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = session as? SessionInfo {
                claudeDetail(s)
            } else if let c = session as? CursorSessionInfo {
                cursorDetail(c)
            }
        }
        .font(Theme.Font.caption)
        .foregroundColor(Theme.textSecondary)
    }

    @ViewBuilder
    private func claudeDetail(_ s: SessionInfo) -> some View {
        if s.contextTokens > 0 {
            HStack(spacing: 8) {
                Text(s.contextLabel).font(Theme.Font.captionMono).foregroundColor(Theme.contextColor(s.contextRatio))
                ContextBar(ratio: s.contextRatio).frame(maxWidth: 160)
            }
        }
        HStack(spacing: 10) {
            if !s.model.isEmpty { Label(s.model, systemImage: "cpu").labelStyle(.titleAndIcon) }
            Label("\(s.messageCount) msgs", systemImage: "bubble.left")
            Label(s.relativeUpdated, systemImage: "clock")
        }
        if !s.currentActivity.isEmpty {
            Text("当前: \(s.currentActivity)").font(Theme.Font.captionMono).foregroundColor(tint)
        }
    }

    @ViewBuilder
    private func cursorDetail(_ c: CursorSessionInfo) -> some View {
        if c.contextPercent >= 0 {
            HStack(spacing: 8) {
                Text(c.contextLabel).font(Theme.Font.captionMono).foregroundColor(Theme.contextColor(c.contextRatio))
                ContextBar(ratio: c.contextRatio).frame(maxWidth: 160)
            }
        }
        HStack(spacing: 10) {
            Label("\(c.messageCount) msgs", systemImage: "bubble.left")
            Label(c.relativeUpdated, systemImage: "clock")
        }
        if !c.currentActivity.isEmpty {
            Text("当前: \(c.currentActivity)").font(Theme.Font.captionMono).foregroundColor(tint)
        }
    }
}

// MARK: - Mini usage row

/// Dashboard's compact usage row: model + token count, with an inline
/// proportional bar that fills from the leading edge.
private struct MiniUsageRow: View {
    let stat: ModelUsage
    @State private var isHovered = false

    var body: some View {
        let ratio = min(1, CGFloat(stat.totalTokens) / 200000)
        return HStack(spacing: 8) {
            Text(stat.model)
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.cardFill(0.06))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.barGradient(for: stat.model))
                        .frame(width: max(3, geo.size.width * ratio))
                        .opacity(isHovered ? 1 : 0.85)
                }
            }
            .frame(height: 6)
            Text(UsageStats.formatTokens(stat.totalTokens))
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textTertiary())
                .contentTransition(.numericText())
                .animation(Theme.Animation.smooth, value: stat.totalTokens)
        }
        .scaleEffect(isHovered ? 1.01 : 1)
        .hoverState($isHovered)
    }
}
