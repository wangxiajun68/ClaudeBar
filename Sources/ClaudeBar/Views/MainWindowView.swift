import Combine
import SwiftUI

// MARK: - Page enum

/// The top-nav destinations.
enum AppPage: String, CaseIterable, Identifiable {
    case dashboard, sessions, providers, connectors, usage, traffic, vpn, settings, help
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
        case .connectors: return "连接器"
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
        case .connectors: return "puzzlepiece.extension"
        case .usage: return "chart.bar"
        case .traffic: return "arrow.left.arrow.right"
        case .vpn: return "globe"
        case .settings: return "slider.horizontal.3"
        case .help: return "questionmark.circle"
        }
    }
}

// MARK: - Main window root

/// The main window's SwiftUI content: a floating navigation capsule between
/// the brand and live status, above the full-width detail area.
struct MainWindowView: View {
    @ProviderState(.configuration) var providerStore: ProviderStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The one preference this shell renders, subscribed individually.
    /// Observing `AppPreferences.shared` wholesale meant every unrelated
    /// write — a VPN port commit, a token-unit toggle, any notch flag —
    /// re-evaluated this body, which reconstructs `DashboardView(onNavigate:)`
    /// with a fresh closure value. Closures are not diffable, so SwiftUI could
    /// not prove the child unchanged and re-ran the whole active page's body
    /// (and all of its derived arrays) for a settings change it does not
    /// render.
    @State private var appearance = AppPreferences.shared.appearance
    @State private var selectedPage: AppPage?
    @State private var showCommandPalette = false
    @State private var surfaceVisible = UIWakePolicy.hasVisibleMainWindow
    /// Page whose provider editor was asked for by another surface. Handed
    /// down to the page; see `route(_:)`.
    @State private var editorRequest: AppPage?

