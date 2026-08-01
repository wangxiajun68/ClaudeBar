import Foundation

/// A live Claude Code session, parsed from ~/.claude/sessions/<pid>.json
struct SessionInfo: Identifiable, Equatable {
    var id: Int { pid }                  // stable identity by pid
    let pid: Int
    let sessionId: String
    let cwd: String
    let startedAt: Double                // epoch ms
    let procStart: String                // human string e.g. "Thu Jul 30 07:48:05 2026"
    let version: String
    let kind: String                     // "interactive" | "headless" | ...
    let entrypoint: String               // "cli" | "sdk" | ...
    let name: String                     // derived session name
    var status: SessionStatus
    var updatedAt: Double               // epoch ms — recency
    var isAlive: Bool                    // kill(pid, 0) == 0

    // Context-window usage, scanned from the session's transcript.
    var contextTokens: Int = 0           // current context size (latest input)
    var contextLimit: Int = 0            // model/provider limit, 0 if unknown
    var model: String = ""              // actual responding model
    var messageCount: Int = 0           // assistant turns in transcript
    var currentActivity: String = ""    // e.g. "Bash" or "Read · path.swift"
    var toolPending: Bool = false       // a tool_use has no following tool_result
    var subagents: [SubagentInfo] = []  // live subagents spawned by this session
    var workflows: [WorkflowInfo] = []  // workflows spawned by this session

    /// Context fill ratio 0...1 (0 if limit unknown).
    var contextRatio: Double {
        guard contextLimit > 0 else { return 0 }
        return min(1.0, Double(contextTokens) / Double(contextLimit))
    }

    /// Compact context label, e.g. "159K / 200K".
    var contextLabel: String {
        guard contextTokens > 0 else { return "—" }
        let used = UsageStats.formatTokens(contextTokens)
        return contextLimit > 0 ? "\(used) / \(UsageStats.formatTokens(contextLimit))" : used
    }

    /// Folder name derived from cwd, e.g. "ClaudeBar".
    var projectFolder: String {
        (cwd as NSString).lastPathComponent
    }

    /// Short "5m ago" style label since last update.
    var relativeUpdated: String {
        let now = Date().timeIntervalSince1970 * 1000
        let secs = max(0, (now - updatedAt) / 1000)
        if secs < 60 { return "\(Int(secs))s" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        return "\(Int(secs / 3600))h"
    }

    /// Short "5m ago" style label since the session started.
    var relativeStarted: String {
        let now = Date().timeIntervalSince1970 * 1000
        let secs = max(0, (now - startedAt) / 1000)
        if secs < 60 { return "\(Int(secs))s" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86400 { return "\(Int(secs / 3600))h" }
        return "\(Int(secs / 86400))d"
    }
}

enum SessionStatus: String {
    case idle, busy, unknown
    var label: String { rawValue }
}

/// Status of a subagent, derived from whether its latest tool_use has a
/// following tool_result.
enum SubagentStatus: String {
    case running, done
}

/// A subagent spawned by a session (Task/Agent tool), parsed from the
/// session's `subagents/` directory.
struct SubagentInfo: Identifiable, Equatable {
    var id: String { agentId }
    let agentId: String
    let agentType: String        // "Explore", "general-purpose", ...
    let description: String
    var activity: String = ""     // last tool the subagent ran
    var status: SubagentStatus = .done
}

/// A workflow spawned by a session. Its member agents are collected but not
/// expanded individually in the UI — the workflow renders as one summary row.
struct WorkflowInfo: Identifiable, Equatable {
    var id: String { workflowId }
    let workflowId: String
    var agents: [SubagentInfo] = []
    var runningCount: Int { agents.filter { $0.status == .running }.count }
}

/// Result of scanning a transcript tail for context-window usage and the
/// session's current activity.
struct ContextScan {
    let tokens: Int
    let model: String
    let count: Int
    let activity: String
    let toolPending: Bool
}

/// Reads ~/.claude/sessions/*.json and reports live Claude Code sessions.
struct SessionMonitor {

    /// All live sessions: parses session files, drops dead processes,
    /// sorts most-recently-active first.
    static func fetchActive() -> [SessionInfo] {
        let dir = FilePaths.claudeDir.appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: dir.path),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension == "json" }) else {
            return []
        }

