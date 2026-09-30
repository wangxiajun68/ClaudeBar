import Foundation
import Combine

struct ConnectivityOutcome: Equatable {
    enum State: Equatable {
        case idle, running, passed, failed
    }

    var state: State = .idle
    var detail: String = ""
    var latencyMS: Int? = nil

    static let idle = ConnectivityOutcome()
}

/// Owns in-flight connectivity tests and their last results. Shared by the
/// Settings page, provider tiles, and the editor so a test started in one
/// surface is visible in the others.
@MainActor
final class ConnectivityTestCenter: ObservableObject {
    static let shared = ConnectivityTestCenter()

    static let proxyKey = "proxy"

    @Published private(set) var outcomes: [String: ConnectivityOutcome] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]

    func outcome(_ key: String) -> ConnectivityOutcome {
        outcomes[key] ?? .idle
    }
    func testProxy(port: Int, running: Bool) {
        run(Self.proxyKey) {
            if !running {
                return ConnectivityOutcome(
                    state: .failed,
                    detail: "本地代理未运行。请启用本地代理，或在供应商上开启流量记录。")
            }
            let hit = await ConnectivityProbe.proxy(port: port)
            return ConnectivityOutcome(
                state: hit.ok ? .passed : .failed,
                detail: hit.message,
                latencyMS: hit.ok ? hit.latencyMS : nil)
        }
    }
    private func run(_ key: String, work: @escaping () async -> ConnectivityOutcome) {
        tasks[key]?.cancel()
        outcomes[key] = ConnectivityOutcome(state: .running, detail: "检测中…")
        tasks[key] = Task { [weak self] in
            let result = await work()
            guard !Task.isCancelled else { return }
            self?.outcomes[key] = result
            self?.tasks[key] = nil
        }
    }
}
