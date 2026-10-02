#!/usr/bin/env python3
"""Exercise production parsing, request construction and dev isolation without cloud access."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = [
    root / 'Sources/Shared/BuildChannel.swift',
    root / 'Sources/ClaudeBar/Utils/FeishuCLI.swift',
    root / 'Sources/ClaudeBar/Models/FeishuDocumentStore.swift',
    root / 'Sources/ClaudeBar/Models/DocumentTable.swift',
    root / 'Sources/ClaudeBar/Models/DocumentMarkup.swift',
]
view = (root / 'Sources/ClaudeBar/Views/Pages/FeishuOperationSheet.swift').read_text()
operation = view[view.index('struct FeishuOperation:'):view.index('struct FeishuOperationSheet:')]
arguments = view[view.index('    private func arguments()'):view.rindex('\n}')].replace('private func arguments', 'func arguments', 1)
fixture = operation + '''
struct CommandFixture {
    var request: FeishuOperation
    var title = "Title"
    var text = "Body"
    var destination = ""
    var mode = "append"
    var permission = "view"
    var exportFormat = "pdf"
    var localURL: URL? = URL(fileURLWithPath: "/tmp/mock-input.md")
    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
''' + arguments + '\n}\n'
rich_source = (root / 'Sources/ClaudeBar/Views/Shared/DocumentInlineEditor.swift').read_text()
rich_fixture = '''
import AppKit
import SwiftUI
enum Theme {
    static let textPrimary = Color.primary
    static let bgSecondary = Color.gray.opacity(0.1)
    enum Ink { static let claude = Color.blue }
}
''' + rich_source + (root / 'Sources/ClaudeBar/Views/Shared/DocumentTableView.swift').read_text().split('/// Cells stay editable;')[0]
swift = '\n'.join(p.read_text() for p in sources) + rich_fixture + fixture + r'''
@main struct Regression {
    @MainActor static func main() async throws {
        func json(_ value: String) throws -> FeishuJSON { try FeishuJSON.payload(Data(value.utf8)) }
        let drive = try json("""
        {"ok":true,"data":{"files":[{"token":"test-doc","name":"方案","type":"docx","url":"https://example.feishu.cn/docx/test-doc"}],"has_more":true,"page_token":"next"}}
        """)
        let page = FeishuPage.parse(drive)
        precondition(page.documents.count == 1 && page.cursor == "next")
        precondition(page.documents[0].isDocument && page.documents[0].webURL != nil)
        let search = try json("""
        {"results":[{"title_highlighted":"<h>项目</h><hb>计划</hb>","result_meta":{"doc_types":"DOCX","url":"https://team.feishu.cn/docx/abc","update_time_iso":"2026-10-02"}}],"has_more":false}
        """)
        let found = FeishuPage.parse(search).documents
        precondition(found.count == 1 && found[0].title == "项目计划" && found[0].token == "abc" && found[0].type == "docx")
        let wiki = try json("""
        {"nodes":[{"node_token":"node","obj_token":"doc","obj_type":"docx","title":"知识库","has_child":true}],"has_more":true,"page_token":"wiki-next"}
        """)
        let node = FeishuPage.parse(wiki).documents[0]
        precondition(node.token == "node" && node.type == "wiki" && node.hasChildren && node.documentReference == "doc" && node.contentType == "docx")
        for link in ["file:///tmp/example", "https://feishu.cn.evil.test/docx/a", "https://user@team.feishu.cn/docx/a", "javascript:alert(1)", "http://team.feishu.cn/docx/a"] {
            precondition(FeishuDocument(token: "a", title: "", type: "docx", url: link, modified: "").webURL == nil)
        }
        for value in ["{\"ok\":false,\"error\":{\"message\":\"secret-token\"}}", "{\"code\":99991672}"] {
            do { _ = try json(value); preconditionFailure("CLI error accepted") }
            catch { precondition(!error.localizedDescription.contains("secret-token")) }
        }
        let invalidPage = try json("{\"files\":[{\"name\":\"missing token\"}]}")
        precondition(FeishuPage.parse(invalidPage).documents.isEmpty)
        let args = FeishuDocumentCommand.list(.init(title: "folder", folder: "folder-id"), query: "", cursor: "next")
        precondition(args.contains("--folder-token") && args.contains("folder-id") && args.contains("next"))
        let query = "\"; touch /tmp/never; $(echo unsafe)"
        let searchArgs = FeishuDocumentCommand.list(.root, query: query)
        precondition(searchArgs[searchArgs.firstIndex(of: "--query")! + 1] == query)
        precondition(searchArgs.suffix(2) == ["--as", "user"])
        let libraryArgs = FeishuDocumentCommand.list(.library, query: "")
        precondition(libraryArgs.contains("my_library") && libraryArgs.contains("+node-list"))
        let instant = Date(timeIntervalSince1970: 1_791_000_000)
        let recent = FeishuLocation.recentlyOpened(days: 7, now: instant)
        let formatter = ISO8601DateFormatter()
        precondition(recent.isRecent && recent.id != FeishuLocation.root.id)
        precondition(formatter.date(from: recent.openedUntil)!.timeIntervalSince(formatter.date(from: recent.openedSince)!) == 7 * 86_400)
        precondition(FeishuLocation.recentlyOpened(days: 100, now: instant).recentDays == 90)
        precondition(FeishuLocation.recentlyOpened(days: 0, now: instant).recentDays == 1)
        let recentArgs = FeishuDocumentCommand.list(recent, query: "")
        precondition(recentArgs.prefix(2) == ["drive", "+search"] && !recentArgs.contains("--folder-token"))
        precondition(recentArgs[recentArgs.firstIndex(of: "--query")! + 1].isEmpty)
        precondition(recentArgs[recentArgs.firstIndex(of: "--sort")! + 1] == "open_time")
        let nextRecentArgs = FeishuDocumentCommand.list(recent, query: query, cursor: "recent-next")
        for flag in ["--opened-since", "--opened-until", "--as"] {
            precondition(recentArgs[recentArgs.firstIndex(of: flag)! + 1] == nextRecentArgs[nextRecentArgs.firstIndex(of: flag)! + 1])
        }
        precondition(nextRecentArgs[nextRecentArgs.firstIndex(of: "--query")! + 1] == query)
        precondition(nextRecentArgs.contains("recent-next") && nextRecentArgs.suffix(2) == ["--as", "user"])


        var lru = FeishuCache<String>(capacity: 2)
        lru.insert("first", for: "a", now: instant)
        lru.insert("second", for: "b", now: instant)
        let firstEntry = lru.read("a")!
        precondition(FeishuCache<String>.fresh(firstEntry, now: instant.addingTimeInterval(59)))
        precondition(!FeishuCache<String>.fresh(firstEntry, now: instant.addingTimeInterval(60)))
        lru.insert("third", for: "c", now: instant)
        precondition(lru.count == 2 && lru.read("b") == nil && lru.read("a")?.value == "first")
        let identityData = try json("{\"appId\":\"test-app\",\"identities\":{\"user\":{\"available\":true,\"openId\":\"test-user\",\"userName\":\"示例\"}}}")
        precondition(FeishuIdentity.parse(identityData).available && FeishuIdentity.parse(identityData).account == "test-app:test-user")
        let botOnly = try json("{\"identity\":\"bot\",\"identities\":{\"user\":{\"available\":false}}}")
        precondition(!FeishuIdentity.parse(botOnly).available)

        let rich = try DocumentMarkup.parse("""
        # 动态数据
        <whiteboard token="private-board-token"></whiteboard>
        ## 场景
        <table><colgroup><col/></colgroup><tbody><tr><th>名称</th><th>示例</th></tr><tr><td rowspan="2">整理 &amp; 保存</td><td><pre lang="JSON"><code>{&quot;type&quot;:&quot;file&quot;}<br/>next</code></pre></td></tr><tr><td><strong>说明</strong><br/>第二行</td></tr></tbody></table>
        ### 步骤
        - [x] 已完成
        - [ ] 待完成
        """)
        let headings = DocumentMarkup.outline(rich)
        precondition(headings.map(\.level) == [1, 2, 3] && headings.map(\.number) == ["1", "1.1", "1.1.1"])
        guard case .embed("白板", "whiteboard") = rich[1] else { preconditionFailure("Whiteboard leaked raw markup") }
        let rows = rich.compactMap { block -> [[String]]? in if case .table(let rows) = block { return rows }; return nil }.first!
        precondition(rows.count == 3 && rows[1][0] == "整理 & 保存" && rows[2][0].hasPrefix("↳"))
        precondition(rows[1][1].contains("{\"type\":\"file\"}\nnext") && !rows[1][1].contains("<code>"))
        precondition(rows[2][1] == "**说明**\n第二行")
        let tasks = rich.compactMap { block -> Bool? in if case .task(_, let checked, _) = block { return checked }; return nil }
        precondition(tasks == [true, false])
        let escaped = try DocumentMarkup.parse("| 名称 | 值 |\n| --- | --- |\n| a\\|b | `c|d` |")
        guard case .table(let pipeRows) = escaped[0] else { preconditionFailure("Missing Markdown table") }
        precondition(pipeRows[1] == ["a|b", "`c|d`"])
        let fenced = try DocumentMarkup.parse("````json\n```\n<whiteboard></whiteboard>\n````")
        guard case .code(_, let literal) = fenced[0] else { preconditionFailure("Missing fenced code") }
        precondition(literal.contains("<whiteboard>"))
        let unsafeHTML = try DocumentMarkup.parse("<div><script>hidden-danger</script><p><a href=\"javascript:alert(1)\">Safe label</a> &lt;plain&gt;</p></div>")
        guard case .paragraph(let safeText) = unsafeHTML[0] else { preconditionFailure("Missing HTML paragraph") }
        precondition(safeText == "Safe label <plain>")
        let duplicates = DocumentMarkup.outline(try DocumentMarkup.parse("# 标题\n## 重复\n## 重复"))
        precondition(Set(duplicates.map(\.id)).count == 3 && duplicates.last?.number == "1.2")
        let sourceWithDuplicates = "# 标题\n```\n## 重复\n```\n## 重复\n## 重复\n<h3><strong>子标题</strong></h3>"
        let sourceHeadings = DocumentMarkup.outline(try DocumentMarkup.parse(sourceWithDuplicates))
        let rawSource = sourceWithDuplicates as NSString
        let firstReal = rawSource.range(of: "## 重复", options: [], range: NSRange(location: rawSource.range(of: "```\n## 重复\n```").upperBound, length: rawSource.length - rawSource.range(of: "```\n## 重复\n```").upperBound)).location
        precondition(DocumentMarkup.sourceLocation(sourceHeadings[1], in: sourceWithDuplicates, headings: sourceHeadings) == firstReal)
        precondition(DocumentMarkup.sourceLocation(sourceHeadings[2], in: sourceWithDuplicates, headings: sourceHeadings) == firstReal + "## 重复\n".utf16.count)
        precondition(DocumentMarkup.sourceLocation(sourceHeadings[3], in: sourceWithDuplicates, headings: sourceHeadings) == rawSource.range(of: "<h3>").location)
        let inlineLiteral = try DocumentMarkup.parse("使用 `<whiteboard token=\"literal\">` 与 **说明**")
        guard case .paragraph(let inlineValue) = inlineLiteral[0] else { preconditionFailure("Missing inline literal") }
        precondition(inlineValue.contains("<whiteboard token="))
        let largeHTML = "<table>" + String(repeating: "<tr><td>数据</td><td><pre lang='JSON'>{&quot;x&quot;:1}</pre></td></tr>", count: 2_000) + "</table>"
        let startedMarkup = Date()
        let largeBlocks = try DocumentMarkup.parse(largeHTML)
        precondition(largeBlocks.count == 1 && Date().timeIntervalSince(startedMarkup) < 3)
        print("PASS: HTML tables/code/entities/row spans, safe embeds, fenced literals, task lists, escaped pipes and unique hierarchical outline anchors")


        let editableSource = "---\r\nname: fixture\r\n---\r\n# 标题😀\r\n\r\n第一段 **重点**\r\n续行\r\n\r\n| 列 | 值 |\r\n| --- | --- |\r\n| 数据 | `a` |\r\n\r\n```swift\r\nlet a = 1\r\n```\r\n\r\n最后一段"
        let located = try DocumentMarkup.locatedBlocks(editableSource)
        let pieces = located.map { (editableSource as NSString).substring(with: $0.range) }
        precondition(pieces == ["# 标题😀", "第一段 **重点**\r\n续行", "| 列 | 值 |\r\n| --- | --- |\r\n| 数据 | `a` |", "```swift\r\nlet a = 1\r\n```", "最后一段"])
        let replaced = DocumentMarkup.replacing(located[1].range, in: editableSource, with: "新内容😀")!
        precondition(replaced == editableSource.replacingOccurrences(of: pieces[1], with: "新内容😀"))
        precondition(DocumentMarkup.replacing(NSRange(location: -1, length: 2), in: editableSource, with: "") == nil)
        let emoji = "😀"
        precondition(DocumentMarkup.replacing(NSRange(location: 1, length: 1), in: emoji, with: "") == nil)
        let groupedHTML = "<div><h2>标题</h2><p>正文</p></div>\n\n之后"
        let grouped = try DocumentMarkup.locatedBlocks(groupedHTML)
        precondition(grouped[0].range != grouped[1].range)
        precondition((groupedHTML as NSString).substring(with: grouped[2].range) == "之后")
        let nested = try DocumentMarkup.parse("<ol start='3'><li>父级<ul><li>子级</li></ul></li><li>同级</li></ol>\n<callout><strong>注意</strong>说明</callout>")
        guard case .numbered(0, "3.", "父级") = nested[0], case .bullet(1, "子级") = nested[1],
              case .numbered(0, "4.", "同级") = nested[2], case .callout("**注意**说明") = nested[3] else { preconditionFailure("Lost nested list or callout hierarchy") }
        print("PASS: source-preserving inline replacements, Unicode/CRLF/frontmatter, shared HTML ranges, nested lists and callouts")
        let lark = """
        <callout emoji="💡" background-color="light-yellow" border-color="yellow"><p>先看结论</p><ul><li>子项</li></ul></callout>
        <grid><column width-ratio="0.6"><p>左栏</p></column><column width-ratio="0.4"><checkbox done="false">待办</checkbox></column></grid>
        <h2 seq="auto">第二节</h2>
        <p>你好 <cite type="user" user-id="ou_x"/> <u>下划线</u> <span text-color="red" background-color="light-yellow">红字</span> <latex>E=mc^2</latex></p>
        <bookmark name="示例" href="https://example.test/docs"></bookmark>
        <whiteboard type="mermaid">flowchart LR
        A-->B</whiteboard>
        """
        let larkBlocks = try DocumentMarkup.locatedBlocks(lark)
        precondition(larkBlocks[0].role == "callout" && larkBlocks[0].chrome.emoji == "💡" && larkBlocks[0].chrome.background == "light-yellow")
        guard case .paragraph("先看结论") = larkBlocks[0].block, case .bullet(_, "子项") = larkBlocks[1].block else { preconditionFailure("Callout lost nested blocks") }
        precondition(larkBlocks[1].group == larkBlocks[0].group)
        let columns = larkBlocks.filter { $0.role == "grid" }
        precondition(columns.count == 2 && columns[0].chrome.column == 0 && abs(columns[0].chrome.ratio - 0.6) < 0.001 && columns[1].chrome.column == 1)
        guard case .task(_, false, "待办") = columns[1].block, columns[1].htmlTag == "checkbox" else { preconditionFailure("Checkbox column missing") }
        precondition(larkBlocks.contains { if case .heading(2, "第二节") = $0.block { return $0.chrome.sequence == "1" }; return false })
        let spans = DocumentMarkup.inlineSpans("<p>你好 <cite type='user' user-id='ou_x'/> <u>下划线</u> <span text-color='red' background-color='light-yellow'>红字</span> <latex>E=mc^2</latex></p>")
        precondition(spans?.contains { $0.mention && $0.text == "成员" } == true)
        precondition(spans?.contains { $0.underline && $0.text == "下划线" } == true)
        precondition(spans?.contains { $0.textColor == "red" && $0.background == "light-yellow" && $0.text == "红字" } == true)
        precondition(spans?.contains { $0.math && $0.text == "E=mc^2" } == true)
        precondition(DocumentPalette.ink("light-blue") == 0x3D7DFF)
        precondition(DocumentPalette.fill("medium-yellow")?.1 == 0.30)
        precondition(larkBlocks.contains { if case .embed("示例", "bookmark") = $0.block { return $0.chrome.link == "https://example.test/docs" }; return false })
        precondition(larkBlocks.contains { if case .embed(_, "whiteboard") = $0.block { return $0.chrome.language == "mermaid" && $0.chrome.caption.contains("A-->B") }; return false })
        print("PASS: Lark callout, grid, checkbox, mention, color, formula, bookmark and whiteboard source")


        let marked = "正文 **重点** 与 *斜体*、`a|b` 和 [链接](https://example.test/a)"
        let richText = DocumentRichText.attributed(marked, size: 15)
        precondition(richText.string == "正文 重点 与 斜体、a|b 和 链接")
        let roundTrip = DocumentRichText.markdown(richText)
        precondition(DocumentRichText.attributed(roundTrip, size: 15).string == richText.string)
        precondition(roundTrip.contains("**重点**") && roundTrip.contains("*斜体*") && roundTrip.contains("https://example.test/a"))
        let literalText = NSAttributedString(string: "*字面* [括号] <标签> 😀", attributes: [.font: NSFont.systemFont(ofSize: 15)])
        precondition(DocumentRichText.attributed(DocumentRichText.markdown(literalText), size: 15).string == literalText.string)
        let pasted = NSAttributedString(string: "安全文本", attributes: [.link: URL(string: "javascript:alert(1)")!])
        precondition(!DocumentRichText.markdown(pasted).contains("javascript"))
        print("PASS: native rich text marks, links, literal punctuation and safe serialization")


        // Mount only the production block editor in an invisible fixture window.
        // No main app, permissions, cloud transport or preference writes.
        NSApplication.shared.setActivationPolicy(.prohibited)
        var nativeUpdate = ""
        let nativeEditor = DocumentInlineEditor(markdown: marked, fontSize: 15, editable: true) { nativeUpdate = $0 }
        let host = NSHostingView(rootView: nativeEditor.frame(width: 600, height: 180))
        let fixtureWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        fixtureWindow.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            for child in view.subviews { if let text = textView(in: child) { return text } }
            return nil
        }
        guard let native = textView(in: host) else { preconditionFailure("Missing native editor") }
        precondition(native.string == richText.string && native.isEditable)
        let focusNavigation = DocumentFocusNavigator()
        focusNavigation.order = ["cell"]
        focusNavigation.register(native as! DocumentTextView, id: "cell")
        precondition(focusNavigation.activeView == nil && focusNavigation.firstView === native)
        fixtureWindow.makeFirstResponder(native)
        native.insertText("😀", replacementRange: NSRange(location: (native.string as NSString).length, length: 0))
        precondition(DocumentRichText.attributed(nativeUpdate, size: 15).string == richText.string + "😀")
        precondition(nativeUpdate.contains("**重点**") && nativeUpdate.contains("*斜体*"))
        try await Task.sleep(for: .milliseconds(100))
        precondition(native.undoManager?.canUndo == true)
        native.undoManager?.undo()
        precondition(native.string == richText.string)
        guard let linkView = native as? DocumentTextView, let layout = native.layoutManager, let container = native.textContainer else { preconditionFailure("Missing production text view") }
        let linkRange = (native.string as NSString).range(of: "链接")
        let glyphRange = layout.glyphRange(forCharacterRange: linkRange, actualCharacterRange: nil)
        layout.ensureLayout(for: container)
        let linkBounds = layout.boundingRect(forGlyphRange: glyphRange, in: container)
        let hit = NSPoint(x: linkBounds.minX + 2 + native.textContainerOrigin.x, y: linkBounds.midY + native.textContainerOrigin.y)
        var opened: URL?
        linkView.openLink = { opened = $0 }
        precondition(linkView.activateLink(at: hit) && opened?.host == "example.test")
        opened = nil
        precondition(!linkView.activateLink(at: hit, modifiers: .option) && opened == nil)
        precondition(!linkView.activateLink(at: NSPoint(x: 599, y: 179)))
        let detected = DocumentRichText.attributed("https://example.test/a `https://example.test/code`", size: 15)
        precondition(detected.attribute(.link, at: 0, effectiveRange: nil) != nil)
        let codeURL = (detected.string as NSString).range(of: "https://example.test/code")
        precondition(detected.attribute(.link, at: codeURL.location, effectiveRange: nil) == nil)
        fixtureWindow.contentView = nil
        print("PASS: production native editor typing preserves marks and Unicode; native undo restores content")


        let tableHTML = "<table border='2'><colgroup><col width='220'/><col width='340'/></colgroup><tr height='90'><th rowspan='2'>合并标题</th><td><a href='https://example.test/a'>链接</a><mention token='preserve-token'>人员</mention></td></tr><tr><td><pre lang='json'><code>{&quot;x&quot;:1}</code></pre></td></tr></table>"
        guard var grid = try DocumentMarkup.locatedBlocks(tableHTML).first?.table else { preconditionFailure("Missing editable topology") }
        precondition(grid.cells.count == 3 && grid.rowCount == 2 && grid.columnCount == 2)
        precondition(grid.cell(atRow: 1, column: 0)?.rowSpan == 2)
        precondition(grid.columnWidths == [220, 340] && grid.rowHeights[0] == 90 && grid.borderWidth == 2)
        grid.columnWidths[0] = DocumentTable.clampWidth(410)
        grid.rowHeights[1] = DocumentTable.clampHeight(135)
        let resizedHTML = grid.html(renderInline: DocumentRichText.html)
        precondition(resizedHTML.contains("preserve-token") && resizedHTML.contains("rowspan=\"2\""))
        guard let resized = try DocumentMarkup.locatedBlocks(resizedHTML).first?.table else { preconditionFailure("Cannot read resized table") }
        precondition(resized.columnWidths == [410, 340] && resized.rowHeights[1] == 135)
        grid.insertRow(at: 1)
        precondition(grid.rowCount == 3 && grid.cell(atRow: 1, column: 0)?.rowSpan == 3)
        grid.deleteRow(at: 1)
        precondition(grid.rowCount == 2 && grid.cell(atRow: 1, column: 0)?.rowSpan == 2)
        grid.insertColumn(at: 1)
        precondition(grid.columnCount == 3 && grid.cell(atRow: 0, column: 2)?.value.contains("链接") == true)
        grid.deleteColumn(at: 1)
        precondition(grid.columnCount == 2 && grid.cell(atRow: 0, column: 1)?.value.contains("链接") == true)
        let spanning = grid.cells.first { $0.rowSpan == 2 }!.id
        grid.split(spanning)
        precondition(grid.cells.count == 4 && grid.cells.allSatisfy { $0.rowSpan == 1 && $0.columnSpan == 1 })
        grid.merge(spanning, below: true)
        precondition(grid.cells.count == 3 && grid.cells.first { $0.id == spanning }?.rowSpan == 2)
        var flat = DocumentTable(rows: [["A", "B"], ["C", "D"]])
        let tableUndo = UndoManager()
        tableUndo.groupsByEvent = false
        let controller = DocumentTableController(flat)
        var serializedTable = ""
        controller.onChange = { serializedTable = $0 }
        let oldWidth = flat.columnWidths[0]
        tableUndo.beginUndoGrouping()
        controller.change(undoManager: tableUndo) { $0.columnWidths[0] = 350; $0.rowHeights[0] = 120 }
        tableUndo.endUndoGrouping()
        precondition(serializedTable.contains("width=\"350") && controller.model.rowHeights[0] == 120)
        tableUndo.undo()
        precondition(controller.model.columnWidths[0] == oldWidth && controller.model.rowHeights[0] == 48)
        tableUndo.redo()
        precondition(controller.model.columnWidths[0] == 350 && controller.model.rowHeights[0] == 120)
        let firstID = flat.cells[0].id
        flat.merge(firstID, below: false)
        precondition(flat.cells.count == 3 && flat.cells.first { $0.id == firstID }?.value == "A\nB")
        flat.split(firstID)
        precondition(flat.cells.count == 4 && flat.cell(atRow: 0, column: 1)?.value == "")
        precondition(DocumentTable.clampWidth(-10) == 72 && DocumentTable.clampWidth(.infinity) == 150)
        precondition(DocumentTable.clampHeight(10000) == 2000)
        precondition(DocumentTable.dimension("color: red; width: 123px;", property: "width") == 123)
        let literalCodeHTML = DocumentRichText.html(DocumentMarkup.fencedCode("```\n**literal** <tag>", language: "json"))
        precondition(literalCodeHTML.contains("**literal** &lt;tag&gt;") && !literalCodeHTML.contains("<strong>literal"))
        precondition(DocumentRichText.allowedURL(URL(string: "https://example.test/")!))
        precondition(DocumentRichText.allowedURL(URL(string: "http://localhost:8080/")!))
        precondition(DocumentRichText.allowedURL(URL(string: "mailto:editor@example.test")!))
        for unsafe in ["javascript:alert(1)", "file:///tmp/private", "data:text/html,a", "https://user:secret@example.test/"] {
            precondition(!DocumentRichText.allowedURL(URL(string: unsafe)!))
        }
        let leafSource = "<div><h2 id='anchor'>标题</h2><p><strong>正文</strong></p><whiteboard token='keep-me'></whiteboard></div>"
        let leaves = try DocumentMarkup.locatedBlocks(leafSource)
        precondition(leaves.count == 3 && leaves[0].htmlTag == "h2" && leaves[1].htmlTag == "p")
        let changedLeaf = DocumentMarkup.replacing(leaves[1].range, in: leafSource, with: "<p>新正文</p>")!
        precondition(changedLeaf.contains("id='anchor'") && changedLeaf.contains("keep-me") && changedLeaf.contains("<p>新正文</p>"))
        print("PASS: real merged table topology, editable dimensions, row/column operations, preserved cell HTML, safe links and HTML leaf ranges")

        let sourceDoc = page.documents[0]
        let deletion = try CommandFixture(request: .init(kind: .delete, document: sourceDoc)).arguments()
        precondition(deletion == ["drive", "+delete", "--file-token", "test-doc", "--type", "docx", "--yes"])
        let move = try CommandFixture(request: .init(kind: .move, document: sourceDoc), destination: "https://team.feishu.cn/drive/folder/folder-target").arguments()
        precondition(move.suffix(2) == ["--folder-token", "folder-target"])
        let copy = try CommandFixture(request: .init(kind: .copy, document: sourceDoc)).arguments()
        precondition(copy.suffix(2) == ["--folder-token", "my_space"])
        for target in ["https://evil.test/drive/folder/a", "https://team.feishu.cn/docx/a"] {
            do { _ = try CommandFixture(request: .init(kind: .move, document: sourceDoc), destination: target).arguments(); preconditionFailure("invalid folder accepted") }
            catch { }
        }
        let comment = try CommandFixture(request: .init(kind: .comment, document: node)).arguments()
        precondition(comment.contains("doc") && comment.suffix(2) == ["--type", "docx"] && !comment.contains("wiki"))
        let overwrite = try CommandFixture(request: .init(kind: .edit, document: sourceDoc, revision: "42"), mode: "overwrite").arguments()
        precondition(overwrite.contains("overwrite") && overwrite.suffix(2) == ["--revision-id", "42"] && overwrite.contains("-"))
        let member = try CommandFixture(request: .init(kind: .member, document: node), text: "reader@example.test").arguments()
        precondition(member.contains("--yes") && member.suffix(2) == ["--perm-type", "single_page"])
        do { _ = try CommandFixture(request: .init(kind: .member, document: node), text: "a@example.test,b@example.test").arguments(); preconditionFailure("multi-member grant accepted") }
        catch { }
        let upload = try CommandFixture(request: .init(kind: .upload)).arguments()
        precondition(upload.contains("--file") && !upload.contains("--file-path"))
        let export = try CommandFixture(request: .init(kind: .export, document: sourceDoc)).arguments()
        precondition(export.contains("--output-dir") && !export.contains("--overwrite"))

        // Dev transport must reject before executable discovery or process launch.
        do { _ = try await FeishuCLI.run(["docs", "+create", "--title", "must never run"]); preconditionFailure("dev ran real CLI") }
        catch { precondition(error.localizedDescription.contains("开发版")) }
        let store = FeishuDocumentStore()
        precondition(store.location.isRecent && store.location.recentDays == 30)
        store.start()
        precondition(store.preview && store.documents.count == 3 && !store.loading)
        store.search("工作计划")
        precondition(store.documents.count == 1)
        store.select(store.documents.first)
        precondition(store.content.contains("示例内容"))
        store.beginEditing()
        let draftID = store.activeDraftID!
        store.updateDraft(text: "保留的草稿")
        store.select(page.documents[0])
        precondition(store.drafts[draftID]?.text == "保留的草稿")
        store.activeDraftID = draftID
        let blockedSave = await store.saveDraft()
        precondition(!blockedSave && store.activeDraft?.text == "保留的草稿")
        store.newDocument()
        store.updateDraft(text: "新建正文", title: "新建标题")
        precondition(store.activeDraft!.arguments().contains("新建标题") && store.activeDraft!.canSave)
        store.discardDraft()
        precondition(store.drafts[draftID] != nil)
        store.checkConnection(); store.beginLogin()
        precondition(store.connection == .unchecked && store.authorizationURL == nil)
        let before = store.documents
        let changed = await store.perform(["drive", "+delete", "--file-token", "never", "--yes"])
        precondition(!changed && store.documents == before)
        store.suspend()
        precondition(!store.loading && !store.detailLoading)

        // Cancellation owns one explicitly mocked child, never another running CLI.
        let owner = FeishuChild()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try owner.start(process)
        owner.cancel()
        process.waitUntilExit()
        precondition(!process.isRunning)
        owner.finish()
        let cancelled = FeishuChild()
        cancelled.cancel()
        do { try cancelled.start(Process()); preconditionFailure("cancelled child started") }
        catch is CancellationError { }
        print("PASS: Feishu production JSON/Drive/search/Wiki parsing, pagination arguments, URL boundary, secret-safe errors, dev isolation, preview state, and child cancellation")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='claudebar-feishu-tests-') as directory:
    path = Path(directory)
    (path / 'regression.swift').write_text(swift)
    subprocess.run(['swiftc', '-D', 'CLAUDEBAR_DEV', '-parse-as-library', str(path / 'regression.swift'), '-o', str(path / 'regression')], check=True, cwd=root)
    subprocess.run([str(path / 'regression')], check=True, timeout=15)

# Keep the production transport intact; replace only executable discovery with a
# temporary mocked CLI. This release harness never sees the user's real CLI.
transport = sources[1].read_text()
start = transport.index('    static func executable() -> URL? {')
end = transport.index('    static func run(', start)
transport = transport[:start] + '''    static func executable() -> URL? {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["FEISHU_TEST_CLI"]!)
    }

''' + transport[end:]
transport_probe = sources[0].read_text() + '\n' + transport + '\n' + sources[2].read_text() + r'''
@main struct TransportRegression {
    @MainActor static func main() async throws {
        let input = String(repeating: "正文\n", count: 100_000)
        let result = try await FeishuCLI.run(["echo", "literal; $(never)"], input: input)
        precondition(result["echo"].text == input && result["argument"].text == "literal; $(never)")
        do { _ = try await FeishuCLI.run(["error"]); preconditionFailure("error succeeded") }
        catch { precondition(!error.localizedDescription.contains("SECRET")) }
        do { _ = try await FeishuCLI.run(["large"]); preconditionFailure("output cap ignored") }
        catch { precondition(error.localizedDescription.contains("过大")) }
        let started = Date()
        let pending = Task { try await FeishuCLI.run(["sleep"]) }
        try await Task.sleep(for: .milliseconds(150))
        pending.cancel()
        do { _ = try await pending.value; preconditionFailure("cancelled request succeeded") }
        catch { precondition(Date().timeIntervalSince(started) < 4) }
        func settled(_ predicate: @MainActor () -> Bool) async throws {
            let until = Date().addingTimeInterval(5)
            while !predicate(), Date() < until { try await Task.sleep(for: .milliseconds(20)) }
            precondition(predicate(), "Store did not settle")
        }
        let state = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FEISHU_TEST_CLI"]!).deletingLastPathComponent()
        func counter(_ name: String) -> Int { Int((try? String(contentsOf: state.appendingPathComponent(name), encoding: .utf8)) ?? "0") ?? 0 }
        let store = FeishuDocumentStore()
        store.start()
        try await settled { store.connection.ready && !store.loading && store.documents.count == 2 }
        let first = store.documents[0], second = store.documents[1]
        store.select(first)
        try await settled { !store.detailLoading && store.revision == "42" }
        let requests = counter("fetch-count")
        store.select(second)
        try await settled { !store.detailLoading }
        store.select(first)
        precondition(!store.detailLoading && counter("fetch-count") == requests + 1)
        let cachedBody = store.content
        store.select(first, force: true)
        precondition(store.detailLoading && store.contentIsStale && store.content == cachedBody)
        try await settled { !store.detailLoading && !store.contentIsStale }
        try "1".write(to: state.appendingPathComponent("fetch-error"), atomically: true, encoding: .utf8)
        store.select(first, force: true)
        try await settled { !store.detailLoading }
        precondition(store.content == cachedBody && store.contentIsStale)
        try FileManager.default.removeItem(at: state.appendingPathComponent("fetch-error"))
        store.select(first, force: true)
        try await settled { !store.detailLoading && !store.contentIsStale }
        store.refresh(force: true)
        precondition(store.documents.count == 2 && store.loading)
        try await settled { !store.loading }
        let searches = counter("search-count")
        store.navigate(.recentlyOpened())
        precondition(!store.loading && counter("search-count") == searches)
        store.refresh(more: true)
        try await settled { !store.loading && store.documents.count == 3 }
        precondition(store.cursor.isEmpty)
        store.select(first)
        store.beginEditing()
        store.updateDraft(text: "Edited Markdown")
        let draftID = store.activeDraftID!
        try "1".write(to: state.appendingPathComponent("conflict"), atomically: true, encoding: .utf8)
        let conflictSave = await store.saveDraft()
        precondition(!conflictSave && store.drafts[draftID]?.text == "Edited Markdown")
        try FileManager.default.removeItem(at: state.appendingPathComponent("conflict"))
        let saved = await store.saveDraft()
        precondition(saved && store.drafts[draftID] == nil)
        try await settled { !store.loading && !store.detailLoading && store.content == "Edited Markdown" }
        let updateArgs = try String(contentsOf: state.appendingPathComponent("update-args"), encoding: .utf8)
        precondition(updateArgs.contains("42") && updateArgs.contains("overwrite"))
        store.newDocument(); store.updateDraft(text: "Created body", title: "Created title")
        let created = await store.saveDraft()
        precondition(created && store.selected?.token == "created" && store.selected?.isDocument == true)
        try await settled { !store.loading && !store.detailLoading }
        store.beginEditing(); store.updateDraft(text: "Belongs to account A")
        let ownedDraft = store.activeDraftID!
        try "user-b".write(to: state.appendingPathComponent("account"), atomically: true, encoding: .utf8)
        store.checkConnection()
        try await settled { store.connection.ready && !store.loading && store.selected == nil }
        store.activeDraftID = ownedDraft
        let wrongAccount = await store.saveDraft()
        precondition(!wrongAccount && store.drafts[ownedDraft]?.text == "Belongs to account A")
        store.beginLogin()
        try await settled { store.authorizationURL != nil }
        store.cancelLogin()
        precondition(store.connection == .needsLogin && store.authorizationURL == nil)
        try "1".write(to: state.appendingPathComponent("login-fast"), atomically: true, encoding: .utf8)
        store.beginLogin()
        try await settled { store.connection.ready && store.authorizationURL == nil && !store.loading }
        precondition(store.documents.count == 2)
        store.suspend()
        print("PASS: production auth status, login cancellation, account cache isolation, cache hits, deduplicated pagination, revision-safe saves, failure retention and create-then-open with mocked CLI")
        print("PASS: production CLI transport drains simultaneous pipes, streams large stdin, preserves literal arguments, caps output, suppresses raw stderr, and cancels only its mock child")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='claudebar-feishu-transport-') as directory:
    import os
    path = Path(directory)
    mock = path / 'mock-cli'
    mock.write_text('''#!/usr/bin/python3
import json, sys, time
mode = sys.argv[1]
from pathlib import Path
state = Path(sys.argv[0]).parent
def emit(value):
    print(json.dumps(value))
    sys.exit(0)
def count(name):
    p = state / name
    p.write_text(str(int(p.read_text() if p.exists() else '0') + 1))
if mode == 'auth':
    if sys.argv[2] == 'status':
        account = (state / 'account').read_text() if (state / 'account').exists() else 'user-a'
        emit({'appId': 'mock-app', 'identities': {'user': {'available': True, 'openId': account, 'userName': 'Mock user'}}})
    if '--no-wait' in sys.argv:
        emit({'verification_url': 'https://accounts.feishu.cn/oauth/mock', 'device_code': 'mock-device'})
    if (state / 'login-fast').exists():
        time.sleep(0.15)
    else: time.sleep(10)
    emit({'ok': True})
if mode == 'wiki': emit({'items': []})
if mode == 'drive':
    count('search-count')
    rows = [{'token': 'a', 'name': 'First', 'type': 'docx'}, {'token': 'b', 'name': 'Second', 'type': 'docx'}]
    more = '--page-token' not in sys.argv
    if not more: rows = [rows[0], {'token': 'c', 'name': 'Third', 'type': 'docx'}]
    emit({'files': rows, 'has_more': more, 'page_token': 'next' if more else ''})
if mode == 'docs':
    command = sys.argv[2]
    if command == '+fetch':
        count('fetch-count')
        time.sleep(0.05)
        if (state / 'fetch-error').exists(): sys.exit(2)
        text = (state / 'body').read_text() if (state / 'body').exists() else 'Original body'
        emit({'document': {'content': text, 'revision_id': '42'}})
    if command == '+update':
        (state / 'update-args').write_text(json.dumps(sys.argv[1:]))
        content = sys.stdin.read()
        if (state / 'conflict').exists():
            sys.stderr.write('SECRET mock conflict')
            sys.exit(2)
        (state / 'body').write_text(content)
        emit({'ok': True})
    if command == '+create':
        (state / 'body').write_text(sys.stdin.read())
        emit({'document_id': 'created', 'url': 'https://mock.feishu.cn/docx/created'})

if mode == 'error':
    sys.stderr.write('SECRET access token must never be displayed')
    sys.exit(2)
if mode == 'sleep':
    time.sleep(20)
if mode == 'large':
    sys.stdout.write('x' * (17 * 1024 * 1024))
else:
    sys.stderr.write('diagnostic' * 30000)
    content = sys.stdin.read()
    print(json.dumps({'ok': True, 'data': {'echo': content, 'argument': sys.argv[2] if len(sys.argv) > 2 else ''}}))
''')
    mock.chmod(0o700)
    (path / 'transport.swift').write_text(transport_probe)
    subprocess.run(['swiftc', '-D', 'CLAUDEBAR_RELEASE', '-parse-as-library', str(path / 'transport.swift'), '-o', str(path / 'transport')], check=True, cwd=root)
    subprocess.run([str(path / 'transport')], check=True, timeout=35, env={**os.environ, 'FEISHU_TEST_CLI': str(mock)})