    /// The page the window was showing before it closed. The hosting view is
    /// torn down on close (see `MainWindowController.releaseContent`), so the
    /// selection is kept by the controller and handed back here.
    var initialPage: AppPage = .dashboard
    /// Reported on every navigation so the controller can remember it across
    /// a close/reopen.
    var onNavigate: (AppPage) -> Void = { _ in }
    init(initialPage: AppPage = .dashboard, onNavigate: @escaping (AppPage) -> Void = { _ in }) {
        self.initialPage = initialPage
        self.onNavigate = onNavigate
        _selectedPage = State(initialValue: initialPage)
    }
    var body: some View {
        VStack(spacing: 0) {
            topBar
            detailView
        }
        .environment(\.surfaceIsVisible, surfaceVisible)
        .onReceive(UIWakePolicy.changes) { surfaceVisible = UIWakePolicy.hasVisibleMainWindow }
        .onReceive(AppPreferences.shared.$appearance.removeDuplicates()) { appearance = $0 }
        // A destination another surface asked for. Read through
        // `ProviderState` so the subscription lands on the store's scoped
        // invalidation, and dropped as soon as it is routed — the request is a
        // one-shot (see `ProviderStore.clearNavigation`).
        .onReceive(providerStore.$navigationRequest.compactMap { $0 }) { request in
            route(request)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Theme.bgPrimary)
        .preferredColorScheme(appearance.colorScheme)
        .id(appearance)
        // ⌘K command palette — instant fuzzy search across pages, sessions,
        // and providers.
        .overlay {
            if showCommandPalette {
                CommandPalette(isPresented: $showCommandPalette) { result in handleCommand(result) }
                    .transition(.opacity)
            }
        }
        .background {
            Button("") { showCommandPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// Route a relayed destination and consume it.
    ///
    /// The editor case is handed to the destination page as state rather than
    /// acted on here: `ProvidersView` owns the sheet, so it is the only view
    /// that can open it.
    private func route(_ request: ProviderStore.NavigationRequest) {
        let destination = request.destination
        providerStore.clearNavigation(request)
        switch destination {
        case .page(let page):
            navigate(to: page)
        case .editor(let page):
            editorRequest = page
            navigate(to: page)
        }
    }

    private func handleCommand(_ result: CommandResult) {
        switch result {
        case .page(let page):
            navigate(to: page)
        case .session:
            navigate(to: .sessions)
        case .provider:
            providerStore.requestNavigation(.editor(.providers))
        }
    }

    // MARK: Top navigation bar

    /// Brand · floating page capsule · live status. The ice canvas continues
    /// behind the navigation so the capsule reads as a separate surface.
    ///
    /// The capsule is the app's largest piece of chrome, so it carries the
    /// full surface language: a milled well (hairline + faint fill), the
    /// weather card's inner frame ring inside its own edge, and a light wash of
    /// the accent behind the whole group. The previous capsule layered a
    /// `chartBlue` fill, an outer border, an inset white border and a shadow to
    /// get there; the ring does it in one stroke.
    ///
    /// `ViewThatFits` drops per-tab glyphs before labels when the window
    /// narrows; tooltips and accessibility labels preserve the full names.
    private var topBar: some View {
        HStack(spacing: Theme.Space.s12) {
            brand
                .fixedSize()
            Spacer(minLength: 0)
            pageTabs
                .padding(Theme.Space.s4)
                .background {
                    Capsule()
                        .fill(Theme.cardSurface)
                        .overlay(Capsule().fill(Theme.chartBlue.opacity(Theme.isDark ? 0.10 : 0.07)))
                        .shadow(color: .black.opacity(Theme.isDark ? 0.20 : 0.08), radius: 16, y: 7)
                }
                .overlay {
                    Capsule()
                        .strokeBorder(Theme.chartBlue.opacity(Theme.isDark ? 0.22 : 0.17), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .overlay {
                    // The weather card's `::after`, scaled to the capsule: the
                    // lit edge sits *inside* the chrome's own border, so the
                    // group reads as a milled bar rather than a pill laid on
                    // the canvas.
                    Capsule()
                        .strokeBorder(Theme.innerFrame.opacity(0.55), lineWidth: 1)
                        .padding(2.5)
                        .allowsHitTesting(false)
                }
            Spacer(minLength: 0)
            liveStatus
                .fixedSize()
        }
        .padding(.horizontal, Theme.Space.s16)
        .padding(.top, Theme.Space.s12)
        .padding(.bottom, Theme.Space.s16)
        .frame(maxWidth: .infinity)
        .background(Theme.bgPrimary)
    }

    private var pageTabs: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s2) { tabRow(showGlyph: true) }
            HStack(spacing: Theme.Space.s2) { tabRow(showGlyph: false) }
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
                case .providers: ProvidersView(editorRequest: $editorRequest)
                case .connectors: ConnectorsView()
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
        onNavigate(page)
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

/// A tab nested in the floating navigation capsule.
struct TopNavTab: View {
    let page: AppPage
    let isSelected: Bool
    /// Dropped when the tab row is too wide for the window — see `pageTabs`.
    var showGlyph: Bool = true
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if showGlyph {
                    // Cached by `engaged`, not animated from the live value.
                    //
                    // `engaged` flips on every pointer entry to a tab, and a
                    // `SignatureGlyph` — like every `InstrumentGlyph` — is a
                    // `Canvas` that strokes 10–20 paths. Animating the
                    // *glyph's own* `phase` means Core Animation has to
                    // re-render that canvas at each interpolated frame, so
                    // every hover entry pays a full re-draw of every mark in
                    // the row. Removing only the tab's own background/colour
                    // animation changed nothing measurable (1760 → 1740 ms per
                    // 5 s hover sweep); removing the glyph's did (1750 → 1490,
                    // and 2460 vs 460 in a later three-way split). Two states
                    // at 17 pt — one engaged, one not — are visually
                    // indistinguishable from the interpolated ones, and the
                    // row stops doing per-frame rasterisation while the
                    // pointer travels across it.
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
            .padding(.horizontal, Theme.Space.s10)
            .frame(height: 36)
            .background {
                Capsule()
                    .fill(isSelected ? Theme.cardSurface
                          : (isHovered ? Theme.chartBlue.opacity(0.12) : Color.clear))
                    .overlay {
                        Capsule()
                            .strokeBorder(isSelected ? Theme.chartBlue.opacity(0.22) : Color.clear,
                                          lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(isSelected ? 0.08 : 0), radius: 5, y: 2)
            }
            .contentShape(Capsule())
            .animation(reduceMotion ? nil : Theme.Motion.state, value: isSelected)
            .animation(reduceMotion ? nil : Theme.Motion.state, value: isHovered)
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
    @ProviderState(.sessions) var providerStore: ProviderStore

    var body: some View {
        StatusPill(label: currentLabel,
                   tint: isBusy ? Theme.claudeHi : Theme.statusIdle,
                   ink: isBusy ? Theme.Ink.claude : Theme.Ink.idle)
    }

    private var isBusy: Bool {
        providerStore.anyClaudeBusy || providerStore.activeCursorCount > 0
            || providerStore.anyExternalBusy
    }

    /// Counts come from `ProviderStore`'s own derived values: the pill used to
    /// run its own `filter` / `contains` passes over the same three arrays on
    /// every session poll, duplicating work the store already does once.
    private var currentLabel: String {
        let busy = providerStore.busySessionCount
        let cursor = providerStore.activeCursorCount
        let external = providerStore.activeExternalCount
        if providerStore.aliveSessions.isEmpty && cursor == 0 && external == 0 { return "空闲" }
        return "\(busy + cursor + external) 运行中"
    }

}
