import AppKit
import SwiftUI

/// Console of proxy access lines. No payloads — the inspector next door
/// owns request / response bodies.
struct ProxyLogView: View {
    @ObservedObject private var log = ProxyAccessLog.shared
    @EnvironmentObject var codexStore: CodexProviderStore
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var copied = false
    /// Filtering is O(rows × 4 lowercased()) and used to run in every `body`
    /// evaluation — including the ones the scroll animation drove. Cache it
    /// and recompute only when an input actually changes.
    @State private var filtered: [ProxyLogEntry] = []
    /// The console auto-scrolls to the tail exactly once per mount; a
    /// re-entrant `onAppear` (LazyVStack rebuilds) used to fire it forever.
    @State private var didInitialScroll = false
    /// What the filter pass actually reads: row identity plus the four fields
    /// the predicate looks at. `publishUpdated` fires on *every* completion, so
    /// without this every sealed request re-ran the pass below over all 500 rows
    /// (up to 2000 `lowercased()` allocations) plus a 500-element struct-array
    /// diff — the same cost `TrafficView` guards with its own stamp.
    @State private var entriesStamp = 0

    enum Filter: String, CaseIterable, Identifiable {
        case all, claude, codex, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "全部"
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .other: return "第三方"
            }
        }
    }

    /// Identity + the four searchable fields; a status/duration/token patch
    /// leaves it unchanged.
    private static func stamp(_ rows: [ProxyLogEntry]) -> Int {
        var hasher = Hasher()
        for row in rows {
            hasher.combine(row.id)
            hasher.combine(row.source)
            hasher.combine(row.path)
            hasher.combine(row.model)
            hasher.combine(row.provider)
            hasher.combine(row.error)
        }
        return hasher.finalize()
    }

    private func recomputeFiltered() {
        entriesStamp = Self.stamp(log.entries)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = log.entries.filter { row in
            switch filter {
            case .all: break
            case .claude: if row.source != .claude { return false }
            case .codex: if row.source != .codex { return false }
            case .other: if row.source != .other { return false }
            }
            guard !q.isEmpty else { return true }
            return row.path.lowercased().contains(q)
                || row.model.lowercased().contains(q)
                || row.provider.lowercased().contains(q)
                || (row.error?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            HairlineDivider()
            if filtered.isEmpty {
                empty
            } else {
                console
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgPrimary)
        .onAppear { recomputeFiltered() }
        .onChange(of: log.entries) { _, rows in
            // `@Published` emits before assignment for the incremental
            // publishers, and the pass is only worth running when it would read
            // something different.
            guard entriesStamp != Self.stamp(rows) else { return }
            recomputeFiltered()
        }
        .onChange(of: filter) { _, _ in recomputeFiltered() }
        .onChange(of: query) { _, _ in recomputeFiltered() }
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Space.s8) {
            ForEach(Filter.allCases) { f in
                let on = filter == f
                Button(f.label) { filter = f }
                    .font(Theme.Font.caption)
                    .foregroundColor(on ? Theme.claude : Theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(on ? Theme.claude.opacity(0.12) : Theme.cardFill(0.06)))
                    .buttonStyle(.plain)
            }
            InstrumentSearchField(prompt: "路径 / 模型 / 供应商", text: $query)
                .frame(maxWidth: 240)
            Spacer()
            RollingNumberText("\(filtered.count)")
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textTertiary())
                .monospacedDigit()
            // 复制 follows what is *visible*: gating it on the buffer meant a
            // query that matched nothing left a live button that copied the
            // empty string, silently wiping the user's pasteboard while
            // reporting 已复制. 清空 follows the buffer, because that is what it
            // clears.
            if !filtered.isEmpty {
                Button(copied ? "已复制" : "复制") { copyVisible() }
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textSecondary)
                    .buttonStyle(.plain)
            }
            if !log.entries.isEmpty {
                Button("清空") { log.clear() }
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.Ink.error)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.s16)
        .padding(.vertical, Theme.Space.s8)
    }

    /// Two different empty states. A query that matches none of the 500 rows is
    /// not "nothing has been logged" — the sibling inspector already makes that
    /// distinction (暂无记录 vs 没有匹配「…」的内容) and this page was telling a
    /// user with a typo that their proxy had never seen a request.
    private var empty: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Text(log.entries.isEmpty ? "暂无请求日志" : "没有匹配的日志")
                .font(Theme.Font.body)
                .foregroundColor(Theme.textSecondary)
            Text(log.entries.isEmpty
                 ? (codexStore.proxyRunning
                    ? "代理已启用。每次转发会在此留下一行（方法、路径、状态、耗时、令牌用量），不记录请求体或响应体。"
                    : "启用本地代理或供应商上的流量记录后，转发请求会显示在这里。")
                 : "共 \(log.entries.count) 行，没有一行同时满足当前的类型筛选与搜索词。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.s16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { row in
                        HStack(alignment: .top, spacing: 0) {
                            Text(row.consoleBody)
                                .font(Theme.Font.console)
                                .foregroundColor(color(for: row))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            // Token column, right-aligned: a new row's counts
                            // appear here the moment its usage event lands,
                            // without the metadata line reflowing.
                            RollingNumberText(row.tokenField)
                                .font(Theme.Font.console)
                                .foregroundColor(Theme.textTertiary())
                                .monospacedDigit()
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                        .help(row.consoleLine)
                        // No per-row .textSelection(.enabled): 500 rows of
                        // selectable text laid out on every content rebuild
                        // is the expensive path. Copy-all covers the need.
                        .padding(.horizontal, Theme.Space.s16)
                        .padding(.vertical, 3)
                        .background(row.id == filtered.last?.id && row.isPending
                                    ? Theme.cardFill(0.04) : Color.clear)
                        .id(row.id)
                    }
                }
                .padding(.vertical, Theme.Space.s8)
            }
            .onAppear {
                guard !didInitialScroll else { return }
                didInitialScroll = true
                scrollToEnd(proxy, animated: false)
            }
            .onChange(of: log.entries.last?.id) { _, _ in
                // Only chase the tail while this view is actually on screen;
                // an off-screen page has no reason to animate its scroll
                // position (that loop used to run at 170 scrolls/s with the
                // page hidden behind opacity(0)).
                guard UIWakePolicy.hasVisibleMainWindow else { return }
                scrollToEnd(proxy, animated: true)
            }
        }
    }

    private func color(for row: ProxyLogEntry) -> Color {
        if row.isPending { return Theme.textSecondary }
        if let err = row.error, !err.isEmpty { return Theme.statusError }
        if row.status >= 500 { return Theme.statusError }
        if row.status >= 400 { return Theme.statusWarning }
        return Theme.textPrimary
    }

    /// `animated: false` for the one-shot jump on mount — `withAnimation` here
    /// turns every appended line into a scroll transaction, which re-evaluates
    /// the content closure and re-enters `onAppear` on the rebuilt LazyVStack.
    ///
    /// Targets `filtered.last` because that is the row the console actually
    /// ends on; with a filter active the *buffer's* last row is not rendered at
    /// all, and scrolling to an id that is not in the view is a no-op.
    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        // Read `filtered` *inside* the deferred block, not before it: the two
        // `.onChange` handlers on `log.entries` (this one and the filter's) run
        // in the same update pass in an order SwiftUI does not promise, so
        // capturing the tail out here could chase the previous row for every
        // appended line.
        DispatchQueue.main.async {
            guard let last = filtered.last else { return }
            if animated {
                withAnimation(Theme.Motion.page) { proxy.scrollTo(last.id, anchor: .bottom) }
            } else {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func copyVisible() {
        let text = filtered.map(\.consoleLine).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
