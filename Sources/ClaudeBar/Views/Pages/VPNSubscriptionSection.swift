import SwiftUI
import AppKit

/// Subscription URL manager: add / edit / copy, remaining traffic, expiry.
/// Mirrors clash-verge's profile extra (`subscription-userinfo`).
struct VpnSubscriptionSection: View {
    var onBrowse: () -> Void = {}
    @ObservedObject private var store = VpnSubscriptionStore.shared
    @ObservedObject private var manager = VpnManager.shared
    @ObservedObject private var prefs = AppPreferences.shared

    @State private var pendingDelete: VpnSubscription?
    @State private var editor: SubEditor?
    @State private var busyID: UUID?
    @State private var queryingAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: Theme.Space.s8) {
                HStack(spacing: 8) {
                    AppGlyph(name: "link", size: 16).foregroundColor(Theme.Ink.claude)
                    Text("订阅").font(Theme.Font.body)
                }
                Spacer(minLength: 0)
                Button { editor = .add } label: { AppGlyph(name: "plus", size: 14) }
                    .buttonStyle(.plain).help("添加订阅")
                Menu {
                    Button(queryingAll ? "查询中…" : "查询全部流量") {
                        Task {
                            queryingAll = true
                            await store.queryAll()
                            queryingAll = false
                        }
                    }
                    .disabled(store.subscriptions.isEmpty || queryingAll || busyID != nil)
                } label: { AppGlyph(name: "ellipsis", size: 14) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("订阅操作")
            }

            if let err = store.errorMessage {
                Text(err)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.Ink.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.subscriptions.isEmpty {
                Text("粘贴 Clash / clash-verge 订阅 URL。添加后可查询剩余流量与到期日。")
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
                    .padding(.vertical, Theme.Space.s8)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(store.subscriptions) { sub in
                        card(sub)
                        if sub.id != store.subscriptions.last?.id { HairlineDivider() }
                    }
                }
            }
        }
        .sheet(item: $editor) { item in
            VpnSubscriptionEditor(draft: item) { name, url in
                Task { await saveEditor(item, name: name, url: url) }
            }
        }
        .alert("删除订阅？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let sub = pendingDelete {
                    store.removeSubscription(sub.id)
                    if manager.isRunning { manager.reloadConfig() }
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { "将移除「\($0.name)」及其节点配置。" } ?? "")
        }
    }

    /// Reload the core onto `sub`. Card taps only browse; this button is the
    /// switch. Turning the module on here matches the main power control, so
    /// a stopped core still comes up with the system proxy.
    private func activate(_ sub: VpnSubscription) {
        guard busyID == nil else { return }
        store.browse(sub.id)
        guard sub.id != store.activeID || !manager.isRunning else { return }
        store.setActive(sub.id)
        if !manager.isRunning {
            prefs.vpnEnabled = true
            prefs.vpnSystemProxyEnabled = true
        }
        manager.reloadConfig()
    }

    private func card(_ sub: VpnSubscription) -> some View {
        let active = sub.id == store.activeID
        let browsing = (store.browsingID ?? store.activeID) == sub.id
        let busy = busyID == sub.id
        let runningHere = active && manager.isRunning
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { store.browse(sub.id); onBrowse() } label: {
                    HStack(spacing: 8) {
                        AppGlyph(name: runningHere ? "checkmark.circle.fill" : "link", size: 14)
                            .foregroundColor(runningHere ? Theme.Ink.claude : Theme.textSecondary)
                        Text(sub.name).font(Theme.Font.bodySmall)
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        if browsing && !active {
                            Text("查看中").font(Theme.Font.micro).foregroundColor(Theme.Ink.claude)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("查看节点 · 不切换运行配置")
                if busy { ProgressView().controlSize(.mini) }
                Menu {
                    Button("查看节点") { store.browse(sub.id); onBrowse() }
                    Button("更新节点配置") {
                        Task {
                            busyID = sub.id
                            if await store.refresh(sub.id), store.activeID == sub.id {
                                manager.reloadConfig()
                            }
                            busyID = nil
                        }
                    }
                    Button("查询流量与到期时间") {
                        Task {
                            busyID = sub.id
                            _ = await store.queryInfo(sub.id)
                            busyID = nil
                        }
                    }
                    Divider()
                    Button("复制订阅链接") { store.copyURL(sub.id) }
                    if let home = sub.homeURL, let url = URL(string: home) {
                        Button("打开机场主页") { NSWorkspace.shared.open(url) }
                    }
                    Button("编辑订阅") { editor = .edit(sub) }
                    Button("删除", role: .destructive) { pendingDelete = sub }
                } label: { AppGlyph(name: "ellipsis", size: 13) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(busyID != nil || queryingAll)
                .help("订阅详情与操作")
            }
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sub.total > 0 ? "剩余 " + VpnFormat.bytes(sub.remainingBytes) : "流量未查询")
                        .font(Theme.Font.captionMono).foregroundColor(Theme.textPrimary)
                    Text("\(sub.nodeCount) 节点 · \(expireText(sub))")
                        .font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if runningHere {
                    Text("运行中").font(Theme.Font.caption).foregroundColor(Theme.Ink.claude)
                } else {
                    ActionButton(active ? "启动" : "启用", tone: .neutral) { activate(sub) }
                        .disabled(busyID != nil || manager.state == .starting || queryingAll)
                        .help("切换并启用这份订阅")
                }
            }
            if sub.total > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.hairline)
                        Capsule().fill(Theme.claude.opacity(0.65))
                            .frame(width: geo.size.width * sub.usedRatio)
                    }
                }
                .frame(height: 2)
                .help("已用 " + VpnFormat.bytes(sub.usedBytes) + " / " + VpnFormat.bytes(sub.total))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 14)
        .background(browsing ? Theme.claude.opacity(0.045) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func expireText(_ sub: VpnSubscription) -> String {
        guard let expires = sub.expires else { return "未查询" }
        let date = Self.day.string(from: expires)
        // Compare dates, not the day count: Int truncates toward zero, so an
        // expiry a few hours ago would report 0 天 instead of 已过期.
        if expires < Date() { return "\(date) · 已过期" }
        return "\(date) · \(max(0, Int(expires.timeIntervalSinceNow / 86400))) 天"
    }

    private func saveEditor(_ item: SubEditor, name: String, url: String) async {
        switch item.kind {
        case .add:
            await store.addSubscription(name: name, url: url)
            if store.errorMessage == nil, manager.isRunning { manager.reloadConfig() }
        case .edit(let id):
            store.rename(id, name: name)
            let current = store.subscriptions.first { $0.id == id }?.url
            if current != url {
                busyID = id
                if await store.replaceURL(id, url: url), store.activeID == id, manager.isRunning {
                    manager.reloadConfig()
                }
                busyID = nil
            }
        }
        editor = nil
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

struct SubEditor: Identifiable {
    enum Kind { case add, edit(UUID) }
    var kind: Kind
    var name: String
    var url: String
    var id: String {
        switch kind {
        case .add: return "add"
        case .edit(let uuid): return uuid.uuidString
        }
    }

    static var add: SubEditor { SubEditor(kind: .add, name: "", url: "") }
    static func edit(_ sub: VpnSubscription) -> SubEditor {
        SubEditor(kind: .edit(sub.id), name: sub.name, url: sub.url)
    }
}

private struct VpnSubscriptionEditor: View {
    let draft: SubEditor
    var onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var url: String

    init(draft: SubEditor, onSave: @escaping (String, String) -> Void) {
        self.draft = draft
        self.onSave = onSave
        _name = State(initialValue: draft.name)
        _url = State(initialValue: draft.url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            Text(draft.kind.isAdd ? "添加订阅链接" : "编辑订阅")
                .font(Theme.Font.titleSmall)
                .foregroundColor(Theme.textPrimary)
            TextField("名称（可空，自动取机场文件名）", text: $name)
                .textFieldStyle(InstrumentFieldStyle(focused: false))
            TextField("订阅 URL", text: $url)
                .textFieldStyle(InstrumentFieldStyle(focused: false))
            Text("使用 clash-verge UA 拉取，从响应头读取剩余流量与到期日。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
            HStack {
                Spacer()
                ActionButton("取消") { dismiss() }
                ActionButton("保存", emphasis: .primary) {
                    onSave(name, url)
                    dismiss()
                }
                .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.Space.s16)
        .frame(width: 440)
    }
}

private extension SubEditor.Kind {
    var isAdd: Bool {
        if case .add = self { return true }
        return false
    }
}
