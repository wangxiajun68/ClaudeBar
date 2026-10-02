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
        let token = item.first("node_token", "token", "doc_token", "file_token")
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
        return FeishuPage(documents: rows.compactMap(FeishuDocument.parse),
                          cursor: data["has_more"].flag ? data["page_token"].text : "")
    }
}

struct FeishuLocation: Identifiable, Equatable, Sendable {
    let title: String
    let folder: String
    var space = ""
    var id: String { space + ":" + folder }
    static let root = FeishuLocation(title: "云空间", folder: "")
    static let library = FeishuLocation(title: "个人文档库", folder: "", space: "my_library")
}

enum FeishuDocumentCommand {
    static func list(_ location: FeishuLocation, query: String, cursor: String = "") -> [String] {
        var args: [String]
        if !query.isEmpty {
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

@MainActor final class FeishuDocumentStore: ObservableObject {
    static let shared = FeishuDocumentStore()
    @Published private(set) var documents: [FeishuDocument] = []
    @Published private(set) var locations: [FeishuLocation] = [.root]
    @Published private(set) var spaces: [FeishuLocation] = []
    @Published private(set) var cursor = ""
    @Published private(set) var loading = false
    @Published private(set) var working = false
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
    private var cache: [String: (FeishuPage, Date)] = [:]
    private var contentCache: [String: (String, String, Date)] = [:]
    private(set) var initialized = false
    var location: FeishuLocation { locations.last ?? .root }
    var preview: Bool { !BuildChannel.allowsSystemIntegration }

    func start() {
        guard !initialized else { return }
        initialized = true
        refresh()
        if !preview {
            Task {
                do {
                    let data = try await FeishuCLI.run(["wiki", "+space-list", "--as", "user", "--page-all", "--page-limit", "3"])
                    spaces = data["items"].items.compactMap { item in
                        let id = item["space_id"].text
                        return id.isEmpty ? nil : FeishuLocation(title: item["name"].text, folder: "", space: id)
                    }
                } catch { /* Drive remains usable when Wiki scope is unavailable. */ }
            }
        }
    }
    func navigate(_ destination: FeishuLocation) {
        locations = [destination]; query = ""; select(nil); refresh()
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
        query = next; select(nil); refresh()
    }
    func refresh(more: Bool = false, force: Bool = false) {
        listTask?.cancel()
        let ticket = UUID(); generation = ticket
        let location = self.location, query = self.query, pageToken = more ? cursor : ""
        let key = location.id + ":" + query
        if !more {
            if let cached = cache[key], !force, Date().timeIntervalSince(cached.1) < 60 { documents = cached.0.documents; cursor = cached.0.cursor; loading = false; return }
            documents = []; cursor = ""
        }
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
                if cache.count >= 12 { cache.removeAll(keepingCapacity: true) }
                cache[key] = (FeishuPage(documents: documents, cursor: cursor), Date())
                if let selected, let fresh = documents.first(where: { $0.id == selected.id }), fresh != selected { self.selected = fresh }
            } catch is CancellationError { } catch {
                if generation == ticket && !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func select(_ doc: FeishuDocument?, force: Bool = false) {
        detailTask?.cancel(); auxiliaryTask?.cancel()
        detailGeneration = UUID(); auxiliaryGeneration = UUID()
        selected = doc; auxiliary = []; auxiliaryCursor = ""; auxiliaryLoading = false
        content = ""; revision = ""; detailLoading = false
        guard let doc, doc.isDocument else { return }
        if preview { content = "# \(doc.title)\n\n这是开发版示例内容。\n\n## 工作区\n\n快速浏览、分页搜索与原生文档阅读。\n\n真实凭据和云端文档仅在正式版中访问。"; return }
        if let cached = contentCache[doc.id], !force, Date().timeIntervalSince(cached.2) < 60 { content = cached.0; revision = cached.1; return }
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
                if contentCache.count >= 8 { contentCache.removeAll(keepingCapacity: true) }
                contentCache[doc.id] = (content, revision, Date())
            } catch is CancellationError { } catch {
                if detailGeneration == ticket && !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func loadAuxiliary(_ tab: String, more: Bool = false) {
        auxiliaryTask?.cancel()
        let ticket = UUID(); auxiliaryGeneration = ticket
        if !more { auxiliary = []; auxiliaryCursor = "" }
        guard let doc = selected, !preview else { return }
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
        working = true; error = nil; notice = nil
        defer { working = false }
        do {
            let data = try await FeishuCLI.run(args + ["--as", "user"], input: input)
            if !data["task_id"].text.isEmpty && data["status"].text != "done" {
                // Async Drive tasks are not proof that a move/delete completed.
                notice = "飞书已受理任务，请刷新列表核对结果。"
            } else { notice = "操作已完成。" }
            cache.removeAll(); contentCache.removeAll()
            if refreshList { refresh(force: true) }
            return true
        } catch { self.error = error.localizedDescription; return false }
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
