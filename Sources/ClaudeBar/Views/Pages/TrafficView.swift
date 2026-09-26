import AppKit
import SwiftUI

/// Everything the inspector would otherwise lose when it unmounts.
///
/// The page used to stay mounted forever (`opacity(0)` when another tab was
/// selected) purely so re-entering it did not re-read multi-MB payloads from
/// SQLite. Keeping it mounted meant its body re-evaluated on every catalog /
/// live-stream publish even while invisible — the single largest idle-CPU
/// item in the app. Owning the expensive state here instead lets the view
/// unmount for real and come back instantly.
final class TrafficPageState: ObservableObject {
    @Published var selectedID: Int64?
    @Published var filter: TrafficView.TrafficFilter = .all
    @Published var query = ""
    @Published var detail: CaptureDetail?
    @Published var tab: TrafficView.TrafficTab = .conversation
    @Published var rawSlice: TrafficView.RawSlice = .request
    @Published var rawCopied = false
    @Published var mode: TrafficView.TrafficMode = .inspector
    @Published var fullTurns: [CaptureTranscript.Turn] = []
    @Published var conversationQuery = ""
    @Published var expandedBlocks: Set<String> = []
    @Published var displayBlocks: [ConvBlock] = []
    @Published var historyCount = 0
    @Published var loadingDetail = false
    /// Guards out-of-order async detail loads; survives remount so a load
    /// started before unmount still lands correctly.
    var loadGen = 0
    /// False between `onDisappear` and the next `onAppear`.
    ///
    /// `loadGen` alone cannot guard the full-render pass: `rebuildFullTurns`
    /// reads the generation but never bumps it, so two rebuilds queued back to
    /// back (a fast `payloadsLoaded` → `fullRender` flip) both capture the same
    /// value and the cancelled one's completion block still passes its guard —
    /// writing a stale `fullTurns` into a remounted view. It also cannot cover
    /// unmount at all, since `onDisappear` bumps the generation *for* the
    /// in-flight load it expects to accept after remount.
    var mounted = false
    let detailQueue = DispatchQueue(label: "com.claudebar.capture-detail", qos: .userInitiated)
    var detailWork: DispatchWorkItem?
    var fullWork: DispatchWorkItem?

    private var conversationInput: ConversationInput?
    private var conversationPending = false
    private let conversationQueue = DispatchQueue(label: "com.claudebar.conversation", qos: .userInitiated)

    func clearConversation() {
        conversationInput = nil
        displayBlocks = []
        historyCount = 0
    }

    func requestConversation(_ input: ConversationInput) {
        guard conversationInput != input else { return }
        conversationInput = input
        startConversation()
    }

    private func startConversation() {
        guard !conversationPending, let input = conversationInput else { return }
        conversationPending = true
        conversationQueue.async { [weak self] in
            let blocks = ConversationBuilder.build(input)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.conversationPending = false
                guard self.conversationInput == input else {
                    self.startConversation()
                    return
                }
                self.historyCount = input.history.count
                self.displayBlocks = blocks
            }
        }
    }

    /// The list selection the inspector should show. Mirrors the old
    /// computed property so remounting restores exactly what was on screen.
    func currentSummary(in records: [CaptureSummary], filtered: [CaptureSummary]) -> CaptureSummary? {
        records.first(where: { $0.id == selectedID }) ?? filtered.first
    }
}

/// Live proxy capture inspector: request list + conversation that fills the pane.
struct TrafficView: View {
    @ObservedObject private var catalog = ProxyCaptureStore.shared.catalog
    private let streams = ProxyCaptureStore.shared.streams
    @State private var selectedLive: CaptureLive?
    @EnvironmentObject var codexStore: CodexProviderStore
    /// Owned by MainWindowController — survives this view's mount/unmount.
    @EnvironmentObject var state: TrafficPageState
    @StateObject private var jsonFold = JSONFoldControl()
    @AppStorage("trafficFullRender") private var fullRender = false

