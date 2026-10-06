import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FeishuDocumentsView: View {
    var navigationWidth: CGFloat = 0
    @ObservedObject private var store = FeishuDocumentStore.shared
    @State private var search = ""
    @State private var tab = "正文"
    @State private var operation: FeishuOperation?
    @State private var showSetup = false
    @State private var typeFilter = "全部"
    @State private var showSource = false
    @State private var componentFailure: String?
    @State private var showDocuments = false
    @State private var editorOutlineVisible = true
    @State private var draftHeadings: [DocumentMarkup.Heading] = []
    @State private var draftLocated: [DocumentMarkup.LocatedBlock] = []
    @State private var draftOutlineText: String?
    @State private var editorJump: FeishuEditorJump?
    @State private var draftPreview = true
    @State private var confirmDiscard = false
    @FocusState private var titleFocused: Bool

    private var creationLocation: FeishuLocation { store.location.isRecent ? .root : store.location }
    private var shown: [FeishuDocument] {
        store.documents.filter { typeFilter == "全部" || (typeFilter == "文档" ? $0.isDocument : $0.isFolder) }
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = store.error { banner(error, symbol: "exclamationmark.triangle", color: Theme.Ink.error) }
            if let notice = store.notice { banner(notice, symbol: "checkmark.circle", color: Theme.Ink.success) }
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .background(Theme.bgPrimary)
        .task { store.start() }
        .onDisappear { store.suspend() }
        .task(id: search) {
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                store.search(search)
            } catch { }
        }
        .onChange(of: store.selected?.id) { _, _ in tab = "正文"; showSource = false; componentFailure = nil }
        .onChange(of: store.activeDraftID) { _, _ in draftPreview = true; titleFocused = store.activeDraft?.isNew == true }
        // The outline exists only for the source pane's left rail: the reader
        // renders its own headings and never reads `draftHeadings`. Keying the
        // task on the text alone made every keystroke in the reader re-parse
        // the whole document (350 ms later) for a panel that is not on screen.
        // `nil` while the reader is showing parks the task entirely; switching
        // to the source pane re-keys it to the current text.
        .task(id: draftPreview ? nil : store.activeDraft?.text) {
            do {
                try await Task.sleep(for: .milliseconds(350)); try Task.checkCancellation()
                let text = store.activeDraft?.text ?? ""
                guard text.utf8.count <= 512_000 else {
                    draftHeadings = []; draftLocated = []; draftOutlineText = nil
                    return
                }
                let worker = Task.detached(priority: .utility) {
                    let located = try DocumentMarkup.locatedBlocks(text)
                    let headings = DocumentMarkup.outline(located.map(\.block))
                    try Task.checkCancellation()
                    return (located, headings)
                }
                let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                draftLocated = prepared.0
                draftHeadings = prepared.1
                draftOutlineText = text
            } catch { }
        }
        .onChange(of: tab) { _, value in if value != "正文" { store.loadAuxiliary(value) } }
        .sheet(item: $operation) { request in
            FeishuOperationSheet(request: request, store: store)
        }
        .sheet(isPresented: $showSetup) { setup }
        .onChange(of: store.authorizationURL) { _, url in if let url { NSWorkspace.shared.open(url) } }
        .confirmationDialog("丢弃当前草稿？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("丢弃草稿", role: .destructive) { store.discardDraft() }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s8) {
            if navigationWidth > 0 {
                Color.clear.frame(width: navigationWidth).accessibilityHidden(true)
            }
            Button { showDocuments.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text("文档")
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
            }.buttonStyle(.plain).headerControl().documentHelp("展开最近访问、文档列表与搜索")
                .popover(isPresented: $showDocuments, arrowEdge: .bottom) {
                    inventory.frame(width: 330, height: 540).padding(8).background(Theme.bgPrimary)
                }
            if store.preview { Text("DEV · 示例").font(Theme.Font.micro).foregroundStyle(Theme.textSecondary) }
            Spacer()
            if !store.drafts.isEmpty {
                Menu {
                    ForEach(store.drafts.values.sorted { $0.id < $1.id }) { draft in
                        Button(draft.title.isEmpty ? "未命名草稿" : draft.title) { store.activeDraftID = draft.id }
                    }
                } label: { Label("草稿 \(store.drafts.count)", systemImage: "doc.badge.clock") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).documentHelp("继续编辑未保存的草稿")
            }
            Button { showSetup = true } label: {
                HStack(spacing: 5) {
                    Circle().fill(store.connection.ready ? Theme.Ink.success : Theme.textSecondary).frame(width: 5, height: 5)
                    Text(store.preview ? "连接设置" : store.connection.title).lineLimit(1)
                }
            }.buttonStyle(.plain).documentHelp("登录与连接状态")
            ActionIcon(symbol: "arrow.clockwise", tint: Theme.textSecondary) { store.refresh(force: true) }
                .disabled(store.loading || store.working || (!store.preview && !store.connection.ready)).documentHelp("刷新列表")
            ActionButton("新建", symbol: "doc.badge.plus") { store.newDocument() }
                .disabled(store.working || !store.location.space.isEmpty || (!store.preview && !store.connection.ready))
                .documentHelp("新建文档")
            ActionIcon(symbol: "folder.badge.plus", tint: Theme.textSecondary) { operation = .init(kind: .folder, location: creationLocation) }
                .documentHelp("新建文件夹").disabled(store.preview || store.working || !store.location.space.isEmpty)
            ActionIcon(symbol: "arrow.up.doc", tint: Theme.textSecondary) { operation = .init(kind: .upload, location: creationLocation) }
                .documentHelp("上传文件").disabled(store.preview || store.working || !store.location.space.isEmpty)
            ActionIcon(symbol: "doc.badge.arrow.up", tint: Theme.textSecondary) { operation = .init(kind: .importDocument, location: creationLocation) }
                .documentHelp("导入 Word / Markdown").disabled(store.preview || store.working || !store.location.space.isEmpty)
        }
        .font(Theme.Font.microMedium).foregroundStyle(Theme.textPrimary)
        .frame(height: 36)
        .padding(.horizontal, Theme.Space.s24)
        .padding(.top, Theme.Space.s12).padding(.bottom, Theme.Space.s12)
    }

    private var inventory: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    Button("最近访问 · 7 天") { navigate(.recentlyOpened(days: 7)) }
                    Button("最近访问 · 30 天") { navigate(.recentlyOpened(days: 30)) }
                    Button("最近访问 · 90 天") { navigate(.recentlyOpened(days: 90)) }
                    Divider()
                    Button("云空间") { navigate(.root) }
                    Button("个人文档库") { navigate(.library) }
                    if !store.spaces.isEmpty {
                        Divider()
                        ForEach(store.spaces) { space in Button(space.title) { navigate(space) } }
                    }
                } label: { Label(store.locations.first?.title ?? "最近访问", systemImage: store.location.isRecent ? "clock.arrow.circlepath" : "folder") }
                .buttonStyle(.borderless)
                Spacer()
                Text("\(shown.count)")
                    .font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
            }
            InstrumentSearchField(prompt: store.location.isRecent ? "搜索最近访问的文档" : "搜索全部飞书文档", text: $search).frame(height: 30)
            HStack {
                Text(store.location.isRecent ? "近 \(store.location.recentDays) 天 · 最近打开优先" : "按更新时间排序")
                    .font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                Menu {
                    ForEach(store.location.isRecent ? ["全部", "文档"] : ["全部", "文档", "文件夹"], id: \.self) { kind in
                        Button(kind) { typeFilter = kind }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18).documentHelp("筛选：" + typeFilter)
            }
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
            Divider()
            // List is the scroll owner: native row reuse, no eager stack around the inventory.
            List {
                ForEach(shown) { doc in
                    Button {
                        if doc.isFolder { search = ""; store.enter(doc) }
                        else { store.select(doc); showDocuments = false }
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
        .padding(10).panelCard()
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let draft = store.activeDraft, draft.isNew { editor(draft) }
            else if let doc = store.activeDraft?.document ?? store.selected {
                if let draft = store.activeDraft { draftToolbar(draft) } else {
                HStack(spacing: 8) {
                    FeishuDocumentGlyph(document: doc, size: 24)
                    Text(doc.title.isEmpty ? "未命名" : doc.title)
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1).textSelection(.enabled).layoutPriority(1)
                    Spacer(minLength: 8)
                    if store.detailLoading { ProgressView().controlSize(.mini) }
                    if store.drafts[doc.id] != nil { Text("草稿 · 未保存").font(Theme.Font.micro).foregroundStyle(Theme.textSecondary) }
                    if store.contentIsStale { Text(store.detailLoading ? "缓存 · 更新中" : "缓存 · 未更新").font(Theme.Font.micro).foregroundStyle(Theme.textSecondary) }
                    FeishuActionFlow(spacing: 3) {
                            documentTabs(doc)
                            Rectangle().fill(Theme.hairline).frame(width: 1, height: 16).padding(.horizontal, 4)
                            if tab == "正文" && doc.isDocument {
                                ActionIcon(symbol: showSource ? "text.alignleft" : "chevron.left.forwardslash.chevron.right", tint: showSource ? Theme.Ink.claude : Theme.textSecondary) { showSource.toggle() }
                                    .documentHelp(showSource ? "排版阅读" : "Markdown 源码")

                            }
                            visibleActions(doc)
                    }.frame(minWidth: 240, maxWidth: 580, alignment: .trailing)
                }.padding(.horizontal, 14).padding(.vertical, 8)
                }

                Divider()
                if tab == "正文" {
                    if let componentFailure, !showSource, store.activeDraft == nil, store.drafts[doc.id] == nil {
                        HStack(spacing: 8) {
                            Text(componentFailure + " 已切换到正文阅读。")
                                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            ActionButton("重试原版") { self.componentFailure = nil }
                        }.padding(12)
                    }
                    if doc.isDocument && store.activeDraft == nil && store.drafts[doc.id] == nil && !showSource && componentFailure == nil {
                        FeishuOfficialDocumentView(document: doc, onUnavailable: { reason in
                            guard store.selected?.id == doc.id else { return }
                            componentFailure = reason
                        })
                    } else if store.detailLoading && store.content.isEmpty {
                        Spacer(); HStack { Spacer(); ProgressView("正在读取文档…"); Spacer() }; Spacer()
                    } else if doc.isDocument {
                        if let draft = store.activeDraft, !draftPreview {
                            FeishuDocumentEditor(text: Binding(get: { store.activeDraft?.text ?? "" }, set: { store.updateDraft(text: $0) }), editable: !store.working, jump: editorJump).id(draft.id)
                        } else {
                            reader(store.activeDraft?.text ?? store.drafts[doc.id]?.text ?? store.content, source: showSource).id(doc.id)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("此类型请在飞书中查看内容", systemImage: doc.symbol)
                            Text("资源标识：\(doc.token)").textSelection(.enabled)
                            if !doc.modified.isEmpty { Text("修改时间：\(doc.modified)") }
                        }.font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).padding(20)
                        Spacer()
                    }
                } else { auxiliary(doc) }
                if doc.type == "wiki" && doc.hasChildren && !store.location.space.isEmpty {
                    ActionButton("浏览子文档", symbol: "folder") { search = ""; store.enter(doc) }.padding(10)
                }
            } else {
                Spacer()
                VStack(spacing: 14) {
                    StandbyEmptyState(label: store.connection.ready || store.preview ? "选择文档，开始阅读" : "连接你的飞书文档",
                                      symbol: "doc.text.image", tint: Theme.Ink.claude,
                                      caption: store.connection.ready || store.preview ? "展开顶部文档列表，或新建一篇文档。" : "在浏览器授权后，回到这里继续。", block: true)
                    if store.connection.ready || store.preview {
                        // Disabled where the header's is: a wiki space has no
                        // folder token to create into. The store refuses too —
                        // this is the visible half of the same rule.
                        ActionButton("新建文档", symbol: "plus", tone: .accent) { store.newDocument() }
                            .disabled(!store.location.space.isEmpty || store.working)
                    } else { ActionButton("连接飞书", tone: .accent) { showSetup = true } }
                }.frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Theme.textPrimary).panelCard()
    }

    @ViewBuilder private func reader(_ text: String, source: Bool = false) -> some View {
        if source || text.utf8.count > 512_000 {
            FeishuDocumentEditor(text: Binding(get: { store.activeDraft?.text ?? store.drafts[store.selected?.id ?? ""]?.text ?? text }, set: { updated in
                if store.activeDraft == nil { store.beginEditing() }
                store.updateDraft(text: updated)
            }), editable: !store.working && !store.detailLoading)
        }
        else {
            SkillMarkdownPreview(content: text, documentNavigation: true, editingEnabled: !store.detailLoading && !store.working, onEdit: { updated in
                guard !store.detailLoading && !store.working else { return }
                if store.activeDraft == nil { store.beginEditing() }
                store.updateDraft(text: updated)
            })
                .environment(\.openURL, OpenURLAction { url in DocumentRichText.allowedURL(url) ? .systemAction : .discarded })
        }
    }

    @ViewBuilder private func documentTabs(_ doc: FeishuDocument) -> some View {
        let names = doc.isDocument ? ["正文", "评论", "协作者", "历史"] : ["信息", "协作者"]
        ForEach(names, id: \.self) { name in
            let value = name == "信息" ? "正文" : name
            let symbol = name == "正文" || name == "信息" ? "doc.text" : name == "评论" ? "bubble.left" : name == "协作者" ? "person.2" : "clock.arrow.circlepath"
            ActionIcon(symbol: symbol, tint: tab == value ? Theme.Ink.claude : Theme.textSecondary) { tab = value }
                .background(tab == value ? Theme.claude.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .documentHelp(name).accessibilityLabel(name)
        }
    }

    @ViewBuilder private func visibleActions(_ doc: FeishuDocument) -> some View {
        if let url = doc.webURL {
            Link(destination: url) { Image(systemName: "arrow.up.right.square").font(.system(size: 13)).frame(width: 26, height: 26) }
                .foregroundStyle(Theme.textSecondary).documentHelp("在飞书中打开")
            ActionIcon(symbol: "link", tint: Theme.textSecondary) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }.documentHelp("复制文档链接")
        }
        ActionIcon(symbol: "arrow.clockwise", tint: Theme.textSecondary) { store.select(doc, force: true) }
            .documentHelp("刷新内容").disabled(!doc.isDocument || store.detailLoading || store.working)
        ActionIcon(symbol: "character.cursor.ibeam", tint: Theme.textSecondary) { operation = .init(kind: .rename, document: doc) }
            .documentHelp("重命名").disabled(store.preview || store.working)
        if !doc.isFolder {
            ActionIcon(symbol: "doc.on.doc", tint: Theme.textSecondary) { operation = .init(kind: .copy, document: doc, location: creationLocation) }
                .documentHelp("创建副本").disabled(store.preview || store.working)
        }
        if doc.type != "wiki" {
            ActionIcon(symbol: "folder", tint: Theme.textSecondary) { operation = .init(kind: .move, document: doc, location: creationLocation) }
                .documentHelp("移动到文件夹").disabled(store.preview || store.working)
        }
        if doc.isDocument {
            ActionIcon(symbol: "text.badge.plus", tint: Theme.textSecondary) { operation = .init(kind: .edit, document: doc, content: store.content, revision: store.revision) }
                .documentHelp("追加内容").disabled(store.preview || store.working || store.detailLoading)
            ForEach(["pdf", "docx", "markdown"], id: \.self) { format in
                ActionIcon(symbol: format == "pdf" ? "doc.richtext" : format == "docx" ? "doc.text" : "arrow.down.doc", tint: Theme.textSecondary) {
                    operation = .init(kind: .export, document: doc, format: format)
                }.documentHelp("导出 " + (format == "docx" ? "Word" : format == "pdf" ? "PDF" : "Markdown")).disabled(store.preview || store.working)
            }
        }
        if doc.type != "wiki" {
            ActionIcon(symbol: "trash", tint: Theme.Ink.error) { operation = .init(kind: .delete, document: doc) }
                .documentHelp("删除").disabled(store.preview || store.working)
        }
    }

    private func draftFooter(_ draft: FeishuDraft) -> String {
        let prefix = draft.isNew ? "创建于 " + draft.location.title : "Markdown · " + (draft.revision.isEmpty ? "示例" : "版本 " + draft.revision)
        return prefix + " · 点击正文直接输入 · 保存后同步飞书"
    }

    private func draftToolbar(_ draft: FeishuDraft) -> some View {
        HStack(spacing: 8) {
                if draft.isNew {
                    TextField("文档标题", text: Binding(get: { store.activeDraft?.title ?? "" }, set: { store.updateDraft(title: $0) }))
                        .textFieldStyle(.plain).font(.system(size: 14, weight: .semibold)).focused($titleFocused)
                } else { Text(draft.title).font(.system(size: 14, weight: .semibold)).lineLimit(1) }
                Spacer(minLength: 8)
                Text(store.preview ? "示例草稿" : draft.text == draft.original && !draft.isNew ? "尚无修改" : "未保存").font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
                ActionIcon(symbol: draftPreview ? "chevron.left.forwardslash.chevron.right" : "doc.text", tint: Theme.Ink.claude) { draftPreview.toggle() }
                    .documentHelp(draftPreview ? "编辑整篇 Markdown 源码" : "返回排版与就地编辑")
                ActionIcon(symbol: "doc.on.doc", tint: Theme.textSecondary) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(draft.text, forType: .string) }.documentHelp("复制草稿 Markdown")
                ActionIcon(symbol: "trash", tint: Theme.Ink.error) { confirmDiscard = true }.documentHelp("丢弃草稿").disabled(store.working)
                ActionIcon(symbol: "xmark", tint: Theme.textSecondary) { store.activeDraftID = nil }.documentHelp("保留草稿并返回阅读")
                ActionButton(draft.isNew ? "创建" : "保存", symbol: "checkmark", tone: .accent, emphasis: .primary) {
                    Task { _ = await store.saveDraft() }
                }.documentHelp(draft.isNew ? "创建飞书文档" : "保存草稿到飞书（⌘S）").keyboardShortcut("s", modifiers: .command).disabled(!draft.canSave || store.working || store.preview || !store.connection.ready)
                if store.working { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func editor(_ draft: FeishuDraft) -> some View {
        VStack(spacing: 0) {
            draftToolbar(draft)
            Divider()
            if draftPreview { reader(draft.text) }
            else {
                ZStack(alignment: .topLeading) {
                    FeishuDocumentEditor(text: Binding(get: { store.activeDraft?.text ?? "" }, set: { store.updateDraft(text: $0) }), editable: !store.working, jump: editorJump)
                        .id(draft.id)
                        .padding(.leading, editorOutlineVisible && !draftHeadings.isEmpty ? 218 : 0)
                    if editorOutlineVisible && !draftHeadings.isEmpty {
                        DocumentOutlinePanel(headings: draftHeadings, onClose: { editorOutlineVisible = false }) { heading in
                            if draftOutlineText == draft.text, store.activeDraft?.id == draft.id,
                               store.activeDraft?.text == draft.text,
                               let location = DocumentMarkup.sourceLocation(heading, in: draftLocated) {
                                editorJump = FeishuEditorJump(location: location)
                            }
                        }.frame(width: 200).padding(10)
                    } else {
                        ActionIcon(symbol: "list.bullet.indent", tint: Theme.Ink.claude, size: 28) { editorOutlineVisible = true }
                            .documentHelp("展开文档目录").padding(10).disabled(draftHeadings.isEmpty)
                    }
                }
            }
            HStack {
                Text(draftFooter(draft))
                Spacer()
                Text("\(draft.text.count) 字")
            }.font(Theme.Font.micro).foregroundStyle(Theme.textSecondary).padding(.horizontal, 16).padding(.vertical, 6)
        }
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
                        .documentHelp("移除此协作者的文档访问权限").accessibilityLabel("移除协作者")
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
        Button("刷新内容") { store.select(doc, force: true) }.disabled(!doc.isDocument || store.detailLoading || store.working)
        Divider()
        Button("重命名") { operation = .init(kind: .rename, document: doc) }.disabled(store.preview || store.working)
        if !doc.isFolder {
            Button("创建副本") { operation = .init(kind: .copy, document: doc, location: store.location) }.disabled(store.preview || store.working)
        }
        if doc.type != "wiki" {
            Button("移动到文件夹") { operation = .init(kind: .move, document: doc, location: store.location) }.disabled(store.preview || store.working)
        }
        if doc.isDocument {
            Button("追加内容") { operation = .init(kind: .edit, document: doc, content: store.content, revision: store.revision) }.disabled(store.preview || store.working || store.detailLoading)
            Button("导出 PDF / Word / Markdown") { operation = .init(kind: .export, document: doc) }.disabled(store.preview || store.working)
        }
        if doc.type != "wiki" {
            Divider()
            Button("删除", role: .destructive) { operation = .init(kind: .delete, document: doc) }.disabled(store.preview || store.working)
        }
    }
    private func navigate(_ location: FeishuLocation) { search = ""; typeFilter = "全部"; store.navigate(location) }
    private func banner(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top) {
            Image(systemName: symbol)
            Text(text).font(Theme.Font.caption).textSelection(.enabled)
            Spacer()
            ActionIcon(symbol: "xmark", size: 18) { if color == Theme.Ink.error { store.error = nil } else { store.notice = nil } }.documentHelp("关闭提示").accessibilityLabel("关闭提示")
        }.foregroundStyle(color).padding(8).background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16).padding(.bottom, 8)
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                FeishuWorkspaceMark().frame(width: 30, height: 30)
                Text("连接飞书").font(.system(size: 20, weight: .semibold))
                Spacer()
                ActionIcon(symbol: "xmark", tint: Theme.textSecondary) { showSetup = false }.documentHelp("关闭飞书连接设置").accessibilityLabel("关闭连接设置")
            }
            HStack(spacing: 8) {
                Circle().fill(store.connection.ready ? Theme.Ink.success : Theme.Ink.warning).frame(width: 7, height: 7)
                Text(store.preview ? "开发版 · 仅预览" : store.connection.title).font(Theme.Font.caption.weight(.semibold))
                if store.connection == .checking || store.connection == .waiting { ProgressView().controlSize(.small) }
            }
            Text(store.preview ? "开发版可体验阅读、编辑与草稿交互，真实登录和云端保存仅在正式版启用。" : "使用官方 CLI 的用户身份。授权在浏览器完成，令牌由 CLI 管理。")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            if store.connection == .waiting {
                Text("请在浏览器完成授权，此窗口可以关闭。完成后文档会自动加载。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                if let url = store.authorizationURL { Link("重新打开授权页面", destination: url) }
                ActionButton("取消本次登录") { store.cancelLogin() }
            } else {
                HStack {
                    ActionButton(store.connection.ready ? "重新授权" : "浏览器登录", symbol: "arrow.up.right", tone: .accent, emphasis: .primary) { store.beginLogin() }
                        .disabled(store.connection == .missingCLI)
                    ActionButton("检查连接", symbol: "arrow.clockwise") { store.checkConnection() }
                }.disabled(store.preview || store.connection == .checking || store.working)
            }
            if let error = store.error { Text(error).font(Theme.Font.caption).foregroundStyle(Theme.Ink.error) }
            Divider()
            Text("首次使用").font(Theme.Font.caption.weight(.semibold))
            Text("安装 lark-cli 并配置飞书应用后，即可在这里登录。需要文档搜索、云空间及知识库权限。")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            HStack {
                Text("lark-cli config init --new --brand feishu").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Spacer()
                ActionIcon(symbol: "doc.on.doc", tint: Theme.textSecondary) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString("lark-cli config init --new --brand feishu", forType: .string)
                }.documentHelp("复制配置命令")
            }.padding(12).background(Theme.fieldWell, in: RoundedRectangle(cornerRadius: 8))
            Link("安装与应用配置指南", destination: URL(string: "https://github.com/larksuite/cli")!).font(Theme.Font.caption)
        }.padding(24).frame(width: 480).foregroundStyle(Theme.textPrimary).background(Theme.cardSurface)
    }

}

