import AppKit
import Foundation

/// Where a session is resumed (设置 → 继续会话).
enum ResumeTerminal: String, CaseIterable, Identifiable {
    case automatic, otty, warp, terminal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "自动"
        case .otty: return "Otty"
        case .warp: return "Warp"
        case .terminal: return "终端"
        }
    }

    var isInstalled: Bool {
        switch self {
        case .automatic, .terminal: return true
        case .otty: return OttyBridge.isInstalled
        case .warp: return FileManager.default.fileExists(atPath: "/Applications/Warp.app")
        }
    }

    /// The concrete app a choice lands on: 自动 prefers Otty, then Warp, then
    /// Terminal; an uninstalled choice degrades the same way.
    var resolved: ResumeTerminal {
        if self != .automatic, isInstalled { return self }
        if ResumeTerminal.otty.isInstalled { return .otty }
        if ResumeTerminal.warp.isInstalled { return .warp }
        return .terminal
    }

    /// Only the AppleScript-driven terminals need 自动化.
    var needsAutomation: Bool { self == .warp || self == .terminal }
}

/// Launching external terminal / editor actions shared by the menu-bar popup,
/// the main-window Sessions page and the notch island, so they cannot drift
/// apart.
///
/// - **Otty** (`OttyBridge`): focuses the pane already running the session,
///   else opens a tab with the resume command. Socket IPC, no permission.
/// - **Warp**: opens a window at the cwd via LaunchServices, then types the
///   command via `osascript` (Warp has no `do script` / run-command link).
/// - **Terminal**: native `do script`.
///
/// Warp and Terminal send Apple Events, so they only run the command when
/// 设置 → 权限与隐私 → 在终端继续会话 is on; otherwise the terminal opens at
/// the cwd and the command is left on the clipboard.
enum TerminalLauncher {
    /// Continue a Claude Code session. While its process (`pid`) is alive the
    /// window / tab hosting it is brought forward (`SessionHost`); a second
    /// `claude --resume` on a live session would fork it. Only an ended
    /// session is resumed with `claude --resume <sessionId>`.
    @MainActor
    static func resumeClaudeSession(cwd: String, sessionId: String, pid: Int? = nil) {
        guard !cwd.isEmpty, isSafePath(cwd), isSafeSessionId(sessionId) else { return }
        if let pid, SessionHost.reveal(pid: pid, sessionId: sessionId, cwd: cwd, agent: .claude) { return }
        launch(command: "claude --resume \(sessionId)", cwd: cwd, sessionId: sessionId)
    }

    /// Continue a Codex session. A `codex` CLI process holding it (`pid`) is
    /// revealed in its terminal; a thread loaded in Codex Desktop opens there.
    /// Otherwise an Otty pane already showing it wins, then Codex Desktop
    /// (`codex://threads/<id>`) when installed, then `codex resume <id>` in
    /// the chosen terminal.
    @MainActor
    static func resumeCodexSession(cwd: String, sessionId: String, pid: Int? = nil, inDesktop: Bool = false) {
        guard isSafeSessionId(sessionId) else { return }
        if let pid, !inDesktop, SessionHost.reveal(pid: pid, sessionId: sessionId, cwd: cwd, agent: .codex) { return }
        let desktopURL = URL(string: "codex://threads/\(sessionId)")
            .flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil ? $0 : nil }
        let command = "codex resume \(sessionId)"
        let usable = !cwd.isEmpty && isSafePath(cwd)
        if inDesktop, let desktopURL {
            NSWorkspace.shared.open(desktopURL)
            return
        }

        if OttyBridge.isInstalled, desktopURL != nil || AppPreferences.shared.resumeTerminal.resolved == .otty {
            let fallback: (@Sendable () -> Void)? = desktopURL.map { url in
                { @Sendable in DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
            }
            OttyBridge.resume(sessionId: sessionId, cwd: usable ? cwd : NSHomeDirectory(), command: command,
                              title: title(for: cwd), fallback: fallback)
            return
        }
        if let desktopURL {
            NSWorkspace.shared.open(desktopURL)
            return
        }
        guard usable else { return }
        launch(command: command, cwd: cwd, sessionId: sessionId)
    }

