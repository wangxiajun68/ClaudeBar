import Foundation
import Combine

struct FeishuDocument: Identifiable, Equatable, Sendable {
    let token: String
    let title: String
    let type: String
    let url: String
    let modified: String
    var hasChildren = false
    var underlyingToken = ""
    var underlyingType = ""
    var id: String { type + ":" + token }
    var isFolder: Bool { type == "folder" }
    var isDocument: Bool { type == "docx" || (type == "wiki" && (underlyingType.isEmpty || underlyingType == "docx")) }
    var documentReference: String {
        if type == "wiki", !underlyingToken.isEmpty { return underlyingToken }
        if type == "wiki", let webURL { return webURL.absoluteString }
        return token
    }
    var contentType: String { type == "wiki" ? (underlyingType.isEmpty ? "docx" : underlyingType) : type }
    var symbol: String {
        switch type {
        case "folder": return "folder.fill"
        case "wiki": return "books.vertical.fill"
        case "sheet": return "tablecells"
        case "bitable": return "square.grid.3x3"
        case "slides": return "rectangle.on.rectangle"
        default: return "doc.text.fill"
        }
    }
    static func parse(_ item: FeishuJSON) -> FeishuDocument? {
        let meta = item["result_meta"] != .null ? item["result_meta"] :
            (item["doc_meta"] != .null ? item["doc_meta"] : item["wiki_meta"])
        let url = item.first("url", "doc_url").isEmpty ? meta.first("url", "doc_url") : item.first("url", "doc_url")
        let link = URL(string: url)
        let token = item.first("node_token", "token", "doc_token", "file_token", "document_id")
        let metaToken = meta.first("doc_token", "node_token", "token")
        let resolved = !token.isEmpty ? token : (!metaToken.isEmpty ? metaToken : link?.lastPathComponent ?? "")
        guard !resolved.isEmpty else { return nil }
        var type = item.first("type", "doc_type", "obj_type").lowercased()
        if type.isEmpty { type = meta.first("doc_type", "doc_types", "type").lowercased() }
        if type.isEmpty { type = meta["doc_types"].items.first?.text.lowercased() ?? "" }
        if !item["node_token"].text.isEmpty || item["wiki_meta"] != .null || link?.pathComponents.contains("wiki") == true { type = "wiki" }
        if type == "sheets" { type = "sheet" }
        if type == "base" { type = "bitable" }
        let title = item.first("name", "title", "title_highlighted")
        let cleanTitle = title.replacingOccurrences(of: "</?h[b]?>", with: "", options: .regularExpression)
        let modified = item.first("modified_time", "edit_time_iso", "edit_time", "obj_edit_time")
        return FeishuDocument(token: resolved,
            title: cleanTitle.isEmpty ? meta.first("title", "name") : cleanTitle,
            type: type.isEmpty ? "file" : type, url: url,
            modified: modified.isEmpty ? meta.first("update_time_iso", "update_time") : modified,
            hasChildren: item["has_child"].flag,
            underlyingToken: item["obj_token"].text,
            underlyingType: item["obj_type"].text.lowercased())
    }
    /// Only official HTTPS links may leave the app; no CLI-supplied custom schemes.
    var webURL: URL? {
        guard let link = URL(string: url), link.scheme == "https", link.user == nil,
              let host = link.host?.lowercased(),
              ["feishu.cn", "larksuite.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return link
    }
}

struct FeishuPage: Sendable {
    let documents: [FeishuDocument]
    let cursor: String
    static func parse(_ data: FeishuJSON) -> FeishuPage {
        let keys = ["files", "nodes", "results", "items"]
        let rows = keys.map { data[$0] }.first { if case .array = $0 { return true }; return false }?.items ?? []
        // The continuation token has two names in this API surface and the
        // command picks which one it returns: `drive files list` answers with
        // `next_page_token` (the raw Drive body passed through), while
        // `drive +search` / `docs +search` / `wiki +node-list` /
        // `+list-comments` answer with `page_token`. Reading only the latter
        // cleared the cursor on every folder listing even with `has_more`
        // true, so 加载更多 never appeared and a folder stopped at its first
        // page with no error (verified against lark-cli 1.0.95, whose
        // `drive.files.list` response schema has no `page_token` key at all).
        let next = data["page_token"].text
        return FeishuPage(documents: rows.compactMap(FeishuDocument.parse),
                          cursor: data["has_more"].flag ? (next.isEmpty ? data["next_page_token"].text : next) : "")
    }
}

struct FeishuLocation: Identifiable, Equatable, Sendable {
    let title: String
    let folder: String
    var space = ""
    var recentDays = 0
    var openedSince = ""
    var openedUntil = ""
    var isRecent: Bool { recentDays > 0 }
    var id: String { isRecent ? "recent:\(openedSince):\(openedUntil)" : space + ":" + folder }
    static let recent = recentlyOpened()
    static func recentlyOpened(days: Int = 30, now: Date = Date()) -> FeishuLocation {
        let duration = min(90, max(1, days))
        let formatter = ISO8601DateFormatter()
        return FeishuLocation(title: "最近访问", folder: "", recentDays: duration,
                              openedSince: formatter.string(from: now.addingTimeInterval(-Double(duration) * 86_400)),
                              openedUntil: formatter.string(from: now))
    }
    static let root = FeishuLocation(title: "云空间", folder: "")
    static let library = FeishuLocation(title: "个人文档库", folder: "", space: "my_library")
}

enum FeishuDocumentCommand {
    static func list(_ location: FeishuLocation, query: String, cursor: String = "") -> [String] {
        var args: [String]
        if location.isRecent {
            // Absolute bounds stay identical across pages; relative time would
            // drift and invalidate the upstream search cursor.
            args = ["drive", "+search", "--query", query, "--page-size", "20",
                    "--opened-since", location.openedSince, "--opened-until", location.openedUntil,
                    "--sort", "open_time", "--doc-types", "doc,docx,wiki,sheet,bitable,slides"]
        } else if !query.isEmpty {
            args = ["docs", "+search", "--query", query, "--page-size", "20"]
        } else if !location.space.isEmpty {
            args = ["wiki", "+node-list", "--space-id", location.space, "--page-size", "50"]
            if !location.folder.isEmpty { args += ["--parent-node-token", location.folder] }
        } else {
            args = ["drive", "files", "list", "--page-size", "100", "--order-by", "EditedTime", "--direction", "DESC"]
            if !location.folder.isEmpty { args += ["--folder-token", location.folder] }
        }
        if !cursor.isEmpty { args += ["--page-token", cursor] }
        return args + ["--as", "user"]
    }
    static func target(_ doc: FeishuDocument) -> [String] { ["--token", doc.token, "--type", doc.type] }
}

struct FeishuIdentity: Equatable {
    let account: String
    let name: String
    let available: Bool
    static func parse(_ data: FeishuJSON) -> FeishuIdentity {
        let user = data["identities"]["user"]
        let app = data["appId"].text
        let userID = user["openId"].text
        return FeishuIdentity(account: app + ":" + userID, name: user["userName"].text,
                              available: user["available"].flag && user["verified"] != .bool(false) && !userID.isEmpty)
    }
}

enum FeishuConnection: Equatable {
    case unchecked, checking, missingCLI, needsLogin, waiting, connected(String), failed
    var title: String {
        switch self {
        case .unchecked: return "连接飞书"
        case .checking: return "检查连接…"
        case .missingCLI: return "安装 CLI"
        case .needsLogin: return "登录飞书"
        case .waiting: return "等待授权…"
        case .connected(let name): return name.isEmpty ? "已连接" : name
        case .failed: return "连接需检查"
        }
    }
    var ready: Bool { if case .connected = self { return true }; return false }
}

/// Small in-memory LRU. Reads do not extend freshness; eviction removes one entry.
struct FeishuCache<Value> {
    struct Entry { let value: Value; let stored: Date; var access: UInt64 }
    let capacity: Int
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    init(capacity: Int) { self.capacity = max(1, capacity) }
    var count: Int { entries.count }
    mutating func read(_ key: String) -> Entry? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1; entry.access = clock; entries[key] = entry
        return entry
    }
    mutating func insert(_ value: Value, for key: String, now: Date = Date()) {
        clock &+= 1
        entries[key] = Entry(value: value, stored: now, access: clock)
        if entries.count > capacity, let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key { entries.removeValue(forKey: oldest) }
    }
    mutating func removeAll() { entries.removeAll() }
    mutating func remove(_ key: String) { entries.removeValue(forKey: key) }
    static func fresh(_ entry: Entry, now: Date = Date()) -> Bool { now.timeIntervalSince(entry.stored) < 60 }
}

