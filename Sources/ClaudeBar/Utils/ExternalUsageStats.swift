import Foundation

/// Usage aggregation for external agent tools — Codex, WorkBuddy, OpenClaw.
///
/// All three write JSONL transcripts with per-record timestamps and token
/// accounting, so one parser parameterized by a record shape covers them:
///
/// - **Codex** (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`): usage lands
///   in `event_msg` records whose payload is `token_count`; the cumulative
///   `total_token_usage` is reported per turn, so only the *last* token_count
///   per file is kept (summing every record would multiply-count).
/// - **WorkBuddy** (`~/.workbuddy/projects/*/*.jsonl`): usage lives on
///   `function_call` records under `providerData.usage` (`inputTokens` /
///   `outputTokens`, with `inputTokensDetails[].cached_tokens`).
/// - **OpenClaw** (`~/.openclaw/agents/*/sessions/*.jsonl`): usage lives on
///   `message` records under `message.usage` (`input` / `output` /
///   `cacheRead` / `cacheWrite`).
///
/// The output reuses `ModelUsage` so external tools fold into the same
/// per-model breakdown as Claude Code usage.
struct ExternalUsageStats {

    // MARK: - Public API

    /// Per-model usage within `interval` across all external tools, sorted by
    /// total tokens descending. Files are rejected by mtime first; parsing is
    /// parallelized the same way as `UsageStats`.
    static func fetch(in interval: DateInterval) -> [ModelUsage] {
        let cutoff = interval.start.timeIntervalSince1970
        var files: [(path: String, kind: ExternalAgentKind, mtime: TimeInterval)] = []
        for kind in ExternalAgentKind.allCases {
            files.append(contentsOf: sessionFiles(kind: kind, cutoff: cutoff))
        }

        var parsed = [[UsageEntry]](repeating: [], count: files.count)
        DispatchQueue.concurrentPerform(iterations: files.count) { j in
            parsed[j] = parseFile(path: files[j].path, kind: files[j].kind)
        }

        var agg: [String: ModelUsage] = [:]
        for entries in parsed {
            for e in entries where interval.contains(e.date) {
                var entry = agg[e.model] ?? ModelUsage(model: e.model)
                entry.calls += e.calls
                entry.inputTokens += e.inputTokens
                entry.outputTokens += e.outputTokens
                entry.cacheReadTokens += e.cacheReadTokens
                entry.cacheCreationTokens += e.cacheCreationTokens
                agg[e.model] = entry
            }
        }
        return agg.values
            .filter { $0.totalTokens > 0 }
            .sorted { $0.totalTokens > $1.totalTokens }
    }

    // MARK: - File discovery

