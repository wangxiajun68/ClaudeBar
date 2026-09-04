import Foundation
import AppKit

extension Process {
    /// Convenience runner: launches and waits for stdout/stderr to drain.
    static func run(_ path: String, args: [String]) throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        return proc
    }
}

/// Privileged fan helper for ClaudeBar.
///
/// Install (once, one admin-password prompt): copies the bundled `claudebar-fanctl`
/// to /usr/local/bin and marks it **setuid root** (4755). After that every fan
/// write runs as root with NO password prompts.
enum FanHelperInstaller {
    static let helperPath = "/usr/local/bin/claudebar-fanctl"

    /// Runs a fan write through the privileged helper. Returns nil on success.
    static func setFanSpeed(fanID: Int, rpm: Int) -> String? {
        runPrivileged(args: ["set", "\(fanID)", "\(rpm)"])
    }

    static func setAutomatic(fanID: Int) -> String? {
        runPrivileged(args: ["auto", "\(fanID)"])
    }

    static func resetAll() -> String? {
        runPrivileged(args: ["autoall"])
    }

    private static func runPrivileged(args: [String]) -> String? {
        // Helper is setuid root (installed once) → run directly, no password.
        guard let proc = try? Process.run(helperPath, args: args) else {
            return "辅助工具不可用，请重新安装。"
        }
        // 10s timeout so UI never hangs on a stuck helper.
        let deadline = Date().addingTimeInterval(10)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning { proc.terminate(); return "辅助工具响应超时。" }
        return proc.terminationStatus == 0 ? nil : "风扇调整失败（退出码 \(proc.terminationStatus)）"
    }

    /// Installs the helper binary once (asks for admin password). Idempotent.
    /// Copies to /usr/local/bin and sets setuid root so future calls need no password.
    static func install() {
        let script = """
        do shell script "mkdir -p /usr/local/bin && cp /Applications/ClaudeBar.app/Contents/Resources/claudebar-fanctl \(helperPath) && chown root:wheel \(helperPath) && chmod 4755 \(helperPath)" with administrator privileges
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            _ = appleScript.executeAndReturnError(&error)
        }
        if let err = error {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "辅助工具安装失败"
                alert.informativeText = (err[NSAppleScript.errorMessage] as? String) ?? "未知错误"
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    static func isInstalled() -> Bool {
        // Must exist AND be setuid-root; otherwise install() again.
        guard FileManager.default.isExecutableFile(atPath: helperPath),
              let attrs = try? FileManager.default.attributesOfItem(atPath: helperPath),
              let posix = attrs[.posixPermissions] as? NSNumber else { return false }
        return posix.uint16Value & 0o4000 != 0
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension Notification.Name {
    static let fanPermissionNeeded = Notification.Name("fanPermissionNeeded")
}