struct FeishuDraft: Identifiable, Equatable {
    let id: String
    let document: FeishuDocument?
    let location: FeishuLocation
    let revision: String
    var title: String
    var text: String
    let original: String
    var account = ""
    var isNew: Bool { document == nil }
    var changed: Bool { isNew || text != original }
    var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (isNew || (!revision.isEmpty && changed)) }
    func arguments() -> [String] {
        if let document {
            return ["docs", "+update", "--doc", document.documentReference, "--command", "overwrite", "--doc-format", "markdown", "--content", "-", "--revision-id", revision]
        }
        return ["docs", "+create", "--title", title.trimmingCharacters(in: .whitespacesAndNewlines), "--doc-format", "markdown", "--content", "-"] + (location.folder.isEmpty ? [] : ["--parent-token", location.folder])
    }
}

@MainActor final class FeishuDocumentStore: ObservableObject {
    static let shared = FeishuDocumentStore()
    @Published private(set) var documents: [FeishuDocument] = []
    @Published private(set) var locations: [FeishuLocation] = [.recent]
    @Published private(set) var spaces: [FeishuLocation] = []
    @Published private(set) var cursor = ""
    @Published private(set) var loading = false
    @Published private(set) var working = false
    @Published private(set) var connection: FeishuConnection = .unchecked
    @Published private(set) var authorizationURL: URL?
    private var account = ""
    private var authTask: Task<Void, Never>?
    private var authGeneration = UUID()
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var content = ""
    @Published private(set) var revision = ""
    @Published private(set) var detailLoading = false
    @Published private(set) var selected: FeishuDocument?
    @Published private(set) var auxiliary: [FeishuJSON] = []
    @Published private(set) var auxiliaryCursor = ""
    @Published private(set) var auxiliaryLoading = false
    private var query = ""
    private var listTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var auxiliaryTask: Task<Void, Never>?
    private var generation = UUID()
    private var detailGeneration = UUID()
    private var auxiliaryGeneration = UUID()
    private var cache = FeishuCache<(FeishuPage, FeishuLocation)>(capacity: 12)
    private var contentCache = FeishuCache<(String, String, String)>(capacity: 8)
    private var visibleListKey = ""
    @Published private(set) var contentIsStale = false
    @Published private(set) var drafts: [String: FeishuDraft] = [:]
    @Published var activeDraftID: String?
    var activeDraft: FeishuDraft? { activeDraftID.flatMap { drafts[$0] } }
    private(set) var initialized = false
    private var lastConnectionCheck = Date.distantPast
    var location: FeishuLocation { locations.last ?? .root }
    var preview: Bool { !BuildChannel.allowsSystemIntegration }

