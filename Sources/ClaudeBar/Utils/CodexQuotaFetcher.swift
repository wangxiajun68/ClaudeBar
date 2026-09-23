import Foundation
import os

/// One ChatGPT Codex rate-limit window returned by Codex App Server.
struct CodexQuotaWindow: Equatable, Identifiable {
    var id: String { label }
    var label: String
    var usedPercent: Double
    var resetsAt: Date?

    var usedText: String {
        let rounded = usedPercent.rounded()
        if abs(usedPercent - rounded) < 0.05 { return "\(Int(rounded))%" }
        return String(format: "%.1f%%", usedPercent)
    }

    var resetText: String {
        guard let resetsAt else { return "已用额度" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return "\(formatter.string(from: resetsAt)) 重置"
    }
}

enum CodexQuotaFetcher {
    private static let logger = Logger(subsystem: "com.claudebar.app",
                                       category: "CodexQuota")

    struct Snapshot: Equatable {
        var windows: [CodexQuotaWindow] = []
        /// Shown when there is nothing to graph.
        var note: String? = nil
    }

    static func fetch() async -> Snapshot {
        var last = Snapshot(note: "Codex 额度查询失败")
        for attempt in 1...3 {
            guard !Task.isCancelled else { return last }
            let snapshot = await Task.detached(priority: .utility) {
                fetchFromAppServer()
            }.value
            guard !Task.isCancelled else { return last }
            last = snapshot
            guard snapshot.windows.isEmpty, shouldRetry(snapshot) else {
                return snapshot
            }
            guard attempt < 3 else { break }
            logger.warning("Transient failure; retrying quota fetch (attempt \(attempt + 1, privacy: .public)/3)")
            try? await Task<Never, Never>.sleep(for: .seconds(attempt))
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

        let deadline = Date().addingTimeInterval(20)
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20,
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
        guard !windows.isEmpty else {
            return Snapshot(note: "当前账户没有 Codex 额度窗口")
        }
        return Snapshot(windows: windows)
    }

    private static func parseWindow(_ window: [String: Any]) -> CodexQuotaWindow? {
        guard let used = number(window["usedPercent"]) else { return nil }
        let minutes = JSONCoerce.intVal(window["windowDurationMins"])
        let reset = number(window["resetsAt"])
        return CodexQuotaWindow(
            label: label(forMinutes: minutes),
            usedPercent: min(100, max(0, used)),
            resetsAt: reset.map(Date.init(timeIntervalSince1970:))
        )
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
        var candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
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
