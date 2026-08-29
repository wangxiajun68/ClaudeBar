import Foundation

// MARK: - Model

/// A live session from an external agent tool — Codex CLI/Desktop,
/// WorkBuddy, or OpenClaw. None of these tools write PID files like Claude
/// Code does, so liveness and busy-ness are both **recency-based**: a session
/// file touched within `recencyWindow` is alive, and one touched within
/// `busyWindow` is considered mid-turn (its writer is actively appending).
struct ExternalSessionInfo: Identifiable, Equatable {
    var id: String { "\(kind.rawValue):\(sessionId)" }
    let kind: ExternalAgentKind
    let sessionId: String
    let cwd: String
    let startedAt: Double        // epoch ms (first record or file birth)
    let updatedAt: Double        // epoch ms (file mtime)
    let model: String            // model declared by the tool ("" if unknown)
    var isAlive: Bool
    var isActive: Bool           // touched within busyWindow → working

    var projectFolder: String { (cwd as NSString).lastPathComponent }

    /// Short "5m ago" style label since last update.
    var relativeUpdated: String {
        let secs = max(0, (Date().timeIntervalSince1970 * 1000 - updatedAt) / 1000)
        if secs < 60 { return "\(Int(secs))s" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86400 { return "\(Int(secs / 3600))h" }
        return "\(Int(secs / 86400))d"
    }
}

/// The external agent tools we recognize, with their on-disk homes.
enum ExternalAgentKind: String, CaseIterable {
    case codex
    case workbuddy
    case openclaw

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .workbuddy: return "WorkBuddy"
        case .openclaw: return "OpenClaw"
        }
    }

    /// Root directory of the tool's session data.
    var rootDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .codex: return home + "/.codex/sessions"
        case .workbuddy: return home + "/.workbuddy/projects"
        case .openclaw: return home + "/.openclaw/agents"
        }
    }

    /// A session counts as "alive" while its transcript was touched this
    /// recently — there is no PID file, so recency is the only liveness
    /// signal. 6 hours covers a long working day without flooding the list
    /// with day-old composers.
    var recencyWindow: TimeInterval { 6 * 3600 }

    /// A session counts as "active" (mid-turn) while its transcript was
    /// touched this recently. Turn granularity differs per tool: Codex
    /// appends token_count events continuously, WorkBuddy/OpenClaw append
    /// per tool call — all land within seconds of each other while working.
    var busyWindow: TimeInterval { 90 }
}

// MARK: - Monitor

/// Scans the on-disk session stores of external agent tools (Codex rollout
/// JSONLs, WorkBuddy project JSONLs, OpenClaw session JSONLs) and reports
/// recent sessions. Pure file metadata + a bounded head read per file, run
/// off-main by `ProviderStore`.
struct ExternalSessionMonitor {

