import SwiftUI
import Combine

// MARK: - Command result

/// What a command-palette selection resolves to. The palette builds a flat list
/// of `CommandItem`s (pages, sessions, providers); picking one yields one of
/// these, which the window routes to the right destination.
enum CommandResult: Equatable {
    case page(AppPage)
    case session(pid: Int)
    case provider(id: UUID)
}
// MARK: - Command item

/// A single searchable row in the command palette. `kind` drives the icon and
/// accent tint; `subtitle` is secondary help text shown under the title.
struct CommandItem: Identifiable {
    enum Kind { case page, claudeSession, cursorSession, provider }
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let result: CommandResult
    /// Lowercased copies, folded once at construction. The filter and the
    /// rank comparison both run per keystroke *and* per comparison inside
    /// `sorted` — re-lowercasing there allocated a fresh string every time.
    let searchTitle: String
    let searchSubtitle: String

    init(id: String, kind: Kind, title: String, subtitle: String,
         icon: String, tint: Color, result: CommandResult) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.result = result
        self.searchTitle = title.lowercased()
        self.searchSubtitle = subtitle.lowercased()
    }
}

// MARK: - Command palette

/// A Raycast/Linear-style ⌘K command palette: a centered floating search field
/// with instant fuzzy-filtered results. As you type, pages, live sessions, and
/// providers are filtered in real time; arrow keys move the selection, return
/// fires it. The palette scales+fades in (not a flat sheet), and the dimmed
/// backdrop dismisses on click. This is the "one keystroke to anywhere"
/// interaction — the signature navigation shortcut.
struct CommandPalette: View {
    @Binding var isPresented: Bool
    let onSelect: (CommandResult) -> Void
    @ProviderState([.configuration, .sessions]) var providerStore: ProviderStore

