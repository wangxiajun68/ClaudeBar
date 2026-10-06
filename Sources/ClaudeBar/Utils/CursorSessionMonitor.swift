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
/// is in flight, using unfinished-run checkpoints and transcript turn markers.
/// Cursor may keep writing SQLite while its JSONL export stops updating.
struct CursorSessionInfo: Identifiable, Equatable {
    var id: String { composerId }
    let composerId: String
    let name: String
    let cwd: String
    let lastUpdatedAt: Double      // latest activity, epoch ms
    var contextPercent: Double     // 0...100 from head.contextUsagePercent (-1 if absent)
    var status: CursorStatus       // agent running?
    var isAlive: Bool              // recent enough to surface

    // Filled by scanning the transcript tail ("" if no transcript).
    var currentActivity: String = ""
    /// `composerHeaders.value.name`, Cursor's own conversation title.
    var title: String = ""
    /// `composerHeaders.value.subtitle` — e.g. "Edited app.py, frontend.html".
    var subtitle: String = ""
    var completionID: String? = nil // byte offset of the latest successful final answer
    var subagents: [CursorSubagentInfo] = []
    /// Cursor is parked on the user: a plan is waiting to be applied, or an
    /// action is blocking the run. Written by Cursor into the composer head
    /// (`hasPendingPlan` / `hasBlockingPendingActions`).
    ///
    /// Reached for the same reason Claude's `waiting` state exists — a run
    /// parked on a decision is not *running* — but read from a different place.
    /// Cursor's own predicate for "is this composer quiet" is
    /// `status != "generating" && hasPendingPlan != true && !blocking`, i.e.
    /// Cursor itself treats both flags as "an agent is busy" only in the sense
    /// that it cannot be driven by a background submit. What they mean to this
    /// app is the opposite: the human is the hold-up. See
    /// `SessionStatus.waiting` for the measured Claude Code evidence; the
    /// Cursor flags are documented in `docs/technical/cursor-session-monitor-investigation.md`.
    var hasPendingDecision: Bool = false

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

    /// Parked on the user rather than working. See `hasPendingDecision`.
    var isWaiting: Bool { hasPendingDecision }

    /// Mid-work: a turn is in flight and *not* held up by a decision. The
    /// dashboard's 运行中 count and the menu-bar pulse both mean this, so the
    /// parked case has to be subtracted here rather than at each call site.
    /// A child that is still running keeps the parent busy after the parent's
    /// own turn has gone idle. The parked case stays excluded: a decision
    /// waiting on the user is not work.
    var isBusy: Bool { !isWaiting && (status == .active || subagents.contains { $0.status == .running }) }

    /// Running children belong on the same line as the parent's own tool.
    /// Callers that are parked already substitute the waiting reason.
    var displayActivity: String {
        let running = subagents.filter { $0.status == .running }
        if isWaiting || running.isEmpty { return currentActivity }
        let children = running.map { agent -> String in
            let name = agent.description.isEmpty ? agent.agentType : agent.description
            return agent.activity.isEmpty ? name : "\(name) · \(agent.activity)"
        }
        if currentActivity.isEmpty { return children.joined(separator: " + ") }
        return (children + [currentActivity]).joined(separator: " + ")
    }

    /// Folder name derived from cwd, e.g. "ClaudeBar".
    var projectFolder: String {
        (cwd as NSString).lastPathComponent
    }

    /// Cursor already stores a real conversation title, so it wins over the
    /// folder; `subtitle` is the "what changed" line shown underneath.
    var displayTitle: String {
        SessionTitle(authored: title, folder: projectFolder).display
    }

    /// Two-part card header: `folder · Cursor 的会话标题`.
    var cardLabel: SessionTitle.Label {
        SessionTitle(authored: title, folder: projectFolder).cardLabel
    }

