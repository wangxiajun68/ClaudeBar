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
    private let editingEnabled: Bool
    @State private var located: [DocumentMarkup.LocatedBlock] = []
    @State private var sourceBuffer = ""
    @State private var lastPublished = ""
    @State private var activeIndex: Int?
    @State private var parseGeneration = UUID()
    @State private var bodies: [Int: String] = [:]
    @StateObject private var navigator = DocumentFocusNavigator()
    init(file: URL) { self.file = file; content = nil; documentNavigation = false; onEdit = nil; editingEnabled = false }
    init(content: String, documentNavigation: Bool = false, editingEnabled: Bool = true, onEdit: ((String) -> Void)? = nil) { file = nil; self.content = content; self.documentNavigation = documentNavigation; self.onEdit = onEdit; self.editingEnabled = editingEnabled }
    @State private var blocks: [MarkdownBlock] = []
    @State private var message: String?
    @State private var loading = true
    @State private var outlineExpanded = true
    @State private var availableWidth: CGFloat = 800
    @State private var viewportWidth: CGFloat = 1000
    @State private var compactOutline = false
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
                        .padding(.leading, outlineExpanded && !headings.isEmpty && viewportWidth >= 850 ? 218 : 0)
                        if outlineExpanded && !headings.isEmpty && viewportWidth >= 850 {
                            DocumentOutlinePanel(headings: headings, onClose: { outlineExpanded = false }) { heading in
                                proxy.scrollTo(heading.id, anchor: .top)
                            }.frame(width: 200).padding(10)
                        } else {
                            ActionIcon(symbol: "list.bullet.indent", tint: Theme.Ink.claude, size: 28) { if viewportWidth < 850 { compactOutline = true } else { outlineExpanded = true } }
                                .help("展开文档目录").padding(10).disabled(headings.isEmpty)
                                .popover(isPresented: $compactOutline) {
                                    DocumentOutlinePanel(headings: headings, onClose: { compactOutline = false }) { heading in
                                        proxy.scrollTo(heading.id, anchor: .top); compactOutline = false
                                    }.frame(width: 230).padding(8)
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            } else { renderContent(proxy: nil) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .task(id: (content ?? file?.path ?? "") + parseGeneration.uuidString) {
            if activeIndex != nil && content == lastPublished { return }
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
                sourceBuffer = content ?? ""
                lastPublished = ""
                bodies = [:]
                located = parsed
                blocks = parsed.map(\.block)
                if blocks.isEmpty && onEdit != nil {
                    blocks = [.paragraph("")]
                    located = [.init(block: .paragraph(""), range: NSRange(location: sourceBuffer.utf16.count, length: 0))]
                }
                navigator.order = located.indices.map { String($0) }
                headings = DocumentMarkup.outline(blocks)
                if parsed.isEmpty && onEdit == nil { message = "文档没有可预览的内容" }
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
            LazyVStack(alignment: .leading, spacing: 0) {
                let rows = flowRows
                ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                    rowBody(row).padding(.top, offset == 0 ? 0 : rowGap(rows[offset - 1], row))
                }
            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        }
    }
    @ViewBuilder private func blockView(_ block: MarkdownBlock, index: Int) -> some View {
        let chrome = located.indices.contains(index) ? located[index].chrome : DocumentMarkup.Chrome()
        switch block {
        case .heading(let level, let value):
            let size = documentNavigation ? [32.0, 25, 20, 17, 15, 14][min(5, max(0, level - 1))] : 0
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if documentNavigation && !chrome.sequence.isEmpty {
                    Text(chrome.sequence).font(.system(size: max(12, size * 0.62), design: .monospaced)).foregroundStyle(Theme.textSecondary)
                }
                richText(index, fallback: value, size: size == 0 ? 16 : size, weight: .semibold)
                    .font(documentNavigation ? nil : (level == 1 ? Theme.Font.titleSmall : (level == 2 ? Theme.Font.section : Theme.Font.chromeEmph)))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            .frame(maxWidth: documentNavigation ? 740 : .infinity, alignment: horizontal(chrome.align))
            .multilineTextAlignment(textAlign(chrome.align))
            .padding(.top, documentNavigation ? (level == 1 ? 4 : 6) : Theme.Space.s8)
            .padding(.bottom, documentNavigation ? 2 : 0)
        case .paragraph(let value):
            richText(index, fallback: value, size: documentNavigation ? 15 : 13)
                .font(documentNavigation ? nil : Theme.Font.bodySmall)
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(documentNavigation ? 7 : 4)
                .multilineTextAlignment(textAlign(chrome.align))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: documentNavigation ? 740 : .infinity, alignment: horizontal(chrome.align))
        case .bullet(let depth, let value):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                Text("•").foregroundStyle(Theme.Ink.claude)
                richText(index, fallback: value, size: documentNavigation ? 15 : 13).foregroundStyle(Theme.textPrimary)
            }
            .font(documentNavigation ? nil : Theme.Font.bodySmall)
            .padding(.leading, CGFloat(min(depth, 8)) * 20)
        case .numbered(let depth, let number, let value):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                Text(number).font(documentNavigation ? .system(size: 15, design: .rounded) : Theme.Font.bodySmall).foregroundStyle(Theme.Ink.claude).frame(minWidth: 22, alignment: .trailing)
                richText(index, fallback: value, size: documentNavigation ? 15 : 13).foregroundStyle(Theme.textPrimary)
            }
            .padding(.leading, CGFloat(min(depth, 8)) * 20)
        case .quote(let value):
            richText(index, fallback: value, size: documentNavigation ? 15 : 13)
                .font(documentNavigation ? nil : Theme.Font.bodySmall)
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(documentNavigation ? 6 : 4)
                .padding(.leading, 14)
                .frame(maxWidth: documentNavigation ? 740 : .infinity, alignment: .leading)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(Theme.Ink.claude.opacity(0.45)).frame(width: 3) }
        case .callout(let value):
            calloutCard(chrome) {
                richText(index, fallback: value, size: documentNavigation ? 15 : 13)
                    .lineSpacing(6).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let language, let value):
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                if !chrome.caption.isEmpty {
                    Text(chrome.caption).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                }
                HStack {
                    Text(language.isEmpty ? (chrome.language.isEmpty ? "代码" : chrome.language) : language)
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
            if documentNavigation, located.indices.contains(index), let model = located[index].table {
                DocumentTableView(source: sourceSlice(index), model: model, editable: onEdit != nil && editingEnabled, onFocus: { focused(index, $0) }) {
                    replaceBlock(index, with: $0)
                }
            } else {
            let columnCount = rows.map(\.count).max() ?? 0
            let widths = (0..<columnCount).map { column -> CGFloat in
                let values = rows.compactMap { $0.indices.contains(column) ? $0[column] : nil }
                let code = values.contains { $0.contains("```") }
                let longest = values.flatMap { $0.components(separatedBy: "\n") }.map(\.count).max() ?? 0
                return code ? 300 : max(145, min(260, CGFloat(longest) * 7 + 24))
            }
            let extra = max(0, availableWidth - widths.reduce(0) { $0 + $1 + 24 }) / CGFloat(max(1, columnCount))
            ScrollView(.horizontal) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<columnCount, id: \.self) { column in
                                tableCell(column < row.count ? row[column] : "", header: rowIndex == 0)
                                    .frame(width: widths[column] + extra, alignment: .topLeading).padding(12)
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
            }
        case .task(let depth, let checked, let value):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { toggleTask(index, depth: depth, checked: checked, value: value) } label: {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle").foregroundStyle(checked ? Theme.Ink.success : Theme.textSecondary)
                }.buttonStyle(.plain).disabled(onEdit == nil || !editingEnabled).help(checked ? "标记为未完成" : "标记为完成")
                richText(index, fallback: value, size: documentNavigation ? 15 : 13)
                    .foregroundStyle(checked && documentNavigation ? Theme.textSecondary : Theme.textPrimary)
                    .strikethrough(checked && documentNavigation)
            }.padding(.leading, CGFloat(min(depth, 8)) * 20)
        case .embed(let title, let kind):
            embedCard(title, kind: kind, chrome: chrome)
        case .image(let alt, let address):
            VStack(alignment: chrome.align == "center" ? .center : .leading, spacing: 8) {
                if let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFit().frame(maxWidth: chrome.width > 0 ? chrome.width : 740, maxHeight: chrome.height > 0 ? chrome.height : 480)
                        case .empty: ProgressView("加载图片…").frame(maxWidth: .infinity, minHeight: 80)
                        default: Label("图片暂无法加载，可在飞书中查看", systemImage: "photo").foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Link(alt.isEmpty ? "打开原图" : alt, destination: url).font(Theme.Font.caption).help("在浏览器中打开原图")
                } else {
                    Label(alt.isEmpty ? (chrome.caption.isEmpty ? "图片" : chrome.caption) : alt, systemImage: "photo")
                    Text("此图片需要飞书访问权限，请使用文档工具栏在飞书中查看。")
                        .font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
                }
                if !chrome.caption.isEmpty && chrome.caption != alt { Text(chrome.caption).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
            }.padding(12).frame(maxWidth: .infinity, alignment: horizontal(chrome.align))
        case .rule:
            HairlineDivider().padding(.vertical, Theme.Space.s4)
        }
    }

    @ViewBuilder private func tableCell(_ value: String, header: Bool) -> some View {
        if value.contains("```") {
            ScrollView(.horizontal) {
                Text(value.replacingOccurrences(of: "(?m)^```[^\n]*\n?", with: "", options: .regularExpression))
                    .font(.system(size: documentNavigation ? 13 : 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary).lineSpacing(4)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(8)
            }.background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 5))
        } else {
            inline(value).font(.system(size: documentNavigation ? 14 : 12, weight: header ? .semibold : .regular))
                .foregroundStyle(Theme.textPrimary).lineSpacing(3)
        }
    }

    private func focused(_ index: Int, _ value: Bool) {
        if value { activeIndex = index; navigator.activeID = String(index) }
        else if activeIndex == index { activeIndex = nil; parseGeneration = UUID() }
    }
    private func replaceBlock(_ index: Int, with replacement: String) {
        guard located.indices.contains(index), onEdit != nil, editingEnabled else { return }
        let range = located[index].range
        guard let updated = DocumentMarkup.replacing(range, in: sourceBuffer, with: replacement) else { return }
        let delta = replacement.utf16.count - range.length
        for other in located.indices where other != index && located[other].range.location >= range.upperBound {
            located[other].range.location += delta
        }
        located[index].range.length = replacement.utf16.count
        sourceBuffer = updated; lastPublished = updated
        onEdit?(updated)
    }
    private func markup(_ index: Int, body: String, prefix: String, suffix: String = "", literal: Bool = false) -> String {
        guard located.indices.contains(index), let tag = located[index].htmlTag else { return prefix + body + suffix }
        let html = literal ? DocumentRichText.escapedHTML(body) : DocumentRichText.html(body)
        if tag.isEmpty { return html }
        let original = (sourceBuffer as NSString).substring(with: located[index].range)
        // Preserve attributes such as anchors, alignment and exported colors.
        if let open = original.range(of: "^<[^>]+>", options: .regularExpression),
           let close = original.range(of: "</" + tag + ">\\s*$", options: [.regularExpression, .caseInsensitive]) {
            return String(original[open]) + html + String(original[close])
        }
        return "<" + tag + ">" + html + "</" + tag + ">"
    }
    private func textBlock(_ index: Int, value: String, prefix: String = "", size: CGFloat = 15, bold: Bool = false,
                           literal: Bool = false, suffix: String = "") -> some View {
        DocumentInlineEditor(markdown: bodies[index] ?? value, fontSize: size, editable: editingEnabled, semibold: bold, literal: literal, focusedOnAppear: true,
                             onFocus: { focused(index, $0) },
                             onBoundary: { direction in
                                 let next = index + direction
                                 guard blocks.indices.contains(next), canEdit(blocks[next], index: next) else { return false }
                                 activeIndex = next
                                 return true
                             },
                             onView: { navigator.register($0, id: String(index)) }) { body in
            bodies[index] = body
            let replacement: String
            if literal && located[index].htmlTag == nil {
                replacement = DocumentMarkup.fencedCode(body, language: String(prefix.dropFirst(3)).trimmingCharacters(in: .newlines))
            } else { replacement = markup(index, body: body, prefix: prefix, suffix: suffix, literal: literal) }
            replaceBlock(index, with: replacement)
        }
    }
    @ViewBuilder private func editableBlock(_ block: MarkdownBlock, index: Int) -> some View {
        switch block {
        case .heading(let level, let value):
            textBlock(index, value: value, prefix: String(repeating: "#", count: level) + " ",
                      size: [32, 25, 20, 17, 15, 14][min(5, max(0, level - 1))], bold: true)
                .padding(.top, level == 1 ? 12 : 22).padding(.bottom, 6).accessibilityAddTraits(.isHeader)
        case .paragraph(let value):
            textBlock(index, value: value).frame(maxWidth: 740, alignment: .leading)
                .overlay(alignment: .topLeading) {
                    if value.isEmpty && (bodies[index] ?? "").isEmpty {
                        Text("开始输入正文…").font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
                            .padding(.top, 3).allowsHitTesting(false)
                    }
                }
        case .bullet(let depth, let value):
            HStack(alignment: .top, spacing: 8) {
                Text("•").foregroundStyle(Theme.Ink.claude).padding(.top, 3)
                textBlock(index, value: value, prefix: String(repeating: "  ", count: depth) + "- ")
            }.padding(.leading, CGFloat(min(depth, 8)) * 20)
        case .numbered(let depth, let number, let value):
            HStack(alignment: .top, spacing: 8) {
                Text(number).foregroundStyle(Theme.Ink.claude).padding(.top, 3)
                textBlock(index, value: value, prefix: String(repeating: "  ", count: depth) + number + " ")
            }.padding(.leading, CGFloat(min(depth, 8)) * 20)
        case .task(let depth, let checked, let value):
            HStack(alignment: .top, spacing: 8) {
                Button {
                    toggleTask(index, depth: depth, checked: checked, value: value)
                } label: { Image(systemName: checked ? "checkmark.circle.fill" : "circle").foregroundStyle(checked ? Theme.Ink.success : Theme.textSecondary) }
                    .buttonStyle(.plain).padding(.top, 4).disabled(!editingEnabled).help(checked ? "标记为未完成" : "标记为完成")
                textBlock(index, value: value, prefix: String(repeating: "  ", count: depth) + (checked ? "- [x] " : "- [ ] "))
            }.padding(.leading, CGFloat(min(depth, 8)) * 20)
        case .quote(let value):
            textBlock(index, value: value, prefix: "> ").padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.textSecondary).frame(width: 1) }
        case .callout(let value):
            calloutCard(located.indices.contains(index) ? located[index].chrome : DocumentMarkup.Chrome()) {
                textBlock(index, value: value)
            }
        case .code(let language, let value):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(language.isEmpty ? "代码" : language).font(Theme.Font.microMedium).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(bodies[index] ?? value, forType: .string) }
                        .buttonStyle(.plain).font(Theme.Font.microMedium).help("复制代码")
                }
                textBlock(index, value: value, prefix: "```" + language + "\n", size: 13, literal: true, suffix: "\n```")
            }.padding(12).background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 8))
        case .table(let rows):
            if located.indices.contains(index) {
                DocumentTableView(source: (sourceBuffer as NSString).substring(with: located[index].range), model: located[index].table ?? DocumentTable(rows: rows),
                                  editable: editingEnabled, onFocus: { focused(index, $0) }) { replaceBlock(index, with: $0) }
            }
        default: blockView(block, index: index)
        }
    }

    private struct FlowRow: Identifiable { let id: Int; let indices: [Int]; let role: String? }
    private var flowRows: [FlowRow] {
        var rows: [FlowRow] = []
        var index = 0
        while index < blocks.count {
            let role = located.indices.contains(index) ? located[index].role : nil
            let group = located.indices.contains(index) ? located[index].group : nil
            if let group, ["grid", "callout", "blockquote", "okr"].contains(role ?? "") {
                var end = index + 1
                while end < blocks.count && end < located.count && located[end].group == group { end += 1 }
                rows.append(FlowRow(id: index, indices: Array(index..<end), role: role))
                index = end
            } else { rows.append(FlowRow(id: index, indices: [index], role: nil)); index += 1 }
        }
        return rows
    }
    private func rowGap(_ previous: FlowRow, _ row: FlowRow) -> CGFloat {
        guard documentNavigation else { return Theme.Space.s12 }
        func listLike(_ row: FlowRow) -> Bool {
            row.indices.allSatisfy { index in
                if !blocks.indices.contains(index) { return false }
                switch blocks[index] { case .bullet, .numbered, .task: return true; default: return false }
            }
        }
        if listLike(previous) && listLike(row) && previous.role == row.role { return 2 }
        if blocks.indices.contains(row.indices[0]), case .heading(let level, _) = blocks[row.indices[0]] { return level == 1 ? 18 : 16 }
        return 14
    }
    @ViewBuilder private func rowBody(_ row: FlowRow) -> some View {
        if row.role == "grid" { gridRow(row.indices) }
        else if row.role == "callout", located.indices.contains(row.indices[0]) {
            calloutCard(located[row.indices[0]].chrome) { clusterStack(row.indices) }
        } else if row.role == "blockquote" {
            clusterStack(row.indices).padding(.leading, 14)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(Theme.Ink.claude.opacity(0.45)).frame(width: 3) }
        } else if row.role == "okr", located.indices.contains(row.indices[0]) {
            VStack(alignment: .leading, spacing: 8) {
                if !located[row.indices[0]].chrome.caption.isEmpty {
                    Text(located[row.indices[0]].chrome.caption).font(Theme.Font.microMedium).foregroundStyle(Theme.textSecondary)
                }
                clusterStack(row.indices)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        } else { one(row.indices[0]) }
    }
    private func clusterStack(_ indices: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 6) { ForEach(indices, id: \.self) { one($0) } }
    }
    private func gridRow(_ indices: [Int]) -> some View {
        let count = max(1, located[indices[0]].chrome.columns)
        let ratios = (0..<count).map { column -> Double in
            let ratio = indices.first { located[$0].chrome.column == column }.map { located[$0].chrome.ratio } ?? 0
            return ratio > 0 ? ratio : 1 / Double(count)
        }
        let total = max(0.01, ratios.reduce(0, +))
        let gap = CGFloat(12)
        let inner = max(CGFloat(count) * 140, availableWidth - gap * CGFloat(max(0, count - 1)))
        return HStack(alignment: .top, spacing: gap) {
            ForEach(0..<count, id: \.self) { column in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(indices.filter { located.indices.contains($0) && located[$0].chrome.column == column }, id: \.self) { one($0) }
                }
                .padding(12)
                .frame(width: max(140, inner * CGFloat(ratios[column] / total)), alignment: .topLeading)
                .background(Theme.bgSecondary.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
            }
        }
    }
    @ViewBuilder private func one(_ index: Int) -> some View {
        if blocks.indices.contains(index), canEdit(blocks[index], index: index), activeIndex == index {
            editableBlock(blocks[index], index: index).id(index)
        } else if blocks.indices.contains(index) {
            blockView(blocks[index], index: index).id(index)
                .contentShape(Rectangle())
                .onTapGesture { if canEdit(blocks[index], index: index) { activeIndex = index } }
        }
    }
    private func canEdit(_ block: MarkdownBlock, index: Int) -> Bool {
        guard onEdit != nil, editingEnabled, documentNavigation else { return false }
        if located.indices.contains(index), located[index].role == "okr" { return false }
        switch block {
        case .heading, .paragraph, .bullet, .numbered, .quote, .callout, .code, .task: return true
        default: return false
        }
    }
    private func sourceSlice(_ index: Int) -> String {
        guard located.indices.contains(index) else { return "" }
        let range = located[index].range
        let total = (sourceBuffer as NSString).length
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= total else { return "" }
        return (sourceBuffer as NSString).substring(with: range)
    }
    private func toggleTask(_ index: Int, depth: Int, checked: Bool, value: String) {
        if located.indices.contains(index), located[index].htmlTag == "checkbox" {
            let raw = sourceSlice(index)
            let next = checked ? "false" : "true"
            var updated = raw
            if let range = raw.range(of: "done=\"(?:true|false)\"", options: .regularExpression) { updated.replaceSubrange(range, with: "done=\"\(next)\"") }
            else if let start = raw.range(of: "<checkbox") { updated.replaceSubrange(start, with: "<checkbox done=\"\(next)\"") }
            replaceBlock(index, with: updated)
        } else {
            replaceBlock(index, with: String(repeating: "  ", count: depth) + (checked ? "- [ ] " : "- [x] ") + (bodies[index] ?? value))
        }
        if blocks.indices.contains(index) { blocks[index] = .task(depth, !checked, bodies[index] ?? value) }
    }
    private func horizontal(_ align: String) -> Alignment {
        switch align { case "center": return .center; case "right": return .trailing; default: return .leading }
    }
    private func textAlign(_ align: String) -> TextAlignment {
        switch align { case "center": return .center; case "right": return .trailing; default: return .leading }
    }
    private func richText(_ index: Int, fallback: String, size: CGFloat, weight: Font.Weight = .regular) -> Text {
        let source = sourceSlice(index)
        guard let spans = DocumentMarkup.inlineSpans(source.isEmpty ? fallback : source) else { return inline(fallback) }
        var attributed = AttributedString()
        for span in spans {
            var run = AttributedString(span.text)
            var font = Font.system(size: span.code || span.math ? max(12, size - 1) : size, weight: span.strong || weight == .semibold ? .semibold : weight, design: span.code || span.math ? .monospaced : .default)
            if span.emphasis { font = font.italic() }
            run.font = font
            if span.underline { run.underlineStyle = .single }
            if span.strike { run.strikethroughStyle = .single }
            if span.code { run.backgroundColor = Theme.bgSecondary }
            if span.mention { run.backgroundColor = Theme.claude.opacity(0.12) }
            if let hex = DocumentPalette.ink(span.textColor) { run.foregroundColor = Color(hex: hex) }
            else if span.mention || span.link != nil { run.foregroundColor = Theme.Ink.claude }
            else { run.foregroundColor = Theme.textPrimary }
            if let fill = DocumentPalette.fill(span.background) { run.backgroundColor = Color(hex: fill.0, opacity: fill.1) }
            if let link = span.link.flatMap(URL.init(string:)), DocumentRichText.allowedURL(link) { run.link = link }
            attributed += run
        }
        return Text(attributed)
    }
    private func calloutCard(_ chrome: DocumentMarkup.Chrome, @ViewBuilder content: () -> some View) -> some View {
        let background = chrome.background.isEmpty ? "light-blue" : chrome.background
        let fill = DocumentPalette.fill(background)
        let border = DocumentPalette.ink(chrome.border.isEmpty ? "blue" : chrome.border) ?? 0x3D7DFF
        return HStack(alignment: .top, spacing: 10) {
            Text(chrome.emoji.isEmpty ? "💡" : chrome.emoji).font(.system(size: 18)).accessibilityHidden(true)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: fill?.0 ?? 0x3D7DFF, opacity: fill?.1 ?? 0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { Rectangle().fill(Color(hex: border)).frame(width: 3) }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: border, opacity: 0.28)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private func embedCard(_ title: String, kind: String, chrome: DocumentMarkup.Chrome) -> some View {
        let symbol = ["whiteboard": "scribble.variable", "file": "paperclip", "bookmark": "link", "button": "arrow.up.right.square", "time": "bell", "task": "checklist", "chat": "bubble.left.and.bubble.right", "pages": "list.bullet.rectangle", "html": "chevron.left.forwardslash.chevron.right", "sheet": "tablecells", "bitable": "square.grid.3x3", "video": "play.rectangle", "audio": "waveform"][kind] ?? "rectangle.on.rectangle"
        let diagram = ["mermaid", "plantuml", "svg"].contains(chrome.language.lowercased()) && !chrome.caption.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Theme.Ink.claude)
                    .frame(width: 34, height: 34).background(Theme.claude.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.isEmpty ? "嵌入内容" : title).font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    if kind == "time", !chrome.caption.isEmpty { Text(chrome.caption).font(Theme.Font.micro).foregroundStyle(Theme.textSecondary) }
                    else if let url = URL(string: chrome.link), DocumentRichText.allowedURL(url) {
                        Link(url.host ?? url.absoluteString, destination: url).font(Theme.Font.micro).help("在浏览器中打开")
                    } else {
                        Text(diagram ? "画板源码保留在下方，完整图形请在飞书中查看。" : "此嵌入内容需在飞书中查看，可使用工具栏的打开按钮。")
                            .font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if diagram {
                ScrollView(.horizontal) {
                    Text(chrome.caption).font(Theme.Font.captionMono).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: true, vertical: false)
                }.padding(8).frame(maxHeight: 160).background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
    }

    private func inline(_ raw: String) -> Text {
        if var value = try? AttributedString(markdown: raw,
                                              options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            for run in value.runs {
                if run.inlinePresentationIntent?.contains(.code) == true {
                    value[run.range].font = .system(size: documentNavigation ? 14 : 12, design: .monospaced)
                    value[run.range].backgroundColor = Theme.bgSecondary
                }
                if run.link != nil { value[run.range].foregroundColor = Theme.Ink.claude }
            }
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
                                DocumentOutlineTitle(title: heading.title)
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

/// Keep Markdown decoding in a leaf with only the title as input. Selection or
/// an unrelated outline change must not reparse every visible heading.
private struct DocumentOutlineTitle: View {
    let title: String
    var body: some View {
        Text((try? AttributedString(markdown: title, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(title))
    }
}
