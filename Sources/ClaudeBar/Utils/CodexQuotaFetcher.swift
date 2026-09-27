import Foundation
import os

/// One ChatGPT Codex rate-limit window returned by Codex App Server.
struct CodexQuotaWindow: Equatable, Identifiable {
    var id: String { label }
    var label: String
    var usedPercent: Double
    var resetsAt: Date?
    /// The window's own length in minutes, straight from the API
    /// (`windowDurationMins`); 0 when the response did not say.
    ///
    /// It rides on the window because the display label is a *presentation* of
    /// it (`300 → "5 小时"`) and a view that wants to know "is this the short
    /// window?" must not re-parse that string to find out. `resetCompact` is the
    /// one reader: a short window shows a clock, a long one a day count.
    var durationMinutes: Int = 0

    var usedText: String {
        let rounded = usedPercent.rounded()
        if abs(usedPercent - rounded) < 0.05 { return "\(Int(rounded))%" }
        return String(format: "%.1f%%", usedPercent)
    }

    var resetText: String { resetClock }

    /// Clock time of the next allowance refresh. Today omits the date.
    var resetClock: String {
        guard let resetsAt else { return "重置时间未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(resetsAt) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "M月d日 HH:mm"
        }
        return "\(formatter.string(from: resetsAt)) 重置"
    }

    /// How long until that refresh, for the dashboard detail line.
    var resetWait: String {
        guard let resetsAt else { return "" }
        let delta = resetsAt.timeIntervalSinceNow
        if delta <= 60 { return "即将重置" }
        let minutes = Int(delta / 60)
        if minutes < 60 { return "\(minutes) 分钟后重置" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours < 48 {
            return rest == 0 ? "\(hours) 小时后重置" : "\(hours) 小时 \(rest) 分后重置"
        }
        return "\(hours / 24) 天后重置"
    }

    /// The reset moment in the fewest characters that still say it — for the
    /// popup header, where two windows share a 133pt cell.
    ///
    /// The popup's Codex chip is three columns wide with a model name and a
    /// vendor line above the gauges, so a *full* clock does not fit: `09-27
    /// 21:00` beside both windows pushes the second one off the cell ("7d 剩…"),
    /// which is a worse readout than no clock at all. What fits is the shortest
    /// honest form of each window's own answer, and the choice follows the
    /// window's **length**, not the calendar day:
    ///
    /// * a **short** window (hours — the 5 小时 one) always prints `HH:mm`. Its
    ///   reset is within hours, so the clock is the reading a person is waiting
    ///   on, and it says *when* rather than *how long*. That holds **even when
    ///   the reset falls just after midnight**: `01:00` is still the exact
    ///   answer, and it is shorter than any date-qualified form.
    /// * a **long** window (days — the 7 天 one) prints `2天`. A wall clock there
    ///   is days away and only looks precise; the day count is the useful
    ///   reading, and it is short.
    ///
    /// The threshold is 24 hours: below it the window resets at most once a day,
    /// so an unqualified `HH:mm` cannot be misread as a far-off instant; at or
    /// above it the answer is genuinely a number of days.
    ///
    /// Minutes are dropped from the clock on purpose — the tooltip and the
    /// dashboard's own clock line carry the exact time, and this is the one place
    /// the reading is abbreviated, so it is abbreviated in one place.
    var resetCompact: String {
        guard let resetsAt else { return "" }
        if durationMinutes > 0, durationMinutes <= 1_440 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: resetsAt)
        }
        // Midnight-to-midnight day difference, not a 24h span: "明天" has to mean
        // the next calendar day, because that is what a person reads it as.
        let days = Calendar.current.dateComponents([.day],
                                                   from: Calendar.current.startOfDay(for: Date()),
                                                   to: Calendar.current.startOfDay(for: resetsAt)).day ?? 0
        if days <= 1 { return "明天" }
        return "\(days)天"
    }
}

enum CodexQuotaFetcher {
    private static let logger = Logger(subsystem: "com.claudebar.app",
                                       category: "CodexQuota")

    struct Snapshot: Equatable {
        var windows: [CodexQuotaWindow] = []
        /// Shown when there is nothing to graph.
        var note: String? = nil
        /// Account credits have no currency guarantee; preserve the API unit.
        var creditBalance: String? = nil
    }

    /// How long a snapshot is considered fresh enough to serve without asking
    /// the network again.
    ///
    /// Measured on this machine: a full round trip is **2.6–6.5 s**, and
    /// `--version` (i.e. process start) is 0.02 s — the cost is the account
    /// call itself, not the CLI. Two callers want the same reading within
    /// seconds of each other (the popup opening, the dashboard, a hover that
    /// woke the store), and a window that resets in hours cannot move
    /// meaningfully in a minute. Serving the last reading inside this window is
    /// what makes the *second* look at the panel instant.
    ///
    /// The poll interval is 900 s, so this never masks a scheduled refresh.
    static let freshWindow: TimeInterval = 60