    // The state below lives on `state`; these computed accessors keep the
    // body readable and the mutation sites unchanged.
    private var selectedID: Int64? {
        get { state.selectedID }
        nonmutating set { state.selectedID = newValue }
    }
    private var filter: TrafficFilter {
        get { state.filter }
        nonmutating set { state.filter = newValue }
    }
    private var query: String {
        get { state.query }
        nonmutating set { state.query = newValue }
    }
    private var detail: CaptureDetail? {
        get { state.detail }
        nonmutating set { state.detail = newValue }
    }
    private var tab: TrafficTab {
        get { state.tab }
        nonmutating set { state.tab = newValue }
    }
    private var rawSlice: RawSlice {
        get { state.rawSlice }
        nonmutating set { state.rawSlice = newValue }
    }
    private var rawCopied: Bool {
        get { state.rawCopied }
        nonmutating set { state.rawCopied = newValue }
    }
    private var mode: TrafficMode {
        get { state.mode }
        nonmutating set { state.mode = newValue }
    }
    private var fullTurns: [CaptureTranscript.Turn] {
        get { state.fullTurns }
        nonmutating set { state.fullTurns = newValue }
    }
    private var conversationQuery: String {
        get { state.conversationQuery }
        nonmutating set { state.conversationQuery = newValue }
    }
    private var expandedBlocks: Set<String> {
        get { state.expandedBlocks }
        nonmutating set { state.expandedBlocks = newValue }
    }
    private var displayBlocks: [ConvBlock] {
        get { state.displayBlocks }
        nonmutating set { state.displayBlocks = newValue }
    }
    private var historyCount: Int {
        get { state.historyCount }
        nonmutating set { state.historyCount = newValue }
    }
    private var loadingDetail: Bool {
        get { state.loadingDetail }
        nonmutating set { state.loadingDetail = newValue }
    }

    private var queryBinding: Binding<String> {
        Binding(get: { state.query }, set: { state.query = $0 })
    }
    private var conversationQueryBinding: Binding<String> {
        Binding(get: { state.conversationQuery }, set: { state.conversationQuery = $0 })
    }
    enum TrafficMode: String, CaseIterable, Identifiable {
        case inspector, log
        var id: String { rawValue }
        var label: String { self == .inspector ? "检查器" : "日志" }
    }

    enum RawSlice: String, CaseIterable, Identifiable {
        case request, rewritten, response, sse
        var id: String { rawValue }
        var label: String {
            switch self {
            case .request: return "请求"
            case .rewritten: return "改写"
            case .response: return "响应"
            case .sse: return "SSE"
            }
        }
    }

