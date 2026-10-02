import Foundation

/// A live Claude Code session, parsed from ~/.claude/sessions/<pid>.json
struct SessionInfo: Identifiable, Equatable {
    var id: Int { pid }                  // stable identity by pid
    let pid: Int
    let sessionId: String
    let cwd: String
    let startedAt: Double                // epoch ms
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
    var firstPrompt: String = ""        // first human prompt → card title
    var toolPending: Bool = false       // a tool_use has no following tool_result
    /// Non-empty while the turn is parked on the user rather than on the model.
    ///
    /// This is the third state the busy/idle pair could not express. Measured
    /// against a live CLI: a Bash approval prompt and an `AskUserQuestion`
    /// dialog both leave the session file at `status: "waiting"`, and the
    /// transcript's last record is an assistant `tool_use` with no
    /// `tool_result` — so `toolPending` is true and every surface drawn from it
    /// said **运行中** while nothing was running and the user was the one being
    /// waited on. The idle notification never fired either, for the mirror
    /// reason: no new answer exists, so the completion key is nil forever.
    ///
    /// `status` carries the CLI's own word for it; this field carries the
    /// coarse bucket the CLI writes alongside it. The 2.1.285 binary emits
    /// `"permission prompt"` / `"input needed"` from
    /// `CRe({status, waitingFor})`, and the dialog descriptors behind
    /// `"input needed"` are `"dialog open"` / `"sandbox request"` /
    /// `"goal proposal"` — so this string is a *bucket*, never a tool name.
    var waitingFor: String = ""
    /// Bare name of the trailing `tool_use` with no `tool_result` yet
    /// (`"Bash"`, `"AskUserQuestion"`, `"ExitPlanMode"`), empty when nothing is
    /// pending. This is the transcript's contribution to the waiting state —
    /// the CLI only writes a coarse bucket, this says which tool.
    var pendingTool: String = ""
    var completionID: String? = nil     // UUID of the latest final assistant answer
    /// Turns + assistant steps seen in the transcript's tail window.
    ///
    /// The point of a counter rather than a flag is that it can tell "a new
    /// turn answered" from "the same answer is still the newest one" — see
    /// `ConfirmedCompletionDetector`. It is read from a sliding window, so it
    /// is *near*-monotone: a window that scrolled past its last turn boundary
    /// reports one less, and `ProviderStore.enrich` clamps the published value
    /// so that shift can only repeat a key, never regress one.
    var turnCount: Int = 0
    var subagents: [SubagentInfo] = []  // live subagents spawned by this session
    var workflows: [WorkflowInfo] = []  // workflows spawned by this session
    /// Transcript byte size at last context scan — skip the tail read when unchanged.
    var transcriptSize: UInt64 = 0

    /// Context fill ratio 0...1 (0 if limit unknown).
    var contextRatio: Double {
        guard contextLimit > 0 else { return 0 }
        return min(1.0, Double(contextTokens) / Double(contextLimit))
    }

    /// The turn is parked on the user, not on the model.
    ///
    /// The CLI's `status` is the authority; the transcript only supplies the
    /// *reason*. That split matters: `toolPending` is true both while a tool is
    /// genuinely running and while the CLI sits on the approval for it, so a
    /// tool-pending session is only "waiting" when the session file says so.
    var isWaiting: Bool { status == .waiting }

    /// Mid-work — what every "运行中" in the app means. See
    /// `SessionStatus.isWorking`.
    var isBusy: Bool { !isWaiting && (status.isWorking || toolPending) }

