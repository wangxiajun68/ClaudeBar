import Foundation
import Darwin
import os

/// One ChatGPT Codex rate-limit window returned by Codex App Server.
struct CodexQuotaWindow: Equatable, Identifiable {
    /// Where the window sits in the account payload — `primary` / `secondary`
    /// for Codex — and the key everything that tracks a window per-window
    /// uses.
    ///
    /// The label cannot serve as that key: it is derived from
    /// `windowDurationMins`, which the API is free to omit, and a payload
    /// without it gives **both** windows the same 「额度」. Keyed by label the
    /// two impersonate each other — `QuotaResetDetector` read the secondary
    /// window's first sighting against the primary's percentage and fired a
    /// rollover alert on the spot, every later real rollover of the 5-hour
    /// window was compared against the 7-day window, and the popup's gauge row
    /// built two cells with one identity. The slot is stable across readings
    /// whatever the payload says about durations.
    var slot: String = ""
    /// Window identity: the slot when there is one, the label otherwise (a
    /// window a caller builds without a slot to give — Cursor's pools).
    var id: String { slot.isEmpty ? label : slot }
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
        /// The reading is a *failure*, not an answer — every window field is
        /// empty because the read did not happen, not because the account has
        /// no allowance.
        ///
        /// The distinction is load-bearing for the reader: `CodexProviderStore`
        /// keeps the last good windows on screen when a poll fails (an empty
        /// list would blank the allowance row and, worse, feed
        /// `QuotaResetDetector` an empty record that prunes all of its
        /// per-window state — the next success would then only seed, and a
        /// rollover that happened across the failure would never be announced).
        /// An authoritative empty answer, by contrast, must clear the row.
        var failed: Bool = false
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
    /// Only trustworthy snapshots are cached — see the store guard in
    /// `fetch()`. A failure is never served from here, so a transient blip
    /// cannot be pinned for a minute.
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
        // spinner up for ~20 s before showing the same failure.
        var last = Snapshot(note: "Codex 额度查询失败", failed: true)
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
            // The backoff is read off the failure, not fixed. A *launch* failure
            // — the app-server's `error sending request for url
            // (https://chatgpt.com/backend-api/wham/usage)` seen in the unified
            // log at 11:08:22, 11:33:33, 12:00:55 … — is the account call going
            // out through a system proxy that still points at a dead mihomo
            // port, because `VpnManager.waitUntilReady` writes the new proxy
            // 3–4 s after launch. A 600 ms retry lands *inside* that window and
            // fails again, so the launch fetch could never succeed; the reading
            // only appeared when the 900 s poll came around. A network failure
            // that is not spend/auth/timeout is almost always this, so it gets
            // the same 4 s the Cursor fetcher uses (see
            // `CursorUsageFetcher.retryDelayMilliseconds`) — long enough to clear
            // the proxy write, still short enough that a genuinely broken
            // network reports in one attempt's time plus four seconds.
            try? await Task<Never, Never>.sleep(
                for: .milliseconds(Self.launchProxyWindowMilliseconds))
        }
        return last
    }

    /// The backoff before the one retry.
    ///
    /// Sized for the failure that actually reaches here: the app-server failing
    /// to *send* (not a spend limit, not auth, not a timeout — those do not
    /// retry), which is the account call leaving through a system proxy that
    /// still points at a dead mihomo port. `VpnManager.waitUntilReady` writes
    /// the new proxy 3–4 s after launch, so the old 600 ms retry landed inside
    /// that window and failed identically; this clears it. It is the same 4 s
    /// `CursorUsageFetcher.retryDelayMilliseconds` uses, for the same reason —
    /// and it is documented in both places because neither fetcher owns the
    /// proxy write, so neither can derive it.
    static let launchProxyWindowMilliseconds = 4_000

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
        guard BuildChannel.allowsSystemIntegration else { return Snapshot(note: BuildChannel.restrictionMessage, failed: true) }
        guard let executable = CodexRuntime.executable() else {
            logger.error("Codex executable not found")
            return Snapshot(note: "未找到 Codex，请先安装或打开 Codex", failed: true)
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A write to a child that already exited raises SIGPIPE, whose default
        // disposition terminates the whole app — app-server does exit on its
        // own, and the `try` below must throw instead (same call as
        // `CodexAppServerClient`).
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        do {
            try process.run()
        } catch {
            logger.error("Failed to start app-server: \(error.localizedDescription, privacy: .public)")
            return Snapshot(note: "无法启动 Codex 额度服务", failed: true)
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
            return Snapshot(note: "Codex 额度请求生成失败", failed: true)
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
        return Snapshot(note: note, failed: true)
    }

    private static func parseResponse(_ json: [String: Any], authMode: String?) -> Snapshot {
        if let error = json["error"] as? [String: Any] {
            let message = diagnosticText(error["message"] as? String ?? "未知错误")
            logger.error("JSON-RPC error: \(message, privacy: .public)")
            if message.localizedCaseInsensitiveContains("auth") {
                return Snapshot(note: "Codex 登录已过期，请重新登录", failed: true)
            }
            return Snapshot(note: "Codex 额度查询失败：\(message)", failed: true)
        }

        guard let result = json["result"] as? [String: Any] else {
            return Snapshot(note: "Codex 额度响应无效", failed: true)
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

        let raw = [("primary", rate["primary"]), ("secondary", rate["secondary"])]
            .compactMap { slot, value in (value as? [String: Any]).map { (slot, $0) } }
        let windows = raw.compactMap { parseWindow($0.1, slot: $0.0) }
        // Windows arrived and none of them could be read: that is a malformed
        // response, not an account without an allowance, and it must not be
        // published as the latter (the reader keeps the last good reading for a
        // failure, and clears the row for an authoritative empty answer).
        if !raw.isEmpty && windows.isEmpty {
            logger.error("rateLimits carried \(raw.count) window(s), none parseable")
            return Snapshot(note: "Codex 额度响应无效", failed: true)
        }
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

    private static func parseWindow(_ window: [String: Any], slot: String) -> CodexQuotaWindow? {
        guard let used = number(window["usedPercent"]) else { return nil }
        let minutes = JSONCoerce.intVal(window["windowDurationMins"])
        return CodexQuotaWindow(
            slot: slot,
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

    private static func finish(_ process: Process, input: Pipe,
                               timeout: DispatchWorkItem) {
        timeout.cancel()
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
