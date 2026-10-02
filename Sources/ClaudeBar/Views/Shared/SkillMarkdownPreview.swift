import AppKit
import SwiftUI

/// A native, selectable Markdown reading surface. Parsing is deliberately
/// bounded and runs off the main actor; no HTML or script is evaluated.
struct SkillMarkdownPreview: View {
    private enum PreviewError: Error { case tooLarge }
    private let file: URL?
    private let content: String?
    private let documentNavigation: Bool
    private let onEdit: ((String) -> Void)?
    @State private var located: [DocumentMarkup.LocatedBlock] = []
    @State private var editingIndex: Int?
    @State private var editingText = ""
    @State private var editingSource = ""
    @FocusState private var blockFocused: Bool
    init(file: URL) { self.file = file; content = nil; documentNavigation = false; onEdit = nil }
    init(content: String, documentNavigation: Bool = false, onEdit: ((String) -> Void)? = nil) { file = nil; self.content = content; self.documentNavigation = documentNavigation; self.onEdit = onEdit }
    @State private var blocks: [MarkdownBlock] = []
    @State private var message: String?
    @State private var loading = true
    @State private var outlineExpanded = true
    @State private var availableWidth: CGFloat = 800
    @State private var headings: [DocumentMarkup.Heading] = []

    var body: some View {
        Group {
            if documentNavigation {
                ScrollViewReader { proxy in
                    ZStack(alignment: .topLeading) {
                        ScrollView {
                            renderContent(proxy: proxy)
                                .frame(maxWidth: 980, alignment: .leading)
                                .padding(.horizontal, 32).padding(.vertical, 28)
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.leading, outlineExpanded && !headings.isEmpty ? 218 : 0)
                        if outlineExpanded && !headings.isEmpty {
                            DocumentOutlinePanel(headings: headings, onClose: { outlineExpanded = false }) { heading in
                                proxy.scrollTo(heading.id, anchor: .top)
                            }.frame(width: 200).padding(10)
                        } else {
                            ActionIcon(symbol: "list.bullet.indent", tint: Theme.Ink.claude, size: 28) { outlineExpanded = true }
                                .help("展开文档目录").padding(10).disabled(headings.isEmpty)
                        }
                    }
                }
            } else { renderContent(proxy: nil) }
        }
        .task(id: content ?? file?.path ?? "") {
            editingIndex = nil
            loading = true
            message = nil
            do {
                let worker = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    if let content {
                        guard content.utf8.count <= 512_000 else { throw PreviewError.tooLarge }
                        return try Self.parse(content)
                    }
                    guard let file else { return [DocumentMarkup.LocatedBlock]() }
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 512_000 else { throw PreviewError.tooLarge }
                    let data = try Data(contentsOf: file, options: .mappedIfSafe)
                    guard data.count <= 512_000 else { throw PreviewError.tooLarge }
                    try Task.checkCancellation()
                    return try Self.parse(String(decoding: data, as: UTF8.self))
                }
                let parsed = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                located = parsed
                blocks = parsed.map(\.block)
                headings = DocumentMarkup.outline(blocks)
                if parsed.isEmpty { message = "文档没有可预览的内容" }
            } catch is CancellationError {
                return
            } catch PreviewError.tooLarge {
                guard !Task.isCancelled else { return }
                message = "文档超过 512 KB，暂不预览。"
            } catch {
                guard !Task.isCancelled else { return }
                message = documentNavigation ? "无法渲染文档，可切换源码查看。" : "无法读取 SKILL.md，请检查文件是否仍在原位置。"
            }
            loading = false
        }
    }

    @ViewBuilder private func renderContent(proxy: ScrollViewProxy?) -> some View {
        if loading && blocks.isEmpty {
            ProgressView(content == nil ? "正在读取 Skill 文档" : "正在排版文档")
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if let message {
            StandbyEmptyState(label: message, symbol: "doc.text", tint: Theme.Ink.claude, block: true)
        } else {
            LazyVStack(alignment: .leading, spacing: documentNavigation ? 14 : Theme.Space.s12) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    VStack(alignment: .leading, spacing: 8) {
                        blockView(block)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { beginBlockEdit(index) }
                            .contextMenu {
                                if onEdit != nil { Button("就地编辑此内容") { beginBlockEdit(index) } }
                            }
                        if editingIndex == index { blockEditor(index) }
                    }.id(index)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        }
    }
    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let value):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                inline(value)
                    .font(documentNavigation ? .system(size: [32.0, 25, 20, 17, 15, 14][min(5, max(0, level - 1))], weight: .semibold) : (level == 1 ? Theme.Font.titleSmall : (level == 2 ? Theme.Font.section : Theme.Font.chromeEmph)))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)

            }.padding(.top, documentNavigation ? (level == 1 ? 12 : 22) : Theme.Space.s8)
                .padding(.bottom, documentNavigation ? 6 : 0)
        case .paragraph(let value):
            inline(value)
                .font(documentNavigation ? .system(size: 15) : Theme.Font.bodySmall)
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(documentNavigation ? 7 : 4)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let depth, let value):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                Text("•").foregroundStyle(Theme.Ink.claude)
                inline(value).foregroundStyle(Theme.textPrimary)
            }
            .font(documentNavigation ? .system(size: 15) : Theme.Font.bodySmall)
            .padding(.leading, CGFloat(min(depth, 8)) * 20)
        case .numbered(let depth, let number, let value):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                Text(number).foregroundStyle(Theme.Ink.claude)
                inline(value).foregroundStyle(Theme.textPrimary)
            }
            .font(documentNavigation ? .system(size: 15) : Theme.Font.bodySmall)
            .padding(.leading, CGFloat(min(depth, 8)) * 20)
        case .quote(let value):
            inline(value)
                .font(documentNavigation ? .system(size: 15) : Theme.Font.bodySmall)
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, Theme.Space.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.textSecondary).frame(width: 1)
                }
        case .code(let language, let value):
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                HStack {
                    Text(language.isEmpty ? "代码" : language)
                        .font(Theme.Font.microMedium)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.Font.microMedium)
                    .foregroundStyle(Theme.Ink.claude).help("复制代码到剪贴板")
                }
                ScrollView(.horizontal) {
                    Text(value)
                        .font(Theme.Font.captionMono)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(Theme.Space.s12)
            .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        case .table(let rows):
            let columnCount = rows.map(\.count).max() ?? 0
            let cellWidth = max(150, min(340, availableWidth / CGFloat(max(1, columnCount)) - 24))
            ScrollView(.horizontal) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<columnCount, id: \.self) { column in
                                tableCell(column < row.count ? row[column] : "", header: rowIndex == 0)
                                    .frame(width: cellWidth, alignment: .topLeading).padding(12)
                                    .frame(maxHeight: .infinity, alignment: .topLeading)
                                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .background(rowIndex == 0 ? Theme.bgOverlay : (rowIndex.isMultiple(of: 2) ? Theme.bgSecondary.opacity(0.45) : Theme.cardSurface))
                        if rowIndex < rows.count - 1 { HairlineDivider() }
                    }
                }.clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.hairline))
        case .task(let depth, let checked, let value):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(checked ? Theme.Ink.success : Theme.textSecondary)
                inline(value).foregroundStyle(Theme.textPrimary)
            }.font(documentNavigation ? .system(size: 15) : Theme.Font.bodySmall).padding(.leading, CGFloat(min(depth, 8)) * 20)
        case .embed(let title, let kind):
            HStack(spacing: 12) {
                Image(systemName: kind == "whiteboard" ? "scribble.variable" : kind == "file" ? "paperclip" : "rectangle.on.rectangle")
                    .font(.system(size: 18)).foregroundStyle(Theme.Ink.claude)
                    .frame(width: 36, height: 36).background(Theme.claude.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.Font.caption.weight(.semibold))
                    Text("此嵌入内容需在飞书中查看，可使用工具栏的打开按钮。")
                        .font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        case .image(let alt, let address):
            HStack(spacing: 10) {
                Image(systemName: "photo").foregroundStyle(Theme.Ink.claude)
                VStack(alignment: .leading, spacing: 4) {
                    Text(alt.isEmpty ? "图片" : alt).font(Theme.Font.caption)
                    Text("图片预览请在飞书中查看").font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if let url = URL(string: address), url.scheme == "https", url.user == nil { Link("打开图片", destination: url).font(Theme.Font.micro) }
            }.padding(12).background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 10))
        case .rule:
            HairlineDivider().padding(.vertical, Theme.Space.s4)
        }
    }

    @ViewBuilder private func tableCell(_ value: String, header: Bool) -> some View {
        if value.contains("```") {
            Text(value.replacingOccurrences(of: "(?m)^```[^\n]*\n?", with: "", options: .regularExpression))
                .font(.system(size: documentNavigation ? 13 : 12, design: .monospaced)).foregroundStyle(Theme.textPrimary).lineSpacing(4)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 5))
        } else {
            inline(value).font(.system(size: documentNavigation ? 14 : 12, weight: header ? .semibold : .regular))
                .foregroundStyle(Theme.textPrimary).lineSpacing(3)
        }
    }

    private func beginBlockEdit(_ index: Int) {
        guard onEdit != nil, editingIndex == nil, let content, located.indices.contains(index) else { return }
        editingSource = content
        editingText = (content as NSString).substring(with: located[index].range)
        editingIndex = index
        blockFocused = true
    }

    private func blockEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("编辑此内容 · Markdown / HTML").font(Theme.Font.caption.weight(.semibold))
                Spacer()
                Button("取消") { editingIndex = nil }.help("取消此处修改，保留原文")
                Button("应用到草稿") {
                    guard let content, content == editingSource,
                          let updated = DocumentMarkup.replacing(located[index].range, in: content, with: editingText) else { return }
                    editingIndex = nil
                    onEdit?(updated)
                }.help("只更新此内容；点击页面保存后才写入飞书")
                    .disabled(content != editingSource)
            }
            TextEditor(text: $editingText)
                .font(.system(size: 14, design: .monospaced))
                .scrollContentBackground(.hidden).focused($blockFocused)
                .frame(minHeight: 100, maxHeight: 260)
                .accessibilityLabel("当前内容的 Markdown 或 HTML")
            Text("其他内容保持排版。应用后可继续编辑，最后统一保存。")
                .font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
        }.padding(12)
            .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.claude, lineWidth: 1))
    }

    private func inline(_ raw: String) -> Text {
        if let value = try? AttributedString(markdown: raw,
                                              options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(value)
        }
        return Text(raw)
    }

    nonisolated private static func parse(_ source: String) throws -> [DocumentMarkup.LocatedBlock] {
        try DocumentMarkup.locatedBlocks(source)
    }
}

