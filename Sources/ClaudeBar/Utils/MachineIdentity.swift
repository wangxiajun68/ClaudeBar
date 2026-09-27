import Foundation
import Darwin
import SystemConfiguration

/// Who this Mac is: the name the user gave it, and the chip Apple ships it with.
///
/// Read once — a machine name and a `machdep.cpu.brand_string` are immutable for
/// the lifetime of the process, and both are `sysctl` / `SCDynamicStore` reads
/// with no business running inside a `body`.
///
/// **The name is the `ComputerName`, not the host name.** This used to read
/// `kern.hostname` and strip a `MacBook` suffix off it, which produced
/// `wangxiajun` from `wangxiajundeMacBook-Pro-8`. That was wrong twice over:
///
/// 1. `kern.hostname` is the *network* host name, and anything on the LAN can
///    rewrite it — a router that hands out a lease by address sets it to the
///    address, and the card then greeted the user as `192.168.10.102`. The name
///    the user chose in System Settings → 共享 is not that string and is not
///    reachable through it.
/// 2. The greeting is a *sentence* ("Hello …"), and what a person calls their
///    own machine is what they typed there — `王夏军的MacBook Pro` — not a
///    transliterated login name this app reconstructed by cutting a suffix off
///    an OS-generated string.
///
/// `SCDynamicStoreCopyComputerName` is the API behind `scutil --get
/// ComputerName`, so the card and the system print the same name.
enum MachineIdentity {
    /// The **person**, for `HELLO 王夏军`.
    ///
    /// The machine name is `王夏军的MacBook Pro`, and the greeting wants the
    /// name out of it: everything from the possessive「的」onward is the machine,
    /// not the person. So the rule is — take what precedes the first
    /// possessive marker, and keep the whole string when there is none.
    ///
    /// It reads as a small thing and it is the difference between a card that
    /// says hello to *you* and one that says hello to your laptop. A person does
    /// not call themselves "王大锤的MacBook Pro".
    ///
    /// The markers, in the order they are tried:
    ///
    /// - **`的`** — the CJK possessive. `王夏军的MacBook Pro` → `王夏军`.
    /// - **`'s` / `’s`** — the Latin one, for a machine named `Sam's MacBook`.
    /// - **a `MacBook` / `iMac` / `Mac mini` … marker with no possessive** — a
    ///   name that concatenated them directly, which is what a login name plus a
    ///   model looks like (`wangxiajundeMacBook-Pro-8`, the shape this app used
    ///   to parse). The `de` there *is* the pinyin 的, which is why the `de`
    ///   form is tried before the bare model.
    ///
    /// A prefix shorter than two characters is not a name — it is a stray marker
    /// (`的MacBook Pro`) — so the whole string is kept instead.
    static var greetingName: String { person(in: displayName) }

    /// The rule itself, split out so it can be driven over a table of machine
    /// names rather than only over this Mac's own — see
    /// `Tests/greeting-name-regressions.py`, which fails on a shape this rule
    /// gets wrong.
    static func person(in raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2 else { return name }
        // Two families, and they are tried in this order because the answer
        // differs: a **possessive** (`的`, `'s`) is punctuation the user typed,
        // so everything before it is the name verbatim; a **model marker** with
        // no possessive is a host name, whose joining characters (`de`, `s`) are
        // part of the OS's string and not part of the name.
        let possessive = ["的", "'s", "\u{2019}s"]
        let hostMarkers = ["deMacBook", "sMacBook", "MacBook", "iMac", "Macmini"]

        for marker in possessive + hostMarkers {
            guard let range = name.range(of: marker, options: .caseInsensitive) else { continue }
            var prefix = String(name[..<range.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: "-_ ’'"))
            // Only a host-name marker leaves a joining character behind:
            // `wangxiajuns-MacBook-Pro` keeps the `s` that joined it. A
            // possessive never does, which is what keeps `Chris’s iMac` → `Chris`.
            if hostMarkers.contains(where: { $0.caseInsensitiveCompare(marker) == .orderedSame }) {
                prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "s"))
            }
            if prefix.count >= 2 { return prefix }
        }
        return name
    }

    /// This Mac's `ComputerName` — what the user typed in System Settings →
    /// 共享, and what `scutil --get ComputerName` prints (`王夏军的MacBook Pro`).
    /// The greeting takes the person out of it; see `greetingName`.
    ///
    /// Returns `Mac` when the name cannot be read. It deliberately does **not**
    /// fall back to `kern.hostname`: that name is rewritten by whatever is on the
    /// network, so on a router that names clients by address the fallback would
    /// greet the user with `192.168.10.102` — the exact failure this replaced.
    /// A generic greeting is a smaller wrong than a numeric one.
    static let displayName: String = {
        let store = SCDynamicStoreCreate(nil, "ClaudeBar.identity" as CFString, nil, nil)
        let raw = store.flatMap { SCDynamicStoreCopyComputerName($0, nil) } as String? ?? ""
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Mac" : name
    }()

    /// The chip — `Apple M3 Pro`. After this app's own display rule: the same
    /// string `HardwareIdentity.name` already shows in the 硬件 popover.
    static let chip: String = sysctlString("machdep.cpu.brand_string") ?? ""

    /// `hw.model` (`Mac15,7`). Only ever seen in a tooltip.
    static let model: String = sysctlString("hw.model") ?? ""

    /// macOS product name + version, e.g. `macOS 26.0`.
    static let system: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
    }()

    /// The one-line "which machine" tooltip: chip, model, system.
    static var summary: String {
        var parts = [String]()
        if !chip.isEmpty { parts.append(chip) }
        if !model.isEmpty { parts.append(model) }
        parts.append(system)
        return parts.joined(separator: " · ")
    }

    /// `sysctlbyname` returning a C string. (`HardwareSensors` reads numbers
    /// through the same call; this is the string form these three identities
    /// need.)
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
