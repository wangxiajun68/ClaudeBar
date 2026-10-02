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
        store.start()
        precondition(store.preview && store.documents.count == 3 && !store.loading)
        store.search("工作计划")
        precondition(store.documents.count == 1)
        store.select(store.documents.first)
        precondition(store.content.contains("示例内容"))
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
transport_probe = sources[0].read_text() + '\n' + transport + r'''
@main struct TransportRegression {
    static func main() async throws {
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
    subprocess.run([str(path / 'transport')], check=True, timeout=20, env={**os.environ, 'FEISHU_TEST_CLI': str(mock)})