    @State private var query = ""
    @State private var selection: String?
    @State private var items: [CommandItem] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if isPresented {
                ZStack {
                    // Dimmed backdrop — click to dismiss.
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture { dismiss() }
                        .transition(.opacity)

                    VStack(spacing: 0) {
                        searchBar
                        HairlineDivider()
                        resultsList
                    }
                    .frame(width: 460)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.Radius.xl)
                            .fill(Theme.cardSurface)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.xl)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    }
                    .shadowCard(radius: 24, y: 12, opacity: 0.12)
                    .scaleEffect(isPresented ? 1 : 0.92)
                    .opacity(isPresented ? 1 : 0)
                    .offset(y: isPresented ? 0 : 8)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                    .focusable()
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.return) { fireSelected(); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                }
                .onAppear {
                    searchFocused = true
                    refreshItems(reselect: true)
                }
            }
        }
        .animation(Theme.Animation.smooth, value: isPresented)
        // While the palette is open a poll can add, finish or drop a session.
        // Rebuilding on the store's own signals (rather than on every render)
        // keeps the list current without re-deriving it per keystroke.
        .onReceive(Publishers.MergeMany(providerStore.viewChanges([.configuration, .sessions]))) { _ in
            guard isPresented else { return }
            refreshItems()
        }
    }

    private func moveSelection(_ delta: Int) {
        let items = filtered
        guard !items.isEmpty else { return }
        let idx = items.firstIndex(where: { $0.id == selection }) ?? -1
        let next = min(max(0, idx + delta), items.count - 1)
        selection = items[next].id
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Font.titleSmall)
                .foregroundColor(Theme.Ink.claude)
            TextField("搜索页面、会话、模型", text: $query)
                .font(Theme.Font.bodyLarge)
                .foregroundColor(Theme.textPrimary)
                .focused($searchFocused)
                .submitLabel(.go)
                .onSubmit { fireSelected() }
                .onChange(of: query) { _, _ in
                    selection = filtered.first?.id
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Font.bodySmall)
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(14)
    }

    // MARK: Results

    private var resultsList: some View {
        ScrollView {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 2) {
                    resultsStack
                }
            } else {
                resultsStack
            }
        }
        .frame(maxHeight: 360)
    }

    private var resultsStack: some View {
        LazyVStack(spacing: 2) {
            ForEach(filtered) { item in
                CommandRow(item: item, isSelected: selection == item.id) {
                    select(item)
                }
            }
            if filtered.isEmpty {
                Text("无匹配结果")
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textTertiary())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            }
        }
        .padding(8)
    }

    // MARK: Items

    /// The full set of navigable items, built when the palette opens or its
    /// source data changes — not on every render. Building them ran
    /// `SessionTitle.condense` for every live session and was previously
    /// repeated for every read of `filtered` (body, `moveSelection`,
    /// `fireSelected`, the query `onChange`): two to three full rebuilds per
    /// keystroke.
    private func buildItems() -> [CommandItem] {
        var items = AppPage.allCases.map { p in
            CommandItem(id: "page:\(p.rawValue)", kind: .page, title: p.label,
                        subtitle: "前往页面",
                        icon: p.icon, tint: Theme.accent,
                        result: .page(p))
        }
        items += providerStore.sessions.filter(\.isAlive).map { s in
            CommandItem(id: "claude:\(s.pid)", kind: .claudeSession, title: s.displayTitle,
                        subtitle: s.name.isEmpty ? "Claude Code · PID \(s.pid)" : s.name,
                        icon: "rectangle.connected.to.line.below",
                        tint: Theme.statusBusy,
                        result: .session(pid: s.pid))
        }
        // Cursor sessions carry no UUID, so they route to the sessions page.
        items += providerStore.cursorSessions.map { s in
            CommandItem(id: "cursor:\(s.composerId)", kind: .cursorSession, title: s.displayTitle,
                        subtitle: s.name.isEmpty ? "Cursor" : s.name,
                        icon: "cursorarrow",
                        tint: Theme.cursorAccent,
                        result: .page(.sessions))
        }
        items += providerStore.providers.map { p in
            CommandItem(id: "provider:\(p.id)", kind: .provider, title: p.name,
                        subtitle: p.activeModel?.name ?? "供应商",
                        icon: "cube",
                        tint: Theme.accent,
                        result: .provider(id: p.id))
        }
        return items
    }

    private func refreshItems(reselect: Bool = false) {
        items = buildItems()
        if reselect { selection = filtered.first?.id }
    }

    /// Case-insensitive substring filter on title + subtitle; prefix matches
    /// rank above contained matches.
    private var filtered: [CommandItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items
            .filter { $0.searchTitle.contains(q) || $0.searchSubtitle.contains(q) }
            .sorted { $0.searchTitle.hasPrefix(q) && !$1.searchTitle.hasPrefix(q) }
    }

    // MARK: Actions

    private func select(_ item: CommandItem) {
        onSelect(item.result)
        dismiss()
    }

    private func fireSelected() {
        if let id = selection, let item = filtered.first(where: { $0.id == id }) {
            select(item)
        } else if let item = filtered.first {
            select(item)
        }
    }

    private func dismiss() {
        withAnimation(Theme.Animation.bouncy) {
            isPresented = false
        }
        query = ""
    }
}

// MARK: - Command row

private struct CommandRow: View {
    let item: CommandItem
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(item.tint.opacity(isSelected ? 0.25 : 0.12))
                        .frame(width: 30, height: 30)
                    AppGlyph(name: item.icon, size: 13, box: 16)
                        .foregroundColor(item.tint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(Theme.Font.bodyLarge)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "return")
                        .font(Theme.Font.badgeMono.weight(.bold))
                        .foregroundColor(Theme.Ink.claude)
                        .symbolEffect(.bounce, value: isSelected)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(isSelected ? Theme.accent.opacity(0.10) : (isHovered ? Theme.cardFill(0.06) : Color.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverState($isHovered)
    }
}