        var sessions: [SessionInfo] = []
        for fileURL in files {
            guard let data = try? Data(contentsOf: fileURL),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            guard let pid = (obj["pid"] as? Int) ?? Int((obj["pid"] as? String) ?? "") else { continue }
            let sessionId = (obj["sessionId"] as? String) ?? ""
            let cwd = (obj["cwd"] as? String) ?? ""
            let startedAt = (obj["startedAt"] as? Double) ?? (obj["startedAt"] as? Int).map(Double.init) ?? 0
            let procStart = (obj["procStart"] as? String) ?? ""
            let version = (obj["version"] as? String) ?? ""
            let kind = (obj["kind"] as? String) ?? ""
            let entrypoint = (obj["entrypoint"] as? String) ?? ""
            let name = (obj["name"] as? String) ?? ""
            let statusStr = (obj["status"] as? String) ?? ""
            let status = SessionStatus(rawValue: statusStr) ?? .unknown
            let updatedAt = (obj["updatedAt"] as? Double) ?? (obj["updatedAt"] as? Int).map(Double.init) ?? startedAt

            // Liveness check: kill(pid, 0) returns 0 if process exists.
            let alive = kill(pid_t(pid), 0) == 0

            sessions.append(SessionInfo(
                pid: pid,
                sessionId: sessionId,
                cwd: cwd,
                startedAt: startedAt,
                procStart: procStart,
                version: version,
                kind: kind,
                entrypoint: entrypoint,
                name: name,
                status: status,
                updatedAt: updatedAt,
                isAlive: alive
            ))
        }

