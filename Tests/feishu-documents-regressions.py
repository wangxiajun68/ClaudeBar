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
swift = '\n'.join(p.read_text() for p in sources) + fixture + r'''
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