    /// Open a workspace folder in Cursor.app. No-op if Cursor isn't installed
    /// or the folder doesn't exist.
    static func openInCursor(cwd: String) {
        guard !cwd.isEmpty, isSafePath(cwd),
              FileManager.default.fileExists(atPath: cwd) else { return }
        let cursorURL = URL(fileURLWithPath: "/Applications/Cursor.app")
        guard FileManager.default.fileExists(atPath: cursorURL.path) else { return }
        let folderURL = URL(fileURLWithPath: cwd)
        NSWorkspace.shared.open([folderURL], withApplicationAt: cursorURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Routing

    private static func launch(command: String, cwd: String, sessionId: String) {
        switch AppPreferences.shared.resumeTerminal.resolved {
        case .otty, .automatic:
            OttyBridge.resume(sessionId: sessionId, cwd: cwd, command: command, title: title(for: cwd))
        case .warp:
            runScripted(shellCmd: shellCommand(command, in: cwd), cwd: cwd, app: .warp)
        case .terminal:
            runScripted(shellCmd: shellCommand(command, in: cwd), cwd: cwd, app: .terminal)
        }
    }

    /// `cd "<cwd>" && <command>`, quoted for the AppleScript string it is
    /// embedded in (AppleScript and the shell each consume one backslash layer).
    private static func shellCommand(_ command: String, in cwd: String) -> String {
        let safeCwd = cwd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "cd \"\(safeCwd)\" && \(command)"
    }

    private static func title(for cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "ClaudeBar" : name
    }

    /// With 自动化 on, type/run the command through AppleScript. Without it,
    /// send no Apple Events at all: open the terminal at `cwd` through
    /// LaunchServices and leave the command on the clipboard to paste.
    private static func runScripted(shellCmd: String, cwd: String, app: ResumeTerminal) {
        guard PermissionGate.allows(.automation) else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(shellCmd, forType: .string)
            let appURL = app == .warp
                ? URL(fileURLWithPath: "/Applications/Warp.app")
                : URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration())
            return
        }
        if app == .warp {
            openInWarp(shellCmd: shellCmd, cwd: cwd)
        } else {
            runInAppleTerminal(shellCmd: shellCmd)
        }
    }

    // MARK: - Warp

    /// Open a window at the cwd via LaunchServices (reliable + permission-free),
    /// then type+submit the command via osascript off the main thread.
    private static func openInWarp(shellCmd: String, cwd: String) {
        NSWorkspace.shared.open([URL(fileURLWithPath: cwd)],
                                withApplicationAt: URL(fileURLWithPath: "/Applications/Warp.app"),
                                configuration: NSWorkspace.OpenConfiguration())
        let appleStr = shellCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Warp" to activate
        delay 0.35
        tell application "System Events"
            keystroke "\(appleStr)"
            delay 0.08
            key code 36
        end tell
        """
        runAppleScript(script)
    }

    // MARK: - Terminal

    /// Terminal: native `do script` runs the command in a new window.
    private static func runInAppleTerminal(shellCmd: String) {
        let appleStr = shellCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(appleStr)\""
        runAppleScript(script)
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    // MARK: - Validation

    /// Reject paths that could break AppleScript string literals or inject shell syntax.
    private static func isSafePath(_ path: String) -> Bool {
        !path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// Session ids are UUID-like; anything else could break out of the
    /// command it is interpolated into.
    private static func isSafeSessionId(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Run an AppleScript string via `/usr/bin/osascript` (args array — no
    /// shell interpolation), off the main thread; best-effort.
    private static func runAppleScript(_ source: String) {
        Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", source]
            _ = try? proc.run()
        }
    }
}
