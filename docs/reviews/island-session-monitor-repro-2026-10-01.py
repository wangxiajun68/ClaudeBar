#!/usr/bin/env python3
"""Audit reproductions using production Swift functions and temporary files only.

Success means the documented defects were reproduced, not that they are fixed.
No app, notification permission, client connection, or real user data is used.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
UTILS = ROOT / "Sources/ClaudeBar/Utils"
MODELS = ROOT / "Sources/ClaudeBar/Models"


def block(path, signature):
    text = path.read_text()
    start = text.index(signature)
    opening = text.index("{", start)
    end, depth = opening + 1, 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end].replace("private static func", "static func")


HARNESS = r'''
func run() throws {
    var reproduced = 0
    func defect(_ condition: Bool, _ name: String) {
        precondition(condition, "No longer reproduced: \(name); reassess this audit")
        reproduced += 1
        print("REPRODUCED: \(name)")
    }
    var wait = WaitingStateDetector<String>()
    _ = wait.record([(id: "existing", isWaiting: false)])
    let newPark = wait.record([(id: "existing", isWaiting: false),
                               (id: "new", isWaiting: true)])
    defect(newPark.isEmpty, "new session first discovered waiting produces no alert")
    _ = wait.record([(id: "existing", isWaiting: true)])
    defect(wait.record([(id: "existing", isWaiting: true)]).isEmpty,
           "two distinct prompts sampled waiting -> waiting produce no second alert")

    let session = SessionInfo(pid: 42, sessionId: "fixture", cwd: "/tmp/audit-project",
                              startedAt: 1, name: "", status: .idle, updatedAt: 1,
                              isAlive: true)
    let transcript = SessionMonitor.transcriptURL(for: session)
    try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
    func json(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }
    func assistant(_ blocks: [[String: Any]], uuid: String = "step",
                   stop: String = "tool_use") -> [String: Any] {
        ["type": "assistant", "uuid": uuid,
         "message": ["content": blocks, "stop_reason": stop, "model": "fixture-model",
                     "usage": ["input_tokens": 100]]]
    }
    func tool(_ id: String, _ name: String) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": [:]]
    }
    let prompt: [String: Any] = ["type": "user", "message": ["content": "fixture prompt"]]
    let tools = assistant([tool("a", "Read"), tool("b", "AskUserQuestion")])
    let result: [String: Any] = ["type": "user", "message": ["content": [
        ["type": "tool_result", "tool_use_id": "a", "content": "done"]]]]
    try (json(tools) + json(result)).write(to: transcript)
    let partial = SessionMonitor.fetchContext(for: session)
    defect(!partial.toolPending && partial.pendingTool.isEmpty,
           "result for tool a wrongly clears still-pending tool b")

    try (json(assistant([tool("a", "Read")])) + json(result) + json(prompt)).write(to: transcript)
    let newTurn = SessionMonitor.fetchContext(for: session)
    defect(newTurn.activity.hasPrefix("Read"), "new user turn retains previous turn's Read activity")

    let answer = assistant([["type": "text", "text": "fixture answer"]], uuid: "same-answer", stop: "end_turn")
    let padding: [String: Any] = ["type": "system", "fixture": String(repeating: "x", count: 70_000)]
    try (json(prompt) + json(assistant([["type": "text", "text": "intermediate"]]))
         + json(padding) + json(answer)).write(to: transcript)
    let old = StoreProbe.enrich([session], previous: [], limits: ["fixture-model": 1000])[0]
    let append = try json(["type": "system", "fixture": String(repeating: "y", count: 30_000)])
    let handle = try FileHandle(forWritingTo: transcript)
    try handle.seekToEnd()
    try handle.write(contentsOf: append)
    try handle.close()
    let slid = StoreProbe.enrich([session], previous: [old], limits: ["fixture-model": 1000])[0]
    var completed = ConfirmedCompletionDetector<Int>()
    _ = completed.record([(id: 42, isBusy: false, turnKey: "\(old.turnCount)|\(old.completionID!)", fresh: true)])
    let repeated = completed.record([(id: 42, isBusy: false,
                                      turnKey: "\(slid.turnCount)|\(slid.completionID!)", fresh: true)])
    defect(old.completionID == slid.completionID && slid.turnCount < old.turnCount && repeated == [42],
           "tail shift lowers published counter and re-announces same answer (\(old.turnCount) -> \(slid.turnCount))")

    try json(answer).write(to: transcript)
    let original = StoreProbe.enrich([session], previous: [], limits: ["fixture-model": 1000])[0]
    let rewritten = assistant([["type": "text", "text": "fixture answer"]], uuid: "next-answer", stop: "end_turn")
    let rewrittenData = try json(rewritten)
    precondition(rewrittenData.count == original.transcriptSize)
    try rewrittenData.write(to: transcript)
    let cached = StoreProbe.enrich([session], previous: [original], limits: ["fixture-model": 2000])[0]
    defect(cached.completionID == "same-answer" && SessionMonitor.fetchContext(for: session).completionID == "next-answer",
           "same-size transcript replacement reuses previous answer")
    defect(cached.contextLimit == 1000,
           "changed context-limit configuration remains cached while transcript size is unchanged")

    let agents = SessionMonitor.sessionDirURL(for: session).appendingPathComponent("subagents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    try json(["agentId": "agent-a", "agentType": "Explore"]).write(to: agents.appendingPathComponent("agent-a.meta.json"))
    let childTranscript = agents.appendingPathComponent("agent-a.jsonl")
    let childTool = assistant([tool("a", "Read")])
    try json(childTool).write(to: childTranscript)
    let parent = StoreProbe.enrich([session], previous: [], limits: [:])[0]
    try (json(childTool) + json(result)).write(to: childTranscript)
    let childCached = StoreProbe.enrich([session], previous: [parent], limits: [:])[0]
    defect(childCached.subagents.first?.status == .running
           && SessionMonitor.fetchSubagents(for: session).direct.first?.status == .done,
           "child completion is frozen by unchanged parent transcript size")

    let codex = fixtureRoot.appendingPathComponent("codex.jsonl")
    let usage: [String: Any] = ["type": "event_msg", "payload": ["type": "token_count", "info": [
        "model_context_window": 200_000, "last_token_usage": ["total_tokens": 180_000]]]]
    let compact: [String: Any] = ["type": "event_msg", "payload": ["type": "context_compacted"]]
    try (json(["type": "event_msg", "payload": ["type": "task_started"]])
         + json(usage) + json(compact)).write(to: codex)
    let compression = CodexProbe.readCodexContext(path: codex.path)
    defect(compression.used == 180_000 && compression.hasOpenTask == true,
           "context_compacted is ignored; pre-compaction context remains published")
    defect(!ExternalSessionMonitor.isRunning(openTask: true, updated: 1000, now: 1301),
           "open turn becomes idle after 301 seconds regardless of live work or approval")

    print("\(reproduced) defects reproduced against production Swift slices")
}
try run()
'''

with tempfile.TemporaryDirectory(prefix="claudebar-island-audit-") as directory:
    folder = Path(directory)
    monitor = UTILS / "ExternalSessionMonitor.swift"
    constants = "\n".join(line for line in monitor.read_text().splitlines()
                          if "private static let codexTail" in line)
    source = folder / "main.swift"
    source.write_text("\n".join([
        "import Foundation",
        "let fixtureRoot = URL(fileURLWithPath: CommandLine.arguments[1])",
        "enum FilePaths { static var claudeDir: URL { fixtureRoot.appendingPathComponent(\".claude\") } }",
        "enum UsageStats { static func formatContext(_ n: Int) -> String { String(n) } }",
        "enum StoreProbe {",
        block(MODELS / "ProviderStore.swift", "private static func enrich("),
        block(MODELS / "ProviderStore.swift", "private static func applyTranscriptBusyFallback("),
        "}",
        "enum CodexProbe {",
        constants,
        block(monitor, "private static func readCodexContext("),
        "}",
        block(MODELS / "IdleTransitionDetector.swift", "struct ConfirmedCompletionDetector<ID: Hashable>"),
        block(MODELS / "IdleTransitionDetector.swift", "struct WaitingStateDetector<ID: Hashable>"),
        HARNESS,
    ]))
    binary = folder / "reproduce"
    subprocess.run([
        "swiftc", "-O", str(source),
        str(UTILS / "SessionMonitor.swift"), str(monitor),
        str(UTILS / "SessionTitle.swift"), str(UTILS / "JSONCoerce.swift"),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary), str(folder)], check=True)
