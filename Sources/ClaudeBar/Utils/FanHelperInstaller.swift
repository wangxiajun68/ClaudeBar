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
    ///
    /// The copy source is *validated* before it is promoted to setuid root.
    /// `/Applications/ClaudeBar.app` is writable by the logged-in user, so an
    /// unvalidated copy would let any user-level process drop a payload at
    /// `Contents/Resources/claudebar-fanctl`, wait for the next (or a
    /// re-)install, and have the app copy it into `/usr/local/bin` as
    /// root:wheel mode 4755 with the user's own one-click admin prompt. This
    /// app is the only thing that may install a root binary, so it is the only
    /// place that check belongs.
    static func install() {
        guard let source = bundledHelperPath else { return }
        guard verifySignature(of: source) else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "辅助工具签名校验失败"
                alert.informativeText = """
                内置的 claudebar-fanctl 未通过代码签名校验，已拒绝安装。
                这通常意味着应用包被改动过。请从 GitHub Releases 重新下载 ClaudeBar。
                """
                alert.alertStyle = .critical
                alert.runModal()
            }
            return
        }
        let script = """
        do shell script "mkdir -p /usr/local/bin && cp \(shellEscape(source)) \(shellEscape(helperPath)) && chown root:wheel \(shellEscape(helperPath)) && chmod 4755 \(shellEscape(helperPath))" with administrator privileges
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

    /// The helper as shipped inside this bundle — never a path assembled from
    /// outside it.
    static var bundledHelperPath: String? {
        Bundle.main.url(forResource: "claudebar-fanctl", withExtension: nil)?.path
    }

    /// `codesign --verify --strict` against the copy we are about to install
    /// as root. Any failure (unsigned, ad-hoc mismatch, tampered) refuses the
    /// install; `install()` is a deliberate user action, so failing closed and
    /// explaining is better than promoting an unknown binary.
    private static func verifySignature(of path: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["--verify", "--strict", path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
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