    /// The most recent successful snapshot, if it is still fresh.
    ///
    /// Only trustworthy snapshots are cached — see `remember`. A failure is
    /// never served from here, so a transient blip cannot be pinned for a
    /// minute.
    private static let cache = Cache()

    private final class Cache {
        private let lock = NSLock()
        private var snapshot: Snapshot?
        private var at: Date?

        func fresh() -> Snapshot? {
            lock.lock(); defer { lock.unlock() }
            guard let snapshot, let at, Date().timeIntervalSince(at) < freshWindow else { return nil }
            return snapshot
        }

        func store(_ snapshot: Snapshot) {
            lock.lock(); defer { lock.unlock() }
            self.snapshot = snapshot
            self.at = Date()
        }

        func clear() {
            lock.lock(); defer { lock.unlock() }
            snapshot = nil
            at = nil
        }
    }

    /// Drop the cached reading so the next caller goes to the network. Called
    /// by a *manual* refresh, where the user is explicitly asking for a new
    /// reading and a one-minute-old one would look like the button did nothing.
    static func invalidateCache() { cache.clear() }

    static func fetch() async -> Snapshot {
        if let fresh = cache.fresh() { return fresh }

        // Two rounds, not three. A failed attempt already cost a full network
        // round trip (2.6–6.5 s measured), so the old third try could leave the
        // spinner up for ~20 s before showing the same failure. The backoff
        // also starts shorter: the first retry is worth ~1 s, not 1 s plus a
        // second attempt's failure just to reach the same note.
        var last = Snapshot(note: "Codex 额度查询失败")
        for attempt in 1...2 {
            guard !Task.isCancelled else { return last }
            let snapshot = await Task.detached(priority: .utility) {
                fetchFromAppServer()
            }.value
            guard !Task.isCancelled else { return last }
            last = snapshot
            guard snapshot.windows.isEmpty, shouldRetry(snapshot) else {
                // Only a real answer is worth remembering.
                if snapshot.note == nil || !snapshot.windows.isEmpty {
                    cache.store(snapshot)
                }
                return snapshot
            }
            guard attempt < 2 else { break }
            logger.warning("Transient failure; retrying quota fetch (attempt \(attempt + 1, privacy: .public)/2)")
            try? await Task<Never, Never>.sleep(for: .milliseconds(600))
        }
        return last
    }

    private static func shouldRetry(_ snapshot: Snapshot) -> Bool {
        guard let note = snapshot.note else { return false }
        return note.hasPrefix("Codex 额度查询失败")
            || note == "Codex 额度查询超时"
            || note == "Codex 额度服务未返回数据"
    }

    /// Ask the installed Codex runtime instead of calling ChatGPT's private
    /// web endpoint directly. App Server owns token refresh and keeps this
    /// integration on Codex's documented account API.
    private static func fetchFromAppServer() -> Snapshot {
        guard let executable = codexExecutable() else {
            logger.error("Codex executable not found")
            return Snapshot(note: "未找到 Codex，请先安装或打开 Codex")
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.error("Failed to start app-server: \(error.localizedDescription, privacy: .public)")
            return Snapshot(note: "无法启动 Codex 额度服务")
        }

        // Was 20 s. The measured round trip is 2.6–6.5 s, so 20 s only ever
        // applied to a *hung* app server — and it kept the panel spinning for
        // twenty seconds to report a timeout. 12 s is three times the slowest
        // healthy call seen, which still absorbs a slow network without letting
        // a stuck process hold the reading hostage.
        let seconds: TimeInterval = 12
        let deadline = Date().addingTimeInterval(seconds)
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds,
                                                       execute: timeout)

