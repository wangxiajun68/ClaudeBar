import AppKit
import Foundation

/// Launching external terminal / editor actions shared by the menu-bar popup
/// and the main-window Sessions page. Both surfaces let the user double-click
/// a Claude Code session to resume it in a terminal, or double-click a Cursor
/// session to open its workspace — the wiring lives here so the two views don't
/// drift apart (they previously carried two divergent copies of the same logic).
///
/// Warp is preferred when installed: it opens a new window at the cwd via
/// LaunchServices (no Apple Events permission needed), then types + submits
/// the `claude --resume <id>` command via `osascript` (Warp exposes no
/// AppleScript `do script` and no `warp://` run-command deep link, so keystroke
/// injection is the reliable path). Terminal's native `do script` is the
/// fallback. The osascript runs off the main thread so the tap returns
/// instantly — `activate` + `delay` + `keystroke` would otherwise block.
/// Requires Automation permission for Warp (or Terminal) on first use.
enum TerminalLauncher {
    /// Resume a Claude Code session: open a terminal in `cwd` and run
    /// `claude --resume <sessionId>` to restore that exact conversation.
    ///
    /// The command is embedded in AppleScript double-quoted string literals,
    /// so both `\` and `"` must be escaped (AppleScript and the shell both
    /// consume the backslash layer, giving the shell a correctly quoted cd).
    /// `sessionId` is a UUID from the session file, but it is validated to a
    /// safe charset anyway so a tampered file cannot inject shell syntax.
    static func resumeClaudeSession(cwd: String, sessionId: String) {
        guard !cwd.isEmpty else { return }
        // Reject a sessionId that could break out of the shell quoting; real
        // session ids are plain UUID hex+dashes.
        guard !sessionId.contains(where: { "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-".contains($0) == false }) else { return }
        let safeCwd = cwd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let shellCmd = "cd \"\(safeCwd)\" && claude --resume \(sessionId)"

        if FileManager.default.fileExists(atPath: "/Applications/Warp.app") {
            openInWarp(shellCmd: shellCmd, cwd: cwd)
        } else {
            runInAppleTerminal(shellCmd: shellCmd)
        }
    }

    /// Open a workspace folder in Cursor.app. No-op if Cursor isn't installed
    /// or the folder doesn't exist.
    static func openInCursor(cwd: String) {
        guard !cwd.isEmpty,
              FileManager.default.fileExists(atPath: cwd) else { return }
        let cursorURL = URL(fileURLWithPath: "/Applications/Cursor.app")
        guard FileManager.default.fileExists(atPath: cursorURL.path) else { return }
        let folderURL = URL(fileURLWithPath: cwd)
        NSWorkspace.shared.open([folderURL], withApplicationAt: cursorURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Warp

    /// Warp path: open a window at the cwd via LaunchServices (reliable +
    /// permission-free), then type+submit the command via osascript off the
    /// main thread so the tap handler is instant.
    private static func openInWarp(shellCmd: String, cwd: String) {
        NSWorkspace.shared.open([URL(fileURLWithPath: cwd)],
                                withApplicationAt: URL(fileURLWithPath: "/Applications/Warp.app"),
                                configuration: NSWorkspace.OpenConfiguration())
        // Escape the command for an AppleScript double-quoted string.
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

    /// Terminal fallback: native `do script` runs the command in a new window.
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

    // MARK: - osascript runner

    /// Run an AppleScript string via `/usr/bin/osascript` (args array — no
    /// shell interpolation, so the source cannot inject extra arguments).
    /// `run()` is synchronous, so this runs off the main thread to keep the
    /// UI responsive; the result is intentionally discarded (best-effort UX
    /// action — a failure leaves the terminal simply unopened).
    private static func runAppleScript(_ source: String) {
        Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.launchPath = "/usr/bin/osascript"
            proc.arguments = ["-e", source]
            _ = try? proc.run()
        }
    }
}