/// Every action remains visible. Narrow workspaces wrap into another compact row.
private struct FeishuActionFlow: Layout {
    var spacing: CGFloat = 3
    private func positions(_ subviews: Subviews, width: CGFloat) -> (CGSize, [CGPoint]) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0, used: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += height + spacing; height = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing; used = max(used, x - spacing); height = max(height, size.height)
        }
        return (CGSize(width: used, height: y + height), points)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(subviews, width: max(26, proposal.width ?? 580)).0
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = positions(subviews, width: bounds.width).1
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + positions[index].x, y: bounds.minY + positions[index].y), anchor: .topLeading, proposal: .unspecified)
        }
    }
}

private struct FeishuDocumentRow: View {
    let document: FeishuDocument
    let selected: Bool
    var body: some View {
        HStack(spacing: 8) {
            FeishuDocumentGlyph(document: document, size: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(document.title.isEmpty ? "未命名" : document.title).font(Theme.Font.caption.weight(.medium)).lineLimit(2)
                Text(Self.kind(document.type) + (document.modified.isEmpty ? "" : " · " + Self.date(document.modified)))
                    .font(Theme.Font.micro).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if document.isFolder { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.textSecondary) }
        }
        .foregroundStyle(Theme.textPrimary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.claude.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()
    private static let timestampSeconds = ISO8601DateFormatter()
    private static func kind(_ type: String) -> String {
        switch type {
        case "docx", "doc": return "文档"
        case "wiki": return "知识库"
        case "sheet": return "表格"
        case "bitable": return "多维表格"
        case "folder": return "文件夹"
        case "slides": return "演示文稿"
        default: return "文件"
        }
    }
    private static func date(_ value: String) -> String {
        let date: Date?
        if let number = Double(value) { date = Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number) }
        else { date = timestamp.date(from: value) ?? timestampSeconds.date(from: value) }
        guard let date else { return value }
        if Calendar.current.isDateInToday(date) { return "今天 " + date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
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

private struct FeishuEditorJump { let id = UUID(); let location: Int }

private struct FeishuDocumentEditor: NSViewRepresentable {
    @Binding var text: String
    let editable: Bool
    var jump: FeishuEditorJump? = nil
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FeishuDocumentEditor
        var lastJump: UUID?
        init(_ parent: FeishuDocumentEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            let remaining = textView.string.utf8.count - ((textView.string as NSString).substring(with: affectedCharRange)).utf8.count
            return remaining + (replacementString?.utf8.count ?? 0) <= 8 * 1024 * 1024
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FeishuTextScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.isRichText = false; view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainerInset = NSSize(width: 28, height: 24)
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator; view.allowsUndo = true
        scroll.documentView = view
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        view.isEditable = editable
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.textColor = Theme.isDark ? .white : .labelColor
        view.insertionPointColor = view.textColor ?? .labelColor
        if let jump, context.coordinator.lastJump != jump.id {
            context.coordinator.lastJump = jump.id
            let range = NSRange(location: min(jump.location, (view.string as NSString).length), length: 0)
            view.setSelectedRange(range); view.scrollRangeToVisible(range)
            view.window?.makeFirstResponder(view)
        }
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

/// Native macOS help and a named accessibility action share the same copy.
private extension View {
    func documentHelp(_ title: String) -> some View {
        help(title).accessibilityLabel(title)
    }
}
