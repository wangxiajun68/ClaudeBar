import SwiftUI
import AppKit

/// The two client families' **real brand marks**, bundled offline: Anthropic's
/// "A\" mark for CC / Claude Code, OpenAI's knot for Codex.
///
/// These are the same artwork the rest of the app already uses for these two
/// clients — `ProviderIdentityMark` names CC with `anthropic` and Codex with
/// `openai` on the official-provider card and in the provider directory, and
/// `Sources/ProviderIcons/README.md` pins them to LobeHub
/// `@lobehub/icons-static-png@1.97.1`. Nothing here redraws a brand by eye.
///
/// What this file owns is the **tile**, and that tile has one job that a bare
/// PNG cannot do: a mark that is pure black on a dark card, or pure white on a
/// light one, is *invisible*. So the artwork sits on `Theme.bgSecondary` in a
/// rounded square — the light well the panel header, the island and the
/// dashboard tiles all draw the clients in, and the same treatment
/// `ProviderIdentityMark` gives the provider page.
///
/// The artwork is normalised by `Tools/gen-brand-marks.py`, not used raw. Raw,
/// each PNG carries its own margin to the edge of a square canvas: measured on
/// the four bundled files that is 33.5pt of the 13pt header tile for Anthropic
/// and 32.5pt for OpenAI at the same size, which puts the mark at 65% of an
/// already-small tile and reads as a smudge. The generator trims that margin and
/// writes every mark back at `KEEP` (80%) of its canvas — and, because Anthropic
/// is nearly twice as wide as it is tall while OpenAI is square, it reserves one
/// shared *side*. Both marks then stand the same width in the same tile, which is
/// what lets a CC chip and a Codex chip sit side by side in one row.
struct ProductBrandMark: View {
    /// `false` = CC / Claude Code (Anthropic), `true` = Codex (OpenAI).
    let codex: Bool
    /// Draw the icon well behind the artwork. Off for a caller that has already
    /// put the mark in a well of its own.
    var well = true

    private var asset: String { codex ? "openai" : "anthropic" }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            if let image = Self.image(asset, dark: Theme.isDark) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    // The generator already normalised the margin, so this only
                    // has to leave the well's own breathing room — a fraction of
                    // the tile, because the tile is the thing that scales.
                    .padding(side * (well ? 0.17 : 0.04))
                    .frame(width: side, height: side)
                    .background {
                        if well {
                            RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
                                .fill(Theme.bgSecondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.28, style: .continuous))
            } else {
                // A missing bundle resource must not read as "no client": fall
                // back to the family's own instrument glyph rather than a blank.
                InstrumentBadge(kind: codex ? .config : .sessions,
                                size: side * 0.62,
                                tint: codex ? Theme.Ink.codex : Theme.Ink.claude)
                    .frame(width: side, height: side)
            }
        }
        .accessibilityLabel(codex ? "Codex" : "Claude Code")
    }

    /// Where the bundled PNGs live. The app leaves this at `Bundle.main`; the
    /// render fixture points it at `Sources/BrandAssets`, because a slice with
    /// no app bundle would otherwise quietly draw the missing-asset fallback and
    /// a blank brand mark would pass every render check.
    nonisolated(unsafe) static var resourceRoot: URL? = Bundle.main.resourceURL?
        .appendingPathComponent("BrandAssets", isDirectory: true)

    /// Decoded once per variant and kept: the mark is drawn on the dashboard
    /// strip, the island and the provider grid, and `NSImage(contentsOf:)` reads
    /// and decodes a PNG on every call.
    private static let cache = NSCache<NSString, NSImage>()

    private static func image(_ asset: String, dark: Bool) -> NSImage? {
        let key = "\(asset)-\(dark ? "dark" : "light")"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let root = resourceRoot,
              let image = NSImage(contentsOf: root.appendingPathComponent("\(key).png")) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}
