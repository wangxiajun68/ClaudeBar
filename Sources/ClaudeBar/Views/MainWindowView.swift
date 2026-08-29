import SwiftUI

// MARK: - Page enum

/// The five sidebar destinations.
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

/// The main window's SwiftUI content: a `NavigationSplitView` with a dark
/// dispatch-roster sidebar and a detail area that switches between the five
/// pages. The Dispatch world's backdrop (a faint radar graticule) sits behind
/// everything, under a soft cursor beacon.
struct MainWindowView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @State private var selectedPage: AppPage? = .dashboard
    @State private var showCommandPalette = false
    @Namespace private var sidebarNamespace

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .frame(minWidth: 900, minHeight: 600)
        // Clean glass backdrop: the window's vibrancy (NSVisualEffectView)
        // paints the base; a soft pointer beacon adds subtle life without any
        // decorative graticule competing with the dashboard's real radar.
        .background(CursorSpotlight())
        // Navigation haptic — a selection tick whenever the page changes.
        .sensoryFeedback(.selection, trigger: selectedPage)
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

    // MARK: Sidebar — the roster

    private var sidebar: some View {
        VStack(spacing: 0) {
            brandHeader

            // Navigation: custom rows + a sliding selection pill. The pill's
            // frame is glass-morph linked to the active row, so it glides
            // between destinations instead of popping.
            VStack(spacing: 2) {
                ForEach(AppPage.allCases) { page in
                    sidebarRow(page)
                }
            }
            .padding(.horizontal, 10)

            Spacer()
            sidebarFooter
                .padding(12)
        }
        .background(Theme.sidebarFill)
        .glassEffect(.regular.tint(Theme.base2.opacity(0.15)), in: Rectangle())
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            // Beacon brand mark — an amber signal orb, lit when anything runs.
            ZStack {
                Circle()
                    .fill(Theme.accentGradient)
                    .frame(width: 22, height: 22)
                Circle()
                    .strokeBorder(Theme.claudeHi.opacity(0.55), lineWidth: 1)
                    .frame(width: 24, height: 24)
                Text("CB")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Theme.base0)
            }
            .beaconGlow(Theme.claude, radius: 9, opacity: isBusy ? 0.38 : 0.22)
            .symbolEffect(.pulse, options: .repeating, isActive: isBusy)

            Text("ClaudeBar")
                .font(Theme.Font.titleSmall)
                .tracking(Theme.Tracking.titleSmall)
                .foregroundColor(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    private var isBusy: Bool {
        providerStore.sessions.contains { $0.isAlive && $0.status == .busy }
            || providerStore.cursorSessions.contains { $0.status == .active }
    }

    private func sidebarRow(_ page: AppPage) -> some View {
        let isSelected = selectedPage == page
        return SidebarRowButton(page: page, isSelected: isSelected, namespace: sidebarNamespace, badge: badge(for: page)) {
            navigate(to: page)
        }
        .help(page.label)
    }

    /// Live count badges per sidebar destination.
    private func badge(for page: AppPage) -> Int? {
        switch page {
        case .sessions:
            let alive = providerStore.sessions.filter(\.isAlive).count
            let cursor = providerStore.cursorSessions.count
            return alive + cursor
        case .providers:
            return providerStore.providers.count
        default:
            return nil
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isBusy ? Theme.claude.opacity(0.3) : Color.clear)
                    .frame(width: 12, height: 12)
                    .scaleEffect(isBusy ? 1 : 0.4)
                    .opacity(isBusy ? 0.6 : 0)
                    .animation(Theme.Animation.pulse.repeatForever(autoreverses: true), value: isBusy)
                Circle()
                    .fill(isBusy ? Theme.claudeHi : Theme.statusIdle)
                    .frame(width: 6, height: 6)
            }
            .frame(width: 14, height: 14)
            Text(currentLabel)
                .font(Theme.Font.captionMono)
                .foregroundColor(isBusy ? Theme.claudeHi : Theme.textSecondary)
            Spacer()
        }
    }

    private var currentLabel: String {
        let alive = providerStore.sessions.filter(\.isAlive)
        let busy = alive.filter { $0.status == .busy }.count
        let cursor = providerStore.cursorSessions.filter { $0.status == .active }.count
        if alive.isEmpty && cursor == 0 { return "STANDBY" }
        return "\(busy + cursor) RUNNING"
    }

    // MARK: Detail

    @ViewBuilder
    private var detailView: some View {
        Group {
            switch selectedPage {
            case .dashboard: DashboardView(onNavigate: navigate(to:))
            case .sessions: SessionsView()
            case .providers: ProvidersView()
            case .usage: UsageView()
            case .settings: SettingsView()
            case nil: DashboardView(onNavigate: navigate(to:))
            }
        }
        .id(selectedPage)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985)),
            removal: .opacity
        ))
    }

    /// Centralized navigation: a page change animates the sidebar pill and
    /// the detail swap together, fast — the tool loads into the task.
    private func navigate(to page: AppPage) {
        withAnimation(Theme.Motion.page) {
            selectedPage = page
        }
    }
}

// MARK: - Sidebar row button

/// A dispatch-roster row: icon + label + live count badge. The selected row
/// carries an amber signal pill (glass-morphed between rows); unselected rows
/// brighten on hover so the whole roster feels alive.
struct SidebarRowButton: View {
    let page: AppPage
    let isSelected: Bool
    let namespace: Namespace.ID
    var badge: Int? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? Theme.claudeHi : rowColor)
                    .symbolEffect(.bounce, value: isSelected)
                    .frame(width: 20)
                Text(page.label)
                    .font(Theme.Font.bodyLarge)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundColor(rowColor)
                Spacer()
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(Theme.Font.captionMono)
                        .foregroundColor(isSelected ? Theme.claudeHi : Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isSelected ? Theme.claude.opacity(0.18) : Theme.cardFill(0.08))
                        )
                        .contentTransition(.numericText())
                        .animation(Theme.Animation.smooth, value: badge)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background {
                if isSelected {
                    // Liquid Glass selection pill, morphed between rows.
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(Color.clear)
                        .glassEffect(.regular.tint(Theme.claude.opacity(0.20)), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                        .glassEffectID("sidebarSelection", in: namespace)
                        .glassEffectTransition(.matchedGeometry)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(Theme.cardFill(0.06))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverState($isHovered)
    }

    private var rowColor: Color {
        if isSelected { return Theme.textPrimary }
        return isHovered ? Theme.textPrimary.opacity(0.9) : Theme.textSecondary
    }
}
