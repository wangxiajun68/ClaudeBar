import CoreGraphics
import Foundation

/// The one place a session card's title is derived, for all three agents.
///
/// The three tools store their titles in completely different places, so each
/// monitor supplies whatever it has and this type applies one shared rule:
///
/// | agent  | source of truth                                    |
/// |--------|----------------------------------------------------|
/// | Codex  | `threads.title` in `state_*.sqlite` (already good) |
/// | Cursor | `composerHeaders.value.name` (already good)        |
/// | CC     | the first human prompt in the transcript (derived) |
///
/// Before this, Codex and Cursor showed a real title while Claude Code showed
/// `cwd`'s last path component — five sessions in one project all read
/// `ClaudeBar`, so the cards were indistinguishable. The fallback chain keeps
/// that from becoming an empty title: a session that yields no prompt (a
/// `/clear`-only session, or a transcript that is still empty) still shows
/// something a user can navigate by.
struct SessionTitle: Equatable {
    /// The session's own title, when the agent exposes one.
    let authored: String
    /// The first human prompt, for agents that have no title field.
    let firstPrompt: String
    /// Last resort: the working directory's name.
    let folder: String
    /// A secondary line some agents store alongside the title (Cursor's
    /// "Edited app.py, frontend.html"). Only ever a sub-line, never the title.
    let authoredSubtitle: String

    init(authored: String = "", firstPrompt: String = "", folder: String = "",
         subtitle: String = "") {
        self.authored = authored
        self.firstPrompt = firstPrompt
        self.folder = folder
        self.authoredSubtitle = subtitle
    }

    /// Title budget, in points, at `Theme.Font.section` (12pt semibold).
    ///
    /// A *character* cap does not work here: measured advances are ~11.9pt for
    /// CJK and ~6.1pt for Latin, so one number truncates CJK correctly and
    /// mangles Latin (or the reverse). Real data makes it concrete — 53% of
    /// non-archived Cursor titles exceed 24 characters, with a median of 28
    /// ("CM cloud organize concurrency"), and CC prompts are CJK sentences.
    ///
    /// 180pt is the title slot on a `.pageSession` cell (280pt) once the status
    /// dot, pill and load chip are taken out: ~15 CJK or ~29 Latin characters,
    /// which fits every common title whole while still catching a pasted essay.
    /// Longest titles are shortened here rather than by SwiftUI so all cards
    /// agree and `help()` matches what is drawn — callers keep
    /// `lineLimit(1)` + `truncationMode(.tail)` as the final guard for cells
    /// that end up narrower than the budget.
    static let maxWidth: CGFloat = 180

    /// One-line title: the session's own title, or its first prompt, or the
    /// folder. Kept for callers that have a single label slot (⌘K, the
    /// dashboard's row) — see `label(_:)` for the two-part card header.
    var display: String {
        for candidate in [authored, firstPrompt] {
            let cleaned = Self.condense(candidate)
            if !cleaned.isEmpty { return Self.shorten(cleaned) }
        }
        return Self.fallback(folder)
    }

    /// The two halves of a card header, already budgeted: `folder | title`.
    struct Label {
        /// Working directory name — always short, and always shown whole.
        let folder: String
        /// The session-specific part. Empty when the folder is all we have,
        /// in which case the header renders `folder` alone rather than
        /// repeating it on both sides of a separator.
        let title: String

        /// Spoken form. The separator is punctuation on screen but a pause
        /// when read aloud, so the two halves are joined with a comma — the
        /// drawn "·" would be read as "middle dot" or skipped entirely.
        var accessibilityText: String { title.isEmpty ? folder : "\(folder)，\(title)" }
    }

    /// Card header: `folder | title`.
    ///
    /// The folder is the *stable* half — it never changes mid-session, so a
    /// scanning eye can find "the ClaudeBar one" without reading the text.
    /// The title is the *specific* half. Splitting them beats the single
    /// label: `ClaudeBar | 修复登录闪烁` answers "which project" and "which
    /// task" at once, where either alone forces a guess.
    ///
    /// Both halves are measured against their own share of `maxWidth` so the
    /// folder cannot crowd the title out, and vice versa.
    var cardLabel: Label {
        let folderText = Self.fallback(folder)
        let titleText = [authored, firstPrompt]
            .map(Self.condense)
            .first { !$0.isEmpty } ?? ""
        // No real title: the folder is the whole header.
        guard !titleText.isEmpty, titleText != folderText else {
            return Label(folder: folderText, title: "")
        }
        return Label(folder: Self.shortenFolder(folderText),
                     title: Self.shorten(titleText))
    }