    /// One sentence for what the user is being asked for, e.g. "等待你确认 · Bash"
    /// / "等待确认计划". Empty when not waiting.
    ///
    /// Derived in one place because five surfaces say it (the island strip and
    /// its row, the popup card, the sessions tile, the dashboard overview), and
    /// the two inputs disagree: the CLI's `waitingFor` is a coarse bucket, while
    /// the transcript knows *which* tool is parked — the half that actually
    /// tells the user what to go answer.
    ///
    /// The `waitingFor` values are the CLI's own, read out of the 2.1.285
    /// binary, not guessed. Its writer is
    /// `waitingFor = status != "waiting" ? nil : (tool_name == "AskUserQuestion"
    /// || tool_name.startsWith("dialog:") ? "input needed" : "permission prompt")`,
    /// and the dialog descriptors it can raise carry `"dialog open"`,
    /// `"sandbox request"`, and `"goal proposal"`. Only the two the writer
    /// produces are load-bearing for the *tool* bucket; the rest arrive with an
    /// empty or non-tool `pendingTool`, which is why they fall through to the
    /// bucket test rather than a tool name.
    var waitingReason: String {
        guard isWaiting else { return "" }
        switch pendingTool {
        case "ExitPlanMode":
            // Not a permission so much as a decision: CC shows the plan and the
            // user picks whether to run it.
            return "等待确认计划"
        case "AskUserQuestion":
            return "等待你选择"
        case "":
            // No trailing tool in the scanned window (a dialog raised before the
            // model wrote another step, a tail that scrolled past the tool_use).
            // The CLI's coarse bucket is all that is left; `"input needed"` is
            // its word for a question, everything else for a go-ahead.
            return waitingFor == "input needed" ? "等待你选择" : "等待你确认"
        default:
            // A `dialog:` pseudo-tool is a CLI-raised dialog, not a tool the
            // model called — naming it to the user would read as jargon. Fall
            // back to the bucket word instead of "等待你确认 · dialog:...".
            if pendingTool.hasPrefix("dialog:") {
                return waitingFor == "input needed" ? "等待你选择" : "等待你确认"
            }
            return "等待你确认 · \(pendingTool)"
        }
    }

    /// Compact context label, e.g. "159K / 200K".
    var contextLabel: String {
        guard contextTokens > 0 else { return "—" }
        let used = UsageStats.formatContext(contextTokens)
        return contextLimit > 0 ? "\(used) / \(UsageStats.formatContext(contextLimit))" : used
    }

    /// Folder name derived from cwd, e.g. "ClaudeBar".
    var projectFolder: String {
        (cwd as NSString).lastPathComponent
    }

    /// Title for cards, palettes and the dashboard. Claude Code has no title
    /// field, so the first human prompt stands in; the folder is the last
    /// resort. See `SessionTitle`.
    var displayTitle: String {
        SessionTitle(firstPrompt: firstPrompt, folder: projectFolder).display
    }

    /// Two-part card header: `folder · 首条 prompt`.
    var cardLabel: SessionTitle.Label {
        SessionTitle(firstPrompt: firstPrompt, folder: projectFolder).cardLabel
    }

    /// Short "5m ago" style label since last update.
    var relativeUpdated: String {
        let now = Date().timeIntervalSince1970 * 1000
        let secs = max(0, (now - updatedAt) / 1000)
        if secs < 60 { return "\(Int(secs))s" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86400 { return "\(Int(secs / 3600))h" }
        return "\(Int(secs / 86400))d"
    }
}

enum SessionStatus: String {
    case idle, busy, unknown
    /// Parked on the user: a permission prompt or an AskUserQuestion dialog is
    /// on screen and the CLI is not doing any work. Written by the CLI itself
    /// into the session record (`"status": "waiting"`); see
    /// `SessionInfo.waitingFor`.
    case waiting
    /// The CLI is inside an interactive shell it launched — `/shell` (also
    /// reachable as `!`), where the user is driving a subprocess rather than
    /// the model. The CLI's own status enum is
    /// `["busy","shell","idle","waiting"]` (read out of the 2.1.285 binary),
    /// so this is a fourth value the app used to drop into `unknown`.
    ///
    /// It is work, not a park: the CLI is not waiting on the user for a
    /// decision, it is holding an open tool the user chose to step into. Left
    /// as `unknown`, a `/shell` session whose transcript still showed a
    /// dangling tool read as 运行中 anyway, but one whose tail had moved on
    /// read as 空闲 while the user was actually in the shell — the reason this
    /// is spelled out rather than folded in.
    case shell
    var label: String { rawValue }

