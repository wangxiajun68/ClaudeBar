#!/usr/bin/env python3
"""Production workflow lifecycle and incremental file parsing; isolated files only."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
utils = root / 'Sources/ClaudeBar/Utils'
swift = r'''
func run() throws {
    let root = FilePaths.claudeDir
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let parent = root.appendingPathComponent("parent.jsonl")
    let directory = root.appendingPathComponent("workflows")
    let folder = directory.appendingPathComponent("wf_test-run")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let journal = folder.appendingPathComponent("journal.jsonl")
    func line(_ value: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(10)
        return data
    }
    func append(_ value: [String: Any], to url: URL) throws {
        let data = try line(value)
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url); return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    func launch(_ task: String = "task-1") throws {
        try append(["type": "user", "toolUseResult": ["runId": "wf_test-run", "taskId": task,
            "workflowName": "Test workflow", "status": "async_launched"]], to: parent)
    }
    func notification(_ status: String, task: String = "task-1", native: Bool = true) throws {
        var value: [String: Any] = ["type": "user", "message": ["content": [["type": "text",
            "text": "<task-notification><task-id>\(task)</task-id><status>\(status)</status><usage><agent_count>2</agent_count></usage><agents_done>1</agents_done><agents_error>1</agents_error></task-notification>"]]]]
        if native { value["origin"] = ["kind": "task-notification"] }
        try append(value, to: parent)
    }
    let monitor = WorkflowMonitor()
    let base = WorkflowInfo(workflowId: "wf_test-run", agents: [
        SubagentInfo(agentId: "agent-a", agentType: "test", description: "", status: .done),
        SubagentInfo(agentId: "agent-b", agentType: "test", description: "", status: .done)])
    func fetch(alive: Bool = true, now: Date = Date()) -> WorkflowInfo {
        monitor.enrich([base], transcript: parent, directory: directory, sessionAlive: alive, now: now)[0]
    }
    try launch()
    try append(["type": "started", "agentId": "a", "key": "0", "phase": "Research"], to: journal)
    var wf = fetch()
    precondition(wf.status == .running && wf.name == "Test workflow" && wf.phase == "Research")
    precondition(wf.runningCount == 1 && wf.completedCount == 0 && wf.agents[0].status == .running)
    precondition(fetch() == wf, "unchanged files must reuse the snapshot")
    try append(["type": "result", "agentId": "a", "key": "0", "result": ["status": "failed"]], to: journal)
    wf = fetch()
    precondition(wf.status == .running && wf.runningCount == 0 && wf.completedCount == 1,
                 "all returned agent results do not finish the workflow; result content is not runtime status")
    try append(["type": "started", "agentId": "b", "key": "1", "phase": "Verify"], to: journal)
    wf = fetch()
    precondition(wf.phase == "Verify" && wf.runningCount == 1)
    precondition(fetch(alive: false).status == .unknown && fetch(alive: false).runningCount == 0)
    precondition(fetch(now: Date().addingTimeInterval(100)).status == .unknown)
    try notification("completed", native: false)
    precondition(fetch().status == .running, "ordinary text is not a lifecycle notification")
    try notification("completed", task: "unrelated-task")
    precondition(fetch().status == .running, "another task cannot finish this workflow")
    for (raw, expected) in [("paused", WorkflowStatus.paused), ("failed", .failed),
                            ("stopped", .cancelled), ("completed", .completed)] {
        try notification(raw)
        wf = fetch()
        precondition(wf.status == expected && wf.runningCount == 0)
        precondition(wf.totalCount == 2 && wf.completedCount == 1 && wf.failedCount == 1)
    }
    try launch("task-2")
    try notification("failed", task: "task-1")
    precondition(fetch().status == .running, "old notification must not terminate a resumed run")
    try append(["type": "result", "agentId": "b", "key": "1", "result": "fixture"], to: journal)
    wf = fetch()
    precondition(wf.completedCount == 2 && wf.status == .running)
    // A partial append is not a full record. Complete it on the next poll.
    let data = try line(["type": "started", "agentId": "c", "phase": "Finish"])
    let handle = try FileHandle(forWritingTo: journal)
    try handle.seekToEnd(); try handle.write(contentsOf: data.dropLast())
    precondition(fetch().runningCount == 0)
    try handle.write(contentsOf: Data([10])); try handle.close()
    precondition(fetch().runningCount == 1 && fetch().phase == "Finish")
    try Data("malformed\n".utf8).write(to: journal)
    precondition(fetch().completedCount == 0, "truncation must discard old counts")
    let replacement = folder.appendingPathComponent("replacement.jsonl")
    try line(["type": "started", "agentId": "d", "phase": "Replacement"]).write(to: replacement)
    try FileManager.default.removeItem(at: journal)
    try FileManager.default.moveItem(at: replacement, to: journal)
    precondition(fetch().runningCount == 1 && fetch().phase == "Replacement")
    for _ in 0..<2 {
        try append(["type": "result", "agentId": "d", "result": "fixture"], to: journal)
    }
    precondition(fetch().completedCount == 1, "replayed results are counted once")
    try notification("completed", task: "task-2")
    precondition(fetch(alive: false).status == .completed, "explicit terminal record survives process exit")
    let missing = monitor.enrich([], transcript: parent, directory: root.appendingPathComponent("missing"), sessionAlive: true)
    precondition(missing.count == 1 && missing[0].status == .completed,
                 "a launch/notification remains visible without agent files")
    var session = SessionInfo(pid: 1, sessionId: "fixture", cwd: root.path, startedAt: 0,
                              name: "", status: .idle, updatedAt: 0, isAlive: true)
    session.workflows = [WorkflowInfo(workflowId: "wf_busy", status: .running)]
    precondition(session.isBusy, "idle parent still shows background workflow activity")
    session.status = .waiting
    precondition(!session.isBusy && session.isWaiting, "workflow must not hide user action needed")
    // Exercise the production session scan, including directory resolution.
    let project = FilePaths.claudeDir.appendingPathComponent("projects")
        .appendingPathComponent(SessionMonitor.projectDirName(for: session.cwd))
    let nativeFolder = project.appendingPathComponent("fixture/subagents/workflows/wf_test-run")
    try FileManager.default.createDirectory(at: nativeFolder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: parent, to: project.appendingPathComponent("fixture.jsonl"))
    try FileManager.default.copyItem(at: journal, to: nativeFolder.appendingPathComponent("journal.jsonl"))
    try JSONSerialization.data(withJSONObject: ["agentType": "workflow-subagent"])
        .write(to: nativeFolder.appendingPathComponent("agent-d.meta.json"))
    let scanned = SessionMonitor.fetchSubagents(for: session)
    precondition(scanned.direct.isEmpty && scanned.workflows.count == 1)
    precondition(scanned.workflows[0].status == .completed && scanned.workflows[0].agents.count == 1)
    print("PASS: native journal lifecycle, stages, async run notifications, stale/dead/unknown, resume ownership, partial append, truncation, no false completion and background activity")
}
try run()
'''
with tempfile.TemporaryDirectory(prefix='claudebar-workflow-') as folder:
    folder = Path(folder)
    paths = (utils / 'FilePaths.swift').read_text().replace('FileManager.default.homeDirectoryForCurrentUser', 'fixtureHome')
    source = folder / 'Regression.swift'
    source.write_text('\n'.join([
        'import Foundation', 'let fixtureHome = URL(fileURLWithPath: CommandLine.arguments[1])',
        (root / 'Sources/Shared/BuildChannel.swift').read_text(), paths,
        (utils / 'SessionTitle.swift').read_text(),
        'enum UsageStats { static func formatContext(_ n: Int) -> String { String(n) } }',
        (utils / 'JSONCoerce.swift').read_text(),
        (utils / 'WorkflowMonitor.swift').read_text(), (utils / 'SessionMonitor.swift').read_text(), swift,
    ]))
    subprocess.run(['swift', str(source), str(folder / 'home')], check=True)
