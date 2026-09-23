import SwiftUI

// MARK: - Page enum

/// The top-nav destinations.
enum AppPage: String, CaseIterable, Identifiable {
    case dashboard, sessions, providers, usage, traffic, vpn, settings, help
    var id: String { rawValue }

    /// The pages that get a top-bar tab. 帮助 is reachable from the trailing
    /// question-mark button instead of spending one of the eight tab slots —
    /// it is a reference page, not a destination you switch between while
    /// working, and the tab row is already at its width budget.
    static var tabs: [AppPage] { allCases.filter { $0 != .help } }

    var label: String {
        switch self {
        case .dashboard: return "概览"
        case .sessions: return "会话"
        case .providers: return "模型"
        case .usage: return "用量"
        case .traffic: return "流量"
        case .vpn: return "VPN"
        case .settings: return "设置"
        case .help: return "帮助"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .sessions: return "rectangle.stack"
        case .providers: return "cube"
        case .usage: return "chart.bar"
        case .traffic: return "arrow.left.arrow.right"
        case .vpn: return "globe"
        case .settings: return "slider.horizontal.3"
        case .help: return "questionmark.circle"
        }
    }
}

// MARK: - Main window root

/// The main window's SwiftUI content: a top navigation bar (brand · pages ·
/// live status) above a full-width detail area. The horizontal bar replaces
/// the old vertical sidebar — the 宫格 content gets the whole window width and
/// the chrome reads as one calm strip instead of a heavy left column.
struct MainWindowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var prefs = AppPreferences.shared
    @State private var selectedPage: AppPage? = .dashboard
    @State private var showCommandPalette = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HairlineDivider()
            detailView
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Theme.bgPrimary)
        .preferredColorScheme(prefs.appearance.colorScheme)
        .id(prefs.appearance)
        // ⌘K command palette — instant fuzzy search across pages, sessions,
        // and providers.
        .overlay { CommandPalette(isPresented: $showCommandPalette) { result in
            handleCommand(result)
        } }
        .background {
            Button("") { showCommandPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProvidersEditor)) { _ in
            navigate(to: .providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openVPNPage)) { _ in
            navigate(to: .vpn)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openHelpPage)) { _ in
            navigate(to: .help)
        }
    }

    private func handleCommand(_ result: CommandResult) {
        switch result {
        case .page(let page):
            navigate(to: page)
        case .session:
            navigate(to: .sessions)
        case .provider:
            navigate(to: .providers)
        }
    }

    // MARK: Top navigation bar

    /// Brand · page tabs (centered) · live status (trailing). One row, 52pt.
    ///
    /// Eight tabs at `s4` run ~570pt; with the brand, the status pill and the
    /// outer padding that is ~812 of the 900pt minimum width, and the window can
    /// be dragged narrower than its minimum once the status label grows
    /// ("3 运行中"). `ViewThatFits` drops the per-tab glyph — 18pt × 8 — when
    /// the full row does not fit, which is cheaper than making the tabs scroll
    /// or truncating a label. The icon's meaning survives in the tooltip and the
    /// accessibility label.
    private var topBar: some View {
        HStack(spacing: Theme.Space.s16) {
            brand
            Spacer()
            pageTabs
            Spacer()
            liveStatus
        }
        .padding(.horizontal, Theme.Space.s16)
        .frame(height: 52)
        .background(Theme.cardSurface)
    }

    private var pageTabs: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s4) { tabRow(showGlyph: true) }
            HStack(spacing: Theme.Space.s4) { tabRow(showGlyph: false) }
        }
    }

    private func tabRow(showGlyph: Bool) -> some View {
        ForEach(AppPage.tabs) { page in
            TopNavTab(page: page, isSelected: selectedPage == page, showGlyph: showGlyph) {
                navigate(to: page)
            }
            .help(page.label)
        }
    }

    private var brand: some View {
        HStack(spacing: Theme.Space.s8) {
            BrandMark(size: 24)
            Text("ClaudeBar")
                .font(Theme.Font.brand)
                .foregroundColor(Theme.textPrimary)
        }
    }

    private var liveStatus: some View {
        HStack(spacing: Theme.Space.s8) {
            MainWindowSessionStatus()
            helpButton
        }
    }

    /// Trailing 帮助 entry: a question-mark chip that routes to the help page.
    private var helpButton: some View {
        Button { navigate(to: .help) } label: {
            IconChip(systemImage: "questionmark",
                     tint: selectedPage == .help ? Theme.claudeHi : Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help("帮助")
        .accessibilityLabel("帮助")
    }

    // MARK: Detail

    @ViewBuilder
    private var detailView: some View {
        ZStack {
            Group {
                switch selectedPage ?? .dashboard {
                case .dashboard: DashboardView(onNavigate: navigate(to:))
                case .sessions: SessionsView()
                case .providers: ProvidersView()
                case .usage: UsageView()
                case .settings: SettingsView()
                case .help: HelpView()
                case .vpn: VPNView()
                // Mounted only while selected. The expensive inspector state
                // lives in TrafficPageState, so re-entry is instant without
                // keeping an invisible copy of the page alive — that resident
                // copy was re-laying out the log console ~170×/s while hidden.
                case .traffic: TrafficView()
                }
            }
            // The traffic page skips the page fade: animating a freshly
            // mounted inspector is the hitch, not the mount.
            .id(selectedPage)
            .transition(selectedPage == .traffic ? .identity : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 8)),
                removal: .opacity
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgPrimary)
    }

    private func navigate(to page: AppPage) {
        if reduceMotion || page == .traffic || selectedPage == .traffic {
            selectedPage = page
        } else {
            withAnimation(Theme.Motion.page) {
                selectedPage = page
            }
        }
    }
}

