import Foundation
import AppKit
import CryptoKit

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
        guard BuildChannel.allowsSystemIntegration else { return BuildChannel.restrictionMessage }
        // Helper is setuid root (installed once) → run directly, no password.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: helperPath)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return "辅助工具不可用，请重新安装。" }
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
    /// The bytes that are *verified* are the bytes that are *promoted*, which is
    /// why this does not verify the bundle resource and then `cp` it: that
    /// leaves an unbounded window — the admin-password prompt — in which
    /// `/Applications/ClaudeBar.app`, writable by the logged-in user, can be
    /// rewritten. Without that property any user-level process could drop a
    /// payload at `Contents/Resources/claudebar-fanctl`, wait for the next (or
    /// a re-)install, and have the app copy it into `/usr/local/bin` as
    /// root:wheel mode 4755 behind the user's own one-click admin prompt.
    /// This app is the only thing that may install a root binary, so the check
    /// lives where the install happens, not at the caller.
    ///
    /// The shape both installers ship: stage a root-owned copy inside the
    /// privileged script, hash it against the digest taken here,
    /// `codesign --verify --strict -R=<this app's anchor>` **the staged copy**,
    /// and only then set the setuid bit and move it into place. Nothing a user
    /// can write is trusted at any point after the prompt; `HelperSignature`
    /// holds the signature half of that check for both files.
    static func install() {
        guard BuildChannel.allowsSystemIntegration else { return }
        guard let source = bundledHelperPath, let digest = Self.digest(of: source) else { return }
        // Courtesy pre-check so a tampered bundle gets the readable alert
        // *instead of* a password prompt. The binding checks are the ones
        // inside the script below, on the bytes that actually become root:
        // the anchor requirement, and the digest taken here from the copy
        // that just passed it.
        guard let requirement = HelperSignature.anchorRequirement(),
              HelperSignature.verify(source, against: requirement) else {
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
        // Stage in a root-owned directory, not in the user-writable tree: a
        // stage file a user could swap by rename would defeat the point.
        let staging = "/Library/PrivilegedHelperTools"
        let shell = """
        set -eu
        /bin/mkdir -p \(ShellQuote.single(staging))
        test ! -L \(ShellQuote.single(staging))
        test "$(/usr/bin/stat -f '%u' \(ShellQuote.single(staging)))" = 0
        test "$(/usr/bin/stat -f '%Lp' \(ShellQuote.single(staging)))" = 755
        stage=$(/usr/bin/mktemp \(ShellQuote.single(staging + "/.claudebar-fanctl.XXXXXX")))
        trap '/bin/rm -f "$stage"' EXIT
        /bin/cp \(ShellQuote.single(source)) "$stage"
        test "$(/usr/bin/shasum -a 256 "$stage" | /usr/bin/cut -d ' ' -f 1)" = \(ShellQuote.single(digest))
        /usr/bin/codesign --verify --strict -R=\(ShellQuote.single(requirement)) "$stage"
        /bin/mkdir -p /usr/local/bin
        /usr/sbin/chown root:wheel "$stage"
        /bin/chmod 4755 "$stage"
        /bin/mv -f "$stage" \(ShellQuote.single(helperPath))
        """
        let literal = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: "do shell script \"\(literal)\" with administrator privileges") {
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

    /// SHA-256 of the bundled helper, taken before the prompt and checked in
    /// the privileged script against the staged copy. `codesign` alone would do
    /// for a normal Mach-O; the digest is what makes the check independent of
    /// the signature's own trust evaluation, exactly as the battery installer
    /// does it.
    private static func digest(of path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The helper as shipped inside this bundle — never a path assembled from
    /// outside it.
    static var bundledHelperPath: String? {
        Bundle.main.url(forResource: "claudebar-fanctl", withExtension: nil)?.path
    }

    static func isInstalled() -> Bool {
        // Must exist AND be setuid-root; otherwise install() again.
        guard FileManager.default.isExecutableFile(atPath: helperPath),
              let attrs = try? FileManager.default.attributesOfItem(atPath: helperPath),
              let posix = attrs[.posixPermissions] as? NSNumber else { return false }
        return posix.uint16Value & 0o4000 != 0
    }
}

extension Notification.Name {
    static let fanPermissionNeeded = Notification.Name("fanPermissionNeeded")
}
