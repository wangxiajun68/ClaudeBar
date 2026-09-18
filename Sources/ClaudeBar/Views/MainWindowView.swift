import SwiftUI

// MARK: - Page enum

/// The five top-nav destinations.
enum AppPage: String, CaseIterable, Identifiable {
    case dashboard, sessions, providers, usage, traffic, vpn, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: return "概览"
        case .sessions: return "会话"
        case .providers: return "模型"
        case .usage: return "用量"
        case .traffic: return "流量"
        case .vpn: return "VPN"
        case .settings: return "设置"
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
        }
    }
}

// MARK: - Main window root

/// The main window's SwiftUI content: a top navigation bar (brand · pages ·
/// live status) above a full-width detail area. The horizontal bar replaces
/// the old vertical sidebar — the 宫格 content gets the whole window width and
/// the chrome reads as one calm strip instead of a heavy left column.
struct MainWindowView: View {
    @EnvironmentObject var providerStore: ProviderStore
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

    /// Brand · page tabs (centered) · live status (trailing). One row, 48pt.
    private var topBar: some View {
        HStack(spacing: Theme.Space.s16) {
            brand
            Spacer()
            HStack(spacing: Theme.Space.s4) {
                ForEach(AppPage.allCases) { page in
                    TopNavTab(page: page, isSelected: selectedPage == page) {
                        navigate(to: page)
                    }
                    .help(page.label)
                }
            }
            Spacer()
            liveStatus
        }
        .padding(.horizontal, Theme.Space.s16)
        .frame(height: 52)
        .background(Theme.cardSurface)
    }

    private var brand: some View {
        HStack(spacing: Theme.Space.s8) {
            BrandMark(size: 24)
            Text("ClaudeBar")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.textPrimary)
        }
    }

    private var isBusy: Bool {
        providerStore.sessions.contains { $0.isAlive && $0.status == .busy }
            || providerStore.cursorSessions.contains { $0.status == .active }
            || providerStore.anyExternalBusy
    }

    private var liveStatus: some View {
        StatusPill(
            label: currentLabel,
            tint: isBusy ? Theme.claudeHi : Theme.statusIdle
        )
    }

    private var currentLabel: String {
        let alive = providerStore.sessions.filter(\.isAlive)
        let busy = alive.filter { $0.status == .busy }.count
        let cursor = providerStore.cursorSessions.filter { $0.status == .active }.count
        let external = providerStore.activeExternalCount
        if alive.isEmpty && cursor == 0 && external == 0 { return "空闲" }
        return "\(busy + cursor + external) 运行中"
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
        if page == .traffic || selectedPage == .traffic {
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
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                AppGlyph(name: page.icon, size: 12)
                    .foregroundColor(isSelected ? Theme.claudeHi : rowColor)
                Text(page.label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundColor(isSelected ? Theme.textPrimary : rowColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule()
                    .fill(isSelected
                          ? Theme.claude.opacity(0.12)
                          : (isHovered ? Theme.cardFill(0.06) : Color.clear))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverState($isHovered)
    }

    private var rowColor: Color {
        isHovered ? Theme.textPrimary.opacity(0.9) : Theme.textSecondary
    }
}
