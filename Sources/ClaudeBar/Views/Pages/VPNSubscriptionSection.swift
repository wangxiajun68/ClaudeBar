import SwiftUI
import AppKit

/// Subscription URL manager: add / edit / copy, remaining traffic, expiry.
/// Mirrors clash-verge's profile extra (`subscription-userinfo`).
struct VpnSubscriptionSection: View {
    @ObservedObject private var store = VpnSubscriptionStore.shared
    @ObservedObject private var manager = VpnManager.shared
    @ObservedObject private var prefs = AppPreferences.shared

    @State private var pendingDelete: VpnSubscription?
    @State private var editor: SubEditor?
    @State private var busyID: UUID?
    @State private var queryingAll = false
    @State private var copiedID: UUID?
    @State private var hoverID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: Theme.Space.s8) {
                SectionHeader(icon: "link", title: "订阅", tint: Theme.claude)
                Spacer(minLength: 0)
                Button {
                    Task {
                        queryingAll = true
                        await store.queryAll()
                        queryingAll = false
                    }
                } label: {
                    ZStack {
                        Text("查询流量")
                            .opacity(queryingAll ? 0 : 1)
                        if queryingAll {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .frame(width: 72, height: 22)
                }
                .adaptiveGlassButton()
                .disabled(store.subscriptions.isEmpty || queryingAll || busyID != nil)
                .help("向机场查询剩余流量与有效期（不替换节点配置）")
                Button("添加链接") { editor = .add }
                    .adaptiveGlassButton(prominent: true)
                    .tint(Theme.claude)
            }

            if let err = store.errorMessage {
                Text(err)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.statusError)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.subscriptions.isEmpty {
                Text("粘贴 Clash / clash-verge 订阅 URL。添加后可查询剩余流量与到期日。")
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
                    .padding(.vertical, Theme.Space.s8)
            } else {
                VStack(spacing: Theme.Space.s8) {
                    ForEach(store.subscriptions) { sub in
                        card(sub)
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

    /// Switch the running core to `sub`.
    ///
    /// Two things used to make this look broken:
    ///  - the tap target was the name label only, so clicks elsewhere on the
    ///    card did nothing;
    ///  - `reloadConfig()` bails out when the module toggle is off, which
    ///    silently defeats a switch that was otherwise accepted. Selecting a
    ///    subscription is an explicit "use this", so turn the module on first
    ///    when the core isn't running — same as flipping the main switch.
    private func activate(_ sub: VpnSubscription) {
        guard sub.id != store.activeID, busyID == nil else { return }
        store.setActive(sub.id)
        if !manager.isRunning {
            // Same as flipping the main switch: turn the module on and let it
            // take over the system proxy, otherwise the core would come up
            // with nothing routed through it.
            prefs.vpnEnabled = true
            prefs.vpnSystemProxyEnabled = true
        }
        manager.reloadConfig()
    }

    private func card(_ sub: VpnSubscription) -> some View {
        let active = sub.id == store.activeID
        let busy = busyID == sub.id
        let hovered = hoverID == sub.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Selection affordance rather than a button: the whole card is
                // the target (see the tap gesture below). A button scoped to
                // just the name meant clicks on the rest of the row — the URL,
                // the traffic line, the padding — silently did nothing, which
                // reads exactly like "the app won't switch subscriptions".
                Circle()
                    .fill(active ? Theme.claude : Theme.textTertiary().opacity(hovered ? 0.7 : 0.35))
                    .frame(width: 6, height: 6)
                    .frame(width: 10, height: 10)
                Text(sub.name)
                    .font(Theme.Font.bodySmall)
                    .foregroundColor(Theme.textPrimary)
                if active {
                    StatusPill(label: "使用中", tint: Theme.claude)
                } else if hovered {
                    Text("点击启用")
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                Text("\(sub.nodeCount) 节点")
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
            }

            trafficRow(sub)

            HStack(spacing: 6) {
                Text(sub.url)
                    .font(Theme.Font.captionMono)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                ActionChip(systemImage: copiedID == sub.id ? "checkmark" : "doc.on.doc",
                           tint: Theme.textSecondary, help: "复制订阅链接") {
                    store.copyURL(sub.id)
                    copiedID = sub.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if copiedID == sub.id { copiedID = nil }
                    }
                }
                if let home = sub.homeURL, let u = URL(string: home) {
                    ActionChip(systemImage: "safari", tint: Theme.textSecondary, help: "打开机场主页") {
                        NSWorkspace.shared.open(u)
                    }
                }
                ActionChip(systemImage: "pencil", tint: Theme.textSecondary, help: "编辑名称与链接") {
                    editor = .edit(sub)
                }
                ActionChip(systemImage: "info.circle", tint: Theme.textSecondary, help: "查询剩余流量与有效期") {
                    Task {
                        busyID = sub.id
                        _ = await store.queryInfo(sub.id)
                        busyID = nil
                    }
                }
                .disabled(busy || queryingAll)
                ActionChip(systemImage: "arrow.clockwise", tint: Theme.textSecondary, help: "更新节点配置") {
                    Task {
                        busyID = sub.id
                        if await store.refresh(sub.id), store.activeID == sub.id {
                            manager.reloadConfig()
                        }
                        busyID = nil
                    }
                }
                .disabled(busy || queryingAll)
                .opacity(busy ? 0.5 : 1)
                ActionChip(systemImage: "trash", tint: Theme.statusError, help: "删除") {
                    pendingDelete = sub
                }
            }
        }
        .padding(Theme.Space.s12)
        .tile(tint: active ? Theme.claude : nil, hovered: hovered)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoverID = sub.id }
            else if hoverID == sub.id { hoverID = nil }
        }
        .onTapGesture { activate(sub) }
        .help(active ? "当前使用的订阅" : "点击切换到「\(sub.name)」")
        .opacity(busy ? 0.85 : 1)
    }

    private func trafficRow(_ sub: VpnSubscription) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.s12) {
                labeled("剩余", sub.total > 0 ? VpnFormat.bytes(sub.remainingBytes) : "未查询")
                labeled("已用", sub.total > 0
                        ? "\(VpnFormat.bytes(sub.usedBytes)) / \(VpnFormat.bytes(sub.total))"
                        : "—")
                labeled("有效期", expireText(sub))
                if let updated = sub.lastUpdated {
                    labeled("查询于", Self.stamp.string(from: updated))
                }
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.textTertiary().opacity(0.18))
                    Capsule()
                        .fill(barColor(sub.usedRatio))
                        .frame(width: max(4, geo.size.width * sub.usedRatio))
                }
            }
            .frame(height: 4)
            .opacity(sub.total > 0 ? 1 : 0.35)
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary())
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
        }
    }

    private func expireText(_ sub: VpnSubscription) -> String {
        guard let expires = sub.expires else { return "未查询" }
        let date = Self.day.string(from: expires)
        let days = Int(expires.timeIntervalSinceNow / 86400)
        if days < 0 { return "\(date) · 已过期" }
        return "\(date) · \(days) 天"
    }

    private func barColor(_ ratio: Double) -> Color {
        if ratio >= 0.9 { return Theme.statusError }
        if ratio >= 0.75 { return Theme.claudeHi }
        return Theme.external
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

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
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
                .textFieldStyle(.roundedBorder)
            TextField("订阅 URL", text: $url)
                .textFieldStyle(.roundedBorder)
            Text("使用 clash-verge UA 拉取，从响应头读取剩余流量与到期日。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .adaptiveGlassButton()
                Button("保存") {
                    onSave(name, url)
                    dismiss()
                }
                .adaptiveGlassButton(prominent: true)
                .tint(Theme.claude)
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
