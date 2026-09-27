import SwiftUI
import AppKit

/// The three client families' **real brand marks**, bundled offline:
/// Anthropic's "A\" mark for CC / Claude Code, OpenAI's knot for Codex, and
/// Cursor's faceted cube.
///
/// These are the same artwork the rest of the app already uses for these
/// clients — `ProviderIdentityMark` names CC with `anthropic` and Codex with
/// `openai` on the official-provider card and in the provider directory, and
/// `Sources/ProviderIcons/README.md` pins all of them (Cursor added
/// 2026-09-27) to LobeHub `@lobehub/icons-static-png@1.97.1`. Nothing here
/// redraws a brand by eye.
///
/// **Cursor used to be an SF Symbol here, and that was wrong.** Every surface
/// drew `cursorarrow.motionlines` — a pointer with speed lines — for a product
/// whose mark is a cube. The mistake is worth recording because it looked
/// plausible: the glyph *is* a cursor, so it reads as "about cursors" without
/// ever being the brand, and no tint or size makes a symbol into a logo.
/// Because there are three families now the flag is a `Brand`, not a `Bool`,
/// so a fourth cannot be added by overloading `true` again.
///
/// What this file owns is the **tile**, and that tile has one job a bare PNG
/// cannot do: every bundled file is a single ink, so on the wrong backdrop —
/// black ink on a black badge, white on a white card — the mark is not "low
/// contrast", it is *gone*. The tile paints `Theme.bgSecondary` behind the
/// artwork, which is the light well the panel header, the island and the
/// dashboard tiles all draw the clients in, and the same treatment
/// `ProviderIdentityMark` gives the provider page; callers whose surface is not
/// that well (a black badge, the greeting card's own sky) say so through `page:`
/// and skip the tile with `well: false`.
///
/// The artwork is normalised by `Tools/gen-brand-marks.py`, not used raw. Raw,
/// each PNG carries its own margin to the edge of a square canvas: measured on
/// the bundled files that is 33.5pt of the 13pt header tile for Anthropic and
/// 32.5pt for OpenAI at the same size, which puts the mark at 65% of an
/// already-small tile and reads as a smudge. The generator trims that margin and
/// writes each mark back at `KEEP` (90%) of its canvas, measured on the *width*
/// so that a wide "A\", a square knot and Cursor's portrait cube all stand one
/// size in a row of chips.
struct ProductBrandMark: View {
    /// The four families this mark can draw, and the bundled asset for each.
    ///
    /// The fourth is not a client: `claudebar` is **this app**, and it is here
    /// for the one tally that names no other product — 第三方, the third-party
    /// traffic ClaudeBar proxies. It sat in the usage legend as bare text beside
    /// three families that each had a mark, which read as a missing icon rather
    /// than as a deliberate difference. Its artwork is the app's own icon
    /// (`Tools/make-claudebar-mark.py`), so the app names itself the same way it
    /// names the clients: with its real mark, not a glyph standing in for one.
    enum Brand: String {
        case claude, codex, cursor, claudebar

        /// `false` = CC, `true` = Codex — the convention the callers that only
        /// ever choose between those two have always used (`GlyphWell.brand`,
        /// `SegmentedCapsule.brand`, `SettingTile.brand`), kept so those call
        /// sites did not have to move when Cursor joined. It is not a
        /// convenience: those surfaces genuinely offer only the two *provider*
        /// clients, and Cursor has no API endpoint to configure.
        init(codex: Bool) { self = codex ? .codex : .claude }

        var asset: String {
            switch self {
            case .claude: return "anthropic"
            case .codex: return "openai"
            case .cursor: return "cursor"
            case .claudebar: return "claudebar"
            }
        }