// MARK: - Top nav tab

/// A top-bar navigation tab: label + accent underline.
struct TopNavTab: View {
    let page: AppPage
    let isSelected: Bool
    /// Dropped when the tab row is too wide for the window — see `pageTabs`.
    var showGlyph: Bool = true
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if showGlyph {
                    SignatureGlyph(name: page.icon,
                                   tint: isSelected ? PageIdentity.ink(page.label) : rowColor,
                                   size: 17, engaged: isSelected || isHovered)
                }
                Text(page.label)
                    .font(isSelected ? Theme.Font.chromeEmph : Theme.Font.chrome)
                    .foregroundColor(isSelected ? Theme.textPrimary : rowColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.cardSurface
                          : (isHovered ? Theme.cardFill(0.04) : Color.clear))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? PageIdentity.ink(page.label).opacity(0.3) : Color.clear,
                                          lineWidth: 1)
                    }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .hoverState($isHovered)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var rowColor: Color {
        isHovered ? Theme.textPrimary.opacity(0.9) : Theme.textSecondary
    }
}

/// Session polling only invalidates this badge, not the page navigation shell.
private struct MainWindowSessionStatus: View {
    @EnvironmentObject var providerStore: ProviderStore

    var body: some View {
        StatusPill(label: currentLabel,
                   tint: isBusy ? Theme.claudeHi : Theme.statusIdle,
                   ink: isBusy ? Theme.Ink.claude : Theme.Ink.idle)
    }

    private var isBusy: Bool {
        providerStore.sessions.contains { $0.isAlive && $0.status == .busy }
            || providerStore.cursorSessions.contains { $0.status == .active }
            || providerStore.anyExternalBusy
    }

    private var currentLabel: String {
        let alive = providerStore.sessions.filter(\.isAlive)
        let busy = alive.filter { $0.status == .busy }.count
        let cursor = providerStore.cursorSessions.filter { $0.status == .active }.count
        let external = providerStore.activeExternalCount
        if alive.isEmpty && cursor == 0 && external == 0 { return "空闲" }
        return "\(busy + cursor + external) 运行中"
    }

}