    /// All transcript files for a tool modified after `cutoff`. Walks the
    /// tool's directory layout (day dirs / project dirs / agent dirs) and
    /// applies the mtime prefilter before anything is opened.
    private static func sessionFiles(kind: ExternalAgentKind, cutoff: TimeInterval) -> [(String, ExternalAgentKind, TimeInterval)] {
        let fm = FileManager.default
        let root = kind.rootDir
        guard let topDirs = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        var out: [(String, ExternalAgentKind, TimeInterval)] = []
        for top in topDirs {
            let topPath = "\(root)/\(top)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: topPath, isDirectory: &isDir), isDir.boolValue else { continue }

            // Codex nests by year/month/day; WorkBuddy/OpenClaw nest one level.
            let leafDirs: [String]
            if kind == .codex {
                leafDirs = [topPath]
            } else {
                leafDirs = [topPath]
            }

            for dir in leafDirs {
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for entry in entries {
                    let path = "\(dir)/\(entry)"
                    var entryIsDir: ObjCBool = false
                    guard fm.fileExists(atPath: path, isDirectory: &entryIsDir) else { continue }
                    if entryIsDir.boolValue {
                        // One more level down (day → files, project → files,
                        // agent → sessions → files).
                        guard let inner = try? fm.contentsOfDirectory(atPath: path) else { continue }
                        for innerEntry in inner {
                            let innerPath = "\(path)/\(innerEntry)"
                            if innerEntry.hasSuffix(".jsonl"),
                               let m = mtimeIfRecent(innerPath, cutoff: cutoff) {
                                // Skip OpenClaw's duplicate trajectory streams.
                                if innerEntry.contains(".trajectory") { continue }
                                out.append((innerPath, kind, m))
                            }
                        }
                    } else if entry.hasSuffix(".jsonl") {
                        // Codex files may sit directly under the day dir.
                        if let m = mtimeIfRecent(path, cutoff: cutoff) {
                            out.append((path, kind, m))
                        }
                    }
                }
                // Codex: year → month → day; handle the two extra levels.
                if kind == .codex {
                    for month in leafDirsX(dir) {
                        guard let days = try? fm.contentsOfDirectory(atPath: month) else { continue }
                        for day in days {
                            let dayPath = "\(month)/\(day)"
                            guard let files = try? fm.contentsOfDirectory(atPath: dayPath) else { continue }
                            for f in files where f.hasSuffix(".jsonl") {
                                let p = "\(dayPath)/\(f)"
                                if let m = mtimeIfRecent(p, cutoff: cutoff) {
                                    out.append((p, kind, m))
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Codex month directories under a year directory (`01`…`12`).
    private static func leafDirsX(_ yearPath: String) -> [String] {
        let fm = FileManager.default
        guard let months = try? fm.contentsOfDirectory(atPath: yearPath) else { return [] }
        return months.map { "\(yearPath)/\($0)" }
    }

    /// mtime of a file if it was modified at/after `cutoff`, else nil.
    private static func mtimeIfRecent(_ path: String, cutoff: TimeInterval) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let t = mtime.timeIntervalSince1970
        return t >= cutoff ? t : nil
    }

    // MARK: - Parsing

    private struct UsageEntry {
        let date: Date
        let model: String
        var calls = 0
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheCreationTokens = 0
    }

    /// Parse one transcript into usage entries. Per-kind shapes are handled
    /// inline — each is a handful of well-known field names.
    private static func parseFile(path: String, kind: ExternalAgentKind) -> [UsageEntry] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }

        var entries: [UsageEntry] = []
        // Codex reports cumulative usage; only the latest token_count per
        // file survives (kept separately so it is timestamped by its record).
        var lastCodex: UsageEntry? = nil

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"usage\"") || line.contains("token_count") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }

            switch kind {
            case .codex:
                // {"timestamp":"...","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{...}}}}
                guard obj["type"] as? String == "event_msg",
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any] else { continue }
                guard let date = isoDate(obj["timestamp"]) else { continue }
                var e = UsageEntry(date: date, model: "codex")
                e.calls = 1
                e.inputTokens = JSONCoerce.intVal(total["input_tokens"])
                e.outputTokens = JSONCoerce.intVal(total["output_tokens"])
                e.cacheReadTokens = JSONCoerce.intVal(total["cached_input_tokens"])
                lastCodex = e

            case .workbuddy:
                // {"timestamp":1787066580481,"type":"function_call","providerData":{"model":"glm-5.2","usage":{"inputTokens":...,"outputTokens":...,"inputTokensDetails":[{"cached_tokens":...}]}}}
                guard obj["type"] as? String == "function_call",
                      let pd = obj["providerData"] as? [String: Any],
                      let usage = pd["usage"] as? [String: Any] else { continue }
                guard let date = msDate(obj["timestamp"]) else { continue }
                let model = (pd["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "workbuddy"
                var e = UsageEntry(date: date, model: model)
                e.calls = 1
                e.inputTokens = JSONCoerce.intVal(usage["inputTokens"])
                e.outputTokens = JSONCoerce.intVal(usage["outputTokens"])
                if let details = usage["inputTokensDetails"] as? [[String: Any]] {
                    e.cacheReadTokens = details.reduce(0) { $0 + JSONCoerce.intVal($1["cached_tokens"]) }
                }
                entries.append(e)

            case .openclaw:
                // {"type":"message","timestamp":"...","message":{"role":"assistant","model":"qwen3.7-plus","usage":{"input":...,"output":...,"cacheRead":...,"cacheWrite":...}}}
                guard obj["type"] as? String == "message",
                      let message = obj["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }
                guard let date = isoDate(obj["timestamp"]) else { continue }
                let model = (message["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "openclaw"
                var e = UsageEntry(date: date, model: model)
                e.calls = 1
                e.inputTokens = JSONCoerce.intVal(usage["input"])
                e.outputTokens = JSONCoerce.intVal(usage["output"])
                e.cacheReadTokens = JSONCoerce.intVal(usage["cacheRead"])
                e.cacheCreationTokens = JSONCoerce.intVal(usage["cacheWrite"])
                entries.append(e)
            }
        }

        // Codex: one entry per file — the cumulative total at last write.
        if let last = lastCodex { entries.append(last) }
        return entries
    }

    /// ISO8601 timestamp ("2026-05-18T02:47:01.079Z") → Date.
    private static func isoDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Epoch-milliseconds timestamp (WorkBuddy) → Date.
    private static func msDate(_ any: Any?) -> Date? {
        guard let ms = JSONCoerce.doubleVal(any) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
