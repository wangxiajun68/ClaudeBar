import AppKit
import SwiftUI

struct FeishuOperation: Identifiable {
    enum Kind: String {
        case create = "新建文档", folder = "新建文件夹", rename = "重命名", copy = "创建副本", move = "移动文档"
        case delete = "删除", edit = "编辑正文", comment = "添加评论", member = "添加协作者"
        case removeMember = "移除协作者", export = "导出文档", history = "历史版本"
        case upload = "上传文件", importDocument = "导入文档"
    }
    let id = UUID()
    let kind: Kind
    var document: FeishuDocument? = nil
    var location: FeishuLocation = .root
    var content = ""
    var revision = ""
    var member: FeishuJSON = .null
    var format = "pdf"
}

struct FeishuOperationSheet: View {
    let request: FeishuOperation
    @ObservedObject var store: FeishuDocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var destination = ""
    @State private var mode = "append"
    @State private var permission = "view"
    @State private var exportFormat = "pdf"
    @State private var localURL: URL?
    @State private var error: String?
    @State private var confirm = false
    @State private var historicalContent = ""
    @State private var readingHistory = false
    @State private var submitting = false

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var needsDestination: Bool { request.kind == .copy || request.kind == .move }
    private var valid: Bool {
        switch request.kind {
        case .create, .folder, .rename, .copy: return !trimmedTitle.isEmpty
        case .edit: return !text.isEmpty && (mode != "overwrite" || !request.revision.isEmpty)
        case .comment, .member: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .export, .upload, .importDocument: return localURL != nil
        case .history: return false
        default: return true
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(request.kind.rawValue).font(Theme.Font.displayHero).tracking(Theme.Tracking.titleSmall)
                Spacer()
                if submitting || readingHistory { ProgressView().controlSize(.small) }
            }
            if let doc = request.document {
                Label(doc.title, systemImage: doc.symbol).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                Text(doc.type.uppercased() + " · " + doc.token).font(Theme.Font.micro).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
            }
            fields
            if let error { Text(error).font(Theme.Font.caption).foregroundStyle(Theme.Ink.error).textSelection(.enabled) }
            HStack {
                Spacer()
                ActionButton("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(submitting)
                if request.kind != .history {
                    ActionButton(request.kind == .delete || request.kind == .removeMember ? "继续" : "确认", tone: .accent, emphasis: .primary) {
                        if request.kind == .delete || request.kind == .removeMember || request.kind == .member || request.kind == .move || (request.kind == .edit && mode == "overwrite") { confirm = true }
                        else { submit() }
                    }
                    .keyboardShortcut(.defaultAction).disabled(!valid || store.working || submitting)
                }
            }
        }
        .padding(26).frame(width: request.kind == .edit || request.kind == .history ? 680 : 520)
        .background(Theme.cardSurface).foregroundStyle(Theme.textPrimary)
        .interactiveDismissDisabled(submitting)
        .onAppear {
            title = request.kind == .copy ? (request.document?.title ?? "") + " · 副本" : request.document?.title ?? ""
            destination = request.location.folder
            exportFormat = request.format
        }
        .task {
            guard request.kind == .history, let doc = request.document else { return }
            readingHistory = true
            defer { readingHistory = false }
            do {
                let data = try await FeishuCLI.run(["docs", "+fetch", "--doc", doc.documentReference, "--revision-id", request.revision, "--doc-format", "markdown", "--as", "user"])
                try Task.checkCancellation()
                historicalContent = data["document"]["content"].text
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .confirmationDialog("确认\(request.kind.rawValue)？", isPresented: $confirm, titleVisibility: .visible) {
            Button("确认执行", role: request.kind == .delete || request.kind == .removeMember ? .destructive : nil) { submit() }
            Button("取消", role: .cancel) { }
        } message: { Text(confirmationMessage) }
    }
    @ViewBuilder private var fields: some View {
        switch request.kind {
        case .create, .folder, .rename, .copy:
            TextField("名称", text: $title).textFieldStyle(InstrumentFieldStyle())
            if request.kind == .create {
                Text("正文 · Markdown").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $text).font(.system(size: 13, design: .monospaced)).frame(height: 220).scrollContentBackground(.hidden).padding(10)
                    .background(Theme.fieldWell, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
            }
            if request.kind == .create || request.kind == .folder { Text("创建位置：\(request.location.title)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
        case .edit:
            SegmentedCapsule(items: ["append", "overwrite"], selection: mode,
                             title: { $0 == "append" ? "追加内容" : "替换全文" },
                             tint: Theme.Ink.claude, onSelect: { mode = $0 })
            if mode == "overwrite" {
                Text("Markdown 替换会丢失原文中的部分富文本、嵌入资源与评论锚点。基于读取版本 \(request.revision) 保存，冲突时请重新读取。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Ink.warning)
            }
            TextEditor(text: $text).font(.system(size: 13, design: .monospaced)).frame(height: 340).scrollContentBackground(.hidden).padding(10)
                    .background(Theme.fieldWell, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
                .onChange(of: mode) { _, value in text = value == "overwrite" ? request.content : "" }
        case .comment:
            TextEditor(text: $text).frame(height: 150).scrollContentBackground(.hidden).padding(10)
                    .background(Theme.fieldWell, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
            Text("添加全文评论，不发送消息通知。").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        case .member:
            TextField("协作者邮箱", text: $text).textFieldStyle(InstrumentFieldStyle())
            SegmentedCapsule(items: ["view", "edit"], selection: permission,
                             title: { $0 == "view" ? "可阅读" : "可编辑" },
                             tint: Theme.Ink.claude, onSelect: { permission = $0 })
            Text("Wiki 授权仅作用于当前页面。不会发送飞书消息通知。").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        case .removeMember:
            Text("移除 \(request.member.first("name", "member_id")) 的 \(request.member["perm"].text) 权限。")
        case .delete:
            Text("将删除该资源。删除文件夹也可能影响其下文档，请先检查内容。").foregroundStyle(Theme.Ink.warning)
        case .export:
            SegmentedCapsule(items: ["pdf", "docx", "markdown"], selection: exportFormat,
                             title: { $0 == "pdf" ? "PDF" : ($0 == "docx" ? "Word" : "Markdown") },
                             tint: Theme.Ink.claude, onSelect: { exportFormat = $0 })
            ActionButton("选择导出目录…", symbol: "folder") { chooseLocal(directory: true) }
            Text(localURL?.path ?? "请选择保存位置").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
            Text("已有同名文件不会被覆盖。").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        case .upload, .importDocument:
            ActionButton("选择本地文件…", symbol: "doc") { chooseLocal(directory: false) }
            Text(localURL?.lastPathComponent ?? "尚未选择文件").font(Theme.Font.caption)
            if request.kind == .importDocument { Text("将 Word / Markdown 文件导入为在线文档。").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
        case .history:
            Text("版本 \(request.revision) · 只读").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            ScrollView { Text(historicalContent).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(12) }
                .frame(height: 380).background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 10))
        case .move: EmptyView()
        }
        if needsDestination {
            Menu {
                Button("云空间根目录") { destination = "" }
                ForEach(store.locations.filter { $0.space.isEmpty && !$0.folder.isEmpty }) { location in
                    Button(location.title) { destination = location.folder }
                }
                ForEach(store.documents.filter { $0.isFolder && $0.id != request.document?.id }) { folder in
                    Button(folder.title) { destination = folder.token }
                }
            } label: { Label("选择目标文件夹", systemImage: "folder") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).headerControl()
            TextField("或粘贴文件夹链接（留空为根目录）", text: $destination).textFieldStyle(InstrumentFieldStyle())
        }
    }
    private var confirmationMessage: String {
        let name = request.document?.title ?? ""
        switch request.kind {
        case .member: return "为 \(text) 授予「\(name)」的\(permission == "edit" ? "编辑" : "阅读")权限。"
        case .removeMember: return "从「\(name)」移除 \(request.member.first("name", "member_id"))，范围：\(request.member.first("perm_type"))。"
        case .move: return "将「\(name)」移动到 \(destination.isEmpty ? "云空间根目录" : destination)，可能改变权限继承。"
        case .edit: return "将「\(name)」的全文替换为输入的 Markdown，可能丢失原有格式及嵌入内容。"
        default: return "删除「\(name)」（\(request.document?.token ?? "")）。"
        }
    }
    private func chooseLocal(directory: Bool) {
        guard BuildChannel.promptsForSystemPermissions else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false
        panel.begin { result in if result == .OK { localURL = panel.url } }
    }
    private func submit() {
        guard valid, !submitting else { return }
        error = nil; submitting = true
        Task {
            defer { submitting = false }
            do {
                let command = try arguments()
                let stdin: String?
                if request.kind == .create || request.kind == .edit { stdin = text }
                else if request.kind == .comment {
                    let elements: [[String: Any]] = [["type": "text_run", "text_run": ["text": text]]]
                    stdin = String(data: try JSONSerialization.data(withJSONObject: elements), encoding: .utf8)
                } else { stdin = nil }
                if await store.perform(command, input: stdin, refreshList: ![.comment, .member, .removeMember, .export].contains(request.kind)) {
                    if request.kind == .edit { store.select(request.document, force: true) }
                    if request.kind == .delete || request.kind == .move { store.select(nil) }
                    if request.kind == .comment { store.loadAuxiliary("评论") }
                    if request.kind == .member || request.kind == .removeMember { store.loadAuxiliary("协作者") }
                    dismiss()
                } else { error = store.error }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func arguments() throws -> [String] {
        let doc = request.document
        let target = doc.map(FeishuDocumentCommand.target) ?? []
        var folderToken = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if folderToken.contains("://") {
            let folder = FeishuDocument(token: "", title: "", type: "folder", url: folderToken, modified: "")
            guard let url = folder.webURL, url.pathComponents.contains("folder"), !url.lastPathComponent.isEmpty else {
                throw FeishuCLIError.failed("请粘贴有效的飞书文件夹链接。")
            }
            folderToken = url.lastPathComponent
        }
        if request.kind == .move && !folderToken.isEmpty && folderToken == doc?.token {
            throw FeishuCLIError.failed("不能将文件夹移动到自身。")
        }
        switch request.kind {
        case .create:
            var args = ["docs", "+create", "--title", trimmedTitle, "--doc-format", "markdown", "--content", "-"]
            if !request.location.folder.isEmpty { args += ["--parent-token", request.location.folder] }
            return args
        case .folder:
            var args = ["drive", "+create-folder", "--name", trimmedTitle]
            if !request.location.folder.isEmpty { args += ["--folder-token", request.location.folder] }
            return args
        case .rename: return ["drive", "+update-title"] + target + ["--title", trimmedTitle]
        case .copy: return ["drive", "+copy"] + target + ["--name", trimmedTitle, "--folder-token", folderToken.isEmpty ? "my_space" : folderToken]
        case .move: return ["drive", "+move", "--file-token", doc?.token ?? "", "--type", doc?.type ?? "", "--folder-token", folderToken]
        case .delete: return ["drive", "+delete", "--file-token", doc?.token ?? "", "--type", doc?.type ?? "", "--yes"]
        case .edit:
            return ["docs", "+update", "--doc", doc?.documentReference ?? "", "--command", mode, "--doc-format", "markdown", "--content", "-"] + (request.revision.isEmpty ? [] : ["--revision-id", request.revision])
        case .comment: return ["drive", "+add-comment", "--doc", doc?.documentReference ?? "", "--full-comment", "--content", "-"] + (doc?.documentReference.hasPrefix("https://") == true ? [] : ["--type", doc?.contentType ?? "docx"])
        case .member:
            guard text.contains("@"), !text.contains(",") else { throw FeishuCLIError.failed("请输入单个有效的协作者邮箱。") }
            return ["drive", "+member-add"] + target + ["--member-type", "email", "--member-id", text.trimmingCharacters(in: .whitespaces), "--perm", permission, "--yes"] + (doc?.type == "wiki" ? ["--perm-type", "single_page"] : [])
        case .removeMember:
            return ["drive", "+member-remove"] + target + ["--member-type", request.member["member_type"].text, "--member-id", request.member["member_id"].text, "--yes"] + (doc?.type == "wiki" ? ["--perm-type", request.member["perm_type"].text] : [])
        case .export: return ["drive", "+export", "--token", doc?.token ?? "", "--doc-type", doc?.type ?? "", "--file-extension", exportFormat, "--output-dir", localURL?.path ?? ""]
        case .upload: return ["drive", "+upload", "--file", localURL?.path ?? "", "--folder-token", request.location.folder]
        case .importDocument: return ["drive", "+import", "--file", localURL?.path ?? "", "--type", "docx", "--folder-token", request.location.folder]
        case .history: throw FeishuCLIError.failed("历史版本仅供阅读。")
        }
    }
}
