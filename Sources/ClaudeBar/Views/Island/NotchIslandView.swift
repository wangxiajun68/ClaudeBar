import SwiftUI

// MARK: - Style

/// Island tokens. The island lives on hardware black whatever the app theme
/// is, so it keeps its own palette instead of reading `Theme`'s light/dark
/// surfaces.
enum IslandStyle {
    // Geometry
    static let topFlare: CGFloat = 6
    static let collapsedBottomRadius: CGFloat = 9
    static let alertBottomRadius: CGFloat = 22
    static let expandedBottomRadius: CGFloat = 26
    static let wingWidth: CGFloat = 52
    static let sidePadding: CGFloat = 12
    static let alertBodyHeight: CGFloat = 54
    static let minAlertWidth: CGFloat = 380
    static let minExpandedWidth: CGFloat = 520

    static let contentTopGap: CGFloat = 6
    static let sectionGap: CGFloat = 8
    static let bottomPadding: CGFloat = 12
    static let sessionRowHeight: CGFloat = 44
    static let sessionRowSpacing: CGFloat = 4
    /// Two columns and two visible rows; additional sessions scroll inside.
    static let sessionColumns = 2
    static let maxSessionRows = 2
    static var sessionLaneHeight: CGFloat {
        CGFloat(maxSessionRows) * sessionRowHeight + CGFloat(maxSessionRows - 1) * sessionRowSpacing
    }
    static let stripReadoutHeight: CGFloat = 14
    static var sessionStripHeight: CGFloat {
        sessionLaneHeight + sessionRowSpacing + stripReadoutHeight
    }
    static var expandedLaneHeight: CGFloat { sessionStripHeight }
    static let usageCardHeight: CGFloat = 156

    /// The one module of the agent mark's icon well: its geometry is a
    /// constant so a `Canvas`-drawn product mark and an instrument glyph
    /// reserve exactly the same square. That equality is what lets
    /// `IslandMarkWell` draw either family without a second size, and it is
    /// the last surviving constant from the deleted glance reel — see
    /// `docs/reviews/ui-audit-backlog.md` §4.
    static let markWellSize: CGFloat = 20

    /// Fixed transparent panel; every morph happens inside it. Derived from
    /// the tallest island there is (two session rows on the tallest notch),
    /// so it follows the geometry instead of being a number that has to be
    /// remembered whenever a band changes.
    static let panelWidth: CGFloat = 640
    static var panelSize: CGSize {
        CGSize(width: panelWidth, height: expandedMaxHeight + 48)
    }
    private static var expandedMaxHeight: CGFloat {
        let tallestNotch: CGFloat = 46
        return tallestNotch + contentTopGap + expandedLaneHeight
            + sectionGap + usageCardHeight + bottomPadding
    }

    // Surfaces & text
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.40)
    static let rim = Color.white.opacity(0.09)

    // Data hues, tuned for #000.
    static let mint = Color(hex: 0x5EEAD4)
    static let amber = Color(hex: 0xFFC53D)
    static let coral = Color(hex: 0xFF6B61)
    static let clay = Color(hex: 0xE8845E)
    static let cobalt = Color(hex: 0x7C9CFF)
    static let violet = Color(hex: 0xB79CFF)
    static let magenta = Color(hex: 0xF472B6)

    static func color(_ agent: IslandAgent) -> Color {
        switch agent {
        case .claude: return clay
        case .codex: return cobalt
        case .cursor: return violet
        }
    }

    static func color(_ source: UsageSource) -> Color {
        switch source {
        case .claude: return clay
        case .codex: return cobalt
        case .thirdParty: return magenta
        }
    }

    // Motion
    static let expandSpring = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let alertSpring = Animation.spring(response: 0.46, dampingFraction: 0.72)
    static let collapseSpring = Animation.spring(response: 0.34, dampingFraction: 0.92)
    static let morphSpring = Animation.spring(response: 0.36, dampingFraction: 0.86)
    static let hoverSpring = Animation.spring(response: 0.24, dampingFraction: 0.8)
}