    /// All recent sessions across the three tools, most recent first.
    static func fetchActive() -> [ExternalSessionInfo] {
        var sessions: [ExternalSessionInfo] = []
        sessions.append(contentsOf: fetchCodex())
        sessions.append(contentsOf: fetchWorkBuddy())
        sessions.append(contentsOf: fetchOpenClaw())
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Codex

    /// Codex writes rollout JSONLs under `~/.codex/sessions/YYYY/MM/DD/`:
    /// `rollout-<ts>-<uuid>.jsonl`. Line 1 is `session_meta` (cwd), and
    /// `turn_context` records carry the model. The transcript filename
    /// embeds the session UUID.
    private static func fetchCodex() -> [ExternalSessionInfo] {
        let root = ExternalAgentKind.codex.rootDir
        let now = Date().timeIntervalSince1970
        // A session is only surfaced if its file was touched within the
        // recency window — restrict the directory walk to dates that can
        // still qualify (today ± 1).
        let cutoff = now - ExternalAgentKind.codex.recencyWindow

        var results: [ExternalSessionInfo] = []
        let fm = FileManager.default
        guard let dayDirs = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        for day in dayDirs.sorted().reversed() {                    // newest date first
            let dayPath = "\(root)/\(day)"
            guard let attrs = try? fm.attributesOfItem(atPath: dayPath),
                  let dayMod = attrs[.modificationDate] as? Date, dayMod.timeIntervalSince1970 >= cutoff - 86_400
            else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: dayPath) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = "\(dayPath)/\(file)"
                guard let meta = fileMeta(path: path, cutoff: cutoff) else { continue }
                let head = readHead(path: path, bytes: 32_000)
                let cwd = head.field(forKey: "\"cwd\":\"")
                // Prefer the turn_context model; fall back to any "model"
                // occurrence (session_meta has none, turn_context always
                // appears within the first turns).
                let model = head.field(forKey: "\"model\":\"")
                let sessionId = file
                    .replacingOccurrences(of: "rollout-", with: "")
                    .suffix(36)                                     // trailing uuid
                results.append(ExternalSessionInfo(
                    kind: .codex,
                    sessionId: String(sessionId),
                    cwd: cwd,
                    startedAt: meta.mtime * 1000,
                    updatedAt: meta.mtime * 1000,
                    model: model,
                    isAlive: true,
                    isActive: now - meta.mtime <= ExternalAgentKind.codex.busyWindow
                ))
            }
        }
        return results
    }

    // MARK: WorkBuddy

    /// WorkBuddy writes one JSONL per project under
    /// `~/.workbuddy/projects/<encoded-cwd>/<sessionId>.jsonl`. Usage-bearing
    /// `function_call` records carry `providerData.model`. The encoded
    /// directory name maps back to the workspace title; the real cwd lives
    /// inside the records, but reading it requires a full scan — the
    /// directory name (e.g. `Users-wangxiajun-WorkBuddy-2026-08-25-19-17-10`)
    /// is human-readable enough as a fallback via the last path component.
    private static func fetchWorkBuddy() -> [ExternalSessionInfo] {
        let kind = ExternalAgentKind.workbuddy
        let root = kind.rootDir
        let now = Date().timeIntervalSince1970
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        var results: [ExternalSessionInfo] = []
        for dir in projectDirs {
            let dirPath = "\(root)/\(dir)"
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = "\(dirPath)/\(file)"
                guard let meta = fileMeta(path: path, cutoff: now - kind.recencyWindow) else { continue }
                // WorkBuddy's cwd lives inside the first user message's
                // <system-reminder> block, which can run long — the head
                // needs enough bytes to reach it (measured: ~13.4KB on a
                // real transcript).
                let head = readHead(path: path, bytes: 24_000)
                let cwd = head.field(forKey: "\"cwd\":\"")
                // The model sits on providerData (e.g. "providerData":
                // {"model":"glm-5.2",…}); a bare "model" key also appears in
                // other uuid-ish contexts, so anchor on providerData.
                var model = ""
                if let pr = head.range(of: "\"providerData\":{") {
                    let pdSegment = head[pr.upperBound...]
                    let pdEnd = pdSegment.firstIndex(of: "\n") ?? pdSegment.endIndex
                    if let mr = pdSegment[..<pdEnd].range(of: "\"model\":\"") {
                        let after = pdSegment[mr.upperBound...]
                        if let q = after.firstIndex(of: "\"") { model = String(after[..<q]) }
                    }
                }
                results.append(ExternalSessionInfo(
                    kind: .workbuddy,
                    sessionId: (file as NSString).deletingPathExtension,
                    cwd: cwd,
                    startedAt: meta.mtime * 1000,
                    updatedAt: meta.mtime * 1000,
                    model: model,
                    isAlive: true,
                    isActive: now - meta.mtime <= kind.busyWindow
                ))
            }
        }
        return results
    }

    // MARK: OpenClaw

    /// OpenClaw stores sessions under
    /// `~/.openclaw/agents/<agent>/sessions/<uuid>.jsonl` (the sibling
    /// `.trajectory.jsonl` is a duplicate stream and is skipped). Line 1 is
    /// a `session` record with cwd; `model_change` records carry the model.
    private static func fetchOpenClaw() -> [ExternalSessionInfo] {
        let kind = ExternalAgentKind.openclaw
        let root = kind.rootDir
        let now = Date().timeIntervalSince1970
        let fm = FileManager.default
        guard let agents = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        var results: [ExternalSessionInfo] = []
        for agent in agents {
            let sessionsPath = "\(root)/\(agent)/sessions"
            guard let files = try? fm.contentsOfDirectory(atPath: sessionsPath) else { continue }
            for file in files where file.hasSuffix(".jsonl") && !file.contains(".trajectory") {
                let path = "\(sessionsPath)/\(file)"
                guard let meta = fileMeta(path: path, cutoff: now - kind.recencyWindow) else { continue }
                let head = readHead(path: path, bytes: 8_000)
                let cwd = head.field(forKey: "\"cwd\":\"")
                let model = head.field(forKey: "\"modelId\":\"")
                results.append(ExternalSessionInfo(
                    kind: .openclaw,
                    sessionId: (file as NSString).deletingPathExtension,
                    cwd: cwd,
                    startedAt: meta.mtime * 1000,
                    updatedAt: meta.mtime * 1000,
                    model: model,
                    isAlive: true,
                    isActive: now - meta.mtime <= kind.busyWindow
                ))
            }
        }
        return results
    }

    // MARK: Helpers

    /// mtime of a session file; nil when the file predates `cutoff` (the
    /// dominant case once a tool has a long history — mtime rejects the
    /// file without opening it).
    private static func fileMeta(path: String, cutoff: TimeInterval) -> (mtime: TimeInterval, size: Int)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let t = mtime.timeIntervalSince1970
        guard t >= cutoff else { return nil }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return (t, size)
    }

    /// Bounded head read of a JSONL file, returned as a String. Only the
    /// first records are needed (session_meta / turn_context / model_change
    /// all appear at the top of the file), so we never read the full
    /// transcript. 24KB covers WorkBuddy's long first user-context block
    /// (measured ~13.4KB before the cwd appears on a real transcript).
    private static func readHead(path: String, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}

// MARK: - Head-field extraction

private extension String {
    /// Value of the first `"key":"value"` occurrence in the head — a cheap
    /// prefix scan instead of parsing every JSONL record. Values are untyped
    /// path/model strings; escaped quotes inside them are impossible for
    /// cwd/model shapes these tools write.
    func field(forKey key: String) -> String {
        guard let r = range(of: key) else { return "" }
        let after = self[r.upperBound...]
        guard let q = after.firstIndex(of: "\"") else { return "" }
        return String(after[..<q])
    }
}
