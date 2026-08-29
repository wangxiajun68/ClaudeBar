import SwiftUI

// MARK: - Page enum

/// The five top-nav destinations.
enum AppPage: String, CaseIterable, Identifiable {
    case dashboard, sessions, providers, usage, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: return "概览"
        case .sessions: return "会话"
        case .providers: return "供应商"
        case .usage: return "用量"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "dot.radiowaves.left.and.right"
        case .sessions: return "antenna.radiowaves.left.and.right"
        case .providers: return "server.rack"
        case .usage: return "chart.bar.xaxis"
        case .settings: return "gearshape"
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
    @State private var selectedPage: AppPage? = .dashboard
    @State private var showCommandPalette = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HairlineDivider()
            detailView
        }
        .frame(minWidth: 900, minHeight: 600)
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
                    TopNavTab(page: page, isSelected: selectedPage == page,
                              badge: badge(for: page)) {
                        navigate(to: page)
                    }
                    .help(page.label)
                }
            }
            Spacer()
            liveStatus
        }
        .padding(.horizontal, Theme.Space.s16)
        .frame(height: 48)
        // Flat translucent fill, not glassEffect: a full-width live blur is
        // re-composited on every 2.5s poll publish and is the single most
        // expensive layer in the window. A static fill reads the same over
        // the near-black backdrop at a fraction of the GPU cost.
        .background(Theme.base1.opacity(0.55))
    }

    private var brand: some View {
        HStack(spacing: Theme.Space.s8) {
            ZStack {
                Circle()
                    .fill(Theme.claude)
                    .frame(width: 22, height: 22)
                Text("A")
                    .font(Theme.Font.microSemibold)
                    .foregroundColor(Theme.base0)
            }
            Text("Axon")
                .font(Theme.Font.titleSmall)
                .tracking(Theme.Tracking.titleSmall)
                .foregroundColor(Theme.textPrimary)
        }
    }

    /// Live count badges per destination.
    private func badge(for page: AppPage) -> Int? {
        switch page {
        case .sessions:
            let alive = providerStore.sessions.filter(\.isAlive).count
            let cursor = providerStore.cursorSessions.count
            let external = providerStore.aliveExternalSessions.count
            return alive + cursor + external
        case .providers:
            return providerStore.providers.count
        default:
            return nil
        }
    }

    private var isBusy: Bool {
        providerStore.sessions.contains { $0.isAlive && $0.status == .busy }
            || providerStore.cursorSessions.contains { $0.status == .active }
            || providerStore.anyExternalBusy
    }

    private var liveStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isBusy ? Theme.claudeHi : Theme.statusIdle)
                .frame(width: 6, height: 6)
            Text(currentLabel)
                .font(Theme.Font.captionMono)
                .foregroundColor(isBusy ? Theme.claudeHi : Theme.textSecondary)
        }
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
        Group {
            switch selectedPage ?? .dashboard {
            case .dashboard: DashboardView(onNavigate: navigate(to:))
            case .sessions: SessionsView()
            case .providers: ProvidersView()
            case .usage: UsageView()
            case .settings: SettingsView()
            }
        }
        .id(selectedPage)
        .transition(.opacity)
    }

    /// Centralized navigation: a page change animates the tab selection and
    /// the detail swap together, fast.
    private func navigate(to page: AppPage) {
        withAnimation(Theme.Motion.page) {
            selectedPage = page
        }
    }
}

// MARK: - Top nav tab

/// A top-bar navigation tab: icon + label + live count badge. Selected tabs
/// get an accent underline and brightened label — a lighter treatment than
/// the old sidebar's filled pill, fitting the horizontal strip.
struct TopNavTab: View {
    let page: AppPage
    let isSelected: Bool
    var badge: Int? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(page.label)
                        .font(Theme.Font.body)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundColor(isSelected ? Theme.textPrimary : rowColor)
                        .lineLimit(1)
                        .fixedSize()
                    if let badge, badge > 0 {
                        Text("\(badge)")
                            .font(Theme.Font.captionMono)
                            .foregroundColor(isSelected ? Theme.claudeHi : Theme.textSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Theme.claude.opacity(0.18) : Theme.cardFill(0.08))
                            )
                            .contentTransition(.numericText())
                            .animation(Theme.Animation.smooth, value: badge)
                    }
                }
                // Accent underline: only on the selected tab.
                Capsule()
                    .fill(isSelected ? Theme.claude : Color.clear)
                    .frame(width: isSelected ? 24 : 0, height: 2)
                    .animation(Theme.Animation.smooth, value: isSelected)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .contentShape(Rectangle())
            .background {
                if isHovered && !isSelected {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.cardFill(0.05))
                }
            }
        }
        .buttonStyle(.plain)
        .hoverState($isHovered)
    }

    private var rowColor: Color {
        isHovered ? Theme.textPrimary.opacity(0.9) : Theme.textSecondary
    }
}