/// What the island's buttons do; the controller owns the side effects
/// (closing the island, activating the app).
struct IslandActions {
    var openSession: (IslandSession) -> Void
    var openMainWindow: () -> Void
    var expandFromAlert: () -> Void
    var dismissAlert: () -> Void
}

/// The token-unit style, carried as an environment *value* rather than as an
/// `.id()` on the island.
///
/// The figures that format tokens are leaves (`RollingNumberText`), and their
/// inputs — the numbers — do not change when the unit style does, so they need
/// an identity change to re-render. Applying it here lets each leaf take it:
/// the three that exist (the wing total, the usage card's hero and month line)
/// re-identify, and nothing else on the island does. An `.id()` on the island
/// itself reset the whole panel instead — see the comment at that site.
struct TokenStyleGenerationKey: EnvironmentKey {
    static let defaultValue = TokenUnitStyle.chinese
}

extension EnvironmentValues {
    var tokenStyleGeneration: TokenUnitStyle {
        get { self[TokenStyleGenerationKey.self] }
        set { self[TokenStyleGenerationKey.self] = newValue }
    }
}


// MARK: - Root

/// Root of the island panel. One black shape morphs between three sizes —
/// collapsed (notch + wings), alert (a session just finished), expanded
/// (sessions + usage) — and the content for the current mode fades in on top.
///
/// Performance: the morph animates only the frame and two shape parameters;
/// transitions are opacity + scale (no blur), hardware islands cast no shadow,
/// detached surfaces use one static shadow and no decorative loops.
struct NotchIslandView: View {
    @ObservedObject var state: NotchIslandState
    @ObservedObject var model: IslandLiveModel
    let actions: IslandActions
    /// The two preferences the island renders, subscribed individually:
    /// observing all of `AppPreferences` would re-render the island for every
    /// unrelated settings change.
    @State private var tokenStyle = AppPreferences.shared.tokenUnitStyle
    @State private var vpnEnabled = AppPreferences.shared.vpnEnabled

    var body: some View {
        island
            .frame(width: IslandStyle.panelSize.width, height: IslandStyle.panelSize.height, alignment: .top)
            .environment(\.colorScheme, .dark)
            .onReceive(AppPreferences.shared.$tokenUnitStyle.removeDuplicates()) { tokenStyle = $0 }
            .onReceive(AppPreferences.shared.$vpnEnabled.removeDuplicates()) { vpnEnabled = $0 }
    }

