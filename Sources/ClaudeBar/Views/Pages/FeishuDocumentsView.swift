import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FeishuDocumentsView: View {
    @ObservedObject private var store = FeishuDocumentStore.shared
    @State private var search = ""
    @State private var tab = "正文"
    @State private var operation: FeishuOperation?
    @State private var showSetup = false
    @State private var typeFilter = "全部"
    @State private var showSource = false

    private var shown: [FeishuDocument] {
        store.documents.filter { typeFilter == "全部" || (typeFilter == "文档" ? $0.isDocument : $0.isFolder) }
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            if store.preview {
                banner("开发版 · 示例预览，不连接真实账号或操作云端文档。", symbol: "eye", color: Theme.Ink.claude)
            }
            if let error = store.error { banner(error, symbol: "exclamationmark.triangle", color: Theme.Ink.error) }
            if let notice = store.notice { banner(notice, symbol: "checkmark.circle", color: Theme.Ink.success) }
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 16) {
                    inventory.frame(width: min(320, max(260, geometry.size.width * 0.32)))
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
        .background(Theme.bgPrimary)
        .task { store.start(); if store.documents.isEmpty && !store.loading { store.refresh() } }
        .onDisappear { store.suspend() }
        .task(id: search) {
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                store.search(search)
            } catch { }
        }
        .onChange(of: store.selected?.id) { _, _ in tab = "正文"; showSource = false }
        .onChange(of: tab) { _, value in if value != "正文" { store.loadAuxiliary(value) } }
        .sheet(item: $operation) { request in
            FeishuOperationSheet(request: request, store: store)
        }
        .sheet(isPresented: $showSetup) { setup }
    }

    private var header: some View {
        PageHeaderCard(tint: Theme.Ink.claude, faceTint: Theme.claude) { _ in
            HStack(alignment: .center, spacing: Theme.Space.s12) {
                FeishuWorkspaceMark()
                    .frame(width: 34, height: 34)
                    .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.hairline))
                VStack(alignment: .leading, spacing: 5) {
                    Text("飞书文档").font(Theme.Font.displayHero).tracking(Theme.Tracking.titleSmall).foregroundStyle(Theme.textPrimary)
                    Text("云空间与知识库，一处管理").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button { showSetup = true } label: { Label("连接设置", systemImage: "terminal") }
                    .buttonStyle(.plain).headerControl()
                Button { store.refresh(force: true) } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .buttonStyle(.plain).headerControl()
                    .disabled(store.loading || store.working).help("刷新文档列表")
                Menu {
                    Button("新建文档", systemImage: "doc.badge.plus") { operation = .init(kind: .create, location: store.location) }
                    Button("新建文件夹", systemImage: "folder.badge.plus") { operation = .init(kind: .folder, location: store.location) }
                    Divider()
                    Button("上传文件", systemImage: "arrow.up.doc") { operation = .init(kind: .upload, location: store.location) }
                    Button("导入 Word / Markdown", systemImage: "doc.badge.arrow.up") { operation = .init(kind: .importDocument, location: store.location) }
                } label: { Label("新建", systemImage: "plus").font(Theme.Font.caption.weight(.semibold)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).headerControl()
                .disabled(store.preview || store.working || !store.location.space.isEmpty)
            }
        }
        .padding(.horizontal, Theme.Space.s24).padding(.top, Theme.Space.s8).padding(.bottom, Theme.Space.s16)
    }

    private var inventory: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Menu {
                    Button("云空间") { navigate(.root) }
                    Button("个人文档库") { navigate(.library) }
                    if !store.spaces.isEmpty {
                        Divider()
                        ForEach(store.spaces) { space in Button(space.title) { navigate(space) } }
                    }
                } label: { Label(store.locations.first?.title ?? "云空间", systemImage: "folder") }
                .buttonStyle(.borderless)
                Spacer()
                Text("\(shown.count) 项\(store.cursor.isEmpty ? "" : " · 可加载更多")")
                    .font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
            }
            InstrumentSearchField(prompt: "搜索全部飞书文档", text: $search).frame(height: 36)
            SegmentedCapsule(items: ["全部", "文档", "文件夹"], selection: typeFilter,
                             title: { $0 }, tint: Theme.Ink.claude,
                             onSelect: { typeFilter = $0 })
            if store.locations.count > 1 && search.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(store.locations.enumerated()), id: \.offset) { index, location in
                            Button(location.title) { store.back(to: index) }.buttonStyle(.borderless)
                            if index < store.locations.count - 1 { Image(systemName: "chevron.right").font(.system(size: 9)) }
                        }
                    }.font(Theme.Font.micro).lineLimit(1)
                }
            }
            if !search.isEmpty { Text("全局搜索结果").font(Theme.Font.micro).foregroundStyle(Theme.textSecondary) }
            Divider()
            // List is the scroll owner: native row reuse, no eager stack around the inventory.
            List {
                ForEach(shown) { doc in
                    Button {
                        if doc.isFolder { search = ""; store.enter(doc) }
                        else { store.select(doc) }
                    } label: {
                        FeishuDocumentRow(document: doc, selected: store.selected?.id == doc.id)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { actions(doc) }
                    .listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .listRowBackground(Color.clear)
                }
                if !store.cursor.isEmpty {
                    ActionButton("加载更多") { store.refresh(more: true) }
                        .disabled(store.loading).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .overlay {
                if store.documents.isEmpty {
                    if store.loading { ProgressView("正在获取文档…").font(Theme.Font.caption) }
                    else { StandbyEmptyState(label: "暂无文档", symbol: "doc.text.magnifyingglass", tint: Theme.Ink.claude, caption: "尝试搜索、切换文档库或检查连接。", block: true) }
                }
            }
            if store.loading && !store.documents.isEmpty { ProgressView().controlSize(.small) }
        }
        .padding(Theme.Space.s14).panelCard()
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let doc = store.selected {
                HStack(alignment: .center, spacing: 12) {
                    FeishuDocumentGlyph(document: doc, size: 40)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(doc.title.isEmpty ? "未命名" : doc.title).font(.system(size: 20, weight: .bold)).textSelection(.enabled)
                        Text(doc.type.uppercased()).font(Theme.Font.microMedium).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if let url = doc.webURL { Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help("在飞书中打开") }
                    Menu { actions(doc) } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 25)
                }.padding(20)
                HStack(spacing: 18) {
                    SegmentedCapsule(items: doc.isDocument ? ["正文", "评论", "协作者", "历史"] : ["信息", "协作者"],
                                     selection: !doc.isDocument && tab == "正文" ? "信息" : tab,
                                     title: { $0 }, tint: Theme.Ink.claude,
                                     onSelect: { tab = $0 == "信息" ? "正文" : $0 })
                    Spacer()
                    if tab == "正文" && doc.isDocument {
                        if store.content.utf8.count <= 512_000 {
                            Button(showSource ? "排版" : "源码") { showSource.toggle() }
                                .buttonStyle(.plain).headerControl()
                                .help("切换 Markdown 源码与排版预览")
                        } else {
                            Text("大文档 · 源码").font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
                        }
                        ActionButton("编辑", symbol: "pencil") { operation = .init(kind: .edit, document: doc, content: store.content, revision: store.revision) }
                            .disabled(store.preview || store.detailLoading || store.content.isEmpty || store.working)
                    }
                }.padding(.horizontal, 20)
                Divider()
                if tab == "正文" {
                    if store.detailLoading { Spacer(); HStack { Spacer(); ProgressView("正在读取文档…"); Spacer() }; Spacer() }
                    else if doc.isDocument {
                        if showSource || store.content.utf8.count > 512_000 {
                            FeishuDocumentReader(content: store.content)
                        } else {
                            ScrollView {
                                SkillMarkdownPreview(content: store.content)
                                    .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .environment(\.openURL, OpenURLAction { url in
                                guard url.scheme == "https" else { return .discarded }
                                return .systemAction
                            })
                            .id(doc.id)
                        }
                    }
                    else {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("此类型请在飞书中查看内容", systemImage: doc.symbol)
                            Text("资源标识：\(doc.token)").textSelection(.enabled)
                            if !doc.modified.isEmpty { Text("修改时间：\(doc.modified)") }
                        }.font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).padding(20)
                        Spacer()
                    }
                } else { auxiliary(doc) }
                if doc.type == "wiki" && doc.hasChildren && !store.location.space.isEmpty {
                    ActionButton("浏览子文档", symbol: "folder") { search = ""; store.enter(doc) }.padding(16)
                }
            } else {
                Spacer()
                VStack(spacing: 16) {
                    StandbyEmptyState(label: "让文档触手可及", symbol: "doc.text.image", tint: Theme.Ink.claude,
                                      caption: "选择左侧文档，专注阅读与协作。", block: true)
                    HStack(spacing: 20) {
                        Label("正文", systemImage: "doc.text")
                        Label("评论", systemImage: "bubble.left")
                        Label("协作", systemImage: "person.2")
                    }.font(Theme.Font.micro).foregroundStyle(Theme.textSecondary).padding(.top, 4)
                }.frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .panelCard()
    }

    private func auxiliary(_ doc: FeishuDocument) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(store.preview ? "示例预览不加载真实协作数据" : "\(store.auxiliary.count) 条已加载")
                    .font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
                Spacer()
                if tab == "评论" {
                    ActionButton("添加评论", symbol: "plus.bubble", tone: .accent) { operation = .init(kind: .comment, document: doc) }
                } else if tab == "协作者" {
                    ActionButton("添加协作者", symbol: "person.badge.plus", tone: .accent) { operation = .init(kind: .member, document: doc) }
                }
            }.padding(16).disabled(store.preview || store.working)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(store.auxiliary.enumerated()), id: \.offset) { _, item in
                        auxiliaryRow(item, doc: doc)
                    }
                    if !store.auxiliaryCursor.isEmpty {
                        ActionButton("加载更多") { store.loadAuxiliary(tab, more: true) }.disabled(store.auxiliaryLoading)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }
            .overlay {
                if store.auxiliaryLoading { ProgressView() }
                else if store.auxiliary.isEmpty { Text("暂无可显示的\(tab)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
            }
        }
    }
    private func auxiliaryRow(_ item: FeishuJSON, doc: FeishuDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if tab == "协作者" {
                HStack {
                    Label(item.first("name", "member_id"), systemImage: "person.circle")
                    Spacer()
                    Text(item["perm"].text == "edit" ? "可编辑" : item["perm"].text == "full_access" ? "完全管理" : "可阅读").foregroundStyle(Theme.textSecondary)
                    ActionIcon(symbol: "person.badge.minus", tint: Theme.Ink.error) { operation = .init(kind: .removeMember, document: doc, member: item) }
                        .disabled(store.preview || store.working || item["member_id"].text.isEmpty || item["member_type"].text.isEmpty || (doc.type == "wiki" && item["perm_type"].text.isEmpty))
                }
            } else if tab == "历史" {
                Text(item.first("name", "description").isEmpty ? "版本 \(item["revision_id"].text)" : item.first("name", "description"))
                Text(item["edit_time"].text).foregroundStyle(Theme.textSecondary)
                ActionButton("查看此版本") {
                    operation = .init(kind: .history, document: doc, revision: item["revision_id"].text)
                }.disabled(store.preview)
            } else {
                HStack {
                    Text(item["is_solved"].flag ? "已解决" : "未解决").foregroundStyle(Theme.textSecondary)
                    Spacer()
                    ActionButton(item["is_solved"].flag ? "重新打开" : "标记解决") {
                        let command = item["is_solved"].flag ? "+restore-comment" : "+resolve-comment"
                        Task {
                            if await store.perform(["drive", command] + FeishuDocumentCommand.target(doc) + ["--comment-id", item["comment_id"].text], refreshList: false) { store.loadAuxiliary("评论") }
                        }
                    }.disabled(store.preview || store.working)
                }
                ForEach(Array(item["reply_list"]["replies"].items.enumerated()), id: \.offset) { _, reply in
                    Text(reply["content"]["elements"].items.map { $0["text_run"]["text"].text }.joined()).textSelection(.enabled)
                }
                if item["has_more"].flag { Text("更多回复请在飞书中查看").foregroundStyle(Theme.textSecondary) }
            }
        }
        .font(Theme.Font.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func actions(_ doc: FeishuDocument) -> some View {
        if let url = doc.webURL {
            Link("在飞书中打开", destination: url)
            Button("复制链接") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
        }
        Button("刷新内容") { store.select(doc, force: true) }.disabled(!doc.isDocument || store.detailLoading)
        Divider()
        Button("重命名") { operation = .init(kind: .rename, document: doc) }.disabled(store.preview || store.working)
        if !doc.isFolder {
            Button("创建副本") { operation = .init(kind: .copy, document: doc, location: store.location) }.disabled(store.preview || store.working)
        }
        if doc.type != "wiki" {
            Button("移动到文件夹") { operation = .init(kind: .move, document: doc, location: store.location) }.disabled(store.preview || store.working)
        }
        if doc.isDocument {
            Button("导出 PDF / Word / Markdown") { operation = .init(kind: .export, document: doc) }.disabled(store.preview || store.working)
        }
        if doc.type != "wiki" {
            Divider()
            Button("删除", role: .destructive) { operation = .init(kind: .delete, document: doc) }.disabled(store.preview || store.working)
        }
    }
    private func navigate(_ location: FeishuLocation) { search = ""; store.navigate(location) }
    private func banner(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top) {
            Image(systemName: symbol)
            Text(text).font(Theme.Font.caption).textSelection(.enabled)
            Spacer()
            if store.error != nil { ActionIcon(symbol: "xmark", size: 20) { store.error = nil } }
        }.foregroundStyle(color).padding(12).background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 24).padding(.bottom, 12)
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("连接飞书 CLI").font(Theme.Font.displayHero)
            Text("使用官方 lark-cli 的用户身份访问已授权的文档。登录在终端完成，ClaudeBar 不保存访问令牌。")
                .foregroundStyle(Theme.textSecondary)
            Text("1. 安装官方 lark-cli\n2. lark-cli config init --new --brand feishu\n3. lark-cli auth login --recommend\n4. lark-cli auth status")
                .font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 10))
            Text("搜索、云空间、知识库、评论及协作者分别需要对应权限；若应用未授权，请在飞书开放平台与 CLI 中完成授权后刷新。")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            Link("官方安装与权限说明", destination: URL(string: "https://github.com/larksuite/cli")!)
            HStack { Spacer(); ActionButton("完成", tone: .accent, emphasis: .primary) { showSetup = false }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 520).background(Theme.cardSurface)
    }
}

