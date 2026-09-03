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

    enum Filter: String, CaseIterable, Identifiable {
        case all, claude, codex
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "全部"
            case .claude: return "Claude"
            case .codex: return "Codex"
            }
        }
    }

    private var filtered: [ProxyLogEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return log.entries.filter { row in
            switch filter {
            case .all: break
            case .claude: if row.source != .claude { return false }
            case .codex: if row.source != .codex { return false }
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
        .background(Theme.base0.opacity(0.35))
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Space.s8) {
            ForEach(Filter.allCases) { f in
                let on = filter == f
                Button(f.label) { filter = f }
                    .font(Theme.Font.caption)
                    .foregroundColor(on ? .white : Theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(on ? Theme.claude.opacity(0.35) : Theme.cardFill(0.06)))
                    .buttonStyle(.plain)
            }
            TextField("路径 / 模型 / 供应商", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Font.bodySmall)
                .frame(maxWidth: 240)
            Spacer()
            Text("\(filtered.count)")
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textTertiary())
                .monospacedDigit()
            if !log.entries.isEmpty {
                Button(copied ? "已复制" : "复制") { copyVisible() }
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textSecondary)
                    .buttonStyle(.plain)
                Button("清空") { log.clear() }
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.statusError)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.s16)
        .padding(.vertical, Theme.Space.s8)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Text("暂无请求日志")
                .font(Theme.Font.body)
                .foregroundColor(Theme.textSecondary)
            Text(codexStore.proxyRunning
                 ? "代理已启用。每次转发会在此留下一行（方法、路径、状态、耗时），不记录请求体或响应体。"
                 : "启用本地代理或供应商上的流量记录后，转发请求会显示在这里。")
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
                        Text(row.consoleLine)
                            .font(Theme.Font.console)
                            .foregroundColor(color(for: row))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.Space.s16)
                            .padding(.vertical, 3)
                            .background(row.id == filtered.last?.id && row.isPending
                                        ? Theme.cardFill(0.04) : Color.clear)
                            .id(row.id)
                    }
                }
                .padding(.vertical, Theme.Space.s8)
            }
            .onAppear { scrollToEnd(proxy) }
            .onChange(of: log.entries.last?.id) { _, _ in scrollToEnd(proxy) }
        }
    }

    private func color(for row: ProxyLogEntry) -> Color {
        if row.isPending { return Theme.textSecondary }
        if let err = row.error, !err.isEmpty { return Theme.statusError }
        if row.status >= 500 { return Theme.statusError }
        if row.status >= 400 { return Theme.statusWarning }
        return Theme.textPrimary
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = filtered.last else { return }
        DispatchQueue.main.async {
            withAnimation(Theme.Motion.page) {
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