    private var island: some View {
        let size = state.islandSize
        let shape = IslandShape(topFlare: state.topFlare, bottomRadius: state.bottomRadius,
                                detached: !state.geometry.hasHardwareNotch)
        return ZStack(alignment: .top) {
            shape.fill(state.geometry.hasHardwareNotch ? Color.black : Color(hex: 0x202328).opacity(0.98))

            switch state.mode {
            case .collapsed:
                if !state.geometry.hasHardwareNotch {
                    capsule
                        .contentShape(shape)
                        .onTapGesture(perform: actions.expandFromAlert)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("查看会话与用量")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { actions.expandFromAlert() }
                } else if state.showsWings {
                    wings.transition(.opacity)
                }
            case .peek:
                detachedPeek
                    .transition(.opacity)
            case .alert:
                if let alert = state.alert {
                    IslandAlertContent(alert: alert, notch: state.notch, width: size.width, actions: actions, detached: !state.geometry.hasHardwareNotch)
                        .id(alert.id)
                        .transition(.islandContent)
                }
            case .expanded:
                if state.geometry.hasHardwareNotch {
                    expandedContent.transition(.islandContent)
                } else {
                    detachedContent.transition(.opacity)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        // Token figures are formatted deep in child views whose inputs do not
        // change with the unit style, so they are re-identified from the one
        // view that owns that style instead of from an identity change applied
        // to the whole island.
        //
        // `.id(tokenStyle)` used to sit *here*, on the shape — so flipping the
        // unit in Settings threw away the identity of the silhouette, the rim
        // stroke and every child: an expanded island lost its `IslandIconButton`
        // hover, the session strip's scroll position and the usage card's scrub
        // index. The style still only flips from Settings, but the reset is now
        // scoped to the figures that actually need re-rendering.
        .environment(\.tokenStyleGeneration, tokenStyle)
        // Collapsed must be edge-less to melt into the notch; the rim light
        // only appears once the island has grown out of it.
        .overlay {
            shape.stroke(IslandStyle.rim, lineWidth: 1)
                .opacity(state.mode == .collapsed && state.geometry.hasHardwareNotch ? 0 : 1)
        }
        .shadow(color: .black.opacity(state.geometry.hasHardwareNotch ? 0 : 0.18), radius: 10, x: 0, y: 4)
        .opacity(state.isCollapsedInvisible ? 0 : 1)
    }

    // MARK: Collapsed

    private var capsule: some View {
        let busy = model.sessions.filter(\.isBusy).count
        let waiting = model.sessions.filter(\.isWaiting).count
        return HStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IslandStyle.textSecondary)
            if state.showsWings {
                Text(busy > 0 ? "\(busy) 个运行中" : "ClaudeBar")
                    .foregroundStyle(IslandStyle.textPrimary)
                Spacer(minLength: 4)
                Circle().fill(waiting > 0 ? IslandStyle.amber : (busy > 0 ? IslandStyle.mint : IslandStyle.textSecondary))
                    .frame(width: 5, height: 5)
                Text(waiting > 0 ? "\(waiting) 待确认" : (busy > 0 ? "\(model.sessions.count) 个会话" : "空闲"))
                    .foregroundStyle(IslandStyle.textSecondary)
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(width: state.collapsedSize.width, height: state.collapsedSize.height)
        .help("悬停查看摘要，点击打开会话")
    }

    private var detachedPeek: some View {
        Button(action: actions.expandFromAlert) {
            HStack(spacing: 10) {
                if let session = model.sessions.first {
                    IslandAgentBadge(agent: session.agent, size: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.project.isEmpty ? session.agent.label : session.project)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IslandStyle.textPrimary)
                        Text(DetachedSessionRow.detail(session))
                            .font(.system(size: 11))
                            .foregroundStyle(IslandStyle.textSecondary)
                    }
                } else {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(IslandStyle.textSecondary)
                    Text("暂无会话 · 点击查看用量")
                        .font(.system(size: 12))
                        .foregroundStyle(IslandStyle.textPrimary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(IslandStyle.textSecondary)
            }
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(width: 280, height: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开会话面板")
    }

    private var detachedContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("会话").font(.system(size: 13, weight: .semibold))
                Text("\(model.sessions.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(IslandStyle.textSecondary)
                Spacer()
                IslandIconButton(symbol: "arrow.up.forward", help: "打开工作台", action: actions.openMainWindow)
                IslandIconButton(symbol: "xmark", help: "收起面板", action: actions.dismissAlert)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            if model.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.stack").font(.system(size: 22, weight: .light))
                    Text("暂无会话").font(.system(size: 13, weight: .medium))
                    Text("开始使用 Claude、Codex 或 Cursor 后显示")
                        .font(.system(size: 10))
                }
                .foregroundStyle(IslandStyle.textSecondary)
                .frame(maxWidth: .infinity).frame(height: 168)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.sessions) { session in
                            DetachedSessionRow(session: session) { actions.openSession(session) }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .scrollIndicators(.visible)
                .scrollDisabled(model.sessions.count <= 3)
                .frame(height: 168)
            }
            HStack {
                Text(model.sessions.count > 3 ? "滚动查看更多会话" : "点击会话，回到工作现场")
                Spacer()
                if vpnEnabled {
                    Circle().fill(model.vpnRunning ? IslandStyle.mint : IslandStyle.textSecondary)
                        .frame(width: 5, height: 5)
                    Text(model.vpnRunning ? "代理已连接" : "代理未连接")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(IslandStyle.textSecondary)
            .padding(.horizontal, 16)
            .frame(height: 32)
            DetachedUsageSummary(usage: model.usage)
                .frame(height: 52)
                .background(Color.white.opacity(0.035))
                .overlay(alignment: .top) { Rectangle().fill(IslandStyle.rim).frame(height: 0.5) }
        }
        .foregroundStyle(IslandStyle.textPrimary)
        .frame(width: 360, height: 300)
    }

    private var wings: some View {
        HStack(spacing: 0) {
            leftWing
                .frame(width: IslandStyle.wingWidth - 8, alignment: .leading)
                .padding(.leading, 8)

            Color.clear.frame(width: state.notch.width)

            RollingNumberText(UsageStats.formatTokens(model.usage.today), rolls: false)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(IslandStyle.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: IslandStyle.wingWidth - 8, alignment: .trailing)
                .padding(.trailing, 8)
                // No implicit `.animation(value: model.usage.today)` here: the
                // figure is one of the sampler's 1 Hz outputs, so the modifier
                // opened a fresh animated transaction on every tick and an
                // in-flight transaction makes the display cycle re-lay out the
                // whole hosting view. The shared roll opens its transaction on
                // the value instead — see `Interaction.swift`.
                //
                // `rolls: false`: this wing is drawn on a panel that is on
                // screen permanently and repainted on every tick of the usage
                // sampler, and `UIWakePolicy` deliberately does *not* count the
                // collapsed island as a visible window. The collapsed readout is a
                // glance at a moving total, not a figure anyone reads digit by
                // digit, so it should not cost a display cycle of its own on a
                // surface the app has already decided is not being looked at.
                .id(tokenStyle)
        }
        .padding(.horizontal, IslandStyle.topFlare)
        .frame(height: state.notch.height)
    }

    /// Busy: the lead agent's mark with its orbit, plus a count when more
    /// than one session runs. Idle: today's pace against yesterday.
    @ViewBuilder private var leftWing: some View {
        let busy = model.busySessions
        if let lead = busy.first {
            HStack(spacing: 5) {
                IslandAgentBadge(agent: lead.agent, busy: true, size: 18)
                if busy.count > 1 {
                    RollingNumberText("\(busy.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(IslandStyle.color(lead.agent))
                        }
            }
            .transition(.opacity)
        } else {
            IslandPaceRing(pace: IslandUsage.pace(model.usage.today, model.usage.yesterday))
                .frame(width: 14, height: 14)
                .transition(.opacity)
        }
    }

    // MARK: Expanded

    private var expandedContent: some View {
        VStack(spacing: 0) {
            header
                .frame(height: state.notch.height)
            VStack(spacing: IslandStyle.sectionGap) {
                sessionsLane
                    .frame(height: state.sessionsLaneHeight, alignment: .top)
                IslandUsageCard(usage: model.usage)
                    .frame(height: IslandStyle.usageCardHeight)
            }
            .padding(.top, IslandStyle.contentTopGap)
            .padding(.horizontal, IslandStyle.sidePadding)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IslandStyle.topFlare)
        .frame(width: state.expandedSize.width)
    }

    /// Split around the notch: the active route on the left, VPN and the
    /// main window on the right. Each side gets exactly the room beside the
    /// hardware so nothing slides under it.
    private var header: some View {
        let side = max(0, (state.expandedSize.width - 2 * IslandStyle.topFlare - state.notch.width) / 2 - 12)
        return HStack(spacing: 0) {
            routeChip
                .frame(width: side, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if vpnEnabled {
                    IslandVpnPill(running: model.vpnRunning)
                }
                IslandIconButton(symbol: "macwindow", help: "打开主窗口", action: actions.openMainWindow)
            }
            .frame(width: side, alignment: .trailing)
        }
        .padding(.horizontal, 12)
    }

    /// The route of the agent most likely being looked at: the lead session's
    /// (Codex has its own route); Claude Code's otherwise.
    private var routeChip: some View {
        let showsCodex = model.sessions.first?.agent == .codex && !model.codexRoute.isEmpty
        let route = showsCodex ? model.codexRoute : model.claudeRoute
        let agent: IslandAgent = showsCodex ? .codex : .claude
        return HStack(spacing: 6) {
            IslandMarkWell(mark: agent, tint: IslandStyle.color(agent))
            Text(route.isEmpty ? "未配置供应商" : route)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(IslandStyle.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(showsCodex ? "Codex 当前路由" : "Claude Code 当前路由")
    }

    private var sessionsLane: some View {
        sessionsStrip(model.sessions)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: IslandStyle.sessionStripHeight, alignment: .top)
    }

    @ViewBuilder
    private func sessionsStrip(_ sessions: [IslandSession]) -> some View {
        if sessions.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 12, weight: .semibold))
                Text("没有运行中的会话")
                    .lineLimit(2)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
            }
            .foregroundStyle(IslandStyle.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            IslandSessionStrip(
                sessions: sessions,
                open: { actions.openSession($0) },
                cost: { model.sessionCosts[$0.id] })
        }
    }
}

/// The detached surface uses static marks and fixed status columns. No per-row
/// timelines, numeric transitions or busy orbits on this always-available HUD.
private struct DetachedSessionRow: View {
    let session: IslandSession
    let action: () -> Void
    @State private var hovered = false

    static func detail(_ session: IslandSession) -> String {
        if session.isWaiting { return IslandSessionRow.waitingLine(for: session) }
        if session.isBusy { return session.activity.isEmpty ? "正在思考…" : session.activity }
        return session.completionID == nil ? "等待输入" : "本轮已完成"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IslandAgentBadge(agent: session.agent, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.project.isEmpty ? session.agent.label : session.project)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IslandStyle.textPrimary)
                    Text(session.agent.label + " · " + Self.detail(session))
                        .font(.system(size: 10.5))
                        .foregroundStyle(IslandStyle.textSecondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(session.isWaiting ? "待确认" : (session.isBusy ? "运行中" : "待命"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(session.isWaiting ? IslandStyle.amber : IslandStyle.textSecondary)
                    .frame(width: 40, alignment: .trailing)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(IslandStyle.textSecondary)
                    .opacity(hovered ? 1 : 0.4)
                    .frame(width: 12)
            }
            .padding(.horizontal, 8)
            .frame(height: 56)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hovered ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if hovered != $0 { hovered = $0 } }
        .help(session.cwd + "\n" + Self.detail(session))
    }
}

private struct DetachedUsageSummary: View {
    let usage: IslandUsage
    @Environment(\.tokenStyleGeneration) private var tokenStyle
    @State private var costDisplay = AppPreferences.shared.costDisplay
    @ObservedObject private var fx = ExchangeRate.shared

    var body: some View {
        let estimate = usage.todayCost
        let shown = ModelPricing.present(estimate.cost, display: costDisplay, rate: fx.effectiveRate)
        let money = [shown.primary, shown.secondary].compactMap { $0 }
            .map { ModelPricing.format($0.amount, currency: $0.currency) }.joined(separator: " + ")
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("今日 Token").font(.system(size: 10)).foregroundStyle(IslandStyle.textSecondary)
                Text(UsageStats.formatTokens(usage.today)).id(tokenStyle)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(estimate.unpricedModels > 0 ? "今日估算 · 含未计价" : "今日估算")
                    .font(.system(size: 10)).foregroundStyle(IslandStyle.textSecondary)
                Text(money.isEmpty ? "—" : money)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
        .help(estimate.detailParts(presented: shown).joined(separator: " · "))
        .onReceive(AppPreferences.shared.$costDisplay.removeDuplicates()) { costDisplay = $0 }
    }
}

// MARK: - Session grid

/// A native vertical scroll view supports both mouse wheels and trackpads.
/// No playback timer moves a session out from under the pointer.
private struct IslandSessionStrip: View {
    let sessions: [IslandSession]
    let open: (IslandSession) -> Void
    let cost: (IslandSession) -> ModelPricing.Estimate?

    private var canScroll: Bool {
        sessions.count > IslandStyle.sessionColumns * IslandStyle.maxSessionRows
    }

    var body: some View {
        VStack(spacing: IslandStyle.sessionRowSpacing) {
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                         count: IslandStyle.sessionColumns),
                          spacing: IslandStyle.sessionRowSpacing) {
                    ForEach(sessions) { session in
                        IslandSessionRow(session: session, cost: cost(session)) { open(session) }
                    }
                }
                .padding(.trailing, canScroll ? 6 : 0)
            }
            .scrollIndicators(.visible)
            .scrollDisabled(!canScroll)
            .frame(height: IslandStyle.sessionLaneHeight)
            .clipped()

            HStack {
                // A count of the lane, not a live figure: rolling is noise on
                // an aggregate that only changes when the lane above already
                // redraws (finding 503).
                RollingNumberText("\(sessions.count) 个会话", rolls: false)
                Spacer(minLength: 0)
                if canScroll {
                    Text("上下滑动查看更多")
                }
            }
            .font(.system(size: 9.5, weight: .medium, design: .rounded))
            .foregroundStyle(IslandStyle.textTertiary)
            .padding(.horizontal, 10)
            .frame(height: IslandStyle.stripReadoutHeight)
        }
    }
}