        var label: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .cursor: return "Cursor"
            // The tally's own word, not "ClaudeBar": the mark stands where the
            // label 第三方 stands everywhere else in the app, and an
            // accessibility label that disagreed with the text beside it would
            // make the legend read as two different things.
            case .claudebar: return "第三方"
            }
        }
    }

    let brand: Brand

    /// The **one** initialiser every call site goes through.
    ///
    /// There is no memberwise init to fall back on: declaring `init(brand:)`
    /// below suppresses it, which is exactly why this one has to spell out all
    /// four properties. A call site that forgot one silently lost it — the
    /// island's `page: true` was accepted by a stale memberwise init and did
    /// nothing, which is the bug this shape prevents.
    ///
    /// - Parameters:
    ///   - well: draw the icon well behind the artwork. Off for a caller that
    ///     has already put the mark in a well of its own.
    ///   - page: which page the mark is drawn on, for the ink — `nil` = a themed
    ///     surface, `true` = a black one (the island), `false` = a light one
    ///     (the greeting card's pale sky). See `dark`.
    ///   - inkWell: a neutral, page-toned well instead of the branded one.
    init(brand: Brand, well: Bool = true, page: Bool? = nil, inkWell: Bool? = nil) {
        self.brand = brand
        self.well = well
        self.page = page
        self.inkWell = inkWell
    }
    /// `false` = CC / Claude Code (Anthropic), `true` = Codex (OpenAI) — see
    /// `Brand.init(codex:)`. Kept as its own spelling because the surfaces that
    /// only choose between the two *provider* clients have always passed it.
    init(codex: Bool, well: Bool = true, page: Bool? = nil, inkWell: Bool? = nil) {
        self.init(brand: Brand(codex: codex), well: well, page: page, inkWell: inkWell)
    }
    /// Draw the icon well behind the artwork. Off for a caller that has already
    /// put the mark in a well of its own.
    var well = true
    /// Which **page** this mark is drawn on, for the ink.
    ///
    /// `nil` = a **themed** surface (`Theme.bgSecondary` / `Theme.cardSurface`),
    /// whose tone follows `Theme.isDark`. `true` = a **black** page (the island,
    /// the notch bar, the recessed metre well); `false` = a **light** page (the
    /// greeting card's pale sky, a white card, the popup's ice canvas).
    ///
    /// It is deliberately not `Theme.isDark`: the island is black in *both*
    /// themes, so asking the theme question drew the wrong ink on the app's
    /// blackest surface. A surface that is black whatever the theme says so.
    ///
    /// **The two files, measured rather than read off their names.** This cost
    /// two rounds of "the island's icons are black", so it is recorded as
    /// numbers: `openai-light.png` and `anthropic-light.png` — and Cursor's too
    /// — carry **black** ink (mean RGB `[0, 0, 0]` over the opaque pixels), and
    /// the `-dark` files carry **white** (`[255, 255, 255]`). LobeHub names them
    /// for the *page* they are drawn on, not for their own luminance, which is
    /// the opposite of what "a dark asset is a dark mark" invites you to assume.
    ///
    /// So: a black page needs the `-dark` file (white ink), a light page needs
    /// `-light` (black ink), and a themed surface follows `Theme.isDark` —
    /// white ink in dark mode, black in light. `dark` below is the *file*
    /// selector and says exactly that; the earlier version had it inverted for
    /// both of the explicit cases, so the island asked for the black file on its
    /// black badge and the popup's light chip asked for the white one.
    var page: Bool? = nil
    /// A neutral, page-toned well instead of the branded one. Only meaningful
    /// for a caller that also lets the mark draw the tile.
    var inkWell: Bool? = nil

    private var asset: String { brand.asset }

    /// Which **file** to decode, i.e. which ink: `true` = the `-dark` asset,
    /// which is the **white** mark; `false` = the `-light` asset, the black one.
    ///
    /// Read it as "use the file named for the page the mark stands on": a black
    /// page takes `-dark`, a light page takes `-light`, and a themed surface
    /// takes whichever the theme is in. See the note on `page` for the measured
    /// ink of each file — the names are about the backdrop, not the glyph.
    private var dark: Bool {
        if let page { return page }
        return Theme.isDark
    }
    private var wellFill: Color {
        guard let inkWell else { return Theme.bgSecondary }
        return inkWell ? Color(hex: 0x1E2228) : Color(hex: 0xF7FAFC)
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            if let image = Self.image(asset, dark: dark) {
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
                                .fill(wellFill)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.28, style: .continuous))
            } else {
                // A missing bundle resource must not read as "no client": fall
                // back to the family's own instrument glyph rather than a blank.
                InstrumentBadge(kind: brand == .codex ? .config : .sessions,
                                size: side * 0.62,
                                tint: Self.fallbackTint(brand))
                    .frame(width: side, height: side)
            }
        }
        .accessibilityLabel(brand.label)
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

    /// The hue the missing-asset fallback reads as, per family. `claudebar` has
    /// no `Theme.Ink` of its own — nothing in the app tints text with the app's
    /// own brand — so it borrows the hue the 第三方 tally already uses
    /// (`UsageSource.thirdParty.ink`), and the mark keeps saying the same thing
    /// as the words beside it even when its artwork failed to load.
    private static func fallbackTint(_ brand: Brand) -> Color {
        switch brand {
        case .claude: return Theme.Ink.claude
        case .codex: return Theme.Ink.codex
        case .cursor: return Theme.Ink.cursor
        case .claudebar: return Theme.Ink.cursor
        }
    }
}