        // Dead processes sink to the bottom; alive sorted by recency.
        return sessions.sorted { a, b in
            if a.isAlive != b.isAlive { return a.isAlive }
            return a.updatedAt > b.updatedAt
        }
    }

    /// Scan a session's transcript for context-window usage. Reads only the
    /// tail of the file (last ~64KB) for speed and returns the latest
    /// assistant message's total input tokens as the current context size,
    /// plus the most recent tool_use (what the session is doing right now)
    /// and whether a tool call is still pending (no result yet → busy).
    static func fetchContext(for session: SessionInfo) -> ContextScan {
        let transcript = transcriptURL(for: session)
        guard FileManager.default.fileExists(atPath: transcript.path),
              let handle = try? FileHandle(forReadingFrom: transcript) else {
            return ContextScan(tokens: 0, model: "", count: 0, activity: "", toolPending: false)
        }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let readSize = min(96_000, fileSize)
        try? handle.seek(toOffset: max(0, fileSize - readSize))
        guard let tailData = try? handle.readToEnd(),
              let tail = String(data: tailData, encoding: .utf8) else {
            try? handle.close()
            return ContextScan(tokens: 0, model: "", count: 0, activity: "", toolPending: false)
        }
        try? handle.close()

        var lastContext = 0
        var lastModel = ""
        var msgCount = 0
        var lastActivity = ""
        // Track positions (line index within the tail) of the most recent
        // tool_use and tool_result to decide whether a tool is still pending.
        var lastToolUseLine = -1
        var lastToolResultLine = -1
        var lineIndex = 0

        for line in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            defer { lineIndex += 1 }
            // Track the latest tool_use → activity.
            if line.contains("\"type\":\"tool_use\""),
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let message = obj["message"] as? [String: Any] {
                let activity = describeActivity(in: message)
                if !activity.isEmpty {
                    lastActivity = activity
                    lastToolUseLine = lineIndex
                }
            }
            // A tool_result following a tool_use means that call completed.
            if line.contains("\"type\":\"tool_result\"") {
                lastToolResultLine = lineIndex
            }
            guard line.contains("\"usage\""), line.contains("\"type\":\"assistant\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            msgCount += 1
            let input = intVal(usage["input_tokens"])
            let cacheRead = intVal(usage["cache_read_input_tokens"])
            let cacheCreate = intVal(usage["cache_creation_input_tokens"])
            lastContext = input + cacheRead + cacheCreate
            lastModel = (message["model"] as? String) ?? lastModel
        }
        // A tool is pending if the last tool_use appears after the last
        // tool_result (i.e. it has no following result yet).
        let pending = lastToolUseLine > lastToolResultLine && lastToolUseLine >= 0
        return ContextScan(tokens: lastContext, model: lastModel, count: msgCount,
                           activity: lastActivity, toolPending: pending)
    }

    /// Scan the session's `subagents/` directory for spawned subagents and
    /// what each is currently doing. Returns both directly-spawned agents
    /// and workflows (each workflow groups its member agents).
    static func fetchSubagents(for session: SessionInfo) -> (direct: [SubagentInfo], workflows: [WorkflowInfo]) {
        let subagentsDir = sessionDirURL(for: session).appendingPathComponent("subagents")
        guard FileManager.default.fileExists(atPath: subagentsDir.path),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: subagentsDir, includingPropertiesForKeys: nil) else {
            return (direct: [], workflows: [])
        }

        var direct: [SubagentInfo] = []
        for entry in entries where entry.lastPathComponent.hasSuffix(".meta.json") {
            guard let data = try? Data(contentsOf: entry),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // Filename: agent-<id>.meta.json → agentId "agent-<id>".
            let fname = entry.deletingPathExtension().deletingPathExtension().lastPathComponent
            let agentId = (meta["agentId"] as? String) ?? fname
            let agentType = (meta["agentType"] as? String) ?? "agent"
            let description = (meta["description"] as? String) ?? ""
            var info = SubagentInfo(agentId: agentId, agentType: agentType, description: description)
            let (activity, pending) = scanAgentActivity(transcript: subagentsDir.appendingPathComponent("\(fname).jsonl"))
            info.activity = activity
            info.status = pending ? .running : .done
            direct.append(info)
        }

        // Workflows live under subagents/workflows/<wf_id>/agent-<id>.meta.json
        var workflows: [WorkflowInfo] = []
        let workflowsDir = subagentsDir.appendingPathComponent("workflows")
        if let wfDirs = try? FileManager.default.contentsOfDirectory(
            at: workflowsDir, includingPropertiesForKeys: nil) {
            for wfDir in wfDirs where (try? wfDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let wfId = wfDir.lastPathComponent
                var wf = WorkflowInfo(workflowId: wfId)
                if let agentFiles = try? FileManager.default.contentsOfDirectory(
                    at: wfDir, includingPropertiesForKeys: nil) {
                    for entry in agentFiles where entry.lastPathComponent.hasSuffix(".meta.json") {
                        guard let data = try? Data(contentsOf: entry),
                              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        let fname = entry.deletingPathExtension().deletingPathExtension().lastPathComponent
                        let agentId = (meta["agentId"] as? String) ?? fname
                        let agentType = (meta["agentType"] as? String) ?? "workflow-subagent"
                        let description = (meta["description"] as? String) ?? ""
                        var info = SubagentInfo(agentId: agentId, agentType: agentType, description: description)
                        let (activity, pending) = scanAgentActivity(transcript: wfDir.appendingPathComponent("\(fname).jsonl"))
                        info.activity = activity
                        info.status = pending ? .running : .done
                        wf.agents.append(info)
                    }
                }
                workflows.append(wf)
            }
        }

        // Running first, then by agentId for stable ordering.
        let sort: (SubagentInfo, SubagentInfo) -> Bool = { a, b in
            if a.status != b.status { return a.status == .running }
            return a.agentId < b.agentId
        }
        direct.sort(by: sort)
        workflows.sort { lhs, rhs in
            let lr = lhs.runningCount > 0
            let rr = rhs.runningCount > 0
            if lr != rr { return lr }      // running workflows first
            return lhs.workflowId < rhs.workflowId
        }
        return (direct: direct, workflows: workflows)
    }

    /// Read the tail of an agent transcript and return (latest activity,
    /// toolPending). Mirrors the pending-tool logic in `fetchContext`.
    private static func scanAgentActivity(transcript: URL) -> (activity: String, pending: Bool) {
        guard FileManager.default.fileExists(atPath: transcript.path),
              let handle = try? FileHandle(forReadingFrom: transcript) else {
            return ("", false)
        }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: max(0, size - 32_000))
        guard let tailData = try? handle.readToEnd(),
              let tail = String(data: tailData, encoding: .utf8) else {
            try? handle.close()
            return ("", false)
        }
        try? handle.close()

        var lastActivity = ""
        var lastToolUseLine = -1
        var lastToolResultLine = -1
        var lineIndex = 0
        for line in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            defer { lineIndex += 1 }
            if line.contains("\"type\":\"tool_use\""),
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let message = obj["message"] as? [String: Any] {
                let activity = describeActivity(in: message)
                if !activity.isEmpty {
                    lastActivity = activity
                    lastToolUseLine = lineIndex
                }
            }
            if line.contains("\"type\":\"tool_result\"") {
                lastToolResultLine = lineIndex
            }
        }
        let pending = lastToolUseLine > lastToolResultLine && lastToolUseLine >= 0
        return (lastActivity, pending)
    }

    // MARK: - Path helpers

    /// The project directory under ~/.claude/projects/, e.g.
    /// `projects/-Users-wangxiajun-Project-ClaudeBar`.
    static func projectDir(for session: SessionInfo) -> URL {
        let projects = FilePaths.claudeDir.appendingPathComponent("projects")
        let encoded = session.cwd.hasPrefix("/")
            ? String(session.cwd.dropFirst()).replacingOccurrences(of: "/", with: "-")
            : session.cwd.replacingOccurrences(of: "/", with: "-")
        return projects.appendingPathComponent("-" + encoded)
    }

    /// The session's main transcript: projects/<encoded-cwd>/<sessionId>.jsonl
    static func transcriptURL(for session: SessionInfo) -> URL {
        projectDir(for: session).appendingPathComponent("\(session.sessionId).jsonl")
    }

    /// The session's directory (holding subagents/), named after the sessionId
    /// and sibling to the transcript file.
    static func sessionDirURL(for session: SessionInfo) -> URL {
        projectDir(for: session).appendingPathComponent(session.sessionId)
    }

    /// Human-readable summary of the latest tool_use in a message:
    /// "Bash · build.sh", "Read · File.swift", "Agent · Explore", etc.
    private static func describeActivity(in message: [String: Any]) -> String {
        guard let content = message["content"] as? [[String: Any]] else { return "" }
        var lastTool = ""
        for item in content where (item["type"] as? String) == "tool_use" {
            let name = (item["name"] as? String) ?? "tool"
            let input = (item["input"] as? [String: Any]) ?? [:]
            let detail: String
            switch name {
            case "Bash":
                let cmd = (input["command"] as? String) ?? ""
                detail = cmd.split(separator: " ").first.map(String.init) ?? "bash"
            case "Read":
                detail = ((input["file_path"] as? String) as NSString?)?.lastPathComponent ?? "file"
            case "Write", "Edit":
                detail = ((input["file_path"] as? String) as NSString?)?.lastPathComponent ?? "file"
            case "Grep", "Glob":
                detail = (input["pattern"] as? String) ?? "search"
            case "Agent", "Task":
                detail = (input["subagent_type"] as? String) ?? "agent"
            case "WebSearch":
                detail = (input["query"] as? String) ?? "search"
            default:
                detail = ""
            }
            lastTool = detail.isEmpty ? name : "\(name) · \(detail)"
        }
        return lastTool
    }

    private static func intVal(_ v: Any?) -> Int {
        if let n = v as? Int { return n }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let n = Int(s) { return n }
        return 0
    }
}
