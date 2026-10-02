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
    /// The shape is the one `BatteryHelperInstaller` already ships: stage a
    /// root-owned copy inside the privileged script, hash it against the
    /// digest taken here, `codesign --verify --strict` **the staged copy**, and
    /// only then set the setuid bit and move it into place. Nothing a user can
    /// write is trusted at any point after the prompt.
    static func install() {
        guard BuildChannel.allowsSystemIntegration else { return }
        guard let source = bundledHelperPath, let digest = Self.digest(of: source) else { return }
        // Courtesy pre-check so a tampered bundle gets the readable alert
        // *instead of* a password prompt. The binding check is the one inside
        // the script below, on the bytes that actually become root.
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
        // Stage in a root-owned directory, not in the user-writable tree: a
        // stage file a user could swap by rename would defeat the point.
        let staging = "/Library/PrivilegedHelperTools"
        let shell = """
        set -eu
        /bin/mkdir -p \(quote(staging))
        test ! -L \(quote(staging))
        test "$(/usr/bin/stat -f '%u' \(quote(staging)))" = 0
        test "$(/usr/bin/stat -f '%Lp' \(quote(staging)))" = 755
        stage=$(/usr/bin/mktemp \(quote(staging + "/.claudebar-fanctl.XXXXXX")))
        trap '/bin/rm -f "$stage"' EXIT
        /bin/cp \(quote(source)) "$stage"
        test "$(/usr/bin/shasum -a 256 "$stage" | /usr/bin/cut -d ' ' -f 1)" = \(quote(digest))
        /usr/bin/codesign --verify --strict "$stage"
        /bin/mkdir -p /usr/local/bin
        /usr/sbin/chown root:wheel "$stage"
        /bin/chmod 4755 "$stage"
        /bin/mv -f "$stage" \(quote(helperPath))
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

    /// Is the copy we are about to promote signed by the **same certificate as
    /// this running app**?
    ///
    /// `codesign --verify --strict` alone is the wrong question, and was the
    /// original bug's quieter half: it proves a signature is *consistent*, not
    /// whose it is. An ad-hoc re-signature (`codesign --force --sign -`) of a
    /// replaced helper satisfies it — measured, exit 0 — and since
    /// `/Applications/ClaudeBar.app` is writable by the logged-in user, that is
    /// exactly the payload this check exists to stop.
    ///
    /// So the test is the **certificate anchor** this app itself is signed
    /// under: `codesign --verify --strict -R=...` with the app's own
    /// `certificate root = H"…"` clause. `Sources/build.sh` signs the helper
    /// before the bundle with the same `SIGN_IDENTITY`, so the genuine pair
    /// shares an anchor, while a helper carrying any *other* signature — an
    /// ad-hoc re-sign, another developer's certificate, an Apple binary —
    /// fails. Measured on the dev build: the shipped helper and the app pass,
    /// an ad-hoc-re-signed copy and `/bin/ls` both exit 3.
    ///
    /// An ad-hoc build (`CODESIGN_IDENTITY=-`, what CI and `make ci` use) has
    /// no anchor to compare: its own designated requirement is a `cdhash`,
    /// which changes with every rebuild and can never be pinned on a
    /// separately signed helper. That case **fails closed** — there is no
    /// identity to verify against, and the one other thing a check could say
    /// there ("some valid signature exists") is precisely the hole this
    /// function was rewritten to close. Nothing a user runs is ad-hoc: both
    /// `make run` and `make release` sign with the local identity.
    private static func verifySignature(of path: String) -> Bool {
        guard let requirement = anchorRequirement() else { return false }
        return verify(path, against: requirement)
    }

    /// The anchor clause of this app's designated requirement, or `nil` when
    /// the app is ad-hoc signed (a `cdhash` requirement, which a separately
    /// signed helper can never satisfy).
    private static func anchorRequirement() -> String? {
        guard let requirement = designatedRequirement() else { return nil }
        // The clause is a hash literal: `certificate root = H"<hex>"`. Take it
        // whole, quotes included, so it can be handed straight to `-R=`.
        let prefix = #"certificate root = H""#
        guard let clause = requirement.range(of: prefix) else { return nil }
        let tail = requirement[clause.lowerBound...]
        guard let close = tail.dropFirst(prefix.count).firstIndex(of: "\"") else { return nil }
        return String(tail[...close])
    }

    /// This app's own designated requirement, as `codesign -d -r-` prints it
    /// (stdout, no leading label).
    private static func designatedRequirement() -> String? {
        let proc = Process(), output = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["-d", "-r-", Bundle.main.bundleURL.path]
        proc.standardOutput = output
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("designated =>") {
                return String(trimmed.dropFirst("designated =>".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// `-R=<requirement>` in one argument: `codesign` only accepts the
    /// requirement joined that way, and splitting it into `-R` plus a spaced
    /// argument makes it treat the requirement as a path.
    private static func verify(_ path: String, against requirement: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["--verify", "--strict", "-R=\(requirement)", path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
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

    /// Single-quoted for the shell, then embedded in an AppleScript string
    /// literal — the paths are quoted here, the whole script is escaped where
    /// it is interpolated.
    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension Notification.Name {
    static let fanPermissionNeeded = Notification.Name("fanPermissionNeeded")
}
