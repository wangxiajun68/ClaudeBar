#!/usr/bin/env python3
"""Production migration logic, temporary native stores, fake version clients."""
from pathlib import Path
import json, os, shlex, sqlite3, subprocess, tempfile, stat, plistlib

root = Path(__file__).resolve().parents[1]
sources = [
    root / 'Sources/Shared/BuildChannel.swift',
    root / 'Sources/ClaudeBar/Models/SessionMigration.swift',
    *[root / ('Sources/ClaudeBar/Utils/' + name + '.swift') for name in
      ['MigrationHistory', 'ConversationMedia', 'MigrationCursorHistory', 'MigrationCursorDesktop', 'MigrationStorage', 'PrivateFileWriter', 'ShellQuote', 'MigrationBridgeConfiguration']]
]
with tempfile.TemporaryDirectory(prefix='claudebar-migration-') as folder:
    work = Path(folder)
    source_id = 'ea7f9767-42bb-491a-b7e9-f6b8de1d7f10'
    cwd = work / "project $literal 'quoted' 中文"
    cwd.mkdir()
    home = work / 'home'
    cli = home / '.local/bin'
    cli.mkdir(parents=True)
    for name, version in [('claude', '2.1.288 (Claude Code)'),
                          ('codex', 'codex-cli 0.159.0-alpha.12.1'),
                          ('agent', '2026.06.19-20-24-33-653a7fb')]:
        path = cli / name
        path.write_text('#!/bin/sh\n' + 'test "$1" = "--version" || exit 97\n' +
                        "printf '%s\\n' " + shlex.quote(version) + '\n')
        path.chmod(0o700)
    facts = 'MIGRATE-fixture-中文; never edit VERSION; verify parser regression'
    def jsonl(rows): return ''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows)
    cc_rows = [
        {'type':'user','uuid':'u','parentUuid':None,'sessionId':source_id,'cwd':str(cwd),
         'message':{'role':'user','content':facts}},
        {'type':'assistant','uuid':'branch-old','parentUuid':'u','sessionId':source_id,
         'message':{'role':'assistant','content':[{'type':'text','text':'Wrong sibling branch'}]}},
        {'type':'assistant','uuid':'a','parentUuid':'u','sessionId':source_id,
         'message':{'role':'assistant','content':[{'type':'text','text':'ACK'},
                                               {'type':'thinking','thinking':'PRIVATE_THOUGHT'}]}}
    ]
    codex_rows = [
        {'type':'session_meta','payload':{'id':source_id,'cwd':str(cwd),'history_mode':'paginated'}},
        {'type':'event_msg','payload':{'type':'task_started'}},
        {'type':'response_item','payload':{'type':'message','role':'user',
                  'content':[{'type':'input_text','text':'<environment_context>PRIVATE_ENV</environment_context>'}]}},
        {'type':'response_item','payload':{'type':'message','role':'user',
                                          'content':[{'type':'input_text','text':facts}]}},
        {'type':'event_msg','payload':{'type':'item_completed','item':{'type':'UserMessage','id':'user1',
                                          'content':[{'type':'text','text':facts}]}}},
        {'type':'response_item','payload':{'type':'reasoning','id':'rs_FOREIGN','encrypted_content':'PRIVATE_THOUGHT'}},
        {'type':'event_msg','payload':{'type':'item_completed','item':{'type':'AgentMessage','id':'answer1',
                                          'content':[{'type':'Text','text':'ACK'}]}}},
        {'type':'event_msg','payload':{'type':'task_complete'}}
    ]
    for index, row in enumerate(codex_rows): row['ordinal'] = index
    desktop = work/'desktop.sqlite'
    db = sqlite3.connect(desktop)
    db.executescript('CREATE TABLE composerHeaders(composerId TEXT PRIMARY KEY,workspaceId TEXT,createdAt INTEGER,lastUpdatedAt INTEGER,isArchived INTEGER,isSubagent INTEGER,recency INTEGER,checkpointAt INTEGER,value TEXT,subagentTypeName TEXT); CREATE TABLE cursorDiskKV(key TEXT UNIQUE ON CONFLICT REPLACE,value BLOB)')
    user_bubble = '93f90eb8-9f69-4e31-97ed-3342a675db1e'
    answer_bubble = 'cc94bd41-5e8a-4101-91a8-5ba3a879ed7b'
    db.execute('INSERT INTO composerHeaders(composerId, value, isSubagent, lastUpdatedAt) VALUES (?, ?, 0, 1)',(source_id,json.dumps({'workspaceIdentifier':{'id':'fixture-workspace','uri':{'fsPath':str(cwd)}}})))
    composer = {'_v':18,'modelConfig':{'modelName':'grok-fixture','accessToken':'PRIVATE_MODEL_SECRET'},'blobEncryptionKey':'PRIVATE_KEY','composerId':source_id,'status':'completed','fullConversationHeadersOnly':[{'bubbleId':user_bubble},{'bubbleId':answer_bubble}]}
    db.execute('INSERT INTO cursorDiskKV VALUES (?,?)',('composerData:'+source_id,json.dumps(composer)))
    for bubble_id, typ, text in [(user_bubble,1,facts),(answer_bubble,2,'ACK')]:
        db.execute('INSERT INTO cursorDiskKV VALUES (?,?)',('bubbleId:'+source_id+':'+bubble_id,json.dumps({'type':typ,'text':text})))
    db.commit();db.close()
    (work/'cc.jsonl').write_text(jsonl(cc_rows))
    (work/'codex.jsonl').write_text(jsonl(codex_rows))
    stubs = r'''
import Foundation
import SQLite3
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
let fixtureRoot = URL(fileURLWithPath: CommandLine.arguments[1])
let fixtureHome = fixtureRoot.appendingPathComponent("home")
enum FilePaths {
    static var claudeDir: URL { fixtureRoot.appendingPathComponent("claude") }
    static var codexDir: URL { fixtureRoot.appendingPathComponent("codex") }
    static var cursorCLIConfigDir: URL { fixtureRoot.appendingPathComponent("cursor") }
    static var sessionMigrationsDir: URL { fixtureRoot.appendingPathComponent("records") }
    static var cursorStateDB: URL { fixtureRoot.appendingPathComponent("desktop.sqlite") }
    static var settingsFile: URL { claudeDir.appendingPathComponent("settings.json") }
    static var codexConfigFile: URL { codexDir.appendingPathComponent("config.toml") }
    static var codexAuthFile: URL { codexDir.appendingPathComponent("auth.json") }
    static var codexProvidersFile: URL { claudeDir.appendingPathComponent("codex-providers.json") }
    static var presetsFile: URL { claudeDir.appendingPathComponent("providers.json") }
}
enum LocalProxyAddress {
    static let port = 15721
    static func isLoopback(_ value: String) -> Bool {
        ["localhost", "127.0.0.1", "[::1]"].contains(URLComponents(string:value)?.host ?? "")
    }
}
struct MockSession { let sessionId: String; let isBusy: Bool; let isWaiting: Bool; let toolPending: Bool }
enum SessionMonitor { static func fetchActive() -> [MockSession] { [] } }
enum CodexConfigWriter {
    // Actual auth-shape predicate is inserted below from production.
    __OFFICIAL_LOGIN_PREDICATE__
    static func readSelection() -> (model: String, providerKey: String, wireAPI: String, baseURL: String)? {
        ("test-model", "fixture_provider", "responses", "https://invalid.example")
    }
}
func mustFail(_ body: () throws -> Void) {
    do { try body(); preconditionFailure("Expected a refusal") } catch {}
}
'''
    config_writer = (root/'Sources/ClaudeBar/Utils/CodexConfigWriter.swift').read_text()
    predicate = config_writer[config_writer.index('    static func hasOfficialLogin'):config_writer.index('    /// Custom id for the official ChatGPT route')]
    stubs = stubs.replace('__OFFICIAL_LOGIN_PREDICATE__', predicate)
    service = (root/'Sources/ClaudeBar/Utils/SessionMigrationService.swift').read_text()
    service = service.replace('FileManager.default.homeDirectoryForCurrentUser.path', 'fixtureHome.path')
    service = service.replace('URL(fileURLWithPath: "/Applications/Cursor.app")', 'fixtureRoot.appendingPathComponent("Cursor.app")')
    (work/'Service.swift').write_text(service)
    terminal = (root/'Sources/ClaudeBar/Utils/TerminalLauncher.swift').read_text()
    entry = terminal[terminal.index('    @MainActor\n    static func openMigratedSession'):terminal.index('    // MARK: - Routing')]
    validation = terminal[terminal.index('    private static func isSafePath'):terminal.index('    /// Run an AppleScript')]
    (work/'Stubs.swift').write_text(stubs + '\n@MainActor enum TerminalLauncher {\n' + entry + validation + r'''
    static var calls = 0
    static var desktopCalls = 0
    static var desktopURL: URL?
    static func openInCursor(cwd: String) { desktopCalls += 1 }
    private static func launch(command: String, cwd: String, sessionId: String) { calls += 1 }
}
@MainActor struct NSWorkspace {
    static let shared = NSWorkspace()
    func open(_ url: URL) -> Bool { TerminalLauncher.desktopURL = url; TerminalLauncher.desktopCalls += 1; return true }
}
''')
    (work/'Main.swift').write_text(r'''
import Foundation
import SQLite3
@main struct Regression {
    @MainActor static func main() async throws {
        let cwd = CommandLine.arguments[2], facts = CommandLine.arguments[3]
        let sourceID = "ea7f9767-42bb-491a-b7e9-f6b8de1d7f10"
        let ccSource = MigrationSource(client: .claude, sessionID: sourceID, cwd: cwd, title: "Fixture")
        let cxSource = MigrationSource(client: .codex, sessionID: sourceID, cwd: cwd, title: "Fixture")
        let ccData = try Data(contentsOf: fixtureRoot.appendingPathComponent("cc.jsonl"))
        let cxData = try Data(contentsOf: fixtureRoot.appendingPathComponent("codex.jsonl"))
        let cc = try MigrationHistory.claude(ccData, source: ccSource)
        let cx = try MigrationHistory.codex(cxData, source: cxSource)
        precondition(cc.messages == cx.messages && cc.messages.count == 2)
        precondition(cc.messages[0].text == facts && cc.messages[1].text == "ACK")
        precondition(!cc.messages.description.contains("PRIVATE") && !cc.messages.description.contains("Wrong sibling"))

        let desktopSource = MigrationSource(client:.cursorDesktop,sessionID:sourceID,cwd:cwd,title:"Fixture")
        let desktop = try MigrationCursorHistory.desktop(FilePaths.cursorStateDB,source:desktopSource)
        precondition(desktop.messages == cc.messages)
        let wrongWorkspace = MigrationSource(client:.cursorDesktop,sessionID:sourceID,cwd:"/wrong",title:"Fixture")
        mustFail { _ = try MigrationCursorHistory.desktop(FilePaths.cursorStateDB,source:wrongWorkspace) }
        var badOrdinal = try MigrationHistory.rows(cxData)
        badOrdinal[2]["ordinal"] = 99
        var badData = Data()
        for row in badOrdinal { badData += try MigrationHistory.json(row); badData.append(10) }
        mustFail { _ = try MigrationHistory.codex(badData,source:cxSource) }
        var rows = try MigrationHistory.rows(ccData)
        rows[2]["parentUuid"] = "missing"
        func data(_ rows: [[String: Any]]) throws -> Data {
            var out = Data()
            for row in rows { out += try MigrationHistory.json(row); out.append(10) }
            return out
        }
        mustFail { _ = try MigrationHistory.claude(data(rows), source: ccSource) }
        mustFail { _ = try MigrationHistory.claude(ccData.dropLast(), source: ccSource) }
        mustFail { _ = try MigrationHistory.claude(ccData + ccData, source: ccSource) }
        rows = try MigrationHistory.rows(ccData)
        rows[0]["message"] = ["role":"user", "content":[["type":"image","source":["data":"NOT_AN_IMAGE"]]]]
        mustFail { _ = try MigrationHistory.claude(data(rows), source: ccSource) }
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        var imageRows = try MigrationHistory.rows(ccData)
        imageRows[0]["message"] = ["role":"user","content":[
            ["type":"text","text":facts],
            ["type":"image","source":["type":"base64","media_type":"image/png","data":png]]]]
        mustFail { _ = try MigrationHistory.claude(data(imageRows), source: ccSource) }
        let imagePreview = try MigrationHistory.claude(data(imageRows), source: ccSource, includeImages: true)
        precondition(imagePreview.imageCount == 1 && imagePreview.messages[0].text == facts)
        precondition(imagePreview.messages[0].images[0].mediaType == "image/png")
        precondition(imagePreview.messages[0].images[0].dataURL == "data:image/png;base64," + png)
        precondition(imagePreview.fingerprint != cc.fingerprint)
        precondition(imagePreview.omissions.contains("已携带用户图片，写入目标会话的对应图片字段。"))
        let imageRewritten = try MigrationHistory.claudeData(imagePreview.messages, sessionID: sourceID, cwd: cwd)
        let imageRound = try MigrationHistory.claude(imageRewritten, source: ccSource, includeImages: true)
        precondition(imageRound.messages.map(\.text) == imagePreview.messages.map(\.text))
        precondition(imageRound.messages[0].images == imagePreview.messages[0].images)
        let codexImage = try MigrationHistory.codexData(imagePreview.messages, sessionID: sourceID, cwd: cwd, providerKey: "fixture")
        precondition(String(decoding: codexImage, as: UTF8.self).contains("\"input_image\""))
        let codexRound = try MigrationHistory.codex(codexImage, source: cxSource, includeImages: true)
        precondition(codexRound.messages[0].images == imagePreview.messages[0].images)
        var badImage = imageRows
        badImage[0]["message"] = ["role":"user","content":[["type":"text","text":facts],
            ["type":"image","source":["type":"base64","media_type":"image/svg+xml","data":png]]]]
        mustFail { _ = try MigrationHistory.claude(data(badImage), source: ccSource, includeImages: true) }
        var audioRows = imageRows
        audioRows[0]["message"] = ["role":"user","content":[["type":"text","text":facts],["type":"audio","source":[:]]]]
        mustFail { _ = try MigrationHistory.claude(data(audioRows), source: ccSource, includeImages: true) }
        var assistantImage = imageRows
        var assistantMessage = assistantImage[2]["message"] as! [String: Any]
        assistantMessage["content"] = [["type":"text","text":"ACK"],
            ["type":"image","source":["type":"base64","media_type":"image/png","data":png]]]
        assistantImage[2]["message"] = assistantMessage
        mustFail { _ = try MigrationHistory.claude(data(assistantImage), source: ccSource, includeImages: true) }
        rows = try MigrationHistory.rows(ccData)
        rows.append(["type":"system", "subtype":"compact_boundary"])
        mustFail { _ = try MigrationHistory.claude(data(rows), source: ccSource) }
        rows = try MigrationHistory.rows(cxData)
        rows.append(["type":"history_base","payload":["thread_id":"foreign"]])
        mustFail { _ = try MigrationHistory.codex(data(rows), source: cxSource) }
        rows = try MigrationHistory.rows(cxData)
        rows.removeLast()
        mustFail { _ = try MigrationHistory.codex(data(rows), source: cxSource) }
        rows = try MigrationHistory.rows(ccData)
        rows[2]["message"] = ["role":"assistant","content":[["type":"tool_use","id":"pending","name":"Bash"]]]
        mustFail { _ = try MigrationHistory.claude(data(rows), source: ccSource) }
        let atLimit = [MigrationMessage(role:.user,text:String(repeating:"x",count:MigrationHistory.maxTextBytes-3)),
                       .init(role:.assistant,text:"ACK")]
        _ = try MigrationHistory.preview(source:ccSource,messages:atLimit,snapshot:Data())
        let huge = [MigrationMessage(role:.user,text:String(repeating:"x",count:MigrationHistory.maxTextBytes-2)),
                    .init(role:.assistant,text:"ACK")]
        do {
            _ = try MigrationHistory.preview(source:ccSource,messages:huge,snapshot:Data())
            preconditionFailure("text budget must remain enforced")
        } catch MigrationFailure.sizeLimit(let reason) { precondition(reason.contains("400,000")) }

        // Large source logs can mostly be omitted telemetry. The old 16 MiB
        // read budget rejected these even when the imported body was tiny.
        var telemetryRows = try MigrationHistory.rows(cxData)
        telemetryRows[telemetryRows.count-1]["padding"] = String(repeating:"x",count:17*1024*1024)
        let largeSource = try data(telemetryRows)
        let sourceURL = fixtureRoot.appendingPathComponent("large-source.jsonl")
        try largeSource.write(to:sourceURL)
        mustFail { _ = try MigrationStorage.readBounded(sourceURL) }
        let loadedSource = try MigrationStorage.readBounded(sourceURL,maxBytes:MigrationHistory.maxSourceFileBytes)
        let largePreview = try MigrationHistory.codex(loadedSource,source:cxSource)
        precondition(largePreview.messages == cx.messages && largePreview.fingerprint != cx.fingerprint)
        let largeImport = try MigrationHistory.claudeData(largePreview.messages,sessionID:sourceID,cwd:cwd)
        precondition(largeImport.count < MigrationHistory.maxFileBytes)
        // A sparse file exercises the upper read boundary without a giant fixture.
        let oversizedURL = fixtureRoot.appendingPathComponent("oversized-source.jsonl")
        FileManager.default.createFile(atPath:oversizedURL.path,contents:nil)
        let oversizedHandle = try FileHandle(forWritingTo:oversizedURL)
        try oversizedHandle.truncate(atOffset:UInt64(MigrationHistory.maxSourceFileBytes+1))
        try oversizedHandle.close()
        do {
            _ = try MigrationStorage.readBounded(oversizedURL,maxBytes:MigrationHistory.maxSourceFileBytes)
            preconditionFailure("source budget must remain enforced")
        } catch MigrationFailure.sizeLimit(let reason) { precondition(reason.contains("64 MiB")) }
        for invalid in [Data([0x0a,0xff]), Data(repeating:0xff,count:12), Data([0x00])] {
            mustFail { _ = try MigrationCursorHistory.fields(invalid) }
        }

        // Compaction markers do not remove canonical messages from a
        // contiguous paginated rollout. Never duplicate the replacement body.
        var compactedRows = try MigrationHistory.rows(cxData)
        compactedRows.insert(["type":"compacted", "payload":["message":"PRIVATE_COMPACTION",
            "replacement_history":[["type":"message","role":"user","content":[["type":"input_text","text":"WRONG_REPLACEMENT"]]]]]],at:6)
        compactedRows.insert(["type":"event_msg","payload":["type":"context_compacted"]],at:7)
        for index in compactedRows.indices { compactedRows[index]["ordinal"] = index }
        let compactedPreview = try MigrationHistory.codex(data(compactedRows),source:cxSource)
        precondition(compactedPreview.messages == cx.messages && compactedPreview.omissions.contains(where:{ $0.contains("压缩") }))
        precondition(!compactedPreview.messages.description.contains("PRIVATE_COMPACTION")
                     && !compactedPreview.messages.description.contains("WRONG_REPLACEMENT"))
        var missingPage = compactedRows; missingPage.remove(at:4)
        mustFail { _ = try MigrationHistory.codex(data(missingPage),source:cxSource) }
        var externalPage = compactedRows
        externalPage.insert(["type":"history_reference","payload":["page":"missing"]],at:5)
        for index in externalPage.indices { externalPage[index]["ordinal"] = index }
        mustFail { _ = try MigrationHistory.codex(data(externalPage),source:cxSource) }
        var legacyCompacted = compactedRows
        legacyCompacted[0]["payload"] = ["id":sourceID,"cwd":cwd,"history_mode":"legacy"]
        mustFail { _ = try MigrationHistory.codex(data(legacyCompacted),source:cxSource) }
        var unknownCompaction = compactedRows; unknownCompaction[6]["payload"] = ["message":"PRIVATE_COMPACTION"]
        mustFail { _ = try MigrationHistory.codex(data(unknownCompaction),source:cxSource) }

        var toolRows = try MigrationHistory.rows(ccData)
        toolRows.append(["type":"assistant","uuid":"call-row","parentUuid":"a","sessionId":sourceID,
            "message":["role":"assistant","content":[["type":"tool_use","id":"foreign-call-private-1","name":"Bash","input":["command":"fixture"]]]]])
        toolRows.append(["type":"user","uuid":"result-row","parentUuid":"call-row","sessionId":sourceID,
            "message":["role":"user","content":[["type":"tool_result","tool_use_id":"foreign-call-private-1","content":"TOOL_FACT-only-in-result","is_error":true]]]])
        toolRows.append(["type":"assistant","uuid":"final-row","parentUuid":"result-row","sessionId":sourceID,
            "message":["role":"assistant","content":"Completed"]])
        let withTools = try MigrationHistory.claude(data(toolRows),source:ccSource,includeCompletedTools:true)
        let textOnly = try MigrationHistory.claude(data(toolRows),source:ccSource)
        precondition(withTools.completedToolCount == 1 && withTools.messages.count == 4)
        precondition(withTools.fingerprint != textOnly.fingerprint)
        let toolText = withTools.messages.map(\.text).joined()
        precondition(toolText.contains("TOOL_FACT-only-in-result") && toolText.contains("\"is_error\":true"))
        precondition(!toolText.contains("foreign-call-private-1") && !toolText.contains("PRIVATE_THOUGHT"))
        precondition(!textOnly.messages.map(\.text).joined().contains("TOOL_FACT-only-in-result"))
        var partialTools = toolRows; partialTools.remove(at:partialTools.count-2)
        mustFail { _ = try MigrationHistory.claude(data(partialTools),source:ccSource,includeCompletedTools:true) }

        var parallel = try MigrationHistory.rows(ccData)
        parallel += [
            ["type":"assistant","uuid":"parallel-r","parentUuid":"a","sessionId":sourceID,
             "message":["id":"msg_parallel","role":"assistant","content":[["type":"tool_use","id":"read-call","name":"Read","input":["file_path":"missing"]]]]],
            ["type":"assistant","uuid":"parallel-b","parentUuid":"parallel-r","sessionId":sourceID,
             "message":["id":"msg_parallel","role":"assistant","content":[["type":"tool_use","id":"bash-call","name":"Bash","input":["command":"fixture"]]]]],
            ["type":"user","uuid":"parallel-read-result","parentUuid":"parallel-r","sessionId":sourceID,
             "message":["role":"user","content":[["type":"tool_result","tool_use_id":"read-call","content":"PARALLEL_ERROR","is_error":true]]]],
            ["type":"user","uuid":"parallel-bash-result","parentUuid":"parallel-b","sessionId":sourceID,
             "message":["role":"user","content":[["type":"tool_result","tool_use_id":"bash-call","content":"PARALLEL_SUCCESS"]]]],
            ["type":"assistant","uuid":"parallel-final","parentUuid":"parallel-bash-result","sessionId":sourceID,
             "message":["role":"assistant","content":"Completed parallel"]]]
        let parallelPreview = try MigrationHistory.claude(data(parallel),source:ccSource,includeCompletedTools:true)
        precondition(parallelPreview.completedToolCount == 2 && parallelPreview.messages.map(\.text).joined().contains("PARALLEL_ERROR"))
        let parallelText = try MigrationHistory.claude(data(parallel),source:ccSource)
        precondition(!parallelText.messages.map(\.text).joined().contains("PARALLEL_ERROR"))
        var wrongBranch = parallel
        wrongBranch[5]["parentUuid"] = "branch-old"
        mustFail { _ = try MigrationHistory.claude(data(wrongBranch),source:ccSource,includeCompletedTools:true) }
        var duplicatedParallel = parallel
        var duplicateResult = parallel[5]; duplicateResult["uuid"] = "duplicate-result"
        duplicatedParallel.insert(duplicateResult,at:duplicatedParallel.count-1)
        mustFail { _ = try MigrationHistory.claude(data(duplicatedParallel),source:ccSource,includeCompletedTools:true) }
        var mixedSibling = parallel
        var mixedMessage = mixedSibling[5]["message"] as! [String:Any]
        var mixedBlocks = mixedMessage["content"] as! [[String:Any]]
        mixedBlocks.append(["type":"text","text":"Do not merge unrelated sibling prose"])
        mixedMessage["content"] = mixedBlocks; mixedSibling[5]["message"] = mixedMessage
        mustFail { _ = try MigrationHistory.claude(data(mixedSibling),source:ccSource,includeCompletedTools:true) }
        var legacyTools = try MigrationHistory.rows(MigrationHistory.codexData(cc.messages,sessionID:sourceID,cwd:cwd,providerKey:"fixture"))
        legacyTools.append(["type":"response_item","payload":["type":"custom_tool_call","call_id":"foreign-call","name":"exec_command","input":"fixture"]])
        legacyTools.append(["type":"response_item","payload":["type":"custom_tool_call_output","call_id":"foreign-call","output":"TOOL_FACT-only-in-result"]])
        legacyTools.append(["type":"response_item","payload":["type":"message","role":"assistant","content":[["type":"output_text","text":"Completed"]]]])
        let cxTools = try MigrationHistory.codex(data(legacyTools),source:cxSource,includeCompletedTools:true)
        precondition(cxTools.completedToolCount == 1 && cxTools.messages.count == 4)
        precondition(cxTools.messages.map(\.text).joined().contains("TOOL_FACT-only-in-result"))
        precondition(!cxTools.messages.map(\.text).joined().contains("foreign-call"))
        let bashTool = withTools.messages.compactMap(\.tool).first
        precondition(bashTool?.name == "Bash" && bashTool?.inputJSON == "{\"command\":\"fixture\"}", "bash input")
        precondition(bashTool?.outputJSON.contains("TOOL_FACT-only-in-result") == true)
        precondition(bashTool?.outputJSON.contains("\"is_error\":true") == true)
        precondition(bashTool?.inputJSON.contains("foreign-call") != true)
        let archivedCC = String(decoding: try MigrationHistory.claudeData(withTools.messages, sessionID: sourceID, cwd: cwd), as: UTF8.self)
        precondition(archivedCC.contains("\"tool_use\"") && archivedCC.contains("\"tool_result\"") && archivedCC.contains("\"is_error\":true"))
        precondition(!archivedCC.contains("迁移的已完成工具记录") && !archivedCC.contains("foreign-call-private-1"), "cc archive leaked")
        let rereadArchived = try MigrationHistory.claude(Data(archivedCC.utf8), source: ccSource, includeCompletedTools: true)
        precondition(rereadArchived.completedToolCount == 1, "cc reread count")
        precondition(rereadArchived.messages.compactMap(\.tool).first?.name == "Bash", "cc reread name")
        precondition(rereadArchived.messages.compactMap(\.tool).first?.inputJSON == bashTool?.inputJSON)
        let execTool = cxTools.messages.compactMap(\.tool).first
        precondition(execTool?.name == "exec_command" && execTool?.inputJSON == "\"fixture\"")
        // Real rollouts carry more `item_completed` tool items than
        // response_item call/output pairs (measured 89 vs 73 and 610 vs 420 in
        // this machine's own sessions; their ids share no value, so no pairing
        // is possible). The old gate — `canonicalTools > completedTools` —
        // compared those two projections and refused ordinary paginated
        // history with 工具格式尚未验证. A tool item with no paired
        // function_call is legitimate and must not refuse the migration; an
        // *unpaired output*, below, still must.
        var mixedProjections = legacyTools
        mixedProjections.insert(["type":"event_msg","payload":["type":"item_completed",
            "item":["type":"CommandExecution","id":"exec-unpaired",
                    "command":["argv":["echo","fixture"]],"status":"completed"]]], at: 3)
        mixedProjections.insert(["type":"event_msg","payload":["type":"item_completed",
            "item":["type":"McpToolCall","id":"mcp-unpaired","status":"completed"]]], at: 4)
        let mixedPreview = try MigrationHistory.codex(data(mixedProjections), source: cxSource, includeCompletedTools: true)
        precondition(mixedPreview.completedToolCount == 1,
                     "unpaired completed items must not be counted as carried tools")
        precondition(!mixedPreview.omissions.contains { $0.contains("尚未验证") },
                     "an unpaired tool item must not refuse the migration")
        mustFail { _ = try MigrationHistory.codex(data(legacyTools + [
            ["type":"response_item","payload":["type":"custom_tool_call_output","call_id":"never-opened","output":"x"]]]),
            source: cxSource, includeCompletedTools: true) }
        let archivedCodex = String(decoding: try MigrationHistory.codexData(cxTools.messages, sessionID: sourceID, cwd: cwd, providerKey: "fixture"), as: UTF8.self)
        precondition(archivedCodex.contains("\"function_call\"") && archivedCodex.contains("\"function_call_output\""), "codex native")
        precondition(!archivedCodex.contains("迁移的已完成工具记录") && !archivedCodex.contains("foreign-call"), "codex leaked")
        let codexToolReread = try MigrationHistory.codex(Data(archivedCodex.utf8), source: cxSource, includeCompletedTools: true)
        precondition(codexToolReread.completedToolCount == 1, "codex reread count")
        precondition(codexToolReread.messages.compactMap(\.tool).first?.inputJSON == "\"fixture\"")
        var toolImage = toolRows
        var resultMessage = toolImage[toolImage.count - 2]["message"] as! [String: Any]
        resultMessage["content"] = [["type":"tool_result","tool_use_id":"foreign-call-private-1","is_error":false,
            "content":[["type":"text","text":"TOOL_FACT-only-in-result"],
                       ["type":"image","source":["type":"base64","media_type":"image/png","data":png]]]]]
        toolImage[toolImage.count - 2]["message"] = resultMessage
        mustFail { _ = try MigrationHistory.claude(data(toolImage), source: ccSource, includeCompletedTools: true) }
        let toolImages = try MigrationHistory.claude(data(toolImage), source: ccSource, includeCompletedTools: true, includeImages: true)
        let carriedTool = toolImages.messages.compactMap(\.tool).first
        precondition(toolImages.imageCount == 1 && carriedTool?.images.first?.dataURL == "data:image/png;base64," + png)
        precondition(carriedTool?.outputJSON.contains(png) != true)
        precondition(!toolImages.messages.map(\.text).joined().contains(png))
        precondition(toolImages.fingerprint != withTools.fingerprint)
        precondition(toolImages.omissions.contains("工具结果中的图片不放进工具输出文本，写入目标的图片字段。"))
        let toolImageCC = String(decoding: try MigrationHistory.claudeData(toolImages.messages, sessionID: sourceID, cwd: cwd), as: UTF8.self)
        precondition(toolImageCC.contains(png) && toolImageCC.contains("\"tool_result\"") && toolImageCC.contains("\"tool_use\""))
        precondition(!toolImageCC.contains("迁移的已完成工具记录") && !toolImageCC.contains("foreign-call"))
        let toolImageReread = try MigrationHistory.claude(Data(toolImageCC.utf8), source: ccSource, includeCompletedTools: true, includeImages: true)
        precondition(toolImageReread.completedToolCount == 1 && toolImageReread.imageCount == 1)
        precondition(toolImageReread.messages.compactMap(\.tool).first?.images.first?.dataURL == "data:image/png;base64," + png)
        let toolImageCodex = String(decoding: try MigrationHistory.codexData(toolImages.messages, sessionID: sourceID, cwd: cwd, providerKey: "fixture"), as: UTF8.self)
        precondition(toolImageCodex.contains("\"input_image\"") && toolImageCodex.contains(png))
        let toolImageSkipped = try MigrationHistory.claude(data(toolImage), source: ccSource, includeImages: true)
        precondition(toolImageSkipped.imageCount == 0 && !toolImageSkipped.messages.map(\.text).joined().contains(png))
        var toolDocument = toolImage
        var documentMessage = toolDocument[toolDocument.count - 2]["message"] as! [String: Any]
        documentMessage["content"] = [["type":"tool_result","tool_use_id":"foreign-call-private-1",
            "content":[["type":"document","source":["type":"base64","media_type":"application/pdf","data":png]]]]]
        toolDocument[toolDocument.count - 2]["message"] = documentMessage
        mustFail { _ = try MigrationHistory.claude(data(toolDocument), source: ccSource, includeCompletedTools: true, includeImages: true) }

        let physicalCwd = try MigrationPath.canonical(cwd)
        let logicalAlias = fixtureRoot.appendingPathComponent("project-alias")
        try FileManager.default.createSymbolicLink(at:logicalAlias,withDestinationURL:URL(fileURLWithPath:cwd))
        let aliasCwd = try MigrationPath.canonical(logicalAlias.path)
        precondition(aliasCwd == physicalCwd)
        let aliasesMatch = try MigrationCursorHistory.workspaceHash(logicalAlias.path) == MigrationCursorHistory.workspaceHash(cwd)
        precondition(aliasesMatch)
        let locations = SessionMigrationService.locations
        for url in [locations.claude, locations.codex, locations.cursorCLI, locations.records] {
            try MigrationStorage.directory(url)
        }
        // The Codex target path follows the client's own convention, measured
        // on real rollouts: the day folder and the filename stamp are the
        // local wall clock. Stamping UTC instead misfiled every run between
        // 00:00 and 08:00 local into the previous day (and at a month
        // boundary, into a folder the readers' day-walk never descends to).
        // 00:30 local is the case that separates the two: it is a different
        // UTC day on any zone east of Greenwich.
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = .current
        let localMidnight = localCalendar.startOfDay(for: Date())
        let shortlyAfterMidnight = localMidnight.addingTimeInterval(30 * 60)
        let midnightURL = try locations.nativeURL(client: .codex, sessionID: UUID().uuidString.lowercased(),
                                                  cwd: cwd, now: shortlyAfterMidnight)
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.timeZone = .current
        dayFormat.dateFormat = "yyyy/MM/dd"
        precondition(midnightURL.deletingLastPathComponent().path.hasSuffix(
            "sessions/" + dayFormat.string(from: shortlyAfterMidnight)),
            "the Codex rollout folder must be the local civil day, not UTC")
        precondition(midnightURL.lastPathComponent.hasPrefix(
            "rollout-" + { () -> String in
                let stamp = DateFormatter()
                stamp.locale = Locale(identifier: "en_US_POSIX")
                stamp.timeZone = .current
                stamp.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
                return stamp.string(from: shortlyAfterMidnight)
            }()), "the rollout filename stamp must be the local wall clock")
        try PrivateFileWriter.write(Data("model=\"test-model\"\n".utf8),to:FilePaths.codexConfigFile)
        try PrivateFileWriter.write(Data("{}".utf8),to:FilePaths.settingsFile)
        let route = MigrationRoute(model:"test-model",providerKey:"fixture_provider",
                                   configurationFingerprint:nil,executablePath:fixtureHome.appendingPathComponent(".local/bin/codex").path)
        let a = try MigrationStorage.prepare(cc,target:.codexCurrent,route:route,locations:locations)
        let reused = try MigrationStorage.prepare(cc,target:.codexCurrent,route:route,locations:locations)
        precondition(a == reused, "same source tip must not create duplicate targets")
        let native = try Data(contentsOf:URL(fileURLWithPath:a.nativePath))
        let nativeText = String(decoding:native,as:UTF8.self)
        precondition(!nativeText.contains("rs_FOREIGN") && !nativeText.contains("PRIVATE"))
        let decoded = try MigrationHistory.codex(native,source:a.targetSource)
        precondition(decoded.messages == cc.messages)
        // Current clients can append canonical events to a legacy import.
        // The original projected messages must still survive the next migration.
        var resumed = try MigrationHistory.rows(native)
        resumed.append(["type":"response_item","payload":["type":"message","role":"user",
            "content":[["type":"input_text","text":"New turn"]]]])
        resumed.append(["type":"event_msg","payload":["type":"item_completed",
            "item":["type":"UserMessage","content":[["type":"text","text":"New turn"]]]]])
        resumed.append(["type":"response_item","payload":["type":"message","role":"assistant",
            "content":[["type":"output_text","text":"New answer"]]]])
        resumed.append(["type":"event_msg","payload":["type":"item_completed",
            "item":["type":"AgentMessage","content":[["type":"Text","text":"New answer"]]]]])
        let reRead = try MigrationHistory.codex(data(resumed),source:a.targetSource)
        precondition(reRead.messages.count == 4 && reRead.messages[0].text == facts)
        let b = try MigrationStorage.prepare(decoded,target:.claude,route:route,locations:locations)
        precondition(a.logicalConversationID == b.logicalConversationID)
        let decodedCC = try MigrationHistory.claude(Data(contentsOf:URL(fileURLWithPath:b.nativePath)),source:b.targetSource)
        precondition(decodedCC.messages == cc.messages)
        let c = try MigrationStorage.prepare(cc,target:.cursorCLI,route:route,locations:locations)
        let cursor = try MigrationCursorHistory.cli(URL(fileURLWithPath:c.nativePath),source:c.targetSource)
        precondition(cursor.messages == cc.messages)
        // A native root may become visible before its message blob. Simulate
        // delayed persistence, not a model response.
        var db: OpaquePointer?
        precondition(sqlite3_open(c.nativePath, &db) == SQLITE_OK)
        let metadataData = try MigrationCursorHistory.value(db!,sql:"SELECT value FROM meta WHERE key = ?",key:"0")
        let metadata = try MigrationCursorHistory.object(MigrationCursorHistory.decodeHex(String(decoding:metadataData,as:UTF8.self))!)
        let rootData = try MigrationCursorHistory.value(db!,sql:"SELECT data FROM blobs WHERE id = ?",key:metadata["latestRootBlobId"] as! String)
        let reference = try MigrationCursorHistory.fields(rootData).first { $0.number == 1 }!.bytes!
        let blobID = reference.map { String(format:"%02x",$0) }.joined()
        let blob = try MigrationCursorHistory.value(db!,sql:"SELECT data FROM blobs WHERE id = ?",key:blobID)
        precondition(sqlite3_exec(db,"DELETE FROM blobs WHERE id = '" + blobID + "'",nil,nil,nil) == SQLITE_OK)
        sqlite3_close(db)
        let storePath = c.nativePath
        DispatchQueue.global().asyncAfter(deadline:.now()+0.15) {
            var writer: OpaquePointer?, stmt: OpaquePointer?
            precondition(sqlite3_open(storePath,&writer) == SQLITE_OK)
            precondition(sqlite3_prepare_v2(writer,"INSERT INTO blobs VALUES (?,?)",-1,&stmt,nil) == SQLITE_OK)
            sqlite3_bind_text(stmt,1,blobID,-1,SQLITE_TRANSIENT)
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt,2,$0.baseAddress,Int32($0.count),SQLITE_TRANSIENT) }
            precondition(sqlite3_step(stmt) == SQLITE_DONE)
            sqlite3_finalize(stmt);sqlite3_close(writer)
        }
        let recoveredCursor = try MigrationCursorHistory.cli(URL(fileURLWithPath:c.nativePath),source:c.targetSource)
        precondition(recoveredCursor.messages == cursor.messages)
        precondition(tryRecords(locations.records).count == 3)
        // Containment must remain stable after parent directories are created.
        let nested = locations.claude.appendingPathComponent("projects/new-child/a.jsonl")
        precondition(locations.containsNative(nested,client:.claude))
        try MigrationStorage.directory(nested.deletingLastPathComponent())
        precondition(locations.containsNative(nested,client:.claude))
        for path in [a.nativePath,b.nativePath,c.nativePath,
                     locations.records.appendingPathComponent(a.id.uuidString+".json").path] {
            let mode = try FileManager.default.attributesOfItem(atPath:path)[.posixPermissions] as! NSNumber
            precondition(mode.intValue & 0o077 == 0, "history must be private")
        }
        precondition(ShellQuote.single("a'$(touch NEVER)").contains("'\\''"))
        let command = try MigrationCommand.shell(for:a,locations:locations)
        try command.write(to:fixtureRoot.appendingPathComponent("command.txt"),atomically:true,encoding:.utf8)
        precondition(!command.contains("--dangerously"))
        var badSource = ccSource; badSource.isBusy = true
        let busy = MigrationPreview(source:badSource,messages:cc.messages,fingerprint:"x",omissions:[])
        mustFail { _ = try MigrationStorage.prepare(busy,target:.claude,route:route,locations:locations) }

        let blocked = fixtureRoot.appendingPathComponent("blocked"); try MigrationStorage.directory(blocked)
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:blocked.path)
        let failing = MigrationLocations(claude:blocked,codex:blocked,cursorCLI:blocked,records:locations.records)
        let changed = MigrationPreview(source:ccSource,messages:cc.messages,fingerprint:"different-tip",omissions:[])
        mustFail { _ = try MigrationStorage.prepare(changed,target:.claude,route:route,locations:failing) }
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:blocked.path)
        let original = try Data(contentsOf:fixtureRoot.appendingPathComponent("cc.jsonl"))
        precondition(original == ccData && tryRecords(locations.records).count == 3)

        let desktopFingerprint = try MigrationCursorDesktop.profile(FilePaths.cursorStateDB,cwd:cwd).fingerprint()
        let desktopRoute = MigrationRoute(model:"grok-fixture",providerKey:"",configurationFingerprint:desktopFingerprint,
            executablePath:fixtureRoot.appendingPathComponent("Cursor.app/Contents/MacOS/Cursor").path)
        let desk = try MigrationStorage.prepare(cc,target:.cursorDesktop,route:desktopRoute,locations:locations)
        let deskAgain = try MigrationStorage.prepare(cc,target:.cursorDesktop,route:desktopRoute,locations:locations)
        precondition(desk == deskAgain)
        let deskRead = try MigrationCursorHistory.desktop(FilePaths.cursorStateDB,source:desk.targetSource)
        precondition(deskRead.messages == cc.messages)
        let originalDesk = try MigrationCursorHistory.desktop(FilePaths.cursorStateDB,source:desktopSource)
        precondition(originalDesk.messages == desktop.messages)
        // An exception during manifest publication rolls back all native rows.
        let profile = try MigrationCursorDesktop.profile(FilePaths.cursorStateDB,cwd:cwd)
        precondition((profile.workspace["uri"] as? [String:Any])?["fsPath"] as? String == cwd)
        let aliasProfile = try MigrationCursorDesktop.profile(FilePaths.cursorStateDB,cwd:logicalAlias.path)
        precondition((aliasProfile.workspace["uri"] as? [String:Any])?["fsPath"] as? String == cwd)
        let rejected = MigrationRecord(id:UUID(),logicalConversationID:UUID(),createdAt:Date(),source:ccSource,
            sourceFingerprint:cc.fingerprint,target:.cursorDesktop,targetSessionID:UUID().uuidString.lowercased(),
            nativePath:FilePaths.cursorStateDB.path,messageCount:2,omissions:[],model:profile.modelName,
            providerKey:"",configurationFingerprint:nil,executablePath:desktopRoute.executablePath)
        mustFail { try MigrationCursorDesktop.insert(cc.messages,record:rejected,profile:profile,database:FilePaths.cursorStateDB) {
            throw MigrationFailure.storage
        } }
        let rejectedExists = try MigrationStorage.exists(rejected)
        precondition(!rejectedExists)
        // A colliding session identity must not replace the existing target.
        mustFail { try MigrationCursorDesktop.insert(cc.messages,record:desk,profile:profile,database:FilePaths.cursorStateDB) {} }
        let deskUnchanged = try MigrationCursorHistory.desktop(FilePaths.cursorStateDB,source:desk.targetSource)
        precondition(deskUnchanged.messages == deskRead.messages)
        var collisionDB: OpaquePointer?
        precondition(sqlite3_open(FilePaths.cursorStateDB.path,&collisionDB) == SQLITE_OK)
        // Same model name with changed maxMode must not reuse a stale target.
        // Later image writes create newer composers, so this mutation has to run while desk is still newest.
        let composerKey = "composerData:" + desk.targetSessionID
        let composerBytes = try MigrationCursorHistory.value(collisionDB!,sql:"SELECT value FROM cursorDiskKV WHERE key = ?",key:composerKey)
        var changedComposer = try MigrationCursorHistory.object(composerBytes)
        var changedModel = changedComposer["modelConfig"] as! [String:Any]
        changedModel["maxMode"] = true; changedComposer["modelConfig"] = changedModel
        let changedHex = try MigrationHistory.json(changedComposer).map { String(format:"%02x",$0) }.joined()
        precondition(sqlite3_exec(collisionDB,"UPDATE cursorDiskKV SET value = CAST(X'" + changedHex + "' AS TEXT) WHERE key = '" + composerKey + "'",nil,nil,nil) == SQLITE_OK)
        mustFail { _ = try MigrationStorage.prepare(cc,target:.cursorDesktop,route:desktopRoute,locations:locations) }
        let composerHex = composerBytes.map { String(format:"%02x",$0) }.joined()
        precondition(sqlite3_exec(collisionDB,"UPDATE cursorDiskKV SET value = CAST(X'" + composerHex + "' AS TEXT) WHERE key = '" + composerKey + "'",nil,nil,nil) == SQLITE_OK)
        let orphanKey = "composerData:" + rejected.targetSessionID
        precondition(sqlite3_exec(collisionDB,"INSERT INTO cursorDiskKV VALUES ('" + orphanKey + "', '{\"unrelated\":true}')",nil,nil,nil) == SQLITE_OK)
        mustFail { try MigrationCursorDesktop.insert(cc.messages,record:rejected,profile:profile,database:FilePaths.cursorStateDB) {} }
        let orphanPreserved = try MigrationCursorHistory.value(collisionDB!,sql:"SELECT value FROM cursorDiskKV WHERE key = ?",key:orphanKey)
        precondition(String(decoding:orphanPreserved,as:UTF8.self) == "{\"unrelated\":true}")
        precondition(sqlite3_exec(collisionDB,"DELETE FROM cursorDiskKV WHERE key = '" + orphanKey + "'",nil,nil,nil) == SQLITE_OK)
        let shared = try MigrationHistory.json(["role":"user","content":[["type":"text","text":facts]]])
        let sharedKey = "agentKv:blob:" + MigrationHistory.fingerprint(shared)
        precondition(sqlite3_exec(collisionDB,"UPDATE cursorDiskKV SET value = X'636f7272757074' WHERE key = '" + sharedKey + "'",nil,nil,nil) == SQLITE_OK)
        mustFail { try MigrationCursorDesktop.insert(cc.messages,record:rejected,profile:profile,database:FilePaths.cursorStateDB) {} }
        let hex = shared.map { String(format:"%02x",$0) }.joined()
        precondition(sqlite3_exec(collisionDB,"UPDATE cursorDiskKV SET value = X'" + hex + "' WHERE key = '" + sharedKey + "'",nil,nil,nil) == SQLITE_OK)
        precondition(sqlite3_exec(collisionDB,"BEGIN IMMEDIATE",nil,nil,nil) == SQLITE_OK)
        mustFail { try MigrationCursorDesktop.insert(cc.messages,record:rejected,profile:profile,database:FilePaths.cursorStateDB) {} }
        precondition(sqlite3_exec(collisionDB,"ROLLBACK",nil,nil,nil) == SQLITE_OK)
        sqlite3_close(collisionDB)
        mustFail { _ = try MigrationCursorDesktop.profile(FilePaths.cursorStateDB,cwd:fixtureRoot.path) }
        mustFail { _ = try MigrationStorage.prepare(imagePreview,target:.cursorDesktop,route:route,locations:locations) }
        mustFail { _ = try MigrationStorage.prepare(imagePreview,target:.cursorCLI,route:route,locations:locations) }
        mustFail { _ = try MigrationStorage.prepare(toolImages,target:.cursorDesktop,route:route,locations:locations) }
        mustFail { _ = try MigrationStorage.prepare(toolImages,target:.cursorCLI,route:route,locations:locations) }
        let cursorImage = try MigrationStorage.prepare(imagePreview,target:.cursorDesktop,route:desktopRoute,locations:locations)
        let cursorImageRead = try MigrationCursorHistory.desktop(FilePaths.cursorStateDB,source:cursorImage.targetSource,includeImages:true)
        precondition(cursorImageRead.imageCount == 1 && cursorImageRead.messages[0].images.first?.mediaType == "image/png")
        let cursorToolImage = try MigrationStorage.prepare(toolImages,target:.cursorDesktop,route:desktopRoute,locations:locations)
        let cursorToolImageRead = try MigrationCursorHistory.desktop(FilePaths.cursorStateDB,source:cursorToolImage.targetSource,includeImages:true)
        precondition(cursorToolImageRead.imageCount == 1)
        let cursorToolPreview = try MigrationHistory.preview(source:desktopSource,messages:[
            .init(role:.user,text:facts),
            .init(role:.assistant,text:"",tool:.init(name:"read_file",inputJSON:"{\"path\":\"fixture\"}",outputJSON:"\"FILE\"",outputKind:"cursor",cursorTool:40,cursorStatus:"completed"))
        ],snapshot:Data("cursor-tool".utf8),completedToolCount:1)
        let cursorToolTarget = try MigrationStorage.prepare(cursorToolPreview,target:.cursorDesktop,route:desktopRoute,locations:locations)
        let cursorToolRead = try MigrationCursorHistory.desktop(FilePaths.cursorStateDB,source:cursorToolTarget.targetSource,includeCompletedTools:true)
        precondition(cursorToolRead.completedToolCount == 1)
        precondition(cursorToolRead.messages.compactMap(\.tool).first?.name == "read_file")
        precondition(cursorToolRead.messages.compactMap(\.tool).first?.cursorTool == 40)
        precondition(cursorToolRead.messages.compactMap(\.tool).first?.inputJSON == "{\"path\":\"fixture\"}")
        let imageTarget = try MigrationStorage.prepare(imagePreview,target:.claude,route:route,locations:locations)
        let installedImage = try MigrationHistory.claude(Data(contentsOf:URL(fileURLWithPath:imageTarget.nativePath)),
            source:imageTarget.targetSource,includeImages:true)
        precondition(installedImage.messages[0].images == imagePreview.messages[0].images)
        let toolsTarget = try MigrationStorage.prepare(withTools,target:.codexCurrent,route:route,locations:locations)
        precondition(toolsTarget.targetSessionID != a.targetSessionID)
        let toolsReRead = try MigrationHistory.codex(Data(contentsOf:URL(fileURLWithPath:toolsTarget.nativePath)),source:toolsTarget.targetSource,includeCompletedTools:true)
        precondition(toolsReRead.completedToolCount == 1)
        precondition(toolsReRead.messages.compactMap(\.tool).first?.name == "Bash")
        precondition(toolsReRead.messages.compactMap(\.tool).first?.inputJSON == withTools.messages.compactMap(\.tool).first?.inputJSON)
        let toolsNative = String(decoding:try Data(contentsOf:URL(fileURLWithPath:toolsTarget.nativePath)),as:UTF8.self)
        precondition(!toolsNative.contains("foreign-call") && toolsNative.contains("\"function_call\""))

        let service = SessionMigrationService.shared
        if BuildChannel.allowsSystemIntegration {
            let project = locations.claude.appendingPathComponent("projects/fixture")
            try MigrationStorage.directory(project)
            let path = project.appendingPathComponent(sourceID+".jsonl")
            try PrivateFileWriter.write(ccData,to:path)
            let live = try await service.preview(ccSource)
            try PrivateFileWriter.write(data(toolRows),to:path)
            let toolsLive = try await service.preview(ccSource,includeCompletedTools:true)
            do { _ = try await service.prepare(source:ccSource,target:.codexCurrent,fingerprint:toolsLive.fingerprint,
                officialModel:"",includeCompletedTools:false); preconditionFailure("tool mode mismatch") }
            catch MigrationFailure.changed {}
            try PrivateFileWriter.write(ccData,to:path)
            let desktopPrepared = try await service.prepare(source:ccSource,target:.cursorDesktop,
                fingerprint:live.fingerprint,officialModel:"")
            precondition(desktopPrepared == desk)
            let desktopCommand = try await service.command(for:desktopPrepared)
            precondition(desktopCommand.isEmpty)
            try TerminalLauncher.openMigratedSession(desktopPrepared,command:desktopCommand)
            precondition(TerminalLauncher.desktopCalls == 1 && TerminalLauncher.calls == 0)
            let desktopURL = TerminalLauncher.desktopURL!
            precondition(desktopURL.scheme == "cursor" && desktopURL.host == "anysphere.cursor-deeplink")
            precondition(URLComponents(url:desktopURL,resolvingAgainstBaseURL:false)?.queryItems == [.init(name:"bcId",value:desktopPrepared.targetSessionID)])
            do { _ = try await service.command(for:rejected); preconditionFailure("crash-orphan native identity") }
            catch MigrationFailure.missing {}

            let providerID = UUID(), fakeProvider:[String:Any] = ["id":providerID.uuidString,"name":"Fixture bridge",
                "apiKey":"private-fixture-provider-key","baseURL":"https://upstream.example/v1","wireAPI":"responses",
                "models":[["name":"fixture-model","reasoningEffort":"low"]]]
            var providers:[String:Any] = ["providers":[fakeProvider],"activeProviderID":providerID.uuidString]
            try PrivateFileWriter.write(MigrationHistory.json(providers),to:FilePaths.codexProvidersFile)
            let bridged = try await service.prepare(source:ccSource,target:.claudeCodexModel,
                fingerprint:live.fingerprint,officialModel:"",bridgeProviderID:providerID,bridgeModel:"fixture-model")
            precondition(bridged.bridgeProviderID == providerID && bridged.model == "fixture-model")
            let manifest = try Data(contentsOf:FilePaths.sessionMigrationsDir.appendingPathComponent(bridged.id.uuidString+".json"))
            precondition(!String(decoding:manifest,as:UTF8.self).contains("private-fixture-provider-key"))
            let bridgeLaunch = MigrationBridgeLaunch(port:32123,token:String(repeating:"a",count:64))
            let bridgeCommand = try await service.command(for:bridged,bridge:bridgeLaunch)
            precondition(bridgeCommand.contains("--settings"))
            let bridgeSettings = try JSONSerialization.jsonObject(with:Data(bridgeLaunch.settings(record:bridged).utf8)) as! [String:Any]
            precondition((bridgeSettings["env"] as! [String:String])["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:32123/migration/"+bridged.id.uuidString.lowercased())
            precondition(!bridgeCommand.contains("private-fixture-provider-key"))
            providers["activeProviderID"] = UUID().uuidString
            try PrivateFileWriter.write(MigrationHistory.json(providers),to:FilePaths.codexProvidersFile)
            _ = try await service.command(for:bridged,bridge:bridgeLaunch) // Global selection cannot retarget the record.
            var changedProvider = fakeProvider; changedProvider["apiKey"] = "new-wallet-fixture"
            providers["providers"] = [changedProvider]
            try PrivateFileWriter.write(MigrationHistory.json(providers),to:FilePaths.codexProvidersFile)
            do { _ = try await service.command(for:bridged,bridge:bridgeLaunch); preconditionFailure("bridge wallet must re-prepare") }
            catch MigrationFailure.changed {}
            precondition(MigrationBridgeConfiguration.responsesURL("https://upstream.example/api/v3")?.path == "/api/v3/responses")
            precondition(MigrationBridgeConfiguration.responsesURL("https://upstream.example/v1")?.path == "/v1/responses")
            var localProvider = fakeProvider; localProvider["baseURL"] = "http://127.0.0.1:15721/v1"
            let localData = try MigrationHistory.json(["providers":[localProvider]])
            mustFail { _ = try MigrationBridgeConfiguration.endpoint(localData,providerID:providerID,model:"fixture-model",localProxyPort:15721) }
            _ = try MigrationBridgeConfiguration.endpoint(localData,providerID:providerID,model:"fixture-model",localProxyPort:15722)
            precondition(MigrationBridgeConfiguration.route("/migration/"+bridged.id.uuidString+"/v1/messages")?.id == bridged.id)
            precondition(MigrationBridgeConfiguration.route("/migration/"+bridged.id.uuidString+"/v1/messages/count_tokens")?.countTokens == true)
            for invalid in ["/migration/../v1/messages","/migration/"+bridged.id.uuidString+"/v1/messages/extra","/migration//"+bridged.id.uuidString+"/v1/messages"] {
                precondition(MigrationBridgeConfiguration.route(invalid) == nil)
            }
            try FileManager.default.removeItem(at:FilePaths.codexProvidersFile)
            let record = try await service.prepare(source:ccSource,target:.codexCurrent,
                fingerprint:live.fingerprint,officialModel:"gpt-test")
            let shell = try await service.command(for:record)
            try TerminalLauncher.openMigratedSession(record,command:shell)
            precondition(TerminalLauncher.calls == 1)
            // Same-model proxy wallet switches may leave config.toml unchanged.
            try PrivateFileWriter.write(Data("provider-wallet-changed".utf8),to:FilePaths.codexProvidersFile)
            do { _ = try await service.command(for:record); preconditionFailure("wallet change must refuse") }
            catch MigrationFailure.changed {}
            try FileManager.default.removeItem(at:FilePaths.codexProvidersFile)
            try PrivateFileWriter.write(Data("changed\n".utf8),to:FilePaths.codexConfigFile)
            do { _ = try await service.command(for:record); preconditionFailure("config change must refuse") }
            catch MigrationFailure.changed {}
            try PrivateFileWriter.write(ccData+Data("\n".utf8),to:path)
            do {
                _ = try await service.prepare(source:ccSource,target:.claude,
                    fingerprint:live.fingerprint,officialModel:"gpt-test")
                preconditionFailure("source change must refuse")
            } catch MigrationFailure.changed {}
            let fresh = try await service.preview(ccSource)
            do {
                _ = try await service.prepare(source:ccSource,target:.codexOfficial,
                    fingerprint:fresh.fingerprint,officialModel:"gpt-test")
                preconditionFailure("missing official login must refuse")
            } catch MigrationFailure.unsupported {}
            try PrivateFileWriter.write(Data("{\"auth_mode\":\"chatgpt\",\"tokens\":{}}".utf8),to:FilePaths.codexAuthFile)
            let official = try await service.prepare(source:ccSource,target:.codexOfficial,
                fingerprint:fresh.fingerprint,officialModel:"gpt-test")
            let args = try MigrationCommand.arguments(for:official)
            precondition(args.contains("model_providers.claudebar_migration_official.requires_openai_auth=true"))
            precondition(official.providerKey != record.providerKey)
        } else {
            let invalid = MigrationSource(client:.cursorDesktop,sessionID:"../escape",cwd:"/absent",title:"")
            do { _ = try await service.preview(invalid); preconditionFailure("dev external read") }
            catch MigrationFailure.restricted {}
            do {
                _ = try await service.prepare(source:invalid,target:.codexOfficial,fingerprint:"",officialModel:"")
                preconditionFailure("dev native write")
            } catch MigrationFailure.restricted {}
            do { _ = try await service.command(for:a); preconditionFailure("dev launch command") }
            catch MigrationFailure.restricted {}
            do { _ = try await service.prepare(source:invalid,target:.cursorDesktop,fingerprint:"",officialModel:"")
                preconditionFailure("dev desktop write") } catch MigrationFailure.restricted {}
            do { _ = try await service.bridgeEndpoint(for:a); preconditionFailure("dev model bridge credential read") }
            catch MigrationFailure.restricted {}
            mustFail { try TerminalLauncher.openMigratedSession(a,command:"codex") }
            precondition(TerminalLauncher.calls == 0)
        }
        print("PASS: \(BuildChannel.name) branch parsing, native formats, privacy, dedup, revisions, rollback and external gates")
    }
    static func tryRecords(_ path:URL) -> [MigrationRecord] { try! MigrationStorage.records(at:path) }
}
''')
    for channel in ['dev','release','unlabelled']:
        channel_root = work / channel
        channel_root.mkdir()
        for name in ['cc.jsonl','codex.jsonl','desktop.sqlite']:
            (channel_root/name).write_bytes((work/name).read_bytes())
        (channel_root/'home/.local').mkdir(parents=True)
        os.symlink(cli,channel_root/'home/.local/bin')
        app = channel_root/'Cursor.app/Contents'
        (app/'MacOS').mkdir(parents=True)
        (app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString':'3.23.12'}))
        (app/'MacOS/Cursor').write_text('#!/bin/sh\nexit 98\n')
        (app/'MacOS/Cursor').chmod(0o700)
        binary = work / ('regression-'+channel)
        flags = [] if channel == 'unlabelled' else ['-D','CLAUDEBAR_'+channel.upper()]
        subprocess.run(['swiftc','-O',*flags,*map(str,sources),str(work/'Service.swift'),
                        str(work/'Stubs.swift'),str(work/'Main.swift'),'-lsqlite3','-o',str(binary)],check=True)
        subprocess.run([str(binary),str(channel_root),str(cwd),facts],check=True)
        desktop_db = sqlite3.connect(channel_root/'desktop.sqlite')
        for key, value in desktop_db.execute("SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'"):
            composer = json.loads(value)
            if key == 'composerData:'+source_id: continue
            assert isinstance(composer['codeBlockData'],dict)
            assert isinstance(composer['originalFileStates'],dict)
            assert isinstance(composer['usageData'],dict)
            assert composer['addedFiles'] == 0 and composer['removedFiles'] == 0
            assert 'PRIVATE' not in value
            assert 'accessToken' not in composer['modelConfig']
            assert composer['conversationState'].startswith('~')
            headers = composer['fullConversationHeadersOnly']
            # Two turns, or user + assistant text + tool + image follow-up + closing assistant.
            assert [item['type'] for item in headers] in ([1, 2], [1, 2, 2, 1, 2])
        desktop_db.close()
        db_path = next((channel_root/'cursor/chats').glob('*/*/store.db'))
        db = sqlite3.connect(db_path)
        value,kind = db.execute("SELECT value, typeof(value) FROM meta WHERE key='0'").fetchone()
        assert kind == 'text' and isinstance(value,str)
        meta = json.loads(bytes.fromhex(value))
        assert db.execute('SELECT COUNT(*) FROM blobs WHERE id=?',(meta['latestRootBlobId'],)).fetchone()[0] == 1
        assert set(db.execute('SELECT DISTINCT typeof(data) FROM blobs')) == {('blob',)}
        db.close()
        manifests = list((channel_root/'records').glob('*.json'))
        assert manifests
        for manifest in manifests:
            record = json.loads(manifest.read_text())
            assert all(key not in record for key in ['apiKey','access_token','authToken'])
            assert stat.S_IMODE(manifest.stat().st_mode) == 0o600
            if record['target'] == 'claude':
                physical = os.path.realpath(record['source']['cwd'])
                expected = ''.join(c if c.isascii() and c.isalnum() else '-' for c in physical)
                assert Path(record['nativePath']).parent.name == expected
        argv = shlex.split((channel_root/'command.txt').read_text())
        assert argv[0] == 'env' and argv[1] == 'CODEX_HOME='+str(channel_root/'codex')
        assert argv[2] == str(channel_root/'home/.local/bin/codex')
        assert argv[3:7] == ['-c','model_provider="fixture_provider"','-m','test-model']
    print('PASS: independent Cursor TEXT/BLOB schema, quoted argv and credential-free private manifests')
