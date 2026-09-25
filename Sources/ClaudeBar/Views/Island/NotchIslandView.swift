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

    /// The rotating glance card is a *fixed box*. Every band inside it is a
    /// named constant, so no card can be taller than another, and the reel can
    /// never resize the session lane (and so the island) when it turns.
    ///
    /// The card is the same 2×2 grid of *modules* on every page — a section
    /// name, an icon, a figure and a unit — so a four-mark hardware page and a
    /// two-mark quota page sit on the same baseline grid.
    static let markWellSize: CGFloat = 20
    static let markValueHeight: CGFloat = 14
    /// The caption line reserves its box even when empty, so a two-up and a
    /// four-up card end on the same baseline.
    static let markCaptionHeight: CGFloat = 11
    static let markCellSpacing: CGFloat = 2
    static let markRowSpacing: CGFloat = 6
    static let cardTitleHeight: CGFloat = 12
    static let cardTitleGap: CGFloat = 6
    static let glanceCardPadding: CGFloat = 10

    static let markCellHeight: CGFloat = markWellSize + markCellSpacing
        + markValueHeight + markCellSpacing + markCaptionHeight
    static let cardBodyHeight: CGFloat = cardTitleHeight + cardTitleGap + 2 * markCellHeight + markRowSpacing
    /// Card contents, then the padding ring around them.
    static let glanceCardSize = CGSize(width: 188, height: cardBodyHeight)
    static let glanceReelWidth: CGFloat = glanceCardSize.width + 2 * glanceCardPadding
    static let glanceReelHeight: CGFloat = cardBodyHeight + 2 * glanceCardPadding + reelPagerBand

    /// Reserve a separate pager band below the complete two-row body.
    static let reelReservesPager = true
    static var reelPagerBand: CGFloat { reelReservesPager ? pagerInset + pagerDotHeight : 0 }
    static var cardContentBand: CGFloat {
        cardBodyHeight
    }

    /// How far into the card the pager sits, measured up from the card's
    /// bottom edge. Only reachable when the lane is at least this tall.
    static var pagerRestingInset: CGFloat { pagerInset + pagerDotHeight }

    /// The pager is pinned from the card's *outer* box, so no page can move it
    /// and the dots never affect a page's layout.
    static let pagerDotHeight: CGFloat = 4
    static let pagerInset: CGFloat = 9

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
}

// MARK: - Root

/// Root of the island panel. One black shape morphs between three sizes —
/// collapsed (notch + wings), alert (a session just finished), expanded
/// (sessions + usage) — and the content for the current mode fades in on top.
///
/// Performance: the morph animates only the frame and two shape parameters;
/// transitions are opacity + scale (no blur), the island casts no shadow,
/// and nothing below here runs a per-frame timeline.
struct NotchIslandView: View {
    @ObservedObject var state: NotchIslandState
    @ObservedObject var model: IslandLiveModel
    let actions: IslandActions
    /// The two preferences the island renders, subscribed individually:
    /// observing all of `AppPreferences` would re-render the island for every
    /// unrelated settings change.
    @State private var tokenStyle = AppPreferences.shared.tokenUnitStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        let shape = IslandShape(topFlare: IslandStyle.topFlare, bottomRadius: bottomRadius)
        return ZStack(alignment: .top) {
            shape.fill(Color.black)

            switch state.mode {
            case .collapsed:
                if state.showsWings {
                    wings.transition(.opacity)
                }
            case .alert:
                if let alert = state.alert {
                    IslandAlertContent(alert: alert, notch: state.notch, width: size.width, actions: actions)
                        .id(alert.id)
                        .transition(.islandContent)
                }
            case .expanded:
                expandedContent
                    .transition(.islandContent)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        // Token figures are formatted deep in child views whose inputs do not
        // change with the unit style; a new identity re-renders them. The
        // style flips only from Settings, so the reset is never visible.
        .id(tokenStyle)
        // Collapsed must be edge-less to melt into the notch; the rim light
        // only appears once the island has grown out of it.
        .overlay {
            shape.stroke(IslandStyle.rim, lineWidth: 1)
                .opacity(state.mode == .collapsed ? 0 : 1)
        }
        .opacity(state.isCollapsedInvisible ? 0 : 1)
    }

    private var bottomRadius: CGFloat {
        switch state.mode {
        case .collapsed: return IslandStyle.collapsedBottomRadius
        case .alert: return IslandStyle.alertBottomRadius
        case .expanded: return IslandStyle.expandedBottomRadius
        }
    }

    // MARK: Collapsed

    private var wings: some View {
        HStack(spacing: 0) {
            leftWing
                .frame(width: IslandStyle.wingWidth - 8, alignment: .leading)
                .padding(.leading, 8)

            Color.clear.frame(width: state.notch.width)

            RollingNumberText(UsageStats.formatTokens(model.usage.today))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(IslandStyle.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: IslandStyle.wingWidth - 8, alignment: .trailing)
                .padding(.trailing, 8)
                .animation(.snappy, value: model.usage.today)
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
                RollingNumberText("\(sessions.count) 个会话")
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

    var body: some View {
        let tint = IslandStyle.color(alert.agent)
        let side = max(0, (width - 2 * IslandStyle.topFlare - notch.width) / 2 - 14)
        VStack(spacing: 0) {
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

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(IslandStyle.textPrimary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(IslandStyle.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let openSession = sessionToOpen {
                    Button { actions.openSession(openSession) } label: {
                        HStack(spacing: 4) {
                            Text(openSession.agent == .cursor ? "打开" : "继续")
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
            }
            .padding(.horizontal, IslandStyle.sidePadding + 8)
            .frame(height: IslandStyle.alertBodyHeight)
        }
        .padding(.horizontal, IslandStyle.topFlare)
        .frame(width: width, height: notch.height + IslandStyle.alertBodyHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: actions.expandFromAlert)
        .overlay { IslandGlint(color: tint) }
    }

    /// The session this alert can jump back into; nil for a quota rollover.
    private var sessionToOpen: IslandSession? {
        if case .finished(let session) = alert { return session }
        return nil
    }

    private var alertQuotaLabel: String {
        if case .quotaReset(let window) = alert { return window.label }
        return ""
    }

    private var headline: String {
        switch alert {
        case .finished(let session):
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
        case .quotaReset:
            return "额度已刷新 · 可以继续使用"
        }
    }

    private var verdict: String {
        switch alert {
        case .finished: return "已完成"
        case .quotaReset: return "已重置"
        }
    }

    /// Mint for a finished turn; amber for a refilled allowance — the same
    /// pairing the quota gauges use when a window is nearly spent.
    private var verdictTint: Color {
        switch alert {
        case .finished: return IslandStyle.mint
        case .quotaReset: return IslandStyle.amber
        }
    }

    private var badgeSymbol: String {
        switch alert {
        case .finished: return "checkmark.circle.fill"
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

    var body: some View {
        IslandShape(topFlare: IslandStyle.topFlare, bottomRadius: IslandStyle.alertBottomRadius)
            .trim(from: max(0, progress - 0.35), to: progress)
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.9).delay(0.12)) { progress = 1.35 }
                withAnimation(.easeIn(duration: 0.3).delay(0.85)) { visible = false }
            }
    }
}

// MARK: - Pieces

/// Today against yesterday as a 14pt ring — full at parity, amber beyond.
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
        .animation(.snappy, value: value)
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
        .onHover { if hovered != $0 { hovered = $0 } }
        .animation(IslandStyle.hoverSpring, value: hovered)
    }
}

private struct IslandPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(IslandStyle.hoverSpring, value: configuration.isPressed)
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
