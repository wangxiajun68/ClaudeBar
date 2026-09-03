import AppKit
import SwiftUI

/// Live proxy capture inspector: request list + conversation that fills the pane.
struct TrafficView: View {
    @ObservedObject private var catalog = ProxyCaptureStore.shared.catalog
    @ObservedObject private var streams = ProxyCaptureStore.shared.streams
    @EnvironmentObject var codexStore: CodexProviderStore
    @State private var selectedID: Int64?
    @State private var filter: TrafficFilter = .all
    @State private var query = ""
    @State private var detail: CaptureDetail?
    @State private var tab: TrafficTab = .conversation
    @State private var rawSlice: RawSlice = .request
    @StateObject private var jsonFold = JSONFoldControl()
    @State private var rawCopied = false
    @State private var mode: TrafficMode = .inspector

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

    private var filtered: [CaptureSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return catalog.records.filter { rec in
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

    private var currentSummary: CaptureSummary? {
        catalog.records.first(where: { $0.id == selectedID }) ?? filtered.first
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
        .background(Theme.base0.opacity(0.35))
    }

    private var modeBar: some View {
        HStack(spacing: Theme.Space.s8) {
            Text("流量")
                .font(Theme.Font.titleSmall)
                .foregroundColor(Theme.textPrimary)
            HStack(spacing: Theme.Space.s4) {
                ForEach(TrafficMode.allCases) { m in
                    let on = mode == m
                    Button(m.label) { mode = m }
                        .font(Theme.Font.caption)
                        .foregroundColor(on ? .white : Theme.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(on ? Theme.claude.opacity(0.35) : Theme.cardFill(0.06)))
                        .buttonStyle(.plain)
                }
            }
            Spacer()
            Circle()
                .fill(codexStore.proxyRunning ? Theme.external : Theme.statusIdle)
                .frame(width: 6, height: 6)
            Text(codexStore.proxyRunning ? "代理已启用" : "代理未启用")
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textSecondary)
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
        .background(Theme.base0.opacity(0.35))
        .onChange(of: selectedID) { _, id in
            tab = .conversation
            reloadDetail(id, raw: false)
        }
        .onChange(of: catalog.records.count) { _, _ in
            if selectedID == nil { selectedID = filtered.first?.id }
        }
        .onChange(of: currentSummary?.state) { _, state in
            if state == .done || state == .error || state == .aborted {
                reloadDetail(selectedID, raw: tab == .raw)
            }
        }
        .onChange(of: tab) { _, t in
            if t == .raw { reloadDetail(selectedID, raw: true) }
        }
        .onAppear {
            if selectedID == nil { selectedID = filtered.first?.id }
        }
    }

    // MARK: - List

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s4) {
                ForEach(TrafficFilter.allCases) { f in
                    let on = filter == f
                    Button(f.label) { filter = f }
                        .font(Theme.Font.caption)
                        .foregroundColor(on ? .white : Theme.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(on ? Theme.claude.opacity(0.35) : Theme.cardFill(0.06)))
                        .buttonStyle(.plain)
                }
                Spacer()
                if !catalog.records.isEmpty {
                    Button("清空") {
                        ProxyCaptureStore.shared.clearAll()
                        selectedID = nil
                        detail = nil
                    }
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.statusError)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.s12)
            .padding(.top, Theme.Space.s12)
            .padding(.bottom, Theme.Space.s8)

            TextField("模型 / 供应商", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Font.bodySmall)
                .padding(.horizontal, Theme.Space.s12)
                .padding(.bottom, Theme.Space.s8)

            HairlineDivider()

            if filtered.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s8) {
                    Text("暂无记录")
                        .font(Theme.Font.body)
                        .foregroundColor(Theme.textSecondary)
                    Text("在供应商上启用流量记录后，Claude Code 与 Codex 的请求将显示于此。")
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.textTertiary())
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.s16)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filtered) { rec in
                            TrafficRow(
                                rec: rec,
                                preview: catalog.livePreview[rec.id],
                                selected: selectedID == rec.id
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
        .background(Theme.base1.opacity(0.35))
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
            .background(Theme.base0.opacity(0.2))
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
            }
            HStack(spacing: Theme.Space.s16) {
                compactStat("耗时", duration(rec))
                compactStat("首字", firstToken(rec))
                compactStat("HTTP", rec.httpStatus == 0 ? "—" : "\(rec.httpStatus)")
                compactStat("输入", rec.promptTokens.map(UsageStats.formatTokens) ?? "—")
                compactStat("输出", rec.completionTokens.map(UsageStats.formatTokens) ?? "—")
                compactStat("缓存", rec.cacheReadTokens.map(UsageStats.formatTokens) ?? "—")
                Spacer(minLength: 0)
            }
            if let err = rec.error, rec.state == .error || rec.state == .aborted {
                Text(err)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.statusError)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, Theme.Space.s16)
        .padding(.vertical, Theme.Space.s12)
    }

    private var tabBar: some View {
        HStack(spacing: Theme.Space.s4) {
            ForEach(TrafficTab.allCases) { t in
                let on = tab == t
                Button(t.label) { tab = t }
                    .font(Theme.Font.bodySmall)
                    .foregroundColor(on ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .overlay(alignment: .bottom) {
                        Capsule().fill(on ? Theme.claude : Color.clear).frame(height: 2)
                    }
                    .buttonStyle(.plain)
            }
            Spacer()
            Text(currentSummary.map { "\($0.providerName)  \($0.path)" } ?? "")
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textTertiary())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Theme.Space.s16)
    }

    private func conversationPane(_ rec: CaptureSummary) -> some View {
        let live = streams.live[rec.id]
        let history = detail?.turns ?? []
        let streaming = rec.state == .streaming || rec.state == .pending
        let reply = CaptureTranscript.replyTurns(
            responseJSON: detail?.responseJSON,
            live: live,
            streaming: streaming)
        let turns = history + reply
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s8) {
                if turns.isEmpty {
                    Text("这条请求没有可展示的对话正文。")
                        .font(Theme.Font.bodySmall)
                        .foregroundColor(Theme.textTertiary())
                        .padding(.top, Theme.Space.s8)
                }
                ForEach(Array(turns.enumerated()), id: \.offset) { i, turn in
                    bubble(
                        role: turn.role,
                        text: turn.text,
                        dim: turn.role == "thinking" || turn.role == "tool",
                        live: streaming && i >= history.count,
                        name: turn.name)
                }
            }
            .padding(Theme.Space.s16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toolsPane(_ rec: CaptureSummary) -> some View {
        let calls = CaptureTranscript.mergingLive(
            detail?.toolCalls ?? [],
            live: streams.live[rec.id]?.tools ?? [])
        let declared = CaptureTranscript.declaredToolCount(from: detail?.requestJSON)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s8) {
                if calls.isEmpty {
                    Text(declared > 0
                         ? "没有工具调用。请求里声明了 \(declared) 个工具。"
                         : "没有工具调用。")
                        .font(Theme.Font.bodySmall)
                        .foregroundColor(Theme.textTertiary())
                }
                ForEach(calls) { t in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t.name.isEmpty ? t.id : t.name)
                            .font(Theme.Font.microMono)
                            .foregroundColor(Theme.cursor)
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
                    .background(Theme.cardFill(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                }
            }
            .padding(Theme.Space.s16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rawPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s8) {
                Picker("", selection: $rawSlice) {
                    ForEach(RawSlice.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
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

    private func bubble(role: String, text: String, dim: Bool, live: Bool = false, name: String = "") -> some View {
        let title = name.isEmpty ? roleLabel(role) : "\(roleLabel(role)) · \(name)"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(Theme.Font.microSemibold)
                    .foregroundColor(roleColor(role))
                if live {
                    Text("实时")
                        .font(Theme.Font.badgeMono)
                        .foregroundColor(Theme.claudeHi)
                }
            }
            if text.count > 6_000 {
                PlainDumpView(text: text)
                    .frame(minHeight: 180, maxHeight: 360)
                    .frame(maxWidth: .infinity)
            } else if text.count < 4_000 {
                Text(text)
                    .font(Theme.Font.bodySmall)
                    .foregroundColor(dim ? Theme.textSecondary : Theme.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(text)
                    .font(Theme.Font.bodySmall)
                    .foregroundColor(dim ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Theme.Space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(roleColor(role).opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func compactStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary())
            Text(value)
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func protocolBadge(_ kind: CaptureKind) -> some View {
        Text(kind.label)
            .font(Theme.Font.badgeMono)
            .foregroundColor(kind == .anthropic ? Theme.claude : Theme.codex)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill((kind == .anthropic ? Theme.claude : Theme.codex).opacity(0.15)))
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "user": return "用户"
        case "assistant": return "助手"
        case "thinking": return "思考"
        case "tool", "function": return "工具"
        default: return role
        }
    }

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "user": return Theme.claude
        case "assistant": return Theme.external
        case "thinking": return Theme.statusWarning
        case "tool", "function": return Theme.cursor
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

    private func reloadDetail(_ id: Int64?, raw: Bool) {
        guard let id else { detail = nil; return }
        DispatchQueue.global(qos: .utility).async {
            let d = ProxyCaptureStore.shared.detail(id: id, includeRaw: raw)
            DispatchQueue.main.async { detail = d }
        }
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

private struct TrafficRow: View {
    let rec: CaptureSummary
    let preview: String?
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dot)
                    .frame(width: 6, height: 6)
                Text(rec.model.isEmpty ? rec.kind.label : rec.model)
                    .font(Theme.Font.bodySmall)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if rec.state == .streaming || rec.state == .pending {
                    Text("实时")
                        .font(Theme.Font.badgeMono)
                        .foregroundColor(Theme.claudeHi)
                }
                Text(rec.startedAt.formatted(date: .omitted, time: .shortened))
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
                    Text("\(p)/\(c)")
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

    private var dot: Color {
        switch rec.state {
        case .streaming, .pending: return Theme.claudeHi
        case .done: return Theme.external
        case .error: return Theme.statusError
        case .aborted: return Theme.statusWarning
        }
    }
}
