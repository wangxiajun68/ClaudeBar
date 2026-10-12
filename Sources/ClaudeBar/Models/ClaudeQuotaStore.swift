import Foundation
import Combine

@MainActor final class ClaudeQuotaStore: ObservableObject {
    static let shared = ClaudeQuotaStore()
    @Published private(set) var windows: [CodexQuotaWindow] = []
    @Published private(set) var note: String? = "点击查询 Claude Code 官方额度"
    @Published private(set) var loading = false
    @Published private(set) var updatedAt: Date?
    private var accountKey: String?
    private var lastAttempt: Date?
    private var retryAt: Date?

    func refresh(manual: Bool = true) async {
        guard !loading else { return }
        let now = Date()
        if let retryAt, now < retryAt { return }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < (manual ? 15 : 300) { return }
        loading = true
        lastAttempt = now
        defer { loading = false }
        let result = await ClaudeQuotaFetcher.fetch()
        guard !Task.isCancelled else { return }
        apply(result)
    }

    func apply(_ result: ClaudeQuotaFetcher.Snapshot) {
        if accountKey != result.accountKey || result.clearWindows || !result.failed {
            windows = result.windows
            updatedAt = result.windows.isEmpty ? nil : Date()
        }
        accountKey = result.accountKey
        note = result.note
        retryAt = result.retryAt
    }
}