        let requests = [
            [
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "claudebar",
                        "title": "ClaudeBar",
                        "version": appVersion,
                    ],
                ],
            ] as [String: Any],
            ["method": "initialized", "params": [:]] as [String: Any],
            ["method": "account/rateLimits/read", "id": 1] as [String: Any],
        ]

        do {
            for request in requests {
                let data = try JSONSerialization.data(withJSONObject: request)
                try input.fileHandleForWriting.write(contentsOf: data)
                try input.fileHandleForWriting.write(contentsOf: Data([0x0A]))
            }
        } catch {
            finish(process, input: input, timeout: timeout)
            return Snapshot(note: "Codex 额度请求生成失败")
        }

        var pending = Data()
        var authMode: String?
        while process.isRunning {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)

            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    continue
                }

                if (json["method"] as? String) == "account/updated",
                   let params = json["params"] as? [String: Any] {
                    authMode = params["authMode"] as? String
                }

                guard number(json["id"]) == 1 else { continue }
                let snapshot = parseResponse(json, authMode: authMode)
                finish(process, input: input, timeout: timeout)
                return snapshot
            }
        }

        finish(process, input: input, timeout: timeout)
        let note = Date() >= deadline
            ? "Codex 额度查询超时"
            : "Codex 额度服务未返回数据"
        logger.error("\(note, privacy: .public)")
        return Snapshot(note: note)
    }

    private static func parseResponse(_ json: [String: Any], authMode: String?) -> Snapshot {
        if let error = json["error"] as? [String: Any] {
            let message = diagnosticText(error["message"] as? String ?? "未知错误")
            logger.error("JSON-RPC error: \(message, privacy: .public)")
            if message.localizedCaseInsensitiveContains("auth") {
                return Snapshot(note: "Codex 登录已过期，请重新登录")
            }
            return Snapshot(note: "Codex 额度查询失败：\(message)")
        }

        guard let result = json["result"] as? [String: Any] else {
            return Snapshot(note: "Codex 额度响应无效")
        }
        let rate: [String: Any]?
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = buckets["codex"] as? [String: Any] {
            rate = codex
        } else {
            rate = result["rateLimits"] as? [String: Any]
        }

        guard let rate else {
            if authMode == "apikey" {
                return Snapshot(note: "API Key 登录没有 ChatGPT 套餐额度")
            }
            if authMode == nil {
                return Snapshot(note: "未登录 ChatGPT")
            }
            return Snapshot(note: "当前账户没有 Codex 额度窗口")
        }

        let windows = [rate["primary"], rate["secondary"]]
            .compactMap { $0 as? [String: Any] }
            .compactMap(parseWindow)
        let credits = creditBalance(rate["credits"] as? [String: Any])
        return Snapshot(windows: windows,
                        note: windows.isEmpty ? "当前账户没有 Codex 额度窗口" : nil,
                        creditBalance: credits)
    }

    static func creditBalance(_ credits: [String: Any]?) -> String? {
        guard let credits else { return nil }
        if credits["unlimited"] as? Bool == true { return "不限量" }
        // An absent balance is unknown, even when hasCredits is false.
        let raw = (credits["balance"] as? String)
            ?? (credits["balance"] as? NSNumber)?.stringValue
        guard let raw, let value = Double(raw), value.isFinite, value >= 0 else { return nil }
        return value.formatted(.number.precision(.fractionLength(0...2))) + " Credits"
    }

    private static func parseWindow(_ window: [String: Any]) -> CodexQuotaWindow? {
        guard let used = number(window["usedPercent"]) else { return nil }
        let minutes = JSONCoerce.intVal(window["windowDurationMins"])
        return CodexQuotaWindow(
            label: label(forMinutes: minutes),
            usedPercent: min(100, max(0, used)),
            resetsAt: epoch(window["resetsAt"] ?? window["resets_at"]),
            durationMinutes: minutes
        )
    }

    /// Codex has returned both unix seconds and milliseconds for `resetsAt`.
    private static func epoch(_ value: Any?) -> Date? {
        let raw: Double?
        if let number = value as? NSNumber {
            raw = number.doubleValue
        } else if let string = value as? String {
            raw = Double(string)
        } else {
            raw = nil
        }
        guard let raw, raw.isFinite, raw > 0 else { return nil }
        let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    /// Keep server diagnostics useful in Console without allowing a malformed
    /// response to inject multiline/noisy UI text.
    private static func diagnosticText(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(oneLine.prefix(240))
    }

    private static func label(forMinutes minutes: Int) -> String {
        switch minutes {
        case 300: return "5 小时"
        case 10_080: return "7 天"
        case 43_200: return "30 天"
        case 0: return "额度"
        default:
            if minutes >= 1_440, minutes.isMultiple(of: 1_440) {
                return "\(minutes / 1_440) 天"
            }
            if minutes >= 60, minutes.isMultiple(of: 60) {
                return "\(minutes / 60) 小时"
            }
            return "\(minutes) 分钟"
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func codexExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // ChatGPT.app moved the bundled CLI into `codex-cli/bin` (codex
        // 0.158 reads the layout from `codex-package.json`). Older installs
        // still ship it directly under Resources, so try both.
        var candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    private static func finish(_ process: Process, input: Pipe,
                               timeout: DispatchWorkItem) {
        timeout.cancel()
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