/// A floating outline shared by reading and editing; independent of the document list.
struct DocumentOutlinePanel: View {
    let headings: [DocumentMarkup.Heading]
    let onClose: () -> Void
    let onJump: (DocumentMarkup.Heading) -> Void
    @State private var selectedID: Int?
    var body: some View {
        let minimumLevel = headings.map(\.level).min() ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "list.bullet.indent").foregroundStyle(Theme.Ink.claude)
                Text("目录").font(Theme.Font.microSemibold)
                Text("\(headings.count)").font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
                Spacer()
                ActionIcon(symbol: "sidebar.left", tint: Theme.textSecondary, size: 20) { onClose() }.help("收起目录")
            }
            HairlineDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(headings) { heading in
                        Button { selectedID = heading.id; onJump(heading) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(heading.number).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.textSecondary.opacity(0.6))
                                Text((try? AttributedString(markdown: heading.title, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(heading.title))
                                    .font(Theme.Font.caption).foregroundStyle(Theme.textPrimary).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, CGFloat(max(0, heading.level - minimumLevel)) * 9)
                            .padding(.horizontal, 5).padding(.vertical, 5)
                            .background(selectedID == heading.id ? Theme.claude.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("跳转到 " + heading.title)
                    }
                }
            }.frame(height: min(370, CGFloat(max(1, headings.count)) * 34))
        }
        .padding(10).foregroundStyle(Theme.textPrimary)
        .background(Theme.cardSurface.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(Theme.isDark ? 0.22 : 0.07), radius: 12, x: 0, y: 4)
    }
}
