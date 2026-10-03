import Foundation

/// The signature question both privileged helpers are installed behind:
/// *whose* signature is it, not merely that one is consistent.
///
/// `codesign --verify --strict` alone is the wrong question, and was the
/// original bug's quieter half: it proves a signature is *consistent*, not
/// whose it is. An ad-hoc re-signature (`codesign --force --sign -`) of a
/// replaced helper satisfies it — measured, exit 0 — and since
/// `/Applications/ClaudeBar.app` is writable by the logged-in user, that is
/// exactly the payload this check exists to stop.
///
/// So the test is the **certificate anchor** this app itself is signed
/// under: `codesign --verify --strict -R=…` with the app's own
/// `certificate root = H"…"` clause. `Sources/build.sh` signs both helpers
/// before the bundle with the same `SIGN_IDENTITY`, so the genuine pair
/// shares an anchor, while a helper carrying any *other* signature — an
/// ad-hoc re-sign, another developer's certificate, an Apple binary —
/// fails. Measured on the dev build: the shipped helpers and the app pass,
/// an ad-hoc-re-signed copy and `/bin/ls` both exit 3.
///
/// An ad-hoc build (`CODESIGN_IDENTITY=-`, what CI and `make ci` use) has
/// no anchor to compare: its own designated requirement is a `cdhash`,
/// which changes with every rebuild and can never be pinned on a
/// separately signed helper. That case **fails closed** — there is no
/// identity to verify against, and the one other thing a check could say
/// there ("some valid signature exists") is precisely the hole this file
/// was written to close. Nothing a user runs is ad-hoc: both `make run`
/// and `make release` sign with the local identity.
///
/// One copy, because the two installers must not drift: the battery helper
/// stages a setuid-root binary and the fan helper a root-owned one, and a
/// check in only one of them is how the second one regressed.
enum HelperSignature {
    /// Is `path` signed under this running app's certificate anchor?
    static func verify(_ path: String) -> Bool {
        guard let requirement = anchorRequirement() else { return false }
        return verify(path, against: requirement)
    }

    /// The anchor clause of this app's designated requirement, or `nil` when
    /// the app is ad-hoc signed (a `cdhash` requirement, which a separately
    /// signed helper can never satisfy).
    ///
    /// Read once: this process's own signature cannot change while it runs,
    /// and the battery installer's `isInstalled()` probe would otherwise
    /// re-run `codesign` over the bundle on every authorization refresh.
    static func anchorRequirement() -> String? { anchor }

    private static let anchor: String? = readAnchorRequirement()

    private static func readAnchorRequirement() -> String? {
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
    static func verify(_ path: String, against requirement: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["--verify", "--strict", "-R=\(requirement)", path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }
}