    /// The session is mid-work, not parked on the user — the property every
    /// "is this thing running" question in the app actually means. `waiting` is
    /// deliberately excluded: a session at a permission prompt has nothing in
    /// flight, and treating it as busy is what made the island say 运行中.
    /// `shell` counts as working for the same reason `busy` does: something is
    /// live and the ball is not in the user's court.
    var isWorking: Bool { self == .busy || self == .shell }
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
    let completionID: String?
    /// Turns + assistant steps in the window. Near-monotone; see
    /// `SessionInfo.turnCount`.
    let turnCount: Int
    /// Name of the trailing `tool_use` that has no `tool_result` yet, when one
    /// is pending — the reason a waiting turn is waiting. Empty otherwise.
    var pendingTool: String = ""
    /// The first human prompt, used as the card title (see `SessionTitle`).
    var title: String = ""
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
            let name = (obj["name"] as? String) ?? ""
            let statusStr = (obj["status"] as? String) ?? ""
            let status = SessionStatus(rawValue: statusStr) ?? .unknown
            // The CLI's own coarse bucket for what it is blocked on
            // ("permission prompt" / "input needed"); empty otherwise. Only
            // meaningful with `waiting` — the CLI writes it there alone.
            let waitingFor = status == .waiting ? ((obj["waitingFor"] as? String) ?? "") : ""
            let updatedAt = (obj["updatedAt"] as? Double) ?? (obj["updatedAt"] as? Int).map(Double.init) ?? startedAt

            // Liveness check: kill(pid, 0) returns 0 if process exists.
            let alive = kill(pid_t(pid), 0) == 0

            sessions.append(SessionInfo(
                pid: pid,
                sessionId: sessionId,
                cwd: cwd,
                startedAt: startedAt,
                name: name,
                status: status,
                updatedAt: updatedAt,
                isAlive: alive,
                waitingFor: waitingFor
            ))
        }