    /// Cursor's "Edited a.py, b.py" line, for cards that render a third line.
    /// Empty when there is nothing worth saying.
    var cardSubtitle: String {
        let cleaned = Self.condense(authoredSubtitle)
        return cleaned.isEmpty ? "" : Self.shorten(cleaned, budget: Self.maxSubtitleWidth)
    }

    /// Folder names are identifiers, not prose: they are short in practice
    /// ("ClaudeBar", "cmcc_skills") and carry no spaces to break on, so they
    /// get a tighter budget to leave the title the room it needs.
    static let maxFolderWidth: CGFloat = 96

    /// A subtitle sits under the title in a smaller font, so it can run wider.
    static let maxSubtitleWidth: CGFloat = 200

    private static func shortenFolder(_ text: String) -> String {
        shorten(text, budget: maxFolderWidth)
    }

    private static func fallback(_ folder: String) -> String {
        let cleaned = condense(folder)
        return cleaned.isEmpty ? "session" : cleaned
    }

    /// Collaborators, tools and the transcript itself can leave structured
    /// wrappers in a prompt: `<command-name>/clear</command-name>`,
    /// `<local-command-stdout>…`, or a markdown heading. None of that belongs
    /// on a card, so strip it and flatten to one line.
    static func condense(_ raw: String) -> String {
        var text = raw
        // Drop XML-ish wrapper tags, keeping any text between them.
        while let open = text.firstIndex(of: "<"), let close = text[open...].firstIndex(of: ">") {
            let tag = text[open...close]
            // A bare "a < b" must not be mistaken for a tag: require no spaces
            // right after '<' and a short, letter-led name.
            let name = tag.dropFirst().dropLast()
            if name.isEmpty || name.count > 24 || name.contains(" ")
                || !name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" || $0 == "-" || $0 == "_" }) {
                break
            }
            text.removeSubrange(open...close)
        }
        // Markdown emphasis / heading marks carry no meaning in a title.
        for marker in ["**", "__", "`", "#"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: "\t", with: " ")
        return text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Truncate to `maxWidth` points and mark the cut with an ellipsis.
    ///
    /// Measures per character so a CJK-heavy prompt and a Latin title get the
    /// same *visual* budget, and steps by `Character` so an emoji or a
    /// composed grapheme is never split. Trailing punctuation left dangling by
    /// the cut is dropped — "标题，…" reads as a typo, "标题…" does not.
    ///
    /// Uses a fixed advance per character class rather than a text measurement
    /// framework: this runs per session on every poll, and the classes are
    /// uniform enough (CJK is full-width, Latin averages 6.1pt at 12pt
    /// semibold, measured over real titles) that the estimate is within one
    /// character of `NSString.size(withAttributes:)`.
    static func shorten(_ text: String, budget: CGFloat = maxWidth) -> String {
        guard width(text) > budget else { return text }
        var head = ""
        var used: CGFloat = 0
        for character in text {
            let advance = CGFloat(character.unicodeScalars.reduce(0) {
                $0 + (isFullWidth($1) ? 11.9 : 6.1)
            })
            if used + advance > budget - ellipsisWidth { break }
            head.append(character)
            used += advance
        }
        while let last = head.last, ",.;:!?，。；：、！？—… ".contains(last) {
            head.removeLast()
        }
        return head + "…"
    }

    private static let ellipsisWidth: CGFloat = 6.1

    /// Full-width ranges that occupy roughly one em at 12pt: CJK ideographs,
    /// kana, Hangul, and the full-width forms/punctuation blocks.
    private static func isFullWidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,          // Hangul Jamo
             0x2E80...0x303E,          // CJK radicals, punctuation
             0x3041...0x33FF,          // kana, CJK compat
             0x3400...0x4DBF,          // CJK ext A
             0x4E00...0x9FFF,          // CJK unified
             0xA000...0xA4CF,          // Yi
             0xAC00...0xD7A3,          // Hangul syllables
             0xF900...0xFAFF,          // CJK compat ideographs
             0xFE30...0xFE6F,          // CJK compat forms
             0xFF00...0xFF60,          // full-width forms
             0xFFE0...0xFFE6,          // full-width signs
             0x1F300...0x1FAFF,        // emoji (present as wide)
             0x20000...0x3FFFD:        // CJK ext B+
            return true
        default:
            return false
        }
    }

    /// Estimated rendered width at `Theme.Font.section`.
    private static func width(_ text: String) -> CGFloat {
        text.unicodeScalars.reduce(0) {
            $0 + (isFullWidth($1) ? 11.9 : 6.1)
        }
    }
}