private struct FeishuDocumentRow: View {
    let document: FeishuDocument
    let selected: Bool
    var body: some View {
        HStack(spacing: 12) {
            FeishuDocumentGlyph(document: document, size: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(document.title.isEmpty ? "未命名" : document.title).font(Theme.Font.caption.weight(.medium)).lineLimit(2)
                Text(document.type.uppercased() + (document.modified.isEmpty ? "" : " · " + Self.date(document.modified)))
                    .font(Theme.Font.micro).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if document.isFolder { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.textSecondary) }
        }
        .foregroundStyle(Theme.textPrimary).padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.claude.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
    private static func date(_ value: String) -> String {
        if let number = Double(value) { return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number).formatted(date: .abbreviated, time: .omitted) }
        return value
    }
}

/// The native text view lays out only its visible region and handles large Markdown
/// without a SwiftUI Text node for every line, paragraph, or keystroke.
private final class FeishuTextScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView else { return }
        text.setFrameSize(NSSize(width: contentSize.width, height: max(contentSize.height, text.frame.height)))
    }
}

private struct FeishuDocumentReader: NSViewRepresentable {
    let content: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FeishuTextScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
        text.isRichText = false; text.textContainerInset = NSSize(width: 22, height: 20)
        text.autoresizingMask = [.width]; text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.layoutManager?.allowsNonContiguousLayout = true
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        if text.string != content {
            text.string = content
            text.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        text.font = .systemFont(ofSize: 14)
        text.textColor = Theme.isDark ? .white : .labelColor
    }
}