// MARK: - Alert

/// The alert strip under the notch, for either kind of alert: the agent's
/// mark, a one-shot glint around the rim, what happened, and the action that
/// follows from it. Clicking anywhere else expands the island.
///
/// A quota rollover reads left-to-right the same way a finished session does —
/// mark, verdict, detail, action — so the two share one layout rather than
/// growing a second strip that would need its own geometry to match.
private struct IslandAlertContent: View {
    let alert: IslandAlert
    let notch: CGSize
    let width: CGFloat
    let actions: IslandActions
    var detached = false

    var body: some View {
        let tint = IslandStyle.color(alert.agent)
        let side = max(0, (width - 2 * IslandStyle.topFlare - notch.width) / 2 - 14)
        VStack(spacing: 0) {
            if !detached {
            HStack(spacing: 0) {
                IslandAgentBadge(agent: alert.agent, size: 20)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: badgeSymbol)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.black, verdictTint)
                            .offset(x: 3, y: 3)
                    }
                    .frame(width: side, alignment: .leading)
                Spacer(minLength: 0)
                Text(verdict)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(verdictTint)
                    .frame(width: side, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: notch.height)
            }

            HStack(spacing: 12) {
                if detached { IslandAgentBadge(agent: alert.agent, size: 28) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(detached ? headline + " · " + verdict : headline)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(IslandStyle.textPrimary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(detached ? IslandStyle.textSecondary : IslandStyle.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let openSession = sessionToOpen {
                    Button { actions.openSession(openSession) } label: {
                        HStack(spacing: 4) {
                            Text(openLabel(openSession))
                            Image(systemName: "arrow.up.forward")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(tint))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(IslandPressStyle())
                } else {
                    // Nothing to open for a quota rollover — the figure itself
                    // is the whole message, so the space goes to a label that
                    // says which window recovered.
                    Text(alertQuotaLabel)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(tint.opacity(0.16)))
                }
                Button(action: actions.dismissAlert) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(IslandStyle.textTertiary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(IslandPressStyle())
                .help("收起通知")
                .accessibilityLabel("收起通知")
            }
            .padding(.horizontal, IslandStyle.sidePadding + 8)
            .frame(height: detached ? 72 : IslandStyle.alertBodyHeight)
        }
        .padding(.horizontal, detached ? 0 : IslandStyle.topFlare)
        .frame(width: width, height: detached ? 72 : notch.height + IslandStyle.alertBodyHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: actions.expandFromAlert)
        .overlay { if !detached { IslandGlint(color: tint) } }
    }

    /// The session this alert can jump back into; nil for a quota rollover.
    private var sessionToOpen: IslandSession? {
        switch alert {
        case .finished(let session): return session
        case .needsInput(let session): return session
        case .quotaReset: return nil
        }
    }

    /// "继续" for a finished turn, "去确认" for one parked on the user: the two
    /// alerts open the same session but ask for different things, and the verb
    /// is the whole difference the user sees.
    private func openLabel(_ session: IslandSession) -> String {
        switch alert {
        case .needsInput: return "去确认"
        case .finished, .quotaReset: return session.agent == .cursor ? "打开" : "继续"
        }
    }

    private var alertQuotaLabel: String {
        if case .quotaReset(let window) = alert { return window.label }
        return ""
    }

    private var headline: String {
        switch alert {
        case .finished(let session), .needsInput(let session):
            return session.project.isEmpty ? session.agent.label : session.project
        case .quotaReset(let window):
            return "\(window.label) 已重置"
        }
    }

    private var detail: String {
        switch alert {
        case .finished(let session):
            let who = session.agent.label + (session.model.isEmpty ? "" : " · " + session.model)
            return who + " · 等待你的下一步"
        case .needsInput(let session):
            let who = session.agent.label + (session.model.isEmpty ? "" : " · " + session.model)
            // Same fallback word as the session row's own line — one helper,
            // so the strip and the row cannot drift (finding 501).
            return who + " · " + IslandSessionRow.waitingLine(for: session)
        case .quotaReset:
            return "额度已刷新 · 可以继续使用"
        }
    }

    private var verdict: String {
        switch alert {
        case .finished: return "已完成"
        case .needsInput: return "需确认"
        case .quotaReset: return "已重置"
        }
    }

    /// Mint for a finished turn, amber for a refilled allowance — the same
    /// pairing the quota gauges use when a window is nearly spent — and the
    /// waiting state's own hue, which is the warning yellow the rest of the app
    /// already reads as "attention, not error".
    private var verdictTint: Color {
        switch alert {
        case .finished: return IslandStyle.mint
        case .needsInput: return IslandStyle.amber
        case .quotaReset: return IslandStyle.amber
        }
    }

    private var badgeSymbol: String {
        switch alert {
        case .finished: return "checkmark.circle.fill"
        case .needsInput: return "hand.raised.fill"
        case .quotaReset: return "arrow.clockwise.circle.fill"
        }
    }
}

/// A single light sweep along the island's rim, then gone. One trim
/// animation on a stroked path — no timeline, no blur.
private struct IslandGlint: View {
    let color: Color
    @State private var progress: CGFloat = 0
    @State private var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        IslandShape(topFlare: IslandStyle.topFlare, bottomRadius: IslandStyle.alertBottomRadius)
            .trim(from: max(0, progress - 0.35), to: progress)
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
            .onAppear {
                // Decoration, not information: Reduce Motion skips the sweep
                // rather than shortening it.
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.9).delay(0.12)) { progress = 1.35 }
                withAnimation(.easeIn(duration: 0.3).delay(0.85)) { visible = false }
            }
    }
}

