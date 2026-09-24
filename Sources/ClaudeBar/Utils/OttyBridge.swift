import AppKit
import Foundation

/// Drives [Otty](https://otty.sh) through its bundled `otty-cli`, which talks
/// to the running app over a local control socket — no Apple Events, so no
/// Automation prompt.
///
/// Otty's agent integration reports every Claude Code / Codex pane's
/// `agent_session_id`, so resuming a session that is already open in Otty
/// focuses that exact pane instead of starting a second copy; only when no
/// pane hosts it does a new tab run `claude --resume <id>` in the session's
/// directory. New tabs start in a login shell (PATH as in the user's
/// terminal) and fall back to that shell when the command exits.
enum OttyBridge {
    static let bundleIdentifier = "io.appmakes.otty"

    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    static var isInstalled: Bool { cliURL != nil }

    private static var cliURL: URL? {
        guard let app = appURL else { return nil }
        let cli = app.appendingPathComponent("Contents/MacOS/otty-cli")
        return FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil
    }

    private static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// Otty's `agent` label for a pane.
    enum Agent: String {
        case claude = "Claude Code"
        case codex = "Codex"
    }

    struct Pane: Decodable {
        let id: String
        let tabID: String?
        let windowID: String?
        let agent: String?
        let agentSessionID: String?
        let cwd: String?

        enum CodingKeys: String, CodingKey {
            case id, agent, cwd
            case tabID = "tab_id"
            case windowID = "window_id"
            case agentSessionID = "agent_session_id"
        }
    }

    private struct Response<Payload: Decodable>: Decodable {
        let ok: Bool
        let data: Payload?
    }

    /// Focus the pane hosting `sessionId`, or open a tab running `command`
    /// in `cwd`. `fallback` runs instead of a new tab when given — Codex
    /// uses it to prefer Codex Desktop for a session Otty is not showing.
    /// Returns immediately; the CLI round-trips happen off the main thread.
    static func resume(sessionId: String, cwd: String, command: String, title: String,
                       fallback: (@Sendable () -> Void)? = nil) {
        guard let cli = cliURL, let app = appURL else { fallback?(); return }
        let wasRunning = isRunning
        // A closed Otty cannot be showing the session.
        if !wasRunning, let fallback {
            fallback()
            return
        }
        Task.detached(priority: .userInitiated) {
            if !wasRunning {
                await launch(app)
                guard waitUntilReady(cli) else { return }
            }
            // A cold start restores the previous layout and relaunches its
            // agents; give a restored pane a moment to report its session
            // before concluding it is not open.
            let attempts = wasRunning ? 1 : 8
            var pane: Pane?
            for attempt in 0..<attempts {
                pane = panes(cli).first { $0.agentSessionID == sessionId }
                if pane != nil || attempt == attempts - 1 { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            if let pane {
                focus(pane, cli: cli)
            } else if let fallback {
                fallback()
                return
            } else {
                run(cli, ["tab", "new", "--cwd", cwd, "--title", title, "--command", command])
            }
            await activate(app)
        }
    }

    /// Focus a session known to be running inside Otty. Never opens a tab:
    /// the session exists, so the worst case is bringing Otty forward.
    ///
    /// A pane whose agent hook has not reported a session id yet is matched
    /// by agent and working directory, but only when that match is unique.
    static func reveal(sessionId: String, cwd: String, agent: Agent) {
        guard let cli = cliURL, let app = appURL else { return }
        Task.detached(priority: .userInitiated) {
            let all = panes(cli)
            let byCwd = all.filter { $0.agent == agent.rawValue && $0.cwd == cwd }
            if let pane = all.first(where: { $0.agentSessionID == sessionId })
                ?? (byCwd.count == 1 ? byCwd.first : nil) {
                focus(pane, cli: cli)
            }
            await activate(app)
        }
    }

    // MARK: - CLI

    private static func focus(_ pane: Pane, cli: URL) {
        if let window = pane.windowID { run(cli, ["window", "focus", window]) }
        if let tab = pane.tabID { run(cli, ["tab", "focus", tab]) }
        run(cli, ["pane", "focus", pane.id])
    }

    /// `pane list`, not the `panes` shorthand: the shorthand is only
    /// recognized as the first word after `--json`, so with `--timeout`
    /// ahead of it the CLI rejects it and every lookup came back empty.
    private static func panes(_ cli: URL) -> [Pane] {
        guard let data = run(cli, ["--json", "pane", "list"]),
              let response = try? JSONDecoder().decode(Response<[Pane]>.self, from: data),
              response.ok else { return [] }
        return response.data ?? []
    }

    /// The control socket appears a beat after the process does.
    private static func waitUntilReady(_ cli: URL) -> Bool {
        for _ in 0..<24 {
            if run(cli, ["--json", "pane", "list"]) != nil { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// Runs the CLI with an argv array (no shell), returning stdout on exit 0.
    @discardableResult
    private static func run(_ cli: URL, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = cli
        process.arguments = ["--timeout", "2000"] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    // MARK: - App

    @MainActor
    private static func launch(_ app: URL) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    /// LaunchServices activation works from a background (accessory) app,
    /// where `NSRunningApplication.activate()` is ignored under macOS 14's
    /// cooperative activation.
    @MainActor
    private static func activate(_ app: URL) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }
}
