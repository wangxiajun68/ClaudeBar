import SwiftUI

/// The client family's mark for the popup's header chip: the real brand artwork
/// beside the family's name.
///
/// It exists as its own view because the chip's eyebrow row is the one place on
/// that surface where a family can be stated by its drawing instead of by a
/// word, and because the same artwork stands wherever the app names the two
/// clients — so "which family is this" is answered by one mark everywhere
/// rather than by a symbol here and a sentence there.
struct CodexModelMark: View {
    /// `false` = CC / Claude, `true` = Codex — `ProductBrandMark`'s convention.
    var codex: Bool
    /// The family's name, drawn beside the mark.
    var value: String?
    /// A second line under it. The chip passes nothing.
    var note: String?
    var tint: Color = Theme.Ink.claude

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                mark(side: 13)
                Text(codex ? "Codex" : "CC")
                    .font(Theme.Font.eyebrow)
                    .foregroundStyle(tint)
            }
            if let value {
                Text(value)
                    .font(Theme.Font.section)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let note {
                Text(note)
                    .rollingNumber()
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Brand mark

    /// A **themed** surface, so the ink follows the theme and `page:` stays nil.
    /// It used to pass `AppPreferences.shared.isDark ? nil : false`, which
    /// resolved to the black-ink file in light mode: legible on the white chip,
    /// but the opposite pair from every icon well beside it, and the same
    /// inversion that made the island's marks invisible. Only a caller whose
    /// ground does *not* follow the theme passes `page:`.
    private func mark(side: CGFloat) -> some View {
        ProductBrandMark(codex: codex, well: false)
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(codex ? 0.16 : 0.22), radius: 5, y: 2)
            .accessibilityHidden(true)
    }
}
