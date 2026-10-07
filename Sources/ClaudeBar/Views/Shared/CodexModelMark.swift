import SwiftUI

/// The client family's mark for the popup's header chip: the real brand
/// artwork, **on its own**.
///
/// It used to draw the family word beside the artwork ("[A\] CC"), and the chip
/// separately drew the same word again from `Text(eyebrow)` — so every chip
/// printed its family twice ("CC CC", "Codex Codex", "Cursor Cursor") and spent
/// ~20pt of a 133pt cell saying one thing two ways. The word is gone from both:
/// the chip now stacks the artwork over the model name, the artwork *is* the
/// family, and the name still reaches the tooltip and VoiceOver.
///
/// It is a view rather than a bare `Image` because it owns the mark's size and
/// shadow — the two things every caller had to remember and one of them always
/// got wrong.
struct CodexModelMark: View {
    /// `false` = CC / Claude, `true` = Codex — `ProductBrandMark`'s convention.
    var codex: Bool
    /// The family's name, kept for the mark's accessibility label. The chip's
    /// tooltip spells the family out anyway, so this only has to be right for
    /// VoiceOver reading the mark in isolation.
    var value: String?

    var body: some View {
        mark(side: 13)
            .accessibilityLabel(value ?? (codex ? "Codex" : "Claude Code"))
    }

    // MARK: - Brand mark

    /// A **themed** surface, so the ink follows the theme and `page:` stays nil.
    /// It used to pass `AppPreferences.shared.isDark ? nil : false`, which
    /// resolved to the black-ink file in light mode: legible on the white chip,
    /// but the opposite pair from every icon well beside it, and the same
    /// inversion that made the island's marks invisible. Only a caller whose
    /// ground does *not* follow the theme passes `page:`.
    private func mark(side: CGFloat) -> some View {
        MarkBuilder.mark(codex ? .codex : .claude, shadowOpacity: codex ? 0.16 : 0.22, side: side)
    }
}

/// The header chip's mark for **Cursor** — the brand cube alone, matching
/// `CodexModelMark`'s new single-glyph anatomy.
///
/// It is a separate type rather than a third case on `CodexModelMark` because
/// that view's whole shape is a `codex: Bool` — a Cursor chip that had to pass
/// "not Codex" would render the Claude artwork, which is the same trap
/// `ProductBrandMark.Brand.init(codex:)` documents.
struct CursorMark: View {
    var body: some View {
        // One builder for both marks (finding 546): the frame and shadow are
        // owned once, here, so the Cursor cube and the Claude/Codex marks
        // cannot drift apart again.
        MarkBuilder.mark(.cursor, shadowOpacity: 0.2)
            .accessibilityLabel("Cursor")
    }
}

/// The file's one owner of a header-chip mark's size and shadow.
///
/// `CodexModelMark` used to keep the pair in its own `mark(side:)` while
/// `CursorMark` re-specified them — the exact drift this file's header warns
/// callers about (finding 546). Both callers come through here now: the
/// side is the constant, the shadow opacity is the one thing that differs
/// between the brand families (Codex's two files sit a touch heavier than the
/// Cursor cube).
private enum MarkBuilder {
    static let side: CGFloat = 13
    static let shadowRadius: CGFloat = 5
    static let shadowY: CGFloat = 2

    static func mark(_ brand: ProductBrandMark.Brand, shadowOpacity: Double,
                     side: CGFloat = Self.side) -> some View {
        ProductBrandMark(brand: brand, well: false)
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
    }
}
