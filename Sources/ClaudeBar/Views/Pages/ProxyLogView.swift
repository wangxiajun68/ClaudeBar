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
    @State private var confirmClear = false
    /// Filtering is O(rows × 4 lowercased()) and used to run in every `body`
    /// evaluation — including the ones the scroll animation drove. Cache it
    /// and recompute only when an input actually changes.
    @State private var filtered: [ProxyLogEntry] = []
    /// Tail-following, as on the VPN page's traffic console: the chase used to
    /// be unconditional, so a reader who scrolled up was yanked back to the
    /// bottom by the next sealed request, and every appended line opened a
    /// fresh 0.18 s scroll transaction whose re-evaluated content closure
    /// re-entered `onAppear` on the rebuilt `LazyVStack`. Appends now scroll
    /// without animation and only while the user is at the tail.
    @State private var followTail = true
    /// Whether the viewport's bottom edge is at the last line, and whether a
    /// scroll gesture is what put it there — a new row also moves the tail
    /// away, and only a *gesture* may turn `followTail` off.
    @State private var atTail = true
    @State private var tracking = false
    /// What the filter pass actually reads: row identity plus the fields a
    /// *seal* patches in place. `schedulePublishLocked` publishes on every
    /// completion, so without this every sealed request re-ran the pass below
    /// over all 500 rows (up to 2000 `lowercased()` allocations) plus a
    /// 500-element struct-array diff — the same cost `TrafficView` guards with
    /// its own stamp.
    @State private var entriesStamp = 0

    private static let tailTolerance: CGFloat = 24

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

    /// Everything a cached row derives from: the four searchable fields, plus
    /// the ones a *seal* patches in place. `ProxyAccessLog.finish` rewrites the
    /// row — `endedAt`, `status`, the four token buckets — and the console
    /// renders all of them (`consoleBody`'s status / duration, `LogTokenColumn`,
    /// `isPending`'s highlight, and 复制's `consoleLine`). Stamping only the
    /// searchable fields would skip exactly the pass that turns a pending grey
    /// `…` row into its finished reading.
    private static func stamp(_ rows: [ProxyLogEntry]) -> Int {
        var hasher = Hasher()
        for row in rows {
            hasher.combine(row.id)
            hasher.combine(row.source)
            hasher.combine(row.path)
            hasher.combine(row.model)
            hasher.combine(row.provider)
            hasher.combine(row.error)
            hasher.combine(row.endedAt)
            hasher.combine(row.status)
            hasher.combine(row.promptTokens)
            hasher.combine(row.completionTokens)
            hasher.combine(row.cacheReadTokens)
            hasher.combine(row.cacheWriteTokens)
        }
        return hasher.finalize()
    }

    private func recomputeFiltered() {
        entriesStamp = Self.stamp(log.entries)
        filtered = Self.matching(log.entries, query: query, filter: filter)
    }

    /// The predicate over the ring, lifted out so the reconcile path can tell
    /// "membership could have changed" from "a cached value needs a patch"
    /// without running it.
    private static func matching(_ rows: [ProxyLogEntry], query: String, filter: Filter) -> [ProxyLogEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { row in
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

    /// The stamp's inputs (see `stamp`) are exactly the fields the predicate
    /// reads plus the ones a seal patches. When the stamp is unchanged the
    /// predicate would return the same members, so only the patched values
    /// need copying — otherwise a streaming `finish` re-ran up to 2,000
    /// `lowercased()` allocations to change nothing but four numbers.
    private func reconcileFiltered() {
        if entriesStamp != Self.stamp(log.entries) {
            recomputeFiltered()
            return
        }
        let ids = Set(filtered.map(\.id))
        let latest = log.entries.filter { ids.contains($0.id) }
        if latest != filtered { filtered = latest }
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
        .onAppear {
            log.loadListIfNeeded()
            recomputeFiltered()
        }
        .onChange(of: log.entries) { _, _ in
            // The pass is only worth running when it would read something
            // different; `reconcileFiltered` still has to run every time,
            // because a seal patches values the *predicate* does not read.
            reconcileFiltered()
        }
        .onChange(of: filter) { _, _ in recomputeFiltered() }
        .onChange(of: query) { _, _ in recomputeFiltered() }
        .alert("清空访问日志？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                log.clear()
                filtered = []
                entriesStamp = 0
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 \(log.entries.count) 行访问记录及其磁盘日志，无法恢复。")
        }
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
            // Two actions that used to be *text* — a font and a colour, with no
            // control drawn at all. They are the same push button every other
            // page's 复制 / 清空 is, in the tone each one's intent asks for.
            if !filtered.isEmpty {
                ActionButton(copied ? "已复制" : "复制") { copyVisible() }
            }
            if !log.entries.isEmpty {
                ActionButton("清空", tone: .destructive) { confirmClear = true }
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
                .rollingNumber(log.entries.isEmpty
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
                            // Fixed-width buckets, so 入 / 出 / 缓存 line up down
                            // the page. A new row's counts land here when its
                            // usage event arrives, without the metadata line
                            // reflowing.
                            LogTokenColumn(entry: row)
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
            // The initial landing is the scroll view's own, resolved as the
            // content is laid out; the one-shot `onAppear` jump it replaces
            // raced the first layout.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentSize.height + geo.contentInsets.bottom
                    - (geo.contentOffset.y + geo.containerSize.height) <= Self.tailTolerance
            } action: { _, tail in
                atTail = tail
                if tracking && !tail { followTail = false }
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    tracking = true
                case .idle:
                    if tracking && atTail && query.isEmpty && filter == .all { followTail = true }
                    tracking = false
                default: break
                }
            }
            .onChange(of: log.entries.last?.id) { _, _ in
                // Only chase the tail while this view is actually on screen;
                // an off-screen page has no reason to animate its scroll
                // position (that loop used to run at 170 scrolls/s with the
                // page hidden behind opacity(0)). `followTail` is false while
                // the user is reading history, and a chase restarts only when
                // they return to the bottom.
                guard followTail, !tracking, UIWakePolicy.hasVisibleMainWindow else { return }
                scrollToEnd(proxy)
            }
            // Returning to the default filter re-establishes the tail; leaving
            // it hides new rows from the console entirely, and chasing an id
            // that is not rendered is a no-op.
            .onChange(of: filter) { _, next in
                guard next == .all, query.isEmpty, followTail else { return }
                scrollToEnd(proxy)
            }
            .overlay(alignment: .bottomTrailing) {
                if !followTail {
                    ActionButton("回到最新", tone: .neutral) {
                        followTail = true
                        scrollToEnd(proxy)
                    }
                    .padding(Theme.Space.s8)
                }
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

    /// No `withAnimation` on the chase: every appended line used to open a
    /// 0.18 s scroll transaction, and at the 0.1 s publish cadence of a busy
    /// proxy the transactions never settled — each display refresh re-ran the
    /// page's whole layout and display list for an effect nobody sees on a
    /// one-line shift.
    ///
    /// Targets `filtered.last` because that is the row the console actually
    /// ends on; with a filter active the *buffer's* last row is not rendered at
    /// all, and scrolling to an id that is not in the view is a no-op.
    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        // Read `filtered` *inside* the deferred block, not before it: the two
        // `.onChange` handlers on `log.entries` (this one and the filter's) run
        // in the same update pass in an order SwiftUI does not promise, so
        // capturing the tail out here could chase the previous row for every
        // appended line.
        DispatchQueue.main.async {
            guard let last = filtered.last else { return }
            proxy.scrollTo(last.id, anchor: .bottom)
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

/// One request's token buckets, each in a fixed slot.
///
/// The old line was one string (`Σ 25.4万 (in 25.3万 / out 452 / hit 0)`).
/// Shorter numbers started further right, so nothing lined up. 合计, 入, 出,
/// 缓存 and 写入 now each own a width, and a missing bucket is `—` rather
/// than a hole that shifts the rest.
struct LogTokenColumn: View {
    let entry: ProxyLogEntry

    private static let number: CGFloat = 72
    private static let label: CGFloat = 26

    var body: some View {
        if entry.totalTokens != nil || entry.isPending {
            HStack(spacing: 10) {
                figure(entry.totalTokens, pending: entry.isPending && entry.totalTokens == nil, strong: true)
                labeled("入", entry.promptTokens)
                labeled("出", entry.completionTokens)
                labeled("缓存", entry.cacheReadTokens)
                labeled("写入", entry.cacheWriteTokens)
            }
            .lineLimit(1)
        }
    }

    private func labeled(_ title: String, _ value: Int?) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(Theme.Font.console)
                .foregroundStyle(Theme.textTertiary().opacity(0.8))
                .frame(width: Self.label, alignment: .trailing)
            figure(value, pending: false, strong: false)
        }
    }

    /// `rolls: false`: these are readings, not animations. A seal flips a
    /// whole visible window of `…` placeholders into values at once, and a
    /// ring already at its cap shifts every row's identity on the same
    /// publish — the rolling transition would start five transactions per
    /// visible row and never settle.
    private func figure(_ value: Int?, pending: Bool, strong: Bool) -> some View {
        let text = pending ? "…" : (value.map(UsageStats.formatTokens) ?? "—")
        return RollingNumberText(text, rolls: false)
            .font(Theme.Font.console)
            .foregroundStyle(strong ? Theme.textSecondary : Theme.textTertiary())
            .frame(width: Self.number, alignment: .trailing)
    }
}
