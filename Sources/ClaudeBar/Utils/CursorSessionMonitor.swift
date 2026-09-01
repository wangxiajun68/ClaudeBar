import Foundation
import SQLite3

// MARK: - Models

/// A live Cursor (IDE) agent session, parsed from Cursor's `state.vscdb`
/// `composerHeaders` table. Cursor stores each chat/agent session as a
/// "composer"; this is the Cursor-side analogue of `SessionInfo`.
///
/// Unlike Claude Code, Cursor has no per-process PID file — sessions live in
/// SQLite. Liveness is therefore recency-based (a composer touched within
/// `recencyWindowMs` is considered "alive"), and "busy" means an agent turn
/// is in flight (either `agentLocation.status == "active"` in the head, or the
/// transcript's last assistant turn has no following `turn_ended` marker).
struct CursorSessionInfo: Identifiable, Equatable {
    var id: String { composerId }
    let composerId: String
    let name: String
    let cwd: String
    let createdAt: Double          // epoch ms
    let lastUpdatedAt: Double      // epoch ms
    var contextPercent: Double     // 0...100 from head.contextUsagePercent (-1 if absent)
    var status: CursorStatus       // agent running?
    var isAlive: Bool              // recent enough to surface

    // Filled by scanning the transcript tail (0/"" if no transcript).
    var messageCount: Int = 0
    var currentActivity: String = ""
    var toolPending: Bool = false   // last turn not yet ended → working
    var subagents: [CursorSubagentInfo] = []

    /// Context fill ratio 0...1 (0 if percent unknown).
    var contextRatio: Double {
        guard contextPercent >= 0 else { return 0 }
        return min(1.0, contextPercent / 100.0)
    }

    /// Compact context label, e.g. "68%". Cursor exposes a fill percentage, not
    /// absolute token counts, so the label is a percent (unlike Claude's "159K / 200K").
    var contextLabel: String {
        guard contextPercent >= 0 else { return "—" }
        return String(format: "%.0f%%", contextPercent)
    }

    /// Folder name derived from cwd, e.g. "ClaudeBar".
    var projectFolder: String {
        (cwd as NSString).lastPathComponent
    }

    /// Short "5m ago" style label since last update.
    var relativeUpdated: String {
        let now = Date().timeIntervalSince1970 * 1000
        let secs = max(0, (now - lastUpdatedAt) / 1000)
        if secs < 60 { return "\(Int(secs))s" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86400 { return "\(Int(secs / 3600))h" }
        return "\(Int(secs / 86400))d"
    }
}

enum CursorStatus: String {
    case active, idle
    var label: String { rawValue }
}

/// A sub-composer spawned by a Cursor session. Cursor records the parent link
/// in the head's `subagentInfo.parentComposerId`; we group subagents under
/// their parent the same way Claude Code's `subagents/*.meta.json` are grouped.
struct CursorSubagentInfo: Identifiable, Equatable {
    var id: String { composerId }
    let composerId: String
    let agentType: String        // subagentTypeName: "explore", "review", ...
    let description: String      // the sub-composer's name
    var activity: String = ""
    var status: CursorSubagentStatus = .done
}

/// Status of a Cursor subagent, derived from whether its last assistant turn
/// has completed (`turn_ended`). Kept distinct from Claude's `SubagentStatus`
/// so this file is self-contained.
enum CursorSubagentStatus: String, Equatable {
    case running, done
}

/// Result of scanning a Cursor transcript tail.
private struct CursorTranscriptScan {
    let count: Int
    let activity: String
    let toolPending: Bool
}

// MARK: - Monitor

/// Reads Cursor's `state.vscdb` (read-only) and reports live Cursor composer
/// sessions. The DB is held open in WAL mode by Cursor while it runs; opening
/// it read-only is safe and never blocks Cursor's writer.
struct CursorSessionMonitor {

    /// Only surface composers touched within this window. Cursor accumulates
    /// hundreds of non-archived composers; without a recency cut the list is
    /// useless. 3 days matches "recently active" without flooding the panel.
    private static let recencyWindowMs: Double = 3 * 86_400 * 1000

    /// How many recent heads to pull from SQLite (ordered by recency). The
    /// `composerHeaders` table is indexed on `(recency, composerId)`, so this
    /// is cheap even though the DB is ~6.5 GB.
    private static let queryLimit: Int32 = 80

    /// Cap on sessions returned, to keep the panel scannable.
    private static let maxDisplay = 14