    enum TrafficFilter: String, CaseIterable, Identifiable {
        case all, anthropic, openai
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "全部"
            case .anthropic: return "Anthropic"
            case .openai: return "OpenAI"
            }
        }
    }

    enum TrafficTab: String, CaseIterable, Identifiable {
        case conversation, tools, raw
        var id: String { rawValue }
        var label: String {
            switch self {
            case .conversation: return "对话"
            case .tools: return "工具"
            case .raw: return "原始"
            }
        }
    }

    /// Filtering is O(rows × 3 `lowercased()`) and used to run in every `body`
    /// evaluation — including the ones the 0.1 s-debounced live-stream publish
    /// drives while anything is streaming. Cache it, exactly as `ProxyLogView`
    /// already does, and recompute only when an input changes.
    @State private var filteredCache: [CaptureSummary] = []
    /// `Self.stamp` of the record list the cache was built from.
    @State private var recordsStamp = ""
    /// `clearAll` deletes every captured request and its payload — the only
    /// copy, no undo — and it used to be a single click on a plain text
    /// button. The VPN module already confirms its destructive action.
    @State private var confirmClear = false

    /// What a filter pass actually depends on: the row identity plus the three
    /// fields the predicate reads. A status/duration-only patch leaves it
    /// unchanged.
    private static func stamp(_ records: [CaptureSummary]) -> String {
        var hasher = Hasher()
        for rec in records {
            hasher.combine(rec.id)
            hasher.combine(rec.model)
            hasher.combine(rec.providerName)
            hasher.combine(rec.preview)
            hasher.combine(rec.kind)
        }
        return String(hasher.finalize())
    }

    private func recomputeFiltered() {
        recordsStamp = Self.stamp(catalog.records)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        filteredCache = catalog.records.filter { rec in
            switch filter {
            case .all: break
            case .anthropic: if rec.kind != .anthropic { return false }
            case .openai: if rec.kind == .anthropic { return false }
            }
            guard !q.isEmpty else { return true }
            return rec.model.lowercased().contains(q)
                || rec.providerName.lowercased().contains(q)
                || rec.preview.lowercased().contains(q)
        }
    }

    private var filtered: [CaptureSummary] { filteredCache }

    private var currentSummary: CaptureSummary? {
        state.currentSummary(in: catalog.records, filtered: filtered)
    }

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            HairlineDivider()
            if mode == .log {
                ProxyLogView()
            } else {
                inspector
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgPrimary)
    }

    private var modeBar: some View {
        HStack(spacing: Theme.Space.s8) {
            PageTitle(title: "流量")
            SegmentedCapsule(items: TrafficMode.allCases,
                             selection: mode,
                             title: { $0.label },
                             tint: Theme.Ink.claude,
                             onSelect: { mode = $0 })
            Spacer()
            StatusPill(
                label: codexStore.proxyRunning ? "代理已启用" : "代理未启用",
                tint: codexStore.proxyRunning ? Theme.statusSuccess : Theme.statusIdle,
                ink: codexStore.proxyRunning ? Theme.Ink.success : Theme.Ink.idle
            )
            if codexStore.proxyRunning {
                if let p = codexStore.activeProvider {
                    Text("·")
                        .foregroundColor(Theme.textTertiary())
                    Text("Codex \(p.name)")
                        .font(Theme.Font.captionMono)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                let tp = codexStore.resolvedThirdPartyOpenAI()
                if let tp, tp.id != codexStore.activeProviderID {
                    Text("·")
                        .foregroundColor(Theme.textTertiary())
                    Text("第三方 \(tp.name)")
                        .font(Theme.Font.captionMono)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, Theme.Space.s16)
        .padding(.top, Theme.Space.s16)
        .padding(.bottom, Theme.Space.s8)
    }

    private var inspector: some View {
        HStack(spacing: 0) {
            listPane
                .frame(width: 300)
                .frame(maxHeight: .infinity)
            VerticalHairline()
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgPrimary)
        .onChange(of: selectedID) { _, id in
            selectedLive = id.flatMap { streams.live[$0] }
            state.clearConversation()
            fullTurns = []
            tab = .conversation
            conversationQuery = ""
            expandedBlocks = []
            displayBlocks = []
            reloadDetail(id, raw: false, tools: false)
        }
        .onChange(of: fullRender) { _, on in
            if on { rebuildFullTurns() }
            rebuildConversation()
        }
        .onChange(of: detail?.summary.id) { _, _ in
            if fullRender { rebuildFullTurns() }
            rebuildConversation()
        }
        .onChange(of: conversationQuery) { _, _ in
            rebuildConversation()
        }
        .onReceive(catalog.$records) { _ in
            // @Published emits before assignment; read the committed array.
            // One handler, not two: this used to be paired with an
            // `onChange(of: catalog.records.count)` that ran the same filter a
            // second time for the same publish (and a count-only handler would
            // miss an in-place record update anyway, hence the deferral).
            DispatchQueue.main.async {
                // Cheap guard: a record publish that does not change what the
                // filter reads (an in-place status/duration patch) must not
                // re-run the O(rows × 3 lowercased()) pass and re-diff the
                // 120-row list behind it.
                guard recordsStamp != Self.stamp(catalog.records) else { return }
                recomputeFiltered()
                if selectedID == nil { selectedID = filtered.first?.id }
            }
        }
        .onChange(of: currentSummary?.state) { _, state in
            if state == .done || state == .error || state == .aborted {
                reloadDetail(selectedID, raw: tab == .raw, tools: tab == .tools)
            }
        }
        .onChange(of: tab) { _, t in
            if t == .raw, detail?.payloadsLoaded != true {
                reloadDetail(selectedID, raw: true, tools: false)
            } else if t == .tools, detail?.toolCalls.isEmpty == true {
                reloadDetail(selectedID, raw: false, tools: true)
            }
        }
        .onAppear {
            // Before anything else: a load whose completion block is still
            // queued may land during this appear pass, and a stale `mounted`
            // would drop a legitimate result.
            state.mounted = true
            // Re-assert the selection, not just fill an empty one: a record
            // publish deferred by `onReceive` can land after a previous
            // `onDisappear` and leave `selectedID` pointing at a row that is no
            // longer in `filtered` — the list renders no highlight and the
            // detail pane sits on its empty state until the user clicks a row.
            recomputeFiltered()
            if selectedID == nil || !filtered.contains(where: { $0.id == selectedID }) {
                selectedID = filtered.first?.id
            }
            selectedLive = currentSummary.flatMap { streams.live[$0.id] }
            rebuildConversation()
        }
        .onReceive(streams.$live) { values in
            let next = currentSummary.flatMap { values[$0.id] }
            guard next != selectedLive else { return }
            selectedLive = next
            rebuildConversation()
        }
        .onDisappear {
            state.mounted = false
            state.loadGen += 1
            state.detailWork?.cancel()
            state.fullWork?.cancel()
            state.clearConversation()
        }
        .onChange(of: filter) { _, _ in recomputeFiltered() }
        .onChange(of: query) { _, _ in recomputeFiltered() }
        .alert("清空全部抓包？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                ProxyCaptureStore.shared.clearAll()
                selectedID = nil
                detail = nil
                recomputeFiltered()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 \(catalog.records.count) 条记录及其请求 / 响应正文，无法恢复。")
                .rollingNumber()
        }
    }

    // MARK: - List

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s8) {
                SegmentedCapsule(items: TrafficFilter.allCases,
                                 selection: filter,
                                 title: { $0.label },
                                 tint: Theme.Ink.claude,
                                 onSelect: { filter = $0 })
                Spacer(minLength: 8)
                if !catalog.records.isEmpty {
                    Button("清空") { confirmClear = true }
                        .adaptiveGlassButton(tint: Theme.statusError, ink: Theme.Ink.error)
                }
            }
            .padding(.horizontal, Theme.Space.s12)
            .padding(.top, Theme.Space.s12)
            .padding(.bottom, Theme.Space.s8)

            InstrumentSearchField(prompt: "模型 / 供应商", text: queryBinding)
                .padding(.horizontal, Theme.Space.s12)
                .padding(.bottom, Theme.Space.s8)

            HairlineDivider()

            if filtered.isEmpty {
                StandbyEmptyState(label: "暂无记录",
                                  symbol: "arrow.left.arrow.right",
                                  tint: Theme.Ink.claude,
                                  caption: "在供应商上启用流量记录后，Claude Code 与 Codex 的请求将显示于此。",
                                  block: true)
                .padding(Theme.Space.s16)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filtered) { rec in
                            TrafficRow(
                                rec: rec,
                                preview: catalog.livePreview[rec.id],
                                selected: selectedID == rec.id,
                                onInterrupt: { interrupt($0) }
                            )
                            .onTapGesture { selectedID = rec.id }
                        }
                    }
                    .padding(.vertical, Theme.Space.s6)
                    .padding(.horizontal, Theme.Space.s8)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.bgSecondary)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let rec = currentSummary {
            VStack(alignment: .leading, spacing: 0) {
                inspectorHeader(rec)
                HairlineDivider()
                tabBar
                HairlineDivider()
                Group {
                    switch tab {
                    case .conversation: conversationPane(rec)
                    case .tools: toolsPane(rec)
                    case .raw: rawPane
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.bgPrimary)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s12) {
                Text("流量检查器")
                    .font(Theme.Font.titleSmall)
                    .foregroundColor(Theme.textPrimary)
                Text("在供应商上启用流量记录后，Claude Code 的 Anthropic 请求与 Codex 的 OpenAI 请求将显示在左侧。流式响应会随接收进度展示推理与正文。")
                    .font(Theme.Font.bodySmall)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Anthropic  ·  /v1/messages")
                    Text("OpenAI     ·  Chat / Responses")
                }
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textTertiary())
                Spacer()
            }
            .padding(Theme.Space.s24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func inspectorHeader(_ rec: CaptureSummary) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(rec.model.isEmpty ? rec.kind.label : rec.model)
                    .font(Theme.Font.titleSmall)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                protocolBadge(rec.kind)
                Text(rec.source.label)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
                Spacer()
                Text(rec.state.rawValue.uppercased())
                    .font(Theme.Font.badgeMono)
                    .foregroundColor(stateColor(rec.state))
                if rec.isLive {
                    ActionChip(systemImage: "stop.fill", tint: Theme.statusError,
                               help: "中断这次对话：断开客户端连接并停止上游请求") {
                        interrupt(rec)
                    }
                }
            }
            HStack(spacing: Theme.Space.s16) {
                compactStat("耗时", duration(rec))
                compactStat("首字", firstToken(rec))
                compactStat("HTTP", rec.httpStatus == 0 ? "—" : "\(rec.httpStatus)")
                compactStat("输入", rec.promptTokens.map(UsageStats.formatTokens) ?? "—")
                compactStat("输出", rec.completionTokens.map(UsageStats.formatTokens) ?? "—")
                // 命中 / 写入, not one lumped 缓存: they are separate buckets at
                // separate prices, and 输入 above excludes both.
                compactStat("命中", rec.cacheReadTokens.map(UsageStats.formatTokens) ?? "—")
                if let written = rec.cacheWriteTokens {
                    compactStat("写入", UsageStats.formatTokens(written))
                }
                Spacer(minLength: 0)
            }
            if let err = rec.error, rec.state == .error || rec.state == .aborted {
                Text(err)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.Ink.error)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, Theme.Space.s16)
        .padding(.vertical, Theme.Space.s12)
    }

    private var tabBar: some View {
        HStack(spacing: Theme.Space.s4) {
            SegmentedCapsule(items: TrafficTab.allCases,
                             selection: tab,
                             title: { $0.label },
                             tint: Theme.Ink.claude,
                             onSelect: { tab = $0 })
            Spacer()
            if tab == .conversation {
                SegmentedCapsule(items: [false, true],
                                 selection: fullRender,
                                 title: { $0 ? "完整" : "简洁" },
                                 tint: Theme.Ink.claude,
                                 onSelect: { fullRender = $0 })
                .help("简洁：去掉 system / 脚手架。完整：按请求体顺序渲染全部消息、图片与请求头。")
            }
            Text(currentSummary.map { "\($0.providerName)  \($0.path)" } ?? "")
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textTertiary())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Theme.Space.s16)
    }

    private func conversationPane(_ rec: CaptureSummary) -> some View {
        let streaming = rec.state == .streaming || rec.state == .pending
        let blocks = displayBlocks
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s8) {
                Image(systemName: "magnifyingglass")
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
                TextField("搜索对话、工具、系统提示", text: conversationQueryBinding)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.bodySmall)
                if !conversationQuery.isEmpty {
                    Button {
                        conversationQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(Theme.Font.caption)
                            .foregroundColor(Theme.textTertiary())
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .instrumentWell(radius: Theme.Radius.md, onCard: true)
            .padding(.horizontal, Theme.Space.s16)
            .padding(.vertical, Theme.Space.s8)
            HairlineDivider()
            if loadingDetail && displayBlocks.isEmpty && !streaming {
                ProgressView("解析对话…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.s8) {
                        if detail?.requestTruncated == true {
                            Text("请求体超过 \(CaptureMedia.payloadCapLabel) 已截断。完整渲染可能不完整。")
                                .font(Theme.Font.caption)
                                .foregroundColor(Theme.Ink.warning)
                        }
                        if fullRender, let headers = detail?.requestHeadersJSON, !headers.isEmpty {
                            requestHeadersSection(headers)
                        }
                        if blocks.isEmpty {
                            Text(conversationQuery.isEmpty
                                 ? (fullRender ? "无法解析这条请求的正文。" : "这条请求没有可展示的对话正文。")
                                 : "没有匹配「\(conversationQuery)」的内容。")
                                .font(Theme.Font.bodySmall)
                                .foregroundColor(Theme.textTertiary())
                                .padding(.top, Theme.Space.s8)
                        }
                        ForEach(blocks) { block in
                            conversationBlock(
                                block,
                                historyCount: historyCount,
                                streaming: streaming)
                        }
                    }
                    .padding(Theme.Space.s16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func requestHeadersSection(_ json: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Text("请求头")
                .font(Theme.Font.microSemibold)
                .foregroundColor(Theme.textSecondary)
            Text(json)
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textPrimary.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }

    @ViewBuilder
    private func conversationBlock(_ block: ConvBlock, historyCount: Int, streaming: Bool) -> some View {
        switch block {
        case .single(let i, let turn):
            bubble(
                role: turn.role,
                text: turn.text,
                dim: turn.role == "thinking" || turn.role == "tool",
                live: streaming && i >= historyCount,
                name: turn.name,
                images: turn.images)
        case .group(let id, let title, let subtitle, let items):
            let open = expandedBlocks.contains(id)
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                Button {
                    if open { expandedBlocks.remove(id) } else { expandedBlocks.insert(id) }
                } label: {
                    HStack(spacing: Theme.Space.s8) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(Theme.Font.caption)
                            .foregroundColor(Theme.textTertiary())
                            .frame(width: 10)
                        Text(title)
                            .font(Theme.Font.microSemibold)
                            .foregroundColor(Theme.textSecondary)
                        Text(subtitle)
                            .rollingNumber()
                            .font(Theme.Font.caption)
                            .foregroundColor(Theme.textTertiary())
                            .lineLimit(1)
                        Spacer()
                        Text(open ? "收起" : "展开")
                            .font(Theme.Font.micro)
                            .foregroundColor(Theme.textTertiary())
                    }
                    .padding(Theme.Space.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.cardFill(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    ForEach(items, id: \.offset) { i, turn in
                        bubble(
                            role: turn.role,
                            text: turn.text,
                            dim: turn.role == "thinking" || turn.role == "tool",
                            live: streaming && i >= historyCount,
                            name: turn.name,
                            images: turn.images)
                    }
                }
            }
        }
    }


    private func toolsPane(_ rec: CaptureSummary) -> some View {
        let calls = CaptureTranscript.mergingLive(
            detail?.toolCalls ?? [],
            live: selectedLive?.tools ?? [])
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s8) {
                if calls.isEmpty {
                    Text("没有工具调用。")
                        .font(Theme.Font.bodySmall)
                        .foregroundColor(Theme.textTertiary())
                }
                ForEach(calls) { t in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t.name.isEmpty ? t.id : t.name)
                            .font(Theme.Font.microMono)
                            .foregroundColor(Theme.Ink.cursor)
                        if !t.arguments.isEmpty {
                            Text(t.arguments)
                                .font(Theme.Font.captionMono)
                                .foregroundColor(Theme.textSecondary)
                                .textSelection(.enabled)
                        }
                        if !t.output.isEmpty {
                            Text(t.output)
                                .font(Theme.Font.captionMono)
                                .foregroundColor(Theme.textPrimary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(Theme.Space.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.cardFill(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                }
            }
            .padding(Theme.Space.s16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rawPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s8) {
                // Four panes of one record — the app's segmented control.
                SegmentedCapsule(items: RawSlice.allCases,
                                 selection: rawSlice,
                                 title: { $0.label },
                                 tint: Theme.Ink.claude,
                                 onSelect: { rawSlice = $0 })
                    .fixedSize()
                Spacer()
                rawToolButton("展开") { jsonFold.expandAll() }
                rawToolButton("收起") { jsonFold.collapseAll() }
                rawToolButton(rawCopied ? "已复制" : "复制") { copyRawJSON() }
            }
            .padding(.horizontal, Theme.Space.s16)
            .padding(.vertical, Theme.Space.s8)
            JSONTreeView(
                source: rawSource ?? "",
                empty: rawEmpty,
                parseID: "\(selectedID ?? 0)-\(rawSlice.rawValue)-\(rawSource?.count ?? 0)",
                fold: jsonFold)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: rawSlice) { _, _ in rawCopied = false }
        .onChange(of: selectedID) { _, _ in rawCopied = false }
    }

    private func rawToolButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(Theme.Font.caption)
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.cardFill(0.06), in: Capsule())
            .buttonStyle(.plain)
    }

    private func copyRawJSON() {
        let src = rawSource ?? ""
        guard !src.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(JSONTree.pretty(src), forType: .string)
        rawCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { rawCopied = false }
    }

    private var rawSource: String? {
        guard let detail else { return nil }
        switch rawSlice {
        case .request: return detail.requestJSON
        case .rewritten: return detail.rewrittenJSON
        case .response: return detail.responseJSON
        case .sse: return detail.rawSSE
        }
    }

    private var rawEmpty: String {
        switch rawSlice {
        case .rewritten: return "此请求未经改写：Anthropic 原样转发，或未启用 Chat 桥接。"
        case .sse: return "非流式请求，或尚未结束。"
        default: return "空"
        }
    }

    private func bubble(role: String, text: String, dim: Bool, live: Bool = false, name: String = "",
                        images: [CaptureMedia.EmbeddedImage] = []) -> some View {
        let title = name.isEmpty ? roleLabel(role) : "\(roleLabel(role)) · \(name)"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(Theme.Font.microSemibold)
                    .foregroundColor(roleColor(role))
                if live {
                    Text("实时")
                        .font(Theme.Font.badgeMono)
                        .foregroundColor(Theme.Ink.claude)
                }
            }
            ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                CaptureThumb(image: img)
            }
            if !text.isEmpty {
                if text.count > 8_000 {
                    let lines = max(16, text.split(separator: "\n", omittingEmptySubsequences: false).count)
                    let height = min(CGFloat(lines) * 15 + 28, 4_000)
                    PlainDumpView(text: text)
                        .frame(height: height)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(text)
                        .font(Theme.Font.bodySmall)
                        .foregroundColor(dim ? Theme.textSecondary : Theme.textPrimary)
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(Theme.Space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(roleColor(role).opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }

    private func compactStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary())
            RollingNumberText(value)
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func protocolBadge(_ kind: CaptureKind) -> some View {
        Text(kind.label)
            .font(Theme.Font.badgeMono)
            .foregroundColor(kind == .anthropic ? Theme.Ink.claude : Theme.Ink.codex)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill((kind == .anthropic ? Theme.claude : Theme.codex).opacity(0.15)))
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "user": return "用户"
        case "assistant": return "助手"
        case "system": return "系统"
        case "developer": return "开发者"
        case "thinking": return "思考"
        case "tools": return "工具声明"
        case "tool", "function": return "工具"
        case "block": return "块"
        case "response": return "响应"
        case "request": return "请求"
        default: return role
        }
    }

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "user": return Theme.claude
        case "assistant": return Theme.external
        case "system", "developer", "tools": return Theme.textSecondary
        case "thinking": return Theme.statusWarning
        case "tool", "function", "block": return Theme.cursor
        case "response": return Theme.external
        default: return Theme.textSecondary
        }
    }

    private func stateColor(_ state: CaptureState) -> Color {
        switch state {
        case .streaming, .pending: return Theme.claudeHi
        case .done: return Theme.external
        case .error: return Theme.statusError
        case .aborted: return Theme.statusWarning
        }
    }

    /// Hard-stop one in-flight call from the traffic page. No-op once the call
    /// has finished (the registry entry is retired in `CaptureTap.finish`).
    private func interrupt(_ rec: CaptureSummary) {
        ProxyInflight.shared.cancel(captureID: rec.id)
    }

    private func rebuildFullTurns() {
        let raw = detail?.requestJSON
        guard detail?.payloadsLoaded == true, raw != nil else {
            reloadDetail(selectedID, raw: true, tools: false)
            return
        }
        let id = selectedID
        let generation = state.loadGen
        let dir = id.map { CaptureMedia.mediaDir(captureID: $0) }
        state.fullWork?.cancel()
        let work = DispatchWorkItem {
            let turns = CaptureTranscript.turns(from: raw, mode: .full, mediaDir: dir)
            DispatchQueue.main.async {
                guard id == selectedID, generation == state.loadGen,
                      state.mounted, fullRender else { return }
                fullTurns = turns
                rebuildConversation()
            }
        }
        state.fullWork = work
        state.detailQueue.async(execute: work)
    }

    private func rebuildConversation() {
        guard let rec = currentSummary else {
            state.clearConversation()
            return
        }
        let matchingDetail = detail?.summary.id == rec.id ? detail : nil
        state.requestConversation(ConversationInput(
            id: rec.id, history: fullRender ? fullTurns : (matchingDetail?.turns ?? []),
            live: selectedLive, response: fullRender ? matchingDetail?.responseJSON : nil,
            headers: fullRender ? matchingDetail?.requestHeadersJSON : nil,
            full: fullRender, streaming: rec.isLive, query: conversationQuery))
    }

    private func reloadDetail(_ id: Int64?, raw: Bool, tools: Bool) {
        state.loadGen += 1
        state.detailWork?.cancel()
        state.fullWork?.cancel()
        guard let id else {
            detail = nil
            displayBlocks = []
            loadingDetail = false
            return
        }
        let gen = state.loadGen
        loadingDetail = displayBlocks.isEmpty
        let work = DispatchWorkItem {
            let d = ProxyCaptureStore.shared.detail(
                id: id, includeRaw: raw, includePayloads: raw, includeTools: tools)
            DispatchQueue.main.async {
                guard gen == state.loadGen else { return }
                detail = d
                loadingDetail = false
                if fullRender { rebuildFullTurns() }
                else { rebuildConversation() }
            }
        }
        state.detailWork = work
        state.detailQueue.async(execute: work)
    }

    private func duration(_ rec: CaptureSummary) -> String {
        let end = rec.endedAt ?? Date()
        let s = end.timeIntervalSince(rec.startedAt)
        if s < 1 { return String(format: "%.0f ms", s * 1000) }
        return String(format: "%.1f s", s)
    }

    private func firstToken(_ rec: CaptureSummary) -> String {
        guard let t = rec.firstTokenAt else { return "—" }
        let s = t.timeIntervalSince(rec.startedAt)
        if s < 1 { return String(format: "%.0f ms", s * 1000) }
        return String(format: "%.1f s", s)
    }
}

