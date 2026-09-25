import SwiftUI

/// The in-app manual, as a **contents rail + reader** rather than a list of
/// accordions.
///
/// The previous shape stacked every article as a collapsed row under a chapter
/// filter, so finding anything meant either reading all the summaries or
/// searching. A manual is read linearly within a topic and jumped around
/// between topics, which is exactly the master/detail split here:
///
///   * the **rail** lists every chapter with its articles, always visible, and
///     marks the one being read;
///   * the **reader** shows the selected article in full — no expand step.
///
/// Search filters the rail down to matching articles and re-seeds the reader
/// onto the first survivor, because it is the fast path when you know the word
/// but not the chapter. There is no separate chapter state to clear: chapters
/// are section headers over the filtered list, so an empty chapter simply
/// omits itself (see `rail`).
///
/// Content lives in `HelpCatalog` as static literals, so this page owns no
/// store — only the selected article, the query, and the cached filter. Those
/// stay `@State`: `MainWindowView` keys the page by `.id(selectedPage)`, so
/// leaving and returning resets to a clean state, which is what a manual wants.
struct HelpView: View {
    @State private var query = ""
    /// The article in the reader. Defaults to the first entry so the page never
    /// opens on an empty pane.
    @State private var selected: String = HelpCatalog.entries.first?.id ?? ""
    /// Cached rail contents; recomputed on query change, never from `body`.
    @State private var matches: [HelpEntry] = HelpCatalog.entries

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HairlineDivider()
            HStack(spacing: 0) {
                rail
                    .frame(width: 260)
                VerticalHairline()
                reader
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgPrimary)
        .onChange(of: query) { _, _ in recompute() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.s16) {
            PageTitle(title: "帮助")
            Spacer(minLength: Theme.Space.s8)
            searchField
        }
        .padding(.horizontal, Theme.Space.s24)
        .padding(.vertical, Theme.Space.s16)
    }

    private var searchField: some View {
        InstrumentSearchField(prompt: "搜索帮助", text: $query)
            .frame(width: 270)
    }

    // MARK: Contents rail

    private var rail: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s16) {
                if matches.isEmpty {
                    StandbyEmptyState(label: "没有匹配的条目",
                                      symbol: "magnifyingglass",
                                      tint: Theme.textSecondary)
                        .padding(.horizontal, Theme.Space.s16)
                        .padding(.top, Theme.Space.s8)
                } else {
                    ForEach(HelpChapter.allCases) { chapter in
                        let items = matches.filter { $0.chapter == chapter }
                        if !items.isEmpty {
                            chapterSection(chapter, items: items)
                        }
                    }
                }
            }
            .padding(.vertical, Theme.Space.s16)
        }
        .background(Theme.bgSecondary)
    }

    private func chapterSection(_ chapter: HelpChapter, items: [HelpEntry]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            HStack(spacing: Theme.Space.s6) {
                AppGlyph(name: chapter.icon, size: 10)
                    .foregroundColor(Theme.textTertiary())
                    .frame(width: 14)
                Text(chapter.label)
                    .font(Theme.Font.microSemibold)
                    .foregroundColor(Theme.textTertiary())
                    .textCase(.uppercase)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s16)
            .padding(.bottom, Theme.Space.s4)

            ForEach(items) { entry in
                railRow(entry)
            }
        }
    }

    private func railRow(_ entry: HelpEntry) -> some View {
        let on = entry.id == selected
        return Button {
            selected = entry.id
        } label: {
            HStack(spacing: Theme.Space.s8) {
                Circle()
                    .fill(on ? Theme.Ink.claude : Theme.hairline)
                    .frame(width: 5, height: 5)
                    .padding(.leading, 12)
                Text(entry.title)
                    .font(.system(size: 12, weight: on ? .semibold : .regular))
                    .foregroundColor(on ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.trailing, Theme.Space.s12)
            .background(on ? Theme.cardSurface : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.summary)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // MARK: Reader

    @ViewBuilder
    private var reader: some View {
        if let entry = selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s16) {
                    VStack(alignment: .leading, spacing: Theme.Space.s6) {
                        HStack(spacing: Theme.Space.s6) {
                            AppGlyph(name: entry.chapter.icon, size: 10)
                                .foregroundColor(Theme.Ink.claude)
                            Text(entry.chapter.label)
                                .font(Theme.Font.microSemibold)
                                .foregroundColor(Theme.Ink.claude)
                        }
                        Text(entry.title)
                            .font(Theme.Font.displayHero)
                            .foregroundColor(Theme.textPrimary)
                        Text(entry.summary)
                            .font(Theme.Font.bodySmall)
                            .foregroundColor(Theme.textSecondary)
                    }
                    HairlineDivider()
                    VStack(alignment: .leading, spacing: Theme.Space.s12) {
                        ForEach(Array(entry.body.enumerated()), id: \.offset) { _, block in
                            HelpBlockView(block: block)
                        }
                    }
                }
                .padding(Theme.Space.s24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            StandbyEmptyState(label: "没有匹配的条目")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var selectedEntry: HelpEntry? {
        matches.first { $0.id == selected } ?? matches.first
    }

    private func recompute() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        matches = q.isEmpty ? HelpCatalog.entries : HelpCatalog.entries.filter { $0.haystack.contains(q) }
        // Keep the reader on an article the new filter still contains.
        if !matches.contains(where: { $0.id == selected }) {
            selected = matches.first?.id ?? ""
        }
    }
}

// MARK: - Block rendering

private struct HelpBlockView: View {
    let block: HelpBlock

    var body: some View {
        switch block {
        case .para(let text):
            helpText(text)
                .font(Theme.Font.bodySmall)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: Theme.Space.s6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                        Text("•")
                            .font(Theme.Font.bodySmall)
                            .foregroundColor(Theme.textTertiary())
                        helpText(item)
                            .font(Theme.Font.bodySmall)
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .code(let snippet):
            CodeBlock(code: snippet)

        case .keys(let keys, let caption):
            KeycapRow(keys: keys, caption: caption)

        case .paths(let rows):
            VStack(alignment: .leading, spacing: Theme.Space.s6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s10) {
                        Text(row.path)
                            .font(Theme.Font.captionMono)
                            .foregroundColor(Theme.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(row.note)
                            .font(Theme.Font.caption)
                            .foregroundColor(Theme.textTertiary())
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Inline emphasis only — `**bold**` and `` `code` `` across the help
    /// prose, which plain `Text` would render as literal asterisks because the
    /// string arrives as a variable, not a literal. Inline-only parsing keeps
    /// the block structure that the `.para` / `.bullets` cases already provide.
    private func helpText(_ raw: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(raw)
    }
}
