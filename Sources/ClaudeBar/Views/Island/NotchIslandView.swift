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
    static let sessionRowSpacing: CGFloat = 2
    static let maxSessionRows = 3
    static let overflowRowHeight: CGFloat = 22
    static let emptyLaneHeight: CGFloat = 40
    static let usageCardHeight: CGFloat = 108

    /// The rotating glance card is a *fixed box*. Every row inside it is a
    /// named constant — well, value, caption, title band — so no card can be
    /// taller than another, and the reel can never resize the session lane
    /// (and so the island) when it turns. Adding a row here means the card
    /// grows by exactly that constant, not by whatever a glyph measures.
    static let markWellSize: CGFloat = 24
    static let markValueHeight: CGFloat = 14
    /// The caption line reserves its box even when empty, so a two-up and a
    /// four-up card end on the same baseline.
    static let markCaptionHeight: CGFloat = 11
    static let markCellSpacing: CGFloat = 3
    static let markRowSpacing: CGFloat = 8
    static let cardTitleHeight: CGFloat = 12
    static let cardTitleGap: CGFloat = 8
    static let glanceCardPadding: CGFloat = 10

    static let markCellHeight: CGFloat = markWellSize + markCellSpacing
        + markValueHeight + markCellSpacing + markCaptionHeight
    static let cardBodyHeight: CGFloat = cardTitleHeight + cardTitleGap + 2 * markCellHeight + markRowSpacing
    /// Card contents, then the padding ring around them.
    static let glanceCardSize = CGSize(width: 188, height: cardBodyHeight)
    static let glanceReelWidth: CGFloat = glanceCardSize.width + 2 * glanceCardPadding
    static let glanceReelHeight: CGFloat = cardBodyHeight + 2 * glanceCardPadding

    /// How far into the card the pager sits, measured up from the card's
    /// bottom edge. Only reachable when the lane is at least this tall.
    static var pagerRestingInset: CGFloat { pagerInset + pagerDotHeight }

    /// The pager floats over the card's bottom edge, pinned from the *outer*
    /// box: no card can move the dots and the dots never affect the card.
    static let pagerDotHeight: CGFloat = 4
    static let pagerInset: CGFloat = 9

    /// Fixed transparent panel; every morph happens inside it. Sized for the
    /// tallest expanded island (three rows + overflow on a 38pt notch).
    static let panelSize = CGSize(width: 640, height: 400)

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
    @State private var sessionPage = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var vpnEnabled = AppPreferences.shared.vpnEnabled

    var body: some View {
        island
            .frame(width: IslandStyle.panelSize.width, height: IslandStyle.panelSize.height, alignment: .top)
            .environment(\.colorScheme, .dark)
            .onReceive(AppPreferences.shared.$tokenUnitStyle.removeDuplicates()) { tokenStyle = $0 }
            .onReceive(AppPreferences.shared.$vpnEnabled.removeDuplicates()) { vpnEnabled = $0 }
            .onChange(of: model.sessions.map(\.id)) { _, _ in sessionPage = 0 }
            .onChange(of: state.mode) { _, mode in
                if mode == .collapsed { sessionPage = 0 }
            }
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
                if let session = state.alert {
                    IslandAlertContent(session: session, notch: state.notch, width: size.width, actions: actions)
                        .id(session.id)
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

            Text(UsageStats.formatTokens(model.usage.today))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(IslandStyle.textPrimary)
                .contentTransition(.numericText())
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
                    Text("\(busy.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(IslandStyle.color(lead.agent))
                        .contentTransition(.numericText())
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
        HStack(alignment: .top, spacing: 8) {
            sessionList
                .frame(maxWidth: .infinity, alignment: .topLeading)
            IslandGlanceReel(balances: model.balances, quota: model.quotaWindows,
                             sessions: model.sessions, usage: model.usage,
                             claudeRoute: model.claudeRoute, codexRoute: model.codexRoute,
                             vpnRunning: model.vpnRunning)
                // Pinned in both dimensions and top-aligned: the reel keeps
                // its constant height whatever the lane gives it.
                .frame(width: IslandStyle.glanceReelWidth,
                       height: IslandStyle.glanceReelHeight,
                       alignment: .top)
                // Option B: the lane still springs with the session count, so
                // when it is shorter than the card the card is top-aligned and
                // the overflow is cut rather than allowed to push the lane (and
                // with it the whole island) taller.
                //
                // KNOWN TRADEOFF: with 0-2 sessions the lane is 40/44/90pt, all
                // under the card's 158pt, so the pager strip is clipped away in
                // those states. Only 3+ sessions show it. In exchange the card
                // itself never changes size while the reel turns.
                .clipped()
        }
    }

    @ViewBuilder private var sessionList: some View {
        let sessions = model.sessions
        let pageCount = max(1, (sessions.count + IslandStyle.maxSessionRows - 1) / IslandStyle.maxSessionRows)
        let page = min(sessionPage, pageCount - 1)
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
            VStack(spacing: IslandStyle.sessionRowSpacing) {
                ForEach(sessions.dropFirst(page * IslandStyle.maxSessionRows).prefix(IslandStyle.maxSessionRows)) { session in
                    IslandSessionRow(session: session) { actions.openSession(session) }
                        .transition(.opacity)
                }
                if sessions.count > IslandStyle.maxSessionRows {
                    Button { sessionPage = (page + 1) % pageCount } label: {
                        Text("\(sessions.count) 个会话 · \(page + 1)/\(pageCount) · 下一组 ›")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(IslandStyle.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: IslandStyle.overflowRowHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: sessions.map(\.id))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: sessionPage)
        }
    }
}

// MARK: - Alert

/// "A session just finished": the agent's mark, a one-shot glint around the
/// rim, which project finished, and a button straight back into it. Clicking
/// anywhere else expands the island.
private struct IslandAlertContent: View {
    let session: IslandSession
    let notch: CGSize
    let width: CGFloat
    let actions: IslandActions

    var body: some View {
        let tint = IslandStyle.color(session.agent)
        let side = max(0, (width - 2 * IslandStyle.topFlare - notch.width) / 2 - 14)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                IslandAgentBadge(agent: session.agent, size: 20)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.black, IslandStyle.mint)
                            .offset(x: 3, y: 3)
                    }
                    .frame(width: side, alignment: .leading)
                Spacer(minLength: 0)
                Text("已完成")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(IslandStyle.mint)
                    .frame(width: side, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: notch.height)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.project.isEmpty ? session.agent.label : session.project)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(IslandStyle.textPrimary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(IslandStyle.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { actions.openSession(session) } label: {
                    HStack(spacing: 4) {
                        Text(session.agent == .cursor ? "打开" : "继续")
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

    private var detail: String {
        let who = session.agent.label + (session.model.isEmpty ? "" : " · " + session.model)
        return who + " · 等待你的下一步"
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
        .onHover { hovered = $0 }
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
