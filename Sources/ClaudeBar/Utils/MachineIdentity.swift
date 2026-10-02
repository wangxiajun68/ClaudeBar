import Foundation
import Darwin
import SystemConfiguration

/// Who this Mac is: the name the user gave it, read once.
///
/// A machine name is immutable for the lifetime of the process, and
/// `SCDynamicStore` is a read with no business running inside a `body`.
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
    /// The **person**, for the greeting's colophon — `Xiajun Wang`.
    ///
    /// The machine name is `王夏军的MacBook Pro`, and the greeting wants the
    /// name out of it: everything from the possessive「的」onward is the machine,
    /// not the person. So the person is taken in two steps —
    ///
    /// 1. **The raw name** (`person(in:)`): everything before the first
    ///    possessive marker, or the whole string when there is none.
    /// 2. **The name it is drawn as** (`displayName(for:)`): a CJK name is
    ///    written in pinyin, given name first — `王夏军` → `Xiajun Wang`. A name
    ///    already in Latin script is left alone (`Sam` stays `Sam`).
    ///
    /// It reads as two small things and they are the difference between a card
    /// that says hello to *you* and one that says hello to your laptop. A person
    /// does not call themselves "王大锤的MacBook Pro".
    ///
    /// The possessive markers, in the order they are tried:
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
    static var greetingName: String { displayName(for: person(in: computerName)) }

    /// The raw rule itself, split out so it can be driven over a table of
    /// machine names rather than only over this Mac's own — see
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
            let raw = String(name[..<range.lowerBound])
            // Only a *host-name* marker can leave a joining character behind,
            // and only when no space separates the name from the model:
            // `wangxiajuns-MacBook-Pro` keeps the `s` that joined it (the `-`
            // after it falls to the separator trim), while `Chris MacBook` has
            // a space the user typed — stripping there would eat the last
            // letter of a perfectly ordinary name. A possessive (`Chris’s iMac`)
            // never leaves a joiner, which is what keeps that `s`.
            let stripJoiner = hostMarkers.contains { $0.caseInsensitiveCompare(marker) == .orderedSame }
                && raw.last != " "
            var prefix = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-_ \u{2019}'"))
            if stripJoiner, prefix.last == "s", prefix.count >= 2 {
                prefix = String(prefix.dropLast())
            }
            if prefix.count >= 2 { return prefix }
        }
        return name
    }

    /// How the person's name is **drawn** — the last step before it reaches the
    /// card.
    ///
    /// A Chinese name written in Latin letters is written in **pinyin, given
    /// name first**: `王夏军` → `Xiajun Wang`, and `王大锤` → `Dachui Wang`. The
    /// card used to print `王夏军` itself, which is the person's name in the
    /// language the rest of this surface is not written in — every other word on
    /// the card is English (`Good afternoon`), so the colophon is the one line
    /// that has to transliterate to match. Latin order is given-name-then-family
    /// (`Xiajun Wang`), not `Wang Xiajun`.
    ///
    /// The surname is the **first** character, not a table lookup, and the given
    /// name the rest. A two-character name (`王刚`) is `Gang Wang`; a compound
    /// surname (`欧阳修`) would be read as `Yangxiu Ou`, which is the one shape
    /// this cannot spell correctly — a table of the ~80 two-character surnames
    /// is a larger wrong surface than the single wrong name it would fix, so the
    /// simple rule stands and is documented rather than half-built.
    ///
    /// Anything already in Latin script is returned untouched (`Sam` → `Sam`),
    /// and a mixed or non-Han string falls back to the raw text rather than
    /// dropping characters. Both are deliberate: the transliteration is an
    /// addition for a Han-script name, never a rewrite of one that is already
    /// readable on the card.
    static func displayName(for raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let han = name.filter { isHan($0) }
        // Not a Han name, or has Latin letters already: the card can read it as
        // it stands, so it is not the transliterator's to rewrite.
        guard !han.isEmpty, han.count == name.count else { return name }
        let characters = Array(han)
        guard characters.count >= 2 else { return name }
        let family = String(characters[0])
        let given = String(characters.dropFirst())
        guard let familyLatin = pinyin(family), let givenLatin = pinyin(given) else { return name }
        return "\(givenLatin) \(familyLatin)"
    }

    /// Whether a scalar is a CJK ideograph — the range a pinyin reading exists
    /// for. Deliberately only the BMP block `4E00–9FFF` plus the compatibility
    /// block, which is what `CFStringTransform`'s transliteration handles; a
    /// character outside them means the string is not a plain Han name.
    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }

    /// A Han string's pinyin reading, `nil` when the transform cannot read it.
    /// The result is words separated by spaces and capitalised on the way in,
    /// which is exactly the shape `displayName` joins.
    private static func pinyin(_ han: String) -> String? {
        let mutable = NSMutableString(string: han)
        let ok = CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        guard ok else { return nil }
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let reading = (mutable as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard !reading.isEmpty, reading.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        return reading.capitalized
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
    static let computerName: String = {
        let store = SCDynamicStoreCreate(nil, "ClaudeBar.identity" as CFString, nil, nil)
        let raw = store.flatMap { SCDynamicStoreCopyComputerName($0, nil) } as String? ?? ""
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Mac" : name
    }()
}