    /// All live Cursor sessions: parses composer heads, drops stale ones,
    /// enriches with transcript activity, sorts busy-first then by recency.
    static func fetchActive() -> [CursorSessionInfo] {
        guard let db = CursorDB.open() else { return [] }
        defer { sqlite3_close(db) }

        let nowMs = Date().timeIntervalSince1970 * 1000
        let cutoff = nowMs - recencyWindowMs

        // --- Main composers (non-archived, non-subagent), most recent first ---
        var sessions: [CursorSessionInfo] = []
        let sql = """
            SELECT composerId, recency, value
            FROM composerHeaders
            WHERE isArchived = 0 AND isSubagent = 0
            ORDER BY recency DESC
            LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, queryLimit)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let composerId = CursorDB.cString(stmt, 0)
            let recency = Double(sqlite3_column_int64(stmt, 1))
            guard let value = CursorDB.textColumn(stmt, 2),
                  let data = value.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let name = (obj["name"] as? String) ?? ""
            let createdAt = (obj["createdAt"] as? Double) ?? recency
            let lastUpdatedAt = (obj["lastUpdatedAt"] as? Double) ?? recency
            let cwd = extractFsPath(obj)
            let ctxPct = (obj["contextUsagePercent"] as? Double) ?? -1
            let locActive = isAgentActive(obj)
            let unfinishedAt = (obj["unfinishedRunAt"] as? Double) ?? 0
            let unfinishedRecent = unfinishedAt > 0 && (nowMs - unfinishedAt) < 120_000

            sessions.append(CursorSessionInfo(
                composerId: composerId,
                name: name,
                cwd: cwd,
                createdAt: createdAt,
                lastUpdatedAt: lastUpdatedAt,
                contextPercent: ctxPct,
                status: (unfinishedRecent || locActive) ? .active : .idle,
                isAlive: lastUpdatedAt > cutoff
            ))
        }

        // Keep only recent, cap, then enrich.
        var shown = Array(sessions.filter(\.isAlive).prefix(maxDisplay))

        for i in shown.indices {
            let scan = scanTranscript(cwd: shown[i].cwd, composerId: shown[i].composerId)
            shown[i].messageCount = scan.count
            shown[i].currentActivity = scan.activity
            shown[i].toolPending = scan.toolPending
            let recentlyTouched = (nowMs - shown[i].lastUpdatedAt) < 120_000
            // Sticky `agentLocation.status == active` on old chats is a Cursor
            // quirk. Trust a live transcript turn, a recent unfinished run, or
            // location+recency together — never a stale "active" from yesterday.
            if scan.toolPending {
                shown[i].status = .active
            } else if shown[i].status == .active && !recentlyTouched && !scan.toolPending {
                shown[i].status = .idle
            }
        }

        // --- Subagents: group non-archived sub-composers by their parent ---
        let parentIDs = Set(shown.map { $0.composerId })
        let subMap = fetchSubagents(db: db, parentIDs: parentIDs)
        for i in shown.indices {
            shown[i].subagents = subMap[shown[i].composerId] ?? []
        }

        // Busy first, then most-recent.
        return shown.sorted { a, b in
            if (a.status == .active) != (b.status == .active) { return a.status == .active }
            return a.lastUpdatedAt > b.lastUpdatedAt
        }
    }

    // MARK: - Subagents

    /// Fetch all non-archived sub-composers and group them under their parent
    /// composer id. Only parents in `parentIDs` are kept (others have no
    /// visible session to attach to).
    private static func fetchSubagents(db: OpaquePointer, parentIDs: Set<String>) -> [String: [CursorSubagentInfo]] {
        var map: [String: [CursorSubagentInfo]] = [:]
        let sql = "SELECT value FROM composerHeaders WHERE isArchived = 0 AND isSubagent = 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let value = CursorDB.textColumn(stmt, 0),
                  let data = value.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let composerId = (obj["composerId"] as? String) ?? ""
            let name = (obj["name"] as? String) ?? ""
            guard let sub = obj["subagentInfo"] as? [String: Any],
                  let parent = (sub["parentComposerId"] as? String) ?? (sub["rootParentConversationId"] as? String),
                  parentIDs.contains(parent) else { continue }
            let typeName = (sub["subagentTypeName"] as? String) ?? "agent"

            var info = CursorSubagentInfo(composerId: composerId, agentType: typeName, description: name)
            let cwd = extractFsPath(obj)
            let (activity, pending) = scanAgentActivity(cwd: cwd, composerId: composerId)
            info.activity = activity
            info.status = pending ? .running : .done
            map[parent, default: []].append(info)
        }

        // Running first, then by composerId for stable ordering.
        for key in map.keys {
            map[key]?.sort { a, b in
                if a.status != b.status { return a.status == .running }
                return a.composerId < b.composerId
            }
        }
        return map
    }

    // MARK: - Transcript scanning

    /// Scan the tail of a composer transcript for message count, the latest
    /// tool activity, and whether a turn is still in flight (no `turn_ended`
    /// after the last assistant message). Mirrors `SessionMonitor.fetchContext`.
    private static func scanTranscript(cwd: String, composerId: String) -> CursorTranscriptScan {
        let scan = scanTail(url: FilePaths.cursorTranscriptURL(cwd: cwd, composerId: composerId), readSize: 96_000)
        return CursorTranscriptScan(count: scan.count, activity: scan.activity, toolPending: scan.pending)
    }

    /// Tail scan for a subagent — activity + pending only (count unused).
    private static func scanAgentActivity(cwd: String, composerId: String) -> (activity: String, pending: Bool) {
        let scan = scanTail(url: FilePaths.cursorTranscriptURL(cwd: cwd, composerId: composerId), readSize: 32_000)
        return (scan.activity, scan.pending)
    }

    /// Shared tail reader. Cursor transcripts are JSONL where each line is
    /// either `{"role":"user"|"assistant","message":{"content":[...]}}` or a
    /// turn marker `{"type":"turn_ended",...}`. A turn is "pending" when the
    /// last assistant message has no following `turn_ended`.
    ///
    /// Single open/seek/read per call; the file's existence is implied by a
    /// successful open, so no separate stat is needed.
    private static func scanTail(url: URL, readSize: UInt64) -> (count: Int, activity: String, pending: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return (0, "", false)
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size - min(readSize, size))
        guard let tailData = try? handle.readToEnd(),
              let tail = String(data: tailData, encoding: .utf8) else {
            return (0, "", false)
        }

        var msgCount = 0
        var lastActivity = ""
        var lastAssistantLine = -1
        var lastTurnEndedLine = -1
        var lineIndex = 0
        for line in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            defer { lineIndex += 1 }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let t = obj["type"] as? String, t == "turn_ended" {
                lastTurnEndedLine = lineIndex
                continue
            }
            guard (obj["role"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }
            msgCount += 1
            lastAssistantLine = lineIndex
            if let act = describeActivity(in: message), !act.isEmpty {
                lastActivity = act
            }
        }
        // A turn is in flight if an assistant message appears after the last
        // turn_ended marker (i.e. the turn never completed).
        let pending = lastAssistantLine > lastTurnEndedLine
        return (msgCount, lastActivity, pending)
    }

    /// Human-readable summary of the latest tool_use in a message:
    /// "Grep · cm_cloud_organize", "Read · File.swift", "Glob · **/*.swift".
    /// Handles both Claude Code and Cursor tool names generically.
    private static func describeActivity(in message: [String: Any]) -> String? {
        guard let content = message["content"] as? [[String: Any]] else { return nil }
        var lastTool = ""
        for item in content where (item["type"] as? String) == "tool_use" {
            let name = (item["name"] as? String) ?? "tool"
            let input = (item["input"] as? [String: Any]) ?? [:]
            let detail = detailFor(name: name, input: input)
            lastTool = detail.isEmpty ? name : "\(name) · \(detail)"
        }
        return lastTool
    }

    /// Pick a short detail string from a tool's input. Tries path-like keys
    /// first (basename), then glob/command/query/subagent fields — covering
    /// Cursor tools (Glob→glob_pattern, Grep→pattern, SemanticSearch→query)
    /// and Claude tools (Read/Edit→file_path, Bash→command, Agent→subagent_type).
    private static func detailFor(name: String, input: [String: Any]) -> String {
        for key in ["file_path", "path", "target_file", "filePath"] {
            if let s = input[key] as? String, !s.isEmpty {
                return (s as NSString).lastPathComponent
            }
        }
        if let s = (input["glob_pattern"] as? String) ?? (input["pattern"] as? String), !s.isEmpty {
            return s
        }
        if let s = input["command"] as? String, !s.isEmpty {
            return s.split(separator: " ").first.map(String.init) ?? "bash"
        }
        if let s = (input["query"] as? String) ?? (input["search_query"] as? String), !s.isEmpty {
            return s
        }
        if let s = (input["subagent_type"] as? String) ?? (input["subagentTypeName"] as? String), !s.isEmpty {
            return s
        }
        return ""
    }

    // MARK: - Head field helpers

    /// `true` if the head declares an active agent location.
    /// Cursor only sets `agentLocation` while a composer is bound to a running
    /// agent; its `status` is "active" in that case.
    private static func isAgentActive(_ obj: [String: Any]) -> Bool {
        guard let loc = obj["agentLocation"] as? [String: Any] else { return false }
        return (loc["status"] as? String) == "active"
    }

    /// Extract the workspace filesystem path from a composer head. Cursor
    /// nests it under `workspaceIdentifier.uri.fsPath` (or, for drafts,
    /// `draftTarget.environment.uri.fsPath`).
    private static func extractFsPath(_ obj: [String: Any]) -> String {
        if let ws = obj["workspaceIdentifier"] as? [String: Any],
           let uri = ws["uri"] as? [String: Any],
           let p = uri["fsPath"] as? String { return p }
        if let dt = obj["draftTarget"] as? [String: Any],
           let env = dt["environment"] as? [String: Any],
           let uri = env["uri"] as? [String: Any],
           let p = uri["fsPath"] as? String { return p }
        return ""
    }

    // MARK: - SQLite helpers

    // Open + column-read helpers live in `CursorDB` (shared with
    // CursorUsageStats).
}