    /// Budgeted "Edited app.py, frontend.html" line.
    var cardSubtitle: String {
        SessionTitle(authored: title, folder: projectFolder, subtitle: subtitle).cardSubtitle
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

/// Status of a Cursor subagent, derived from whether its last turn
/// has completed (`turn_ended`). Kept distinct from Claude's `SubagentStatus`
/// so this file is self-contained.
enum CursorSubagentStatus: String, Equatable {
    case running, done
}

/// Result of scanning a Cursor transcript tail.
private struct CursorTranscriptScan {
    let activity: String
    let toolPending: Bool
    let completionID: String?
    let ended: Bool
    /// The transcript file's mtime, as epoch ms (`0` when it could not be read).
    /// See `turnLiveWindowMs` for what it is for.
    let modifiedAt: Double

    func inFlight(nowMs: Double, unfinishedAt: Double, checkpointAt: Double, starting: Bool = false) -> Bool {
        if ended && modifiedAt >= unfinishedAt { return false }
        let checkpointLive = unfinishedAt > 0
            && (nowMs - max(unfinishedAt, checkpointAt)) < CursorSessionMonitor.turnLiveWindowMs
        let transcriptLive = toolPending && modifiedAt > 0
            && (nowMs - modifiedAt) < CursorSessionMonitor.turnLiveWindowMs
        return checkpointLive || transcriptLive || starting
    }
}

// MARK: - Monitor

/// Reads Cursor's `state.vscdb` (read-only) and reports live Cursor composer
/// sessions. The DB is held open in WAL mode by Cursor while it runs; opening
/// it read-only is safe and never blocks Cursor's writer.
struct CursorSessionMonitor {

    /// Only surface composers touched within this window. Cursor accumulates
    /// hundreds of non-archived composers; without a recency cut the list is
    /// useless. 3 days matches "recently active" without flooding the panel.
    ///
    /// This is a *listing* window, not a liveness test, and the difference
    /// matters: Cursor has no PID to check, so unlike Claude — where `isAlive`
    /// is `kill(pid, 0) == 0` and a dead session simply drops out — a three-day
    /// window is all that stands between the panel and yesterday's chats. See
    /// `turnLiveWindowMs` for the much shorter window that answers "is a turn
    /// actually in flight".
    private static let recencyWindowMs: Double = 3 * 86_400 * 1000

    /// A pending turn needs a write within ten minutes. Either the transcript
    /// or an unfinished run's SQLite checkpoint can supply that clock: Cursor
    /// can keep checkpointing for an entire turn without exporting JSONL.
    /// Submission time and agentLocation alone cannot prove ongoing work.
    /// Frozen, interrupted turns still expire when both write clocks stop.
    fileprivate static let turnLiveWindowMs: Double = 10 * 60 * 1000

    /// Budget for the recent list. Running sessions are never dropped to fit it.
    private static let maxDisplay = 14

    /// All live Cursor sessions: parses composer heads, drops stale ones,
    /// enriches with transcript activity, sorts busy-first then by recency.
    static func fetchActive() -> [CursorSessionInfo] {
        guard let db = CursorDB.open() else { return [] }
        defer { sqlite3_close(db) }

        let nowMs = Date().timeIntervalSince1970 * 1000
        let cutoff = nowMs - recencyWindowMs

        // Read the recent header set before imposing a display budget. A long
        // run can have an old submission/recency but a fresh checkpoint, and
        // must not disappear behind newer idle conversations or a row limit.
        //
        // `checkpointAt` is read but not filtered on: `ORDER BY recency DESC`
        // already decides the walk order, and `checkpointAt >= cutoff` cannot
        // use `idx_composerHeaders_1 (recency, composerId)` — the plan is a
        // full SCAN of the index every 2.5 s poll (measured 1.3 ms vs 0.4 ms
        // on 875 rows; the gap widens with the table). The arm was also
        // redundant in practice: a fresh checkpoint belongs to a composer
        // Cursor is still writing, and every write advances recency too.
        // Measured over all 611 real rows that carry both clocks, a checkpoint
        // leads its recency by at most 34 minutes, and the one composer the
        // 2026-09-28 investigation was written about ended with recency
        // *later* than its checkpoint. `inFlight` still consumes the selected
        // `checkpointAt`, so the long-run case keeps its clock — only the
        // prefilter that could never see it is gone.
        var sessions: [CursorSessionInfo] = []
        let sql = """
            SELECT composerId, recency, value, checkpointAt
            FROM composerHeaders
            WHERE isArchived = 0 AND isSubagent = 0
              AND recency >= ?
            ORDER BY recency DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let composerId = CursorDB.cString(stmt, 0)
            let recency = Double(sqlite3_column_int64(stmt, 1))
            guard let value = CursorDB.textColumn(stmt, 2),
                  let data = value.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let name = (obj["name"] as? String) ?? ""
            let subtitle = (obj["subtitle"] as? String) ?? ""
            let submittedAt = (obj["lastUpdatedAt"] as? Double) ?? recency
            let checkpointAt = max(Double(sqlite3_column_int64(stmt, 3)),
                                   (obj["conversationCheckpointLastUpdatedAt"] as? Double) ?? 0)
            let cwd = extractFsPath(obj)
            let ctxPct = (obj["contextUsagePercent"] as? Double) ?? -1
            let unfinishedAt = (obj["unfinishedRunAt"] as? Double) ?? 0
            let scan = scanTranscript(cwd: cwd, composerId: composerId)

            // A plan waiting to be applied, or an action blocking the run:
            // Cursor's own two flags for "this composer is held up on a human".
            let pendingDecision = (obj["hasPendingPlan"] as? Bool) == true
                || (obj["hasBlockingPendingActions"] as? Bool) == true

            // A terminal marker closes its own run, including errors. An old
            // answer must not close a newer run that has not reached JSONL yet.
            let terminalCurrent = scan.ended && scan.modifiedAt >= unfinishedAt
            let starting = isAgentActive(obj) && (nowMs - submittedAt) < 120_000
            let turnInFlight = scan.inFlight(nowMs: nowMs, unfinishedAt: unfinishedAt,
                                            checkpointAt: checkpointAt, starting: starting)
            // Finished transcripts carry the completion clock; later metadata
            // writes must not make an old answer look newly delivered.
            let updatedAt = max(submittedAt, terminalCurrent ? 0 : checkpointAt, scan.modifiedAt)

            sessions.append(CursorSessionInfo(
                composerId: composerId,
                name: name,
                cwd: cwd,
                lastUpdatedAt: updatedAt,
                contextPercent: ctxPct,
                status: turnInFlight ? .active : .idle,
                isAlive: updatedAt > cutoff,
                currentActivity: scan.activity,
                title: name,
                subtitle: subtitle,
                completionID: terminalCurrent ? scan.completionID : nil,
                hasPendingDecision: pendingDecision
            ))
        }

        let sorted = sessions.filter(\.isAlive).sorted { a, b in
            if (a.status == .active) != (b.status == .active) { return a.status == .active }
            if a.lastUpdatedAt != b.lastUpdatedAt { return a.lastUpdatedAt > b.lastUpdatedAt }
            return a.composerId < b.composerId
        }
        let busyCount = sorted.filter { $0.status == .active }.count
        var shown = Array(sorted.prefix(max(maxDisplay, busyCount)))

        // --- Subagents: group non-archived sub-composers by their parent ---
        let parentIDs = Set(shown.map { $0.composerId })
        let subMap = fetchSubagents(db: db, parentIDs: parentIDs)
        for i in shown.indices {
            shown[i].subagents = subMap[shown[i].composerId] ?? []
        }

        return shown
    }

    // MARK: - Subagents

    /// Fetch all non-archived sub-composers and group them under their parent
    /// composer id. Only parents in `parentIDs` are kept (others have no
    /// visible session to attach to).
    ///
    /// The parent id lives inside the `value` JSON blob, so the grouping
    /// filter runs after parsing the recent header set. Checkpoint recency is
    /// selected but not filtered on, for the same reason as `fetchActive`:
    /// the `OR checkpointAt >= ?` arm makes the plan a full index SCAN on
    /// every poll, and a helper with a fresh checkpoint always has a fresh
    /// recency too.
    private static func fetchSubagents(db: OpaquePointer, parentIDs: Set<String>) -> [String: [CursorSubagentInfo]] {
        var map: [String: [CursorSubagentInfo]] = [:]
        guard !parentIDs.isEmpty else { return map }
        let nowMs = Date().timeIntervalSince1970 * 1000
        let cutoff = nowMs - recencyWindowMs
        let sql = """
            SELECT value, checkpointAt FROM composerHeaders
            WHERE isArchived = 0 AND isSubagent = 1
              AND recency >= ?
            ORDER BY recency DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let value = CursorDB.textColumn(stmt, 0),
                  let data = value.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let composerId = (obj["composerId"] as? String) ?? ""
            let name = (obj["name"] as? String) ?? ""
            guard let sub = obj["subagentInfo"] as? [String: Any],
                  let parent = [sub["parentComposerId"] as? String, sub["rootParentConversationId"] as? String]
                    .compactMap({ $0 }).first(where: { parentIDs.contains($0) }) else { continue }
            let typeName = (sub["subagentTypeName"] as? String) ?? "agent"

            var info = CursorSubagentInfo(composerId: composerId, agentType: typeName, description: name)
            let cwd = extractFsPath(obj)
            // Current Cursor stores helpers beneath the root transcript,
            // not in their own composer directory. Retain the old path as a
            // fallback for exports from versions that used separate folders.
            let root = (sub["rootParentConversationId"] as? String) ?? parent
            let url = FilePaths.cursorTranscriptURL(cwd: cwd, composerId: root)
                .deletingLastPathComponent().appendingPathComponent("subagents/\(composerId).jsonl")
            var scan = scanTail(url: url, readSize: 32_000)
            if scan.modifiedAt == 0 {
                scan = scanTail(url: FilePaths.cursorTranscriptURL(cwd: cwd, composerId: composerId), readSize: 32_000)
            }
            let unfinishedAt = (obj["unfinishedRunAt"] as? Double) ?? 0
            let checkpointAt = max(Double(sqlite3_column_int64(stmt, 1)),
                                   (obj["conversationCheckpointLastUpdatedAt"] as? Double) ?? 0)
            info.activity = scan.activity
            info.status = scan.inFlight(nowMs: nowMs, unfinishedAt: unfinishedAt,
                                        checkpointAt: checkpointAt) ? .running : .done
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

    /// Scan the tail of a composer transcript for the latest tool activity and
    /// whether a turn is still in flight (no `turn_ended` after the last user
    /// or assistant message). Mirrors `SessionMonitor.fetchContext`.
    private static func scanTranscript(cwd: String, composerId: String) -> CursorTranscriptScan {
        scanTail(url: FilePaths.cursorTranscriptURL(cwd: cwd, composerId: composerId), readSize: 96_000)
    }

    /// Shared tail reader. Cursor transcripts are JSONL where each line is
    /// either `{"role":"user"|"assistant","message":{"content":[...]}}` or a
    /// turn marker `{"type":"turn_ended",...}`. A turn is "pending" when the
    /// last user or assistant message has no following `turn_ended`.
    ///
    /// Single open/seek/read per call; the file's existence is implied by a
    /// successful open, so no separate stat is needed. The file's mtime comes
    /// back with the result because the caller needs it to tell a live pending
    /// turn from a frozen one — see `turnLiveWindowMs`.
    private static func scanTail(url: URL, readSize: UInt64) -> CursorTranscriptScan {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return CursorTranscriptScan(activity: "", toolPending: false, completionID: nil, ended: false, modifiedAt: 0)
        }
        defer { try? handle.close() }
        let modifiedAt = ((try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? nil)?.timeIntervalSince1970 ?? 0
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size - min(readSize, size))
        guard let tailData = try? handle.readToEnd() else {
            return CursorTranscriptScan(activity: "", toolPending: false, completionID: nil, ended: false, modifiedAt: modifiedAt * 1000)
        }
        // Lossy decode — a strict one fails for the whole window whenever the
        // seek landed mid-character (see `SessionMonitor.fetchContext`).
        var lastActivity = ""
        var lastMessageLine = -1
        var lastTurnEndedLine = -1
        var lastAssistantWasFinalText = false
        var completionID: String?
        var lineIndex = 0
        var byteOffset = size - min(readSize, size)
        for rawLine in tailData.split(separator: 0x0A, omittingEmptySubsequences: false) {
            defer { byteOffset += UInt64(rawLine.count + 1) }
            let line = String(decoding: rawLine, as: UTF8.self)
            defer { lineIndex += 1 }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let t = obj["type"] as? String, t == "turn_ended" {
                lastTurnEndedLine = lineIndex
                completionID = (obj["status"] as? String) == "success" && lastAssistantWasFinalText
                    ? "turn-\(byteOffset)" : nil
                lastAssistantWasFinalText = false
                continue
            }
            if (obj["role"] as? String) == "user" {
                lastMessageLine = lineIndex
                lastActivity = ""
                completionID = nil
                lastAssistantWasFinalText = false
                continue
            }
            guard (obj["role"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }
            lastMessageLine = lineIndex
            completionID = nil
            let blocks = message["content"] as? [[String: Any]] ?? []
            lastAssistantWasFinalText = blocks.contains { ($0["type"] as? String) == "text"
                && !(($0["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                && !blocks.contains { ($0["type"] as? String) == "tool_use" }
            if let act = describeActivity(in: message), !act.isEmpty {
                lastActivity = act
            }
        }
        // Submission starts the turn; waiting for the first assistant block
        // otherwise hides slow first-token generation and queued work.
        let pending = lastMessageLine > lastTurnEndedLine
        let ended = lastTurnEndedLine >= 0 && lastTurnEndedLine > lastMessageLine
        return CursorTranscriptScan(activity: lastActivity, toolPending: pending,
                                    completionID: completionID, ended: ended, modifiedAt: modifiedAt * 1000)
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
    /// This location binding can remain "active" after a turn completes; only
    /// use it for the brief startup grace period, never as a live heartbeat.
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

    // Open + column-read helpers live in `CursorDB`.
}
