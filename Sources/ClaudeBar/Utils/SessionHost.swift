import AppKit
import Darwin

/// Finds the app a running agent process lives in and brings that session's
/// own window / tab forward — so 继续会话 on a live session jumps to it
/// instead of starting a second copy with `--resume`.
///
/// The host is found by walking the process's parents to the first regular
/// (Dock) app: Otty, Terminal, iTerm2, Cursor / VS Code's integrated
/// terminal, Warp, Ghostty… Helper processes (`Cursor Helper (Plugin)`) are
/// not regular apps, so the walk continues past them to the app itself.
enum SessionHost {
    struct Host {
        let app: NSRunningApplication
        /// The session's controlling terminal, e.g. `/dev/ttys003`.
        let tty: String?
    }

    private static let terminalBundle = "com.apple.Terminal"
    private static let itermBundle = "com.googlecode.iterm2"
    /// Editors that focus the window already showing a folder when asked to
    /// open it again.
    private static let folderFocusingEditors: Set<String> = [
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.exafunction.windsurf",
    ]

    static func host(of pid: pid_t) -> Host? {
        guard pid > 1, let own = bsdInfo(pid) else { return nil }
        let tty = ttyPath(own.e_tdev)
        var current = pid
        for _ in 0..<24 {
            guard let info = bsdInfo(current) else { return nil }
            let parent = pid_t(info.pbi_ppid)
            guard parent > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent),
               app.activationPolicy == .regular, app.bundleURL != nil {
                return Host(app: app, tty: tty)
            }
            current = parent
        }
        return nil
    }

    /// Bring the live session in `pid` forward. Returns false when no GUI host
    /// was found (a detached tmux server, an SSH session…), leaving the caller
    /// to fall back to resuming.
    @MainActor
    @discardableResult
    static func reveal(pid: Int, sessionId: String, cwd: String, agent: OttyBridge.Agent) -> Bool {
        guard let host = host(of: pid_t(pid)), let bundleURL = host.app.bundleURL else { return false }
        switch host.app.bundleIdentifier {
        case OttyBridge.bundleIdentifier?:
            OttyBridge.reveal(sessionId: sessionId, cwd: cwd, agent: agent)
        case terminalBundle? where host.tty != nil && PermissionGate.allows(.automation):
            runAppleScript(terminalScript(tty: host.tty!))
        case itermBundle? where host.tty != nil && PermissionGate.allows(.automation):
            runAppleScript(itermScript(tty: host.tty!))
        case let bundle? where folderFocusingEditors.contains(bundle) && !cwd.isEmpty:
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: bundleURL,
                                    configuration: configuration)
        default:
            activate(bundleURL)
        }
        return true
    }

    /// LaunchServices activation works from an accessory app, where
    /// `NSRunningApplication.activate()` is ignored under cooperative activation.
    @MainActor
    static func activate(_ bundleURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
    }

    // MARK: - Process info

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// `/dev/ttysNNN` for a controlling-terminal device, validated so it can
    /// be embedded in a script literal.
    private static func ttyPath(_ device: UInt32) -> String? {
        let dev = dev_t(bitPattern: device)
        guard dev != -1, dev != 0, let name = devname(dev, S_IFCHR) else { return nil }
        let tty = String(cString: name)
        guard tty.hasPrefix("tty"), tty.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return "/dev/" + tty
    }

    // MARK: - Terminal / iTerm2

    private static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
            activate
        end tell
        """
    }

    private static func itermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            tell t to select
                            tell s to select
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end repeat
            activate
        end tell
        """
    }

    private static func runAppleScript(_ source: String) {
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            _ = try? process.run()
        }
    }
}
