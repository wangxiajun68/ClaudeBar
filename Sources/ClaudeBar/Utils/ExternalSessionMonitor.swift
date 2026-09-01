import Foundation

// MARK: - Model

/// A live Codex CLI/Desktop session. Codex does not write PID files like
/// Claude Code, so liveness and busy-ness are both **recency-based**: a
/// session file touched within `recencyWindow` is alive, and one touched
/// within `busyWindow` is considered mid-turn (its writer is actively
/// appending).
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
    var contextTokens: Int = 0
    var contextLimit: Int = 0

    var projectFolder: String { (cwd as NSString).lastPathComponent }

    var contextRatio: Double {
        guard contextLimit > 0 else { return 0 }
        return min(1, Double(contextTokens) / Double(contextLimit))
    }

    var contextLabel: String {
        guard contextLimit > 0 || contextTokens > 0 else { return kind.displayName }
        let used = UsageStats.formatContext(contextTokens)
        if contextLimit > 0 { return "\(used) / \(UsageStats.formatContext(contextLimit))" }
        return used
    }

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

    var displayName: String { "Codex" }

    var icon: String { "chevron.left.forwardslash.chevron.right" }

    var rootDir: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.codex/sessions"
    }

    /// A session counts as "alive" (surfaced in the list) while its
    /// transcript was touched this recently. There is no PID file, so
    /// recency is the only liveness signal. 30 days covers history browsing;
    /// sessions sort most-recent-first so old ones never crowd the top.
    var recencyWindow: TimeInterval { 30 * 86400 }

    /// Codex appends token_count events continuously while a turn is in
    /// flight — they land within seconds of each other.
    var busyWindow: TimeInterval { 90 }
}

// MARK: - Monitor

/// Scans Codex rollout JSONLs and reports recent sessions. Pure file
/// metadata + a bounded head/tail read per file, run off-main by
/// `ProviderStore`.
struct ExternalSessionMonitor {

    static func fetchActive() -> [ExternalSessionInfo] {
        fetchCodex().sorted { $0.updatedAt > $1.updatedAt }
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
        // recency window. Codex nests by year/month/day; cap the walk at the
        // 3 most recent months so a long Codex history never walks the whole
        // tree.
        let cutoff = now - ExternalAgentKind.codex.recencyWindow

        var results: [ExternalSessionInfo] = []
        let fm = FileManager.default
        guard let yearDirs = try? fm.contentsOfDirectory(atPath: root).sorted().reversed() else { return [] }
        yearLoop: for year in yearDirs {
            let yearPath = "\(root)/\(year)"
            guard let months = try? fm.contentsOfDirectory(atPath: yearPath).sorted().reversed() else { continue }
            for month in months {
                let monthPath = "\(yearPath)/\(month)"
                guard let days = try? fm.contentsOfDirectory(atPath: monthPath).sorted().reversed() else { continue }
                for day in days {
                    let dayPath = "\(monthPath)/\(day)"
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
                        let base = (file as NSString).deletingPathExtension
                        let sessionId = String(base.suffix(36))
                        let ctx = readCodexContext(path: path)
                        results.append(ExternalSessionInfo(
                            kind: .codex,
                            sessionId: sessionId,
                            cwd: cwd,
                            startedAt: meta.mtime * 1000,
                            updatedAt: meta.mtime * 1000,
                            model: model,
                            isAlive: true,
                            isActive: now - meta.mtime <= ExternalAgentKind.codex.busyWindow,
                            contextTokens: ctx.used,
                            contextLimit: ctx.limit
                        ))
                    }
                }
            }
            // History is capped: once a year's scan has crossed the window,
            // older years cannot qualify. Stop after 2 years max walk.
            if results.count > 400 { break yearLoop }
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
    /// transcript.
    private static func readHead(path: String, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// Tail `token_count` — `last_token_usage.total_tokens` vs `model_context_window`.
    private static func readCodexContext(path: String) -> (used: Int, limit: Int) {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return (0, 0) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size - min(48_000, size))
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return (0, 0) }
        var used = 0, limit = 0
        for line in text.split(separator: "\n") {
            guard line.contains("token_count"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any] else { continue }
            if let w = info["model_context_window"] as? Int { limit = w }
            else if let w = info["model_context_window"] as? Double { limit = Int(w) }
            let last = (info["last_token_usage"] as? [String: Any])
                ?? (info["total_token_usage"] as? [String: Any])
            if let last {
                let total = JSONCoerce.intVal(last["total_tokens"])
                let input = JSONCoerce.intVal(last["input_tokens"])
                    + JSONCoerce.intVal(last["cached_input_tokens"])
                used = total > 0 ? total : input
            }
        }
        return (used, limit)
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
