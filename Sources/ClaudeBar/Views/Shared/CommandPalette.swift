import SwiftUI

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
    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let result: CommandResult
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
    @EnvironmentObject var providerStore: ProviderStore

    @State private var query = ""
    @State private var selection: UUID?
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if isPresented {
                ZStack {
                    // Dimmed backdrop — click to dismiss.
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { dismiss() }
                        .transition(.opacity)

                    VStack(spacing: 0) {
                        searchBar
                        Divider().opacity(0.2)
                        resultsList
                    }
                    .frame(width: 460)
                    .glassEffect(
                        .regular.tint(Theme.bgSecondary.opacity(0.3)),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.xl)
                    )
                    .shadowCard(radius: 30, y: 16, opacity: 0.5)
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
                    selection = allItems.first?.id
                }
            }
        }
        .animation(Theme.Animation.smooth, value: isPresented)
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.accent)
                .symbolEffect(.pulse, options: .repeating)
            TextField("搜索页面、会话、供应商…", text: $query)
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
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
    }

    // MARK: Results

    private var resultsList: some View {
        ScrollView {
            GlassEffectContainer(spacing: 2) {
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
        }
        .frame(maxHeight: 360)
    }

    // MARK: Items

    /// The full set of navigable items, rebuilt from the store each render.
    private var allItems: [CommandItem] {
        var items = AppPage.allCases.map { p in
            CommandItem(kind: .page, title: p.label,
                        subtitle: "跳转到页面",
                        icon: p.icon, tint: Theme.accent,
                        result: .page(p))
        }
        items += providerStore.sessions.filter(\.isAlive).map { s in
            CommandItem(kind: .claudeSession, title: s.projectFolder,
                        subtitle: s.name.isEmpty ? "Claude Code · PID \(s.pid)" : s.name,
                        icon: "rectangle.connected.to.line.below",
                        tint: Theme.statusBusy,
                        result: .session(pid: s.pid))
        }
        items += providerStore.cursorSessions.map { s in
            CommandItem(kind: .cursorSession, title: s.projectFolder,
                        subtitle: s.name.isEmpty ? "Cursor" : s.name,
                        icon: "cursorarrow",
                        tint: Theme.cursorAccent,
                        result: .provider(id: UUID())) // cursor has no UUID; route to sessions page
        }
        items += providerStore.providers.map { p in
            CommandItem(kind: .provider, title: p.name,
                        subtitle: p.activeModel?.name ?? "供应商",
                        icon: "server.rack",
                        tint: Theme.accent,
                        result: .provider(id: p.id))
        }
        return items
    }

    /// Fuzzy-ish filter: case-insensitive substring on title + subtitle, with
    /// simple prefix-rank so typed-prefix matches float above contained ones.
    private var filtered: [CommandItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allItems }
        return allItems.compactMap { item in
            let title = item.title.lowercased()
            let sub = item.subtitle.lowercased()
            guard title.contains(q) || sub.contains(q) else { return nil }
            return item
        }
        .sorted { a, b in
            // Prefix matches rank first.
            let ap = a.title.lowercased().hasPrefix(q)
            let bp = b.title.lowercased().hasPrefix(q)
            if ap != bp { return ap }
            return false
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
                    Image(systemName: item.icon)
                        .font(.system(size: 12, weight: .semibold))
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
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.accent.opacity(0.8))
                        .symbolEffect(.bounce, value: isSelected)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(
                .regular.tint(isSelected ? Theme.accent.opacity(0.2) : (isHovered ? Theme.cardFill(0.06) : .clear)),
                in: RoundedRectangle(cornerRadius: Theme.Radius.md)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverState($isHovered)
    }
}