// MARK: - Pieces

/// Today against yesterday as a 14pt ring — full at parity, amber beyond.
///
/// The ring is only ever drawn in the *collapsed* wings (see `leftWing`), i.e.
/// on the one surface that is on screen permanently and that `UIWakePolicy`
/// deliberately does not count as visible. `pace` is today's total against
/// yesterday's, so it changes on every usage-index pass — an FSEvents transcript
/// burst can move it several times a second. An `.animation(.snappy, value:)`
/// there opened an animated transaction on each of those, and an in-flight
/// transaction makes every display cycle re-lay out the whole hosting view — for
/// a 14pt ring on a panel nobody is looking at. `trim(to:)` on a `Shape` is
/// `Animatable`, so dropping the modifier costs only the interpolation.
private struct IslandPaceRing: View {
    let pace: Double?

    var body: some View {
        let value = pace ?? 0
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: min(1, value))
                .stroke(value > 1 ? IslandStyle.amber : IslandStyle.mint,
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .help(pace.map { "今日为昨日的 \(Int(($0 * 100).rounded()))%" } ?? "昨日无用量")
    }
}

private struct IslandVpnPill: View {
    let running: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(running ? IslandStyle.mint : Color.white.opacity(0.3))
                .frame(width: 6, height: 6)
            Text(running ? "代理" : "代理未连接")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(running ? IslandStyle.textPrimary : IslandStyle.textTertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .animation(.snappy, value: running)
    }
}

/// Round glass icon button for the expanded header.
private struct IslandIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovered ? IslandStyle.textPrimary : IslandStyle.textSecondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(hovered ? 0.14 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(IslandPressStyle())
        .help(help)
        .accessibilityLabel(help)
        .onHover { if hovered != $0 { hovered = $0 } }
        .animation(IslandStyle.hoverSpring, value: hovered)
    }
}

private struct IslandPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : IslandStyle.hoverSpring, value: configuration.isPressed)
    }
}

// MARK: - Transition

extension AnyTransition {
    /// Content grows out of the notch: fades in while settling from 94 %
    /// toward the top edge. Opacity + scale only, so it stays on the GPU.
    static var islandContent: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
    }
}