private struct CaptureThumb: View {
    let image: CaptureMedia.EmbeddedImage
    @State private var ns: NSImage?

    var body: some View {
        Group {
            if let ns {
                Image(nsImage: ns)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 480, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.cardFill(0.08))
                    .frame(maxWidth: 240, maxHeight: 120)
                    .overlay {
                        ProgressView().controlSize(.small)
                    }
            }
        }
        .task(id: image.fileURL?.path ?? "\(image.data?.count ?? 0)") {
            let src = image
            ns = await Task.detached(priority: .utility) {
                CaptureMedia.nsImage(from: src)
            }.value
        }
    }
}

/// One rendered conversation row. Internal (not private) because
/// `TrafficPageState` caches the built list across the view's unmount.
enum ConvBlock: Identifiable {
    case single(index: Int, turn: CaptureTranscript.Turn)
    case group(id: String, title: String, subtitle: String,
               items: [(offset: Int, turn: CaptureTranscript.Turn)])

    var id: String {
        switch self {
        case .single(let i, _): return "s-\(i)"
        case .group(let id, _, _, _): return id
        }
    }
}

private struct TrafficRow: View {
    let rec: CaptureSummary
    let preview: String?
    let selected: Bool
    let onInterrupt: (CaptureSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                sourceChip
                Text(rec.model.isEmpty ? rec.kind.label : rec.model)
                    .font(Theme.Font.bodySmall)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if rec.state == .streaming || rec.state == .pending {
                    Text("实时")
                        .font(Theme.Font.badgeMono)
                        .foregroundColor(Theme.Ink.claude)
                    // The row itself is a tap target for selection, so the chip
                    // sits above it and swallows its own clicks.
                    ActionChip(systemImage: "stop.fill", tint: Theme.statusError,
                               help: "中断这次对话：断开客户端连接并停止上游请求") {
                        onInterrupt(rec)
                    }
                }
                Text(ProxyAccessLog.clockShort.string(from: rec.startedAt))
                    .font(Theme.Font.captionMono)
                    .foregroundColor(Theme.textTertiary())
            }
            Text(preview ?? rec.preview)
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(rec.kind.label)
                Text(rec.isStream ? "stream" : "json")
                if let p = rec.promptTokens, let c = rec.completionTokens {
                    Text("\(p)/\(c)").rollingNumber()
                }
            }
            .font(Theme.Font.captionMono)
            .foregroundColor(Theme.textTertiary())
        }
        .padding(Theme.Space.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectionTint(selected, color: rec.kind == .anthropic ? Theme.claude : Theme.codex, corner: 6)
        .contentShape(Rectangle())
    }

    private var sourceChip: some View {
        let color: Color = {
            switch rec.source {
            case .claude: return Theme.claude
            case .codex: return Theme.codex
            case .other: return Theme.cursor
            }
        }()
        return Text(rec.source.shortLabel)
            .font(Theme.Font.badgeMono)
            .foregroundColor(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
    }

    private var dot: Color {
        switch rec.state {
        case .streaming, .pending: return Theme.claudeHi
        case .done: return Theme.external
        case .error: return Theme.statusError
        case .aborted: return Theme.statusWarning
        }
    }
}