    func start() {
        if preview { if !initialized { initialized = true; refresh() }; return }
        guard !initialized else {
            if connection.ready {
                if Date().timeIntervalSince(lastConnectionCheck) >= 60 { checkConnection() }
                else { refresh(); if activeDraft == nil, let selected { select(selected) } }
            }
            return
        }
        initialized = true
        checkConnection()
    }
    func checkConnection() {
        guard !preview, !working, connection != .waiting else { return }
        authTask?.cancel()
        let ticket = UUID(); authGeneration = ticket
        connection = .checking
        authTask = Task {
            guard FeishuCLI.executable() != nil else { connection = .missingCLI; return }
            do {
                let data = try await FeishuCLI.run(["auth", "status", "--json"])
                try Task.checkCancellation()
                guard authGeneration == ticket else { return }
                let identity = FeishuIdentity.parse(data)
                if identity.account != account || !identity.available {
                    suspend(); cache.removeAll(); contentCache.removeAll()
                    documents = []; spaces = []; cursor = ""; select(nil)
                    visibleListKey = ""
                }
                guard identity.available else { connection = .needsLogin; return }
                account = identity.account
                connection = .connected(identity.name)
                lastConnectionCheck = Date()
                refresh()
                if activeDraft == nil, let selected { select(selected) }
                let spacesData = try? await FeishuCLI.run(["wiki", "+space-list", "--as", "user", "--page-all", "--page-limit", "3"])
                guard authGeneration == ticket, !Task.isCancelled else { return }
                spaces = (spacesData?["items"].items ?? []).compactMap { item in
                    let id = item["space_id"].text
                    return id.isEmpty ? nil : FeishuLocation(title: item["name"].text, folder: "", space: id)
                }
            } catch { if authGeneration == ticket && !Task.isCancelled { connection = .failed; self.error = error.localizedDescription } }
        }
    }
    func beginLogin() {
        guard !preview, !working, connection != .waiting else { return }
        authTask?.cancel(); suspend()
        let ticket = UUID(); authGeneration = ticket
        authorizationURL = nil; connection = .waiting; error = nil
        authTask = Task {
            do {
                let data = try await FeishuCLI.run(["auth", "login", "--domain", "docs,drive,wiki,sheets,base,slides", "--no-wait", "--json"])
                try Task.checkCancellation()
                guard authGeneration == ticket else { return }
                let reference = FeishuDocument(token: "", title: "", type: "", url: data["verification_url"].text, modified: "")
                guard let url = reference.webURL, !data["device_code"].text.isEmpty else { throw FeishuCLIError.failed("CLI 未返回有效授权链接，请检查 CLI 配置。") }
                authorizationURL = url
                _ = try await FeishuCLI.run(["auth", "login", "--device-code", data["device_code"].text, "--json"], timeout: 600)
                try Task.checkCancellation()
                guard authGeneration == ticket else { return }
                authorizationURL = nil; connection = .unchecked
                notice = "授权完成，正在加载文档。"
                checkConnection()
            } catch {
                if authGeneration == ticket && !Task.isCancelled { authorizationURL = nil; connection = .failed; self.error = "授权未完成，可重新登录。请先确认 CLI 已配置飞书应用。" }
            }
        }
    }
    func cancelLogin() {
        guard connection == .waiting else { return }
        authTask?.cancel(); authGeneration = UUID(); authorizationURL = nil; connection = .needsLogin
    }
    func navigate(_ destination: FeishuLocation) {
        locations = [destination]; query = ""; activeDraftID = nil; select(nil); refresh()
    }
    func enter(_ doc: FeishuDocument) {
        guard doc.isFolder || (doc.type == "wiki" && doc.hasChildren && !location.space.isEmpty) else { return }
        locations.append(FeishuLocation(title: doc.title, folder: doc.token, space: location.space))
        query = ""; select(nil); refresh()
    }
    func back(to index: Int) {
        locations = Array(locations.prefix(index + 1)); query = ""; select(nil); refresh()
    }
    func search(_ value: String) {
        let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard next != query else { return }
        query = next; refresh()
    }
    func refresh(more: Bool = false, force: Bool = false) {
        guard preview || connection.ready else { return }
        guard !more || !cursor.isEmpty else { return }
        listTask?.cancel()
        let ticket = UUID(); generation = ticket
        error = nil
        let key = (location.isRecent ? "recent:\(location.recentDays)" : location.id) + ":" + query
        if !more {
            if let cached = cache.read(key), !force {
                documents = cached.value.0.documents; cursor = cached.value.0.cursor
                if location.isRecent { locations = [cached.value.1] }
                visibleListKey = key
                if FeishuCache<(FeishuPage, FeishuLocation)>.fresh(cached) { loading = false; return }
            } else if visibleListKey != key {
                documents = []; cursor = ""
            }
            if location.isRecent { locations = [.recentlyOpened(days: location.recentDays)] }
            cursor = "" // Old cursors belong to the old absolute search window.
        }
        visibleListKey = key
        let location = self.location, query = self.query, pageToken = more ? cursor : ""
        if preview {
            documents = Self.examples.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
            loading = false; return
        }
        loading = true; error = nil
        listTask = Task {
            defer { if generation == ticket { loading = false } }
            do {
                let response = try await FeishuCLI.run(FeishuDocumentCommand.list(location, query: query, cursor: pageToken))
                try Task.checkCancellation()
                guard generation == ticket else { return }
                let page = FeishuPage.parse(response)
                let combined = more ? documents + page.documents : page.documents
                var seen = Set<String>()
                documents = combined.filter { seen.insert($0.id).inserted }
                cursor = page.cursor == pageToken ? "" : page.cursor
                cache.insert((FeishuPage(documents: documents, cursor: cursor), location), for: key)
                if let selected, let fresh = documents.first(where: { $0.id == selected.id }), fresh != selected { self.selected = fresh }
            } catch is CancellationError { } catch {
                if generation == ticket && !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func select(_ doc: FeishuDocument?, force: Bool = false) {
        let sameDocument = selected?.id == doc?.id
        detailTask?.cancel(); auxiliaryTask?.cancel()
        detailGeneration = UUID(); auxiliaryGeneration = UUID()
        if selected?.id != doc?.id { activeDraftID = nil }
        selected = doc; auxiliary = []; auxiliaryCursor = ""; auxiliaryLoading = false
        let previousContent = content, previousRevision = revision
        content = ""; revision = ""; detailLoading = false; contentIsStale = false
        guard let doc, doc.isDocument, preview || connection.ready else { return }
        if preview { content = "# \(doc.title)\n\n这是开发版示例内容。\n\n## 工作区\n\n快速浏览、分页搜索与原生文档阅读。\n\n真实凭据和云端文档仅在正式版中访问。"; return }
        if let cached = contentCache.read(doc.id) {
            content = cached.value.0; revision = cached.value.1
            if !force && cached.value.2 == doc.modified && FeishuCache<(String, String, String)>.fresh(cached) { return }
            contentIsStale = true
        } else if force && sameDocument { content = previousContent; revision = previousRevision; contentIsStale = true }
        let ticket = detailGeneration
        detailLoading = true
        detailTask = Task {
            defer { if detailGeneration == ticket { detailLoading = false } }
            do {
                let data = try await FeishuCLI.run(["docs", "+fetch", "--doc", doc.documentReference, "--doc-format", "markdown", "--as", "user"])
                try Task.checkCancellation()
                guard detailGeneration == ticket else { return }
                content = data["document"]["content"].text
                revision = data["document"]["revision_id"].text
                contentIsStale = false
                contentCache.insert((content, revision, doc.modified), for: doc.id)
            } catch is CancellationError { } catch {
                if detailGeneration == ticket && !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func loadAuxiliary(_ tab: String, more: Bool = false) {
        auxiliaryTask?.cancel()
        let ticket = UUID(); auxiliaryGeneration = ticket
        if !more { auxiliary = []; auxiliaryCursor = "" }
        guard let doc = selected, !preview, connection.ready else { return }
        var args: [String]
        switch tab {
        case "评论": args = ["drive", "+list-comments"] + FeishuDocumentCommand.target(doc) + ["--solved-status", "all"]
        case "协作者": args = ["drive", "+member-list"] + FeishuDocumentCommand.target(doc) + ["--fields", "name,type"]
        default: args = ["docs", "+history-list", "--doc", doc.documentReference]
        }
        if more && !auxiliaryCursor.isEmpty { args += ["--page-token", auxiliaryCursor] }
        args += ["--as", "user"]
        let command = args
        auxiliaryLoading = true
        auxiliaryTask = Task {
            defer { if auxiliaryGeneration == ticket { auxiliaryLoading = false } }
            do {
                let data = try await FeishuCLI.run(command)
                try Task.checkCancellation()
                guard auxiliaryGeneration == ticket else { return }
                let rows = tab == "历史" ? data["entries"].items : data["items"].items
                auxiliary = more ? auxiliary + rows : rows
                auxiliaryCursor = data["has_more"].flag ? data["page_token"].text : ""
            } catch is CancellationError { } catch {
                if auxiliaryGeneration == ticket && !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func perform(_ args: [String], input: String? = nil, refreshList: Bool = true) async -> Bool {
        guard !working else { return false }
        guard !preview else { error = "开发版仅提供示例预览；请在正式版管理真实文档。"; return false }
        guard connection.ready else { error = "请先连接飞书再保存。"; return false }
        let selectionAtStart = selected?.id, draftAtStart = activeDraftID
        if refreshList {
            suspend(); cache.removeAll()
            if let selected { contentCache.remove(selected.id) }
        }
        working = true; error = nil; notice = nil
        defer { working = false }
        do {
            let data = try await FeishuCLI.run(args + ["--as", "user"], input: input)
            if !data["task_id"].text.isEmpty && data["status"].text != "done" {
                // Async Drive tasks are not proof that a move/delete completed.
                notice = "飞书已受理任务，请刷新列表核对结果。"
            } else { notice = "操作已完成。" }
            if (args.contains("+create") || args.contains("+copy") || args.contains("+import")),
               selected?.id == selectionAtStart, activeDraftID == draftAtStart {
                let result = data["document"] == .null ? data : data["document"]
                if let created = FeishuDocument.parse(result) {
                    let titleIndex = args.firstIndex(of: "--title")
                    let fallbackTitle = titleIndex.map { args[$0 + 1] } ?? created.title
                    let normalized = FeishuDocument(token: created.token, title: created.title.isEmpty ? fallbackTitle : created.title,
                                                    type: args.contains("+create") || args.contains("+import") ? "docx" : created.type,
                                                    url: created.url, modified: created.modified)
                    select(normalized, force: true)
                }
            }
            if refreshList { refresh(force: true) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func beginEditing() {
        guard let doc = selected, doc.isDocument, !detailLoading else { return }
        if drafts[doc.id] == nil {
            guard reserveDraft() else { return }
            let existingBytes = drafts.values.reduce(0) { $0 + $1.text.utf8.count }
            guard existingBytes + content.utf8.count <= 8 * 1024 * 1024 else {
                error = "正文超过可编辑草稿容量，请在飞书中编辑或先保存其他草稿。"; return
            }
            drafts[doc.id] = FeishuDraft(id: doc.id, document: doc, location: location, revision: revision,
                                        title: doc.title, text: content, original: content, account: account)
        }
        activeDraftID = doc.id
    }
    func newDocument() {
        guard reserveDraft() else { return }
        let id = UUID().uuidString
        drafts[id] = FeishuDraft(id: id, document: nil, location: location.isRecent ? .root : location,
                                revision: "", title: "", text: "", original: "", account: account)
        activeDraftID = id
    }
    private func reserveDraft() -> Bool {
        guard drafts.count < 8 else { error = "已有 8 份草稿，请保存或丢弃一份后继续。"; return false }
        return true
    }
    func updateDraft(text: String? = nil, title: String? = nil) {
        guard let id = activeDraftID, var draft = drafts[id], !working else { return }
        if let text {
            let otherBytes = drafts.values.filter { $0.id != id }.reduce(0) { $0 + $1.text.utf8.count }
            guard otherBytes + text.utf8.count <= 8 * 1024 * 1024 else { error = "草稿总量已达 8 MB，请保存或导出后继续。"; return }
            draft.text = text
        }
        if let title { draft.title = title }
        drafts[id] = draft
    }
    func discardDraft() {
        guard !working, let id = activeDraftID else { return }
        drafts.removeValue(forKey: id); activeDraftID = nil
    }
    func saveDraft() async -> Bool {
        guard let draft = activeDraft, draft.canSave else { return false }
        guard draft.account == account else { error = "当前登录账号已改变。请切回原账号保存，或复制草稿内容。"; return false }
        if await perform(draft.arguments(), input: draft.text) {
            drafts.removeValue(forKey: draft.id)
            if activeDraftID == draft.id {
                activeDraftID = nil
                if let doc = draft.document { select(doc, force: true) }
            }
            return true
        }
        // Revision conflicts and offline failures leave the exact submitted draft intact.
        return false
    }
    func suspend() {
        listTask?.cancel(); detailTask?.cancel(); auxiliaryTask?.cancel()
        generation = UUID(); detailGeneration = UUID(); auxiliaryGeneration = UUID()
        loading = false; detailLoading = false; auxiliaryLoading = false
    }
    private static let examples = [
        FeishuDocument(token: "preview-design", title: "产品设计与协作规范", type: "docx", url: "", modified: "示例"),
        FeishuDocument(token: "preview-weekly", title: "本周工作计划", type: "docx", url: "", modified: "示例"),
        FeishuDocument(token: "preview-notes", title: "团队知识库 · 入门指南", type: "docx", url: "", modified: "示例")
    ]
}
