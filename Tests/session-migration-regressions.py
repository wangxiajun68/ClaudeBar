#!/usr/bin/env python3
"""Production migration logic, temporary native stores, fake version clients."""
from pathlib import Path
import json, os, shlex, sqlite3, subprocess, tempfile, stat, plistlib

root = Path(__file__).resolve().parents[1]
sources = [
    root / 'Sources/Shared/BuildChannel.swift',
    root / 'Sources/ClaudeBar/Models/SessionMigration.swift',
    *[root / ('Sources/ClaudeBar/Utils/' + name + '.swift') for name in
      ['MigrationHistory', 'MigrationCursorHistory', 'MigrationCursorDesktop', 'MigrationStorage', 'PrivateFileWriter', 'ShellQuote', 'MigrationBridgeConfiguration']]
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
        let huge = [MigrationMessage(role:.user,text:String(repeating:"x",count:400_001)), .init(role:.assistant,text:"ACK")]
        mustFail { _ = try MigrationHistory.preview(source:ccSource,messages:huge,snapshot:Data()) }
        for invalid in [Data([0x0a,0xff]), Data(repeating:0xff,count:12), Data([0x00])] {
            mustFail { _ = try MigrationCursorHistory.fields(invalid) }
        }

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
        let toolsTarget = try MigrationStorage.prepare(withTools,target:.codexCurrent,route:route,locations:locations)
        precondition(toolsTarget.targetSessionID != a.targetSessionID)
        let toolsReRead = try MigrationHistory.codex(Data(contentsOf:URL(fileURLWithPath:toolsTarget.nativePath)),source:toolsTarget.targetSource)
        precondition(toolsReRead.messages == withTools.messages)

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
            assert len(composer['fullConversationHeadersOnly']) == 2
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