/// App-owned document mark: a folded page and a blue/cyan ribbon. Static paths,
/// no bitmap decoding or continuously animated layers on the document workspace.
private struct FeishuWorkspaceMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 48
            context.scaleBy(x: scale, y: scale)
            let paper = Path(roundedRect: CGRect(x: 12, y: 8, width: 26, height: 33), cornerRadius: 5)
            context.fill(paper, with: .color(Theme.claude.opacity(0.12)))
            var wing = Path()
            wing.move(to: CGPoint(x: 7, y: 27))
            wing.addLine(to: CGPoint(x: 33, y: 13))
            wing.addLine(to: CGPoint(x: 25, y: 34))
            wing.addLine(to: CGPoint(x: 21, y: 26))
            wing.closeSubpath()
            context.fill(wing, with: .linearGradient(Gradient(colors: [Theme.claude, Color(hex: 0x29B8D8)]), startPoint: CGPoint(x: 9, y: 27), endPoint: CGPoint(x: 32, y: 14)))
            var tail = Path()
            tail.move(to: CGPoint(x: 21, y: 26))
            tail.addLine(to: CGPoint(x: 14, y: 35))
            tail.addLine(to: CGPoint(x: 16, y: 24))
            tail.closeSubpath()
            context.fill(tail, with: .color(Theme.Ink.claude))
        }.accessibilityHidden(true)
    }
}

private struct FeishuDocumentGlyph: View {
    let document: FeishuDocument
    var size: CGFloat = 36
    private var tint: Color {
        switch document.type {
        case "folder": return Theme.Ink.warning
        case "wiki": return Theme.Ink.cursor
        case "sheet", "bitable": return Theme.Ink.success
        default: return Theme.Ink.claude
        }
    }
    var body: some View {
        Image(systemName: document.symbol)
            .font(.system(size: size * 0.45, weight: .medium)).symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint).frame(width: size, height: size)
            .background(tint.opacity(Theme.isDark ? 0.13 : 0.065), in: RoundedRectangle(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }
}
