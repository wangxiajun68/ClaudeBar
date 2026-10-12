import Foundation
import Security
import LocalAuthentication
import CoreFoundation
import CryptoKit

/// Read-only Claude account usage. Never refreshes or writes client credentials.
enum ClaudeQuotaFetcher {
    struct Snapshot {
        var windows: [CodexQuotaWindow] = []
        var note: String? = nil
        var failed = false
        var clearWindows = false
        var accountKey: String? = nil
        var retryAt: Date? = nil
    }

    struct Credential {
        let token: String
        let expiresAt: Date?
    }

    static func credential(from data: Data) -> Credential? {
        guard data.count <= 1_048_576,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let expiry = (oauth["expiresAt"] as? NSNumber).flatMap { value -> Date? in
            guard CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return Date(timeIntervalSince1970: value.doubleValue / 1000)
        }
        return Credential(token: token, expiresAt: expiry)
    }

    private static func readCredential() -> Credential? {
        guard BuildChannel.allowsSystemIntegration else { return nil }
        // Refuse any Keychain authentication UI, including in release builds.
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let found = credential(from: data) { return found }
        let file = FilePaths.claudeDir.appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return credential(from: data)
    }

    static func parse(_ data: Data) -> Snapshot {
        guard data.count <= 1_048_576,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["error"] == nil else { return Snapshot(note: "额度响应无法读取", failed: true) }
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var windows: [CodexQuotaWindow] = []
        for (slot, label, duration) in [("five_hour", "5 小时", 300), ("seven_day", "7 天", 10_080),
                                        ("seven_day_sonnet", "Sonnet · 7 天", 10_080), ("seven_day_opus", "Opus · 7 天", 10_080)] {
            guard let value = json[slot] as? [String: Any],
                  let percent = value["utilization"] as? NSNumber,
                  CFGetTypeID(percent) != CFBooleanGetTypeID(),
                  percent.doubleValue.isFinite, percent.doubleValue >= 0 else { continue }
            let reset = (value["resets_at"] as? String).flatMap { fractional.date(from: $0) ?? iso.date(from: $0) }
            windows.append(.init(slot: slot, label: label, usedPercent: min(100, percent.doubleValue),
                                 resetsAt: reset, durationMinutes: duration))
        }
        return Snapshot(windows: windows, note: windows.isEmpty ? "账号未返回额度窗口" : nil)
    }

    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }()

    static func fetch(using session: URLSession = transport) async -> Snapshot {
        guard BuildChannel.allowsSystemIntegration else {
            return Snapshot(note: "开发版不读取 Claude 登录凭据或查询真实额度", clearWindows: true)
        }
        let login = await Task.detached(priority: .utility) { readCredential() }.value
        guard !Task.isCancelled else { return Snapshot(note: "查询已取消", failed: true) }
        guard let login else {
            return Snapshot(note: "未读取到 Claude 登录；请先在 Claude Code 登录官方账号后查询", clearWindows: true)
        }
        let key = SHA256.hash(data: Data(login.token.utf8)).map { String(format: "%02x", $0) }.joined()
        if let expiry = login.expiresAt, expiry <= Date() {
            return Snapshot(note: "Claude 登录已过期，请在 Claude Code 重新登录", clearWindows: true, accountKey: key)
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(login.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return Snapshot(note: "额度查询未收到有效响应", failed: true, accountKey: key) }
            var result: Snapshot
            switch http.statusCode {
            case 200: result = parse(data)
            case 401: result = Snapshot(note: "Claude 登录已失效，请重新登录", clearWindows: true)
            case 403: result = Snapshot(note: "此账号暂不可查询官方额度", clearWindows: true)
            case 429:
                let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 300
                result = Snapshot(note: "额度查询频率受限，请稍后重试", failed: true,
                                  retryAt: Date().addingTimeInterval(wait.isFinite ? max(60, min(3600, wait)) : 300))
            default: result = Snapshot(note: "额度服务暂不可用（HTTP \(http.statusCode)）", failed: true)
            }
            result.accountKey = key
            return result
        } catch {
            return Snapshot(note: Task.isCancelled ? "查询已取消" : "额度查询失败，请稍后重试", failed: true, accountKey: key)
        }
    }
}
