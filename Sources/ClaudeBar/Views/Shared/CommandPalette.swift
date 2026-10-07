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

/// A single searchable row in the command palette. `icon` and `tint` drive the
/// row's glyph and accent; `subtitle` is secondary help text under the title.
///
/// `Equatable` so `CommandRow` can compare rows: an arrow keypress only flips
/// the selection, and equality is what lets SwiftUI skip the body of every row
/// whose identity, content and selection state did not change. A non-Equatable
/// row re-rendered all N rows per keypress (finding 220).
struct CommandItem: Identifiable, Equatable {
    let id: String
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

    init(id: String, title: String, subtitle: String,
         icon: String, tint: Color, result: CommandResult) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.result = result
        self.searchTitle = title.lowercased()
        self.searchSubtitle = subtitle.lowercased()
    }

    /// Prepare only when the query or source items change. A stable linear
    /// partition keeps prefix matches first without sorting each redraw.
    static func matching(_ items: [CommandItem], query: String) -> [CommandItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        var prefix: [CommandItem] = []
        var contained: [CommandItem] = []
        for item in items {
            if item.searchTitle.hasPrefix(q) {
                prefix.append(item)
            } else if item.searchTitle.contains(q) || item.searchSubtitle.contains(q) {
                contained.append(item)
            }
        }
        prefix.append(contentsOf: contained)
        return prefix
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
    @State private var filtered: [CommandItem] = []
    @State private var storeChanges: AnyCancellable?
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
                        RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                            .fill(Theme.cardSurface)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    }
                    .shadowCard(radius: 24, y: 12, opacity: 0.12)
                    // The entrance is carried by the transition alone: this
                    // subtree only exists inside `if isPresented`, so the
                    // transition supplies the scale and fade.
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
        .task {
            // Subscribed once per presentation, not rebuilt per body pass.
            // Constructed in `body`, the MergeMany chain (13 store publishers)
            // was re-allocated and re-subscribed on every keystroke — the
            // palette's body passes on each one (finding 223). The closed-
            // palette guard stays inside the sink: publishes while closed are
            // dropped, which is why the reopen refresh exists.
            storeChanges = Publishers.MergeMany(providerStore.viewChanges([.configuration, .sessions]))
                .sink { _ in
                    guard isPresented else { return }
                    refreshItems()
                }
        }
        // Escape, then ⌘K again *inside* the dismissal's fade: the panel never
        // leaves the hierarchy (measured — no `onDisappear`, no re-mount, so
        // `onAppear` never runs again), yet `dismiss()` has already cleared the
        // query while `filtered` still holds the previous search's rows. The
        // reopened panel would draw that subset under an empty box — and
        // return would fire a row the user can no longer see a reason for —
        // until the next publish or keystroke. Refreshing on the open edge
        // closes the window; the mount path above still covers a real remount.
        .onChange(of: isPresented) { _, presented in
            guard presented else { return }
            searchFocused = true
            refreshItems(reselect: true)
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
                    refreshResults(reselect: true)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .instrumentWell(radius: Theme.Radius.lg, focused: searchFocused,
                        accent: Theme.Ink.claude, onCard: true)
        .padding(10)
    }

    // MARK: Results

    private var resultsList: some View {
        ScrollViewReader { proxy in
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
            // Arrow-key selection must stay visible: the list holds up to ~40
            // rows in a 360pt viewport, and Return fires whatever `selection`
            // names — without this, the highlight could sit below the fold and
            // Return would activate a row the user cannot see (finding 221).
            .onChange(of: selection) { _, id in
                guard let id else { return }
                withAnimation(Theme.Animation.roll) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var resultsStack: some View {
        LazyVStack(spacing: 2) {
            ForEach(filtered) { item in
                CommandRow(item: item, isSelected: selection == item.id) {
                    select(item)
                }
                .equatable()
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
            CommandItem(id: "page:\(p.rawValue)", title: p.label,
                        subtitle: "前往页面",
                        icon: p.icon, tint: Theme.accent,
                        result: .page(p))
        }
        items += providerStore.sessions.filter(\.isAlive).map { s in
            CommandItem(id: "claude:\(s.pid)", title: s.displayTitle,
                        subtitle: s.name.isEmpty ? "Claude Code · PID \(s.pid)" : s.name,
                        icon: "rectangle.connected.to.line.below",
                        tint: Theme.statusBusy,
                        result: .session(pid: s.pid))
        }
        // Cursor sessions carry no UUID, so they route to the sessions page.
        items += providerStore.cursorSessions.map { s in
            CommandItem(id: "cursor:\(s.composerId)", title: s.displayTitle,
                        subtitle: s.name.isEmpty ? "Cursor" : s.name,
                        // The palette is a list of *sessions*, so a row's icon
                        // is the row's kind, not a brand — the sessions page
                        // beside it names the client with the bundled mark, and
                        // a palette that repeated the cube on all three rows
                        // would lose the "which client" reading instead of
                        // gaining it (the subtitle already says Cursor).
                        icon: "cursorarrow",
                        tint: Theme.cursorAccent,
                        result: .page(.sessions))
        }
        items += providerStore.providers.map { p in
            CommandItem(id: "provider:\(p.id)", title: p.name,
                        subtitle: p.activeModel?.name ?? "供应商",
                        icon: "cube",
                        tint: Theme.accent,
                        result: .provider(id: p.id))
        }
        return items
    }

    private func refreshItems(reselect: Bool = false) {
        items = buildItems()
        refreshResults(reselect: reselect)
    }

    private func refreshResults(reselect: Bool = false) {
        filtered = CommandItem.matching(items, query: query)
        if reselect || !filtered.contains(where: { $0.id == selection }) {
            selection = filtered.first?.id
        }
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
        // The query is cleared here so the fade-out already shows the empty
        // field. `filtered`/`items`/`selection` deliberately stay: clearing
        // them wiped the list under the animation's last frame, and the one
        // hazard they do carry — a re-open *inside* the fade, which reuses this
        // instance with `filtered` still holding the old search's rows — is
        // closed by the `onChange(of: isPresented)` refresh in `body`, which
        // rebuilt and reselected before the panel's first frame
        // (`Tests/command-palette-reopen-regressions.py` measures both that
        // same-transaction path and the settle-past-the-fade remount).
        query = ""
    }
}

// MARK: - Command row

private struct CommandRow: View, Equatable {
    /// The closure is deliberately not compared: it calls `select`, which
    /// captures nothing that changes what the row draws (same rule as
    /// `TrafficRow`). Comparing the item and the selection flag is what lets
    /// an arrow keypress skip every row but the two whose highlight moved.
    static func == (lhs: CommandRow, rhs: CommandRow) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected
    }

    let item: CommandItem
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
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
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.10) : (isHovered ? Theme.cardFill(0.06) : Color.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverState($isHovered)
    }
}