        // Dead processes sink to the bottom; alive sorted by recency.
        return sessions.sorted { a, b in
            if a.isAlive != b.isAlive { return a.isAlive }
            return a.updatedAt > b.updatedAt
        }
    }

    /// Scan a session's transcript for context-window usage. Reads only the
    /// tail of the file (last ~96KB) — the latest assistant message's total
    /// input tokens (fresh + cache read + cache create) approximates the
    /// current context size — plus the most recent tool_use (current activity)
    /// and whether a tool call is still pending (no result yet → busy).
    ///
    /// Single open/seek/read per poll; `size` from `seekToEnd` doubles as the
    /// existence check, so no separate `fileExists` stat is needed.
    /// The session's first human prompt, from the transcript's *head*.
    ///
    /// The title is not in the tail this monitor normally reads, so this is a
    /// second bounded read. Claude Code marks a typed prompt with
    /// `origin.kind == "human"` (`promptSource: "typed"`); everything else in
    /// the `user` stream is plumbing that must not become a title:
    ///
    ///   - `isMeta: true` — injected `<local-command-caveat>` notices
    ///   - `isSidechain: true` — subagent traffic
    ///   - `origin == nil` — `/effort`, `/clear` … command wrappers
    ///
    /// Measured on 40 local transcripts: 35 yield a clean first prompt, and the
    /// 5 that do not (`/clear`-only sessions, `<history>` injections) fall back
    /// to the folder name via `SessionTitle`.
    private static func firstHumanPrompt(for session: SessionInfo) -> String {
        guard let handle = try? FileHandle(forReadingFrom: transcriptURL(for: session)) else { return "" }
        defer { try? handle.close() }
        // Prompts live well inside the first few records; 16KB covers the
        // session preamble at a fraction of a full read.
        guard let data = try? handle.read(upToCount: 16_000), !data.isEmpty else { return "" }
        let head = String(decoding: data, as: UTF8.self)
        for line in head.split(separator: "\n", omittingEmptySubsequences: true) {
            // Substring check first: only user-shaped lines pay for a parse.
            guard line.contains("\"type\":\"user\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (obj["type"] as? String) == "user" else { continue }
            if (obj["isMeta"] as? Bool) == true { continue }
            if (obj["isSidechain"] as? Bool) == true { continue }
            guard let origin = obj["origin"] as? [String: Any],
                  (origin["kind"] as? String) == "human" else { continue }
            guard let message = obj["message"] as? [String: Any] else { continue }
            let content = message["content"]
            let text: String
            if let plain = content as? String {
                text = plain
            } else if let blocks = content as? [[String: Any]] {
                text = blocks.compactMap { block -> String? in
                    guard (block["type"] as? String) == "text" else { return nil }
                    return block["text"] as? String
                }.joined(separator: " ")
            } else {
                text = ""
            }
            let cleaned = SessionTitle.condense(text)
            if !cleaned.isEmpty { return cleaned }
        }
        return ""
    }

    static func fetchContext(for session: SessionInfo) -> ContextScan {
        guard let handle = try? FileHandle(forReadingFrom: transcriptURL(for: session)) else {
            return ContextScan(tokens: 0, model: "", count: 0, activity: "", toolPending: false,
                               completionID: nil, turnCount: 0)
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let readSize = min(96_000, fileSize)
        try? handle.seek(toOffset: fileSize - readSize)
        guard let tailData = try? handle.readToEnd() else {
            return ContextScan(tokens: 0, model: "", count: 0, activity: "", toolPending: false,
                               completionID: nil, turnCount: 0)
        }
        // Lossy decode: the tail read starts at a byte offset that usually
        // lands inside a multi-byte character, and a strict decode then fails
        // for the *whole* window — measured on 31 of 600 local transcripts,
        // each one silently reporting 0 context tokens. A lossy decode keeps
        // every line but the partial first one.
        let tail = String(decoding: tailData, as: UTF8.self)

        var lastContext = 0
        var lastModel = ""
        var msgCount = 0
        var lastActivity = ""
        var lastToolName = ""
        var completionID: String?
        // Turns + assistant steps seen in the window: a counter that only ever
        // grows while the transcript grows, and that a window shift can lower
        // by one boundary at most. The pair is what tells the completion
        // detector "a new turn answered" rather than "here is the same old
        // answer again" — and `ProviderStore.enrich` clamps the *published*
        // value so a window that scrolled past its last boundary can only
        // repeat a key, never regress one.
        var turnCount = 0
        var stepCount = 0
        // Track positions (line index within the tail) of the most recent
        // tool_use and tool_result to decide whether a tool is still pending.
        var lastToolUseLine = -1
        var lastToolResultLine = -1
        var lineIndex = 0

        for line in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            defer { lineIndex += 1 }
            // A final answer is valid only until the next user prompt or
            // assistant step. Tool results are user-shaped transcript records,
            // but they do not begin a new turn.
            if line.contains("\"type\":\"user\""),
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               (obj["type"] as? String) == "user" {
                let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]]
                let onlyToolResults = blocks.map { items in !items.isEmpty && items.allSatisfy {
                    ($0["type"] as? String) == "tool_result"
                } } ?? false
                if !onlyToolResults { completionID = nil; turnCount += 1 }
            }
            if line.contains("\"type\":\"assistant\""),
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let message = obj["message"] as? [String: Any] {
                completionID = nil
                stepCount += 1
                if (obj["isSidechain"] as? Bool) != true,
                   // `end_turn` means exactly "the turn stopped and the floor is
                   // the user's": every `tool_use` step carries that stop reason
                   // too, so the "has a text block" test below is what separates
                   // a final answer from a step that only called a tool.
                   (message["stop_reason"] as? String) == "end_turn",
                   let blocks = message["content"] as? [[String: Any]],
                   blocks.contains(where: { ($0["type"] as? String) == "text"
                       && !(($0["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                   let uuid = obj["uuid"] as? String, !uuid.isEmpty {
                    completionID = uuid
                }
            }
            // Track the latest tool_use → activity, and keep the bare tool name
            // so a *waiting* turn can name what it is waiting for.
            if line.contains("\"type\":\"tool_use\""),
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let message = obj["message"] as? [String: Any] {
                let activity = describeActivity(in: message)
                if !activity.isEmpty {
                    lastActivity = activity
                    lastToolUseLine = lineIndex
                }
                if let name = (message["content"] as? [[String: Any]])?
                    .last(where: { ($0["type"] as? String) == "tool_use" })?["name"] as? String {
                    lastToolName = name
                }
            }
            // A tool_result following a tool_use means that call completed.
            if line.contains("\"type\":\"tool_result\"") {
                lastToolResultLine = lineIndex
            }
            // Substring check first: only assistant usage lines pay for a
            // full JSON parse, which is the dominant cost on large tails.
            guard line.contains("\"usage\""), line.contains("\"type\":\"assistant\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            msgCount += 1
            let input = JSONCoerce.intVal(usage["input_tokens"])
            let cacheRead = JSONCoerce.intVal(usage["cache_read_input_tokens"])
            let cacheCreate = JSONCoerce.intVal(usage["cache_creation_input_tokens"])
            lastContext = input + cacheRead + cacheCreate
            lastModel = (message["model"] as? String) ?? lastModel
        }
        // A tool is pending if the last tool_use appears after the last
        // tool_result (i.e. it has no following result yet).
        let pending = lastToolUseLine > lastToolResultLine && lastToolUseLine >= 0
        return ContextScan(tokens: lastContext, model: lastModel, count: msgCount,
                           activity: lastActivity, toolPending: pending, completionID: completionID,
                           turnCount: turnCount + stepCount,
                           pendingTool: pending ? lastToolName : "",
                           title: firstHumanPrompt(for: session))
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
        guard let handle = try? FileHandle(forReadingFrom: transcript) else {
            return ("", false)
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let readSize = min(32_000, size)
        try? handle.seek(toOffset: size - readSize)
        guard let tailData = try? handle.readToEnd() else {
            return ("", false)
        }
        // Lossy decode — see `readContext` for why a strict one drops the
        // whole tail on a mid-character seek.
        let tail = String(decoding: tailData, as: UTF8.self)

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

    /// Claude Code's own project-directory encoding, mirrored exactly.
    ///
    /// The client's rule is `cwd.replace(/[^a-zA-Z0-9]/g, "-")` — **every**
    /// character outside `[A-Za-z0-9]`, not just `/` — with the leading slash
    /// becoming the leading dash. Replacing only `/` is right for
    /// `/Users/me/Project/foo` and wrong for every path holding anything else;
    /// a dot is the common case. `…/Project/helix/.helix/agents/…` is stored
    /// as `-Users-…-helix--helix-…` on this machine, while the old code
    /// computed a directory that never exists — so that session showed no
    /// context, no title, and no sub-agents at all.
    ///
    /// Runs longer than 200 characters get a hash suffix from the client
    /// (its own base-36 function of the full string), which cannot be mirrored
    /// without copying that function; `locateTranscript` is the fallback that
    /// covers it rather than guessing.
    static func projectDirName(for cwd: String) -> String {
        var slug = "-"
        slug.reserveCapacity(cwd.count + 1)
        for byte in cwd.utf8 {
            let alphanumeric = (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            slug.append(alphanumeric ? Character(UnicodeScalar(byte)) : "-")
        }
        return slug
    }

    /// The directory the session's project lives in: the mirrored name when it
    /// exists, else whatever `locateTranscript` resolves.
    static func projectDir(for session: SessionInfo) -> URL {
        if let slashed = transcriptCache.dir(for: session.sessionId) {
            return URL(fileURLWithPath: slashed)
        }
        let projects = FilePaths.claudeDir.appendingPathComponent("projects")
        let mirrored = projects.appendingPathComponent(projectDirName(for: session.cwd))
        if directoryExists(mirrored) { return mirrored }
        if let transcript = locateTranscript(sessionId: session.sessionId, projects: projects) {
            let dir = transcript.deletingLastPathComponent()
            transcriptCache.store(dir.path, for: session.sessionId)
            return dir
        }
        return mirrored
    }

    /// The session's main transcript: projects/<encoded-cwd>/<sessionId>.jsonl
    static func transcriptURL(for session: SessionInfo) -> URL {
        projectDir(for: session).appendingPathComponent("\(session.sessionId).jsonl")
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Robustness net under the mirrored encoding: find `<sessionId>.jsonl`
    /// inside the projects tree. The session id is a UUID, unique across the
    /// tree, so a single match is the session — this covers a slug this app's
    /// mirror cannot compute (the client's >200-character hash suffix) and any
    /// future change to the client's rule. Runs at most once per session id per
    /// process: the answer is cached, and only a miss reaches it.
    private static func locateTranscript(sessionId: String, projects: URL) -> URL? {
        guard !sessionId.isEmpty,
              let children = try? FileManager.default.contentsOfDirectory(
                at: projects, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let candidate = child.appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// sessionId → project directory, filled only by `locateTranscript` hits.
    /// Bounded by the number of sessions this process ever sees, and dropped
    /// with the process, which is the same lifetime as the monitor's data.
    private static let transcriptCache = TranscriptPathCache()

    private final class TranscriptPathCache: @unchecked Sendable {
        private let lock = NSLock()
        private var directories: [String: String] = [:]

        func dir(for sessionId: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return directories[sessionId]
        }

        func store(_ path: String, for sessionId: String) {
            lock.lock(); defer { lock.unlock() }
            directories[sessionId] = path
        }
    }

    static func transcriptSize(for session: SessionInfo) -> UInt64 {
        let path = transcriptURL(for: session).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let n = attrs[.size] as? NSNumber else { return 0 }
        return n.uint64Value
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
}
