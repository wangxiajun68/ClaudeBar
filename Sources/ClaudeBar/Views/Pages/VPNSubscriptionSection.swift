import SwiftUI
import AppKit

/// The subscription page's write lock.
///
/// One operation at a time: an add, a whole-list query, or one subscription's
/// update — each downloads and may reload the core, and two overlapping ones
/// would write the same profile or restart the core twice. Two rules hold the
/// lock sound, and both used to be violated by three loose `@State` flags:
///
/// - **Every claim happens synchronously in the click that starts the work**,
///   not inside the `Task` that performs it — a task's closure begins after
///   the current event batch is dispatched, so a second click delivered in
///   the same batch would still see the old state and pass every guard.
/// - **A release only frees the lock if it still belongs to the releasing
///   operation.** A straggling completion must not clear a claim that a newer
///   click has already taken.
///
/// It is a value type rather than view state scattered across the section so
/// `Tests/vpn-subscription-reentry-regressions.py` can execute the real
/// policy without launching the app.
struct SubscriptionBusy: Equatable {
    enum Owner: Equatable {
        case add
        case queryAll
        case update(UUID)

        var updatingID: UUID? {
            if case .update(let id) = self { return id }
            return nil
        }
    }

    private(set) var owner: Owner?

    var isIdle: Bool { owner == nil }
    /// The subscription currently updating, for that card's spinner.
    var updatingID: UUID? { owner?.updatingID }
    /// An add has no subscription id yet, so its spinner cannot be scoped to
    /// one card — it shows on every card, as it always has.
    var isAdding: Bool { owner == .add }
    var isQueryingAll: Bool { owner == .queryAll }

    /// Take the lock for `next`; false when another operation holds it.
    mutating func claim(_ next: Owner) -> Bool {
        guard owner == nil else { return false }
        owner = next
        return true
    }

    /// Give the lock back, but only if this operation still holds it.
    mutating func release(_ held: Owner) {
        if owner == held { owner = nil }
    }
}

/// Subscription URL manager: add / edit / copy, remaining traffic, expiry.
/// Mirrors clash-verge's profile extra (`subscription-userinfo`).
struct VpnSubscriptionSection: View {
    var onBrowse: () -> Void = {}
    @ObservedObject private var store = VpnSubscriptionStore.shared
    @ObservedObject private var manager = VpnManager.shared
    @ObservedObject private var prefs = AppPreferences.shared

    @State private var pendingDelete: VpnSubscription?
    @State private var editor: SubEditor?
    @State private var busy = SubscriptionBusy()

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
                    .disabled(!busy.isIdle)
                Menu {
                    Button(busy.isQueryingAll ? "查询中…" : "查询全部流量") {
                        startBusy(.queryAll) { await store.queryAll() }
                    }
                    .disabled(store.subscriptions.isEmpty || !busy.isIdle)
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

            // A subscriptions.json that does not decode leaves the list empty
            // and, from the user's side, silently gone. Say so — and that the
            // file is untouched, because `save()` refuses while this is set.
            if store.loadFailed {
                Text("subscriptions.json 无法解析，已按只读处理（不会覆盖该文件）。修复或移走它后重启应用。")
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
                // Claimed here, synchronously in the click that dismisses the
                // sheet — not inside the Task below, which starts a main-actor
                // turn later. The page's re-entrancy guards read this lock.
                //
                // An edit whose URL is unchanged renames only and downloads
                // nothing; the claim it still takes is released in
                // `saveEditor`. `claim` failing means another operation owns
                // the page, and the save is refused rather than racing it.
                let owner: SubscriptionBusy.Owner
                switch item.kind {
                case .add: owner = .add
                case .edit(let id): owner = .update(id)
                }
                guard busy.claim(owner) else { return }
                Task { await saveEditor(item, name: name, url: url, owner: owner) }
            }
        }
        .alert("删除订阅？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                guard let sub = pendingDelete else { return }
                // Delete is a write like the others: it must not run while a
                // download could still write this subscription's profile, and
                // must not start a config reload over one already in flight.
                // The lock is the same one every path claims, so there is no
                // flag combination to keep in sync. The alert closes either
                // way.
                guard busy.isIdle, manager.state != .starting else { return }
                // Only deleting the *active* subscription changes what the
                // core is running — the generated config inlines the active
                // profile alone, so removing any other card used to restart
                // the kernel (stop → port release → relaunch, seconds of
                // 启动中) for a file the core never read. `removeSubscription`
                // reassigns `activeID` exactly when the removed id was active,
                // so the captured comparison is the same truth the reload
                // needs.
                let wasActive = sub.id == store.activeID
                store.removeSubscription(sub.id)
                if wasActive, manager.isRunning { manager.reloadConfig() }
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
    ///
    /// Refuses while any other write is in flight (`busy` — every claim is
    /// taken synchronously by the click that starts the work, so this sees a
    /// download that just began) and while a restart this very method already
    /// began is under way — that one is `manager.state`, set to `.starting`
    /// synchronously by `reloadConfig`. The busy lock alone could not see it:
    /// it is released as soon as the operation that started the restart
    /// returns. This is the page's most expensive effect (core stop → port
    /// release → relaunch, seconds of 启动中), so it refuses rather than
    /// races.
    private func activate(_ sub: VpnSubscription) {
        guard busy.isIdle, manager.state != .starting else { return }
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
        // The spinner is scoped to the card the operation names; an add has
        // no card yet, so it spins every row (the pre-refactor behaviour).
        let busyHere = busy.updatingID == sub.id || busy.isAdding
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
                if busyHere { ProgressView().controlSize(.mini) }
                Menu {
                    Button("查看节点") { store.browse(sub.id); onBrowse() }
                    Button("更新节点配置") {
                        startBusy(.update(sub.id)) {
                            if await store.refresh(sub.id), store.activeID == sub.id {
                                manager.reloadConfig()
                            }
                        }
                    }
                    Button("查询流量与到期时间") {
                        startBusy(.update(sub.id)) {
                            _ = await store.queryInfo(sub.id)
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
                .disabled(!busy.isIdle)
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
                        .disabled(!busy.isIdle || manager.state == .starting)
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

    /// The menu paths' entry point: claims the lock through `busy` (the
    /// caller has already checked `isIdle` via `.disabled`, but the claim is
    /// the authority — a second click in the same event batch finds the lock
    /// taken), then runs the download and releases it. The release names its
    /// owner, so a completion that lands after a newer claim cannot clear it.
    private func startBusy(_ owner: SubscriptionBusy.Owner, _ body: @escaping () async -> Void) {
        guard busy.claim(owner) else { return }
        Task {
            await body()
            busy.release(owner)
        }
    }

    private func saveEditor(_ item: SubEditor, name: String, url: String,
                            owner: SubscriptionBusy.Owner) async {
        defer { busy.release(owner) }
        switch item.kind {
        case .add:
            await store.addSubscription(name: name, url: url)
            if store.errorMessage == nil, manager.isRunning { manager.reloadConfig() }
        case .edit(let id):
            store.rename(id, name: name)
            let current = store.subscriptions.first { $0.id == id }?.url
            // replaceURL stores the trimmed value; compare the same trimmed
            // form so a padded-but-identical paste doesn't re-download the
            // profile and restart the active core for nothing.
            let next = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if current != next {
                if await store.replaceURL(id, url: next), store.activeID == id, manager.isRunning {
                    manager.reloadConfig()
                }
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
