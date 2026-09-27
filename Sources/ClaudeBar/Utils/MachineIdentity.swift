import Foundation
import Darwin

/// Who this Mac is: the name the user gave it, and the chip Apple ships it with.
///
/// Read once — a host name and a `machdep.cpu.brand_string` are immutable for
/// the lifetime of the process, and both are `sysctl` reads with no business
/// running inside a `body`.
///
/// The **host** name is `kern.hostname` minus its `.local` suffix
/// (`wangxiajundeMacBook-Pro-8`) — the same string `scutil --get LocalHostName`
/// prints, and the short form the 共享 pane asks the user for. It is
/// deliberately *not* `Host.current().localizedName`: that returns the
/// `ComputerName`, which is the **localized** full sentence ("王夏军的MacBook
/// Pro"). A greeting three words long that mixes the OS's own naming style into
/// this app's voice is the wrong read for a one-line card caption; the short
/// host name is also what a person answers when asked "which machine".
enum MachineIdentity {
    /// The person in `HELLO wangxiajun`.
    ///
    /// `kern.hostname` on this Mac is `wangxiajundeMacBook-Pro-8`: the name,
    /// then `de` (的), then the model. The greeting wants the name. A host
    /// that does not carry a MacBook suffix stays whole, and still falls
    /// back to "Mac" when the name cannot be read.
    static var greetingName: String {
        let host = displayName
        for marker in ["deMacBook", "s-MacBook", "-MacBook", "MacBook"] {
            guard let range = host.range(of: marker, options: .caseInsensitive) else { continue }
            let prefix = host[..<range.lowerBound]
                .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
            if prefix.count >= 2 { return String(prefix) }
        }
        return host
    }

    /// The greeting's machine. Never empty: an unresolvable host falls back to "Mac".
    static let displayName: String = {
        let raw = sysctlString("kern.hostname") ?? ""
        let short = raw.replacingOccurrences(of: ".local", with: "")
            .trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? "Mac" : short
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