/// Immutable inputs isolate parsing/filtering from SwiftUI body evaluation.
struct ConversationInput: Equatable {
    let id: Int64
    let history: [CaptureTranscript.Turn]
    let live: CaptureLive?
    let response: String?
    let headers: String?
    let full: Bool
    let streaming: Bool
    let query: String
}

enum ConversationBuilder {
    static func build(_ input: ConversationInput) -> [ConvBlock] {
        let reply = (input.streaming || input.full) ? CaptureTranscript.replyTurns(
            responseJSON: input.response, live: input.live, streaming: input.streaming,
            mode: input.full ? .full : .conversation) : []
        let turns = (input.history + reply).enumerated().map { ($0.offset, $0.element) }
        let q = input.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let headersMatch = input.full && input.headers?.lowercased().contains(q) == true
        let visible = q.isEmpty ? turns : turns.filter { _, turn in
            headersMatch || turn.text.lowercased().contains(q)
                || turn.name.lowercased().contains(q) || turn.role.lowercased().contains(q)
                || roleLabel(turn.role).contains(q)
                || (isSystemRole(turn.role) && "系统提示".contains(q))
                || (turn.role == "tool" && "工具调用".contains(q))
        }
        return !input.full && q.isEmpty ? groupedBlocks(visible)
            : visible.map { .single(index: $0.0, turn: $0.1) }
    }
    static func groupedBlocks(_ turns: [(Int, CaptureTranscript.Turn)]) -> [ConvBlock] {
        var out: [ConvBlock] = []
        var i = 0
        while i < turns.count {
            let (idx, turn) = turns[i]
            if Self.isSystemRole(turn.role) {
                var items: [(offset: Int, turn: CaptureTranscript.Turn)] = [(idx, turn)]
                i += 1
                while i < turns.count, Self.isSystemRole(turns[i].1.role) {
                    items.append((turns[i].0, turns[i].1))
                    i += 1
                }
                let chars = items.reduce(0) { $0 + $1.turn.text.count }
                out.append(.group(
                    id: "sys-\(idx)",
                    title: "系统提示",
                    subtitle: items.count > 1 ? "\(items.count) 段 · \(Self.formatCount(chars))" : Self.formatCount(chars),
                    items: items))
            } else if turn.role == "tool" {
                var items: [(offset: Int, turn: CaptureTranscript.Turn)] = [(idx, turn)]
                i += 1
                while i < turns.count, turns[i].1.role == "tool" {
                    items.append((turns[i].0, turns[i].1))
                    i += 1
                }
                if items.count == 1 {
                    out.append(.single(index: idx, turn: turn))
                } else {
                    let names = items.map { $0.turn.name }.filter { !$0.isEmpty }
                    let preview = names.isEmpty ? "\(items.count) 次" : names.prefix(4).joined(separator: " · ")
                    out.append(.group(
                        id: "tool-\(idx)",
                        title: "工具调用",
                        subtitle: "\(items.count) · \(preview)",
                        items: items))
                }
            } else {
                out.append(.single(index: idx, turn: turn))
                i += 1
            }
        }
        return out
    }

    static func isSystemRole(_ role: String) -> Bool {
        role == "system" || role == "developer" || role == "tools"
    }

    static func formatCount(_ n: Int) -> String {
        if n >= 10_000 { return String(format: "%.1f 万字", Double(n) / 10_000) }
        return "\(n) 字"
    }

    static func roleLabel(_ role: String) -> String {
        switch role {
        case "user": return "用户"
        case "assistant": return "助手"
        case "system": return "系统"
        case "developer": return "开发者"
        case "thinking": return "思考"
        case "tools": return "工具声明"
        case "tool", "function": return "工具"
        case "block": return "块"
        case "response": return "响应"
        case "request": return "请求"
        default: return role
        }
    }

}
