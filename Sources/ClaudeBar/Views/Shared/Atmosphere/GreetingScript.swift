import AppKit
import CoreText

/// The faces the greeting can be written in, chosen in 设置 → 问候字体.
///
/// Twenty are bundled under `Resources/Fonts` (SIL OFL 1.1, or Apache 2.0 for
/// Yellowtail and Satisfy; each licence ships beside its font). Four are the
/// Mac's own script faces and are looked up by PostScript name. Any face that
/// cannot be loaded falls back to Snell Roundhand, which every Mac has.
///
/// The raw value is what `AppPreferences` persists: never rename a case's
/// string, or a saved choice silently resets to the default.
enum GreetingTypeface: String, CaseIterable, Identifiable, Sendable {
    case pacifico
    case borel
    case playwriteUSModern
    case playwriteUSTrad
    case playwriteGBS
    case playwriteNZ
    case dancingScript
    case yellowtail
    case satisfy
    case cookie
    case damion
    case grandHotel
    case lobster
    case greatVibes
    case sacramento
    case parisienne
    case playball
    case kaushanScript
    case ooohBaby
    case grapeNuts
    case signPainter
    case snellRoundhand
    case savoye
    case zapfino

    static let standard: GreetingTypeface = .borel

    enum Source: Sendable {
        /// A file under `GreetingScript.resourceRoot`; `weight` sets the
        /// `wght` axis of a variable font.
        case bundled(file: String, weight: Double? = nil)
        /// An installed face, by PostScript name.
        case system(postScriptName: String)
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pacifico: return "Pacifico"
        case .borel: return "Borel"
        case .playwriteUSModern: return "Playwrite US Modern"
        case .playwriteUSTrad: return "Playwrite US Trad"
        case .playwriteGBS: return "Playwrite GB S"
        case .playwriteNZ: return "Playwrite NZ"
        case .dancingScript: return "Dancing Script"
        case .yellowtail: return "Yellowtail"
        case .satisfy: return "Satisfy"
        case .cookie: return "Cookie"
        case .damion: return "Damion"
        case .grandHotel: return "Grand Hotel"
        case .lobster: return "Lobster"
        case .greatVibes: return "Great Vibes"
        case .sacramento: return "Sacramento"
        case .parisienne: return "Parisienne"
        case .playball: return "Playball"
        case .kaushanScript: return "Kaushan Script"
        case .ooohBaby: return "Oooh Baby"
        case .grapeNuts: return "Grape Nuts"
        case .signPainter: return "SignPainter"
        case .snellRoundhand: return "Snell Roundhand"
        case .savoye: return "Savoye LET"
        case .zapfino: return "Zapfino"
        }
    }

    var source: Source {
        switch self {
        case .pacifico: return .bundled(file: "Pacifico-Regular.ttf")
        case .borel: return .bundled(file: "Borel-Regular.ttf")
        case .playwriteUSModern: return .bundled(file: "PlaywriteUSModern[wght].ttf", weight: 400)
        case .playwriteUSTrad: return .bundled(file: "PlaywriteUSTrad[wght].ttf", weight: 400)
        case .playwriteGBS: return .bundled(file: "PlaywriteGBS[wght].ttf", weight: 400)
        case .playwriteNZ: return .bundled(file: "PlaywriteNZ[wght].ttf", weight: 400)
        case .dancingScript: return .bundled(file: "DancingScript[wght].ttf", weight: 700)
        case .yellowtail: return .bundled(file: "Yellowtail-Regular.ttf")
        case .satisfy: return .bundled(file: "Satisfy-Regular.ttf")
        case .cookie: return .bundled(file: "Cookie-Regular.ttf")
        case .damion: return .bundled(file: "Damion-Regular.ttf")
        case .grandHotel: return .bundled(file: "GrandHotel-Regular.ttf")
        case .lobster: return .bundled(file: "Lobster-Regular.ttf")
        case .greatVibes: return .bundled(file: "GreatVibes-Regular.ttf")
        case .sacramento: return .bundled(file: "Sacramento-Regular.ttf")
        case .parisienne: return .bundled(file: "Parisienne-Regular.ttf")
        case .playball: return .bundled(file: "Playball-Regular.ttf")
        case .kaushanScript: return .bundled(file: "KaushanScript-Regular.ttf")
        case .ooohBaby: return .bundled(file: "OoohBaby-Regular.ttf")
        case .grapeNuts: return .bundled(file: "GrapeNuts-Regular.ttf")
        case .signPainter: return .system(postScriptName: "SignPainter-HouseScript")
        case .snellRoundhand: return .system(postScriptName: "SnellRoundhand-Bold")
        case .savoye: return .system(postScriptName: "SavoyeLetPlain")
        case .zapfino: return .system(postScriptName: "Zapfino")
        }
    }

    /// Extra weight laid on each side of the outline, em. Only monoline faces
    /// take it: they thicken evenly and keep their round ends, where a stroke
    /// around a high-contrast face fills in the hairlines that make it one.
    /// More than ~0.02 starts to close the counters of `a`, `e` and `o`.
    var weight: CGFloat {
        switch self {
        case .borel: return 0.012
        case .playwriteUSModern, .playwriteUSTrad, .playwriteGBS, .playwriteNZ: return 0.008
        case .sacramento: return 0.01
        case .ooohBaby, .grapeNuts: return 0.006
        case .satisfy, .savoye: return 0.003
        case .greatVibes, .parisienne: return 0.002
        default: return 0
        }
    }

    var isBundled: Bool {
        if case .bundled = source { return true }
        return false
    }
}

/// Glyph outlines for the greeting, in the chosen `GreetingTypeface`.
///
/// Outlines are taken once per face and phrase at 1000 units and kept in em
/// (y down, origin on the baseline at the pen's start). The renderer fills
/// them and strokes them `typeface.weight` wide on each side.
enum GreetingScript {
    static let fallbackPostScriptName = "SnellRoundhand-Bold"
    nonisolated(unsafe) static var resourceRoot: URL? = Bundle.main.resourceURL?.appendingPathComponent("Fonts")

    /// Built once and never mutated, so it can be handed across threads.
    struct Line: @unchecked Sendable {
        /// Glyph outlines, em, y down.
        var path: CGPath
        var advance: CGFloat
        /// Ink bounds, em, y down, without the added weight.
        var bounds: CGRect
    }

    private struct LineKey: Hashable {
        var typeface: GreetingTypeface
        var text: String
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        /// `.some(nil)` records a face that failed to load, so the file is not
        /// read again on every layout.
        var descriptors: [GreetingTypeface: CTFontDescriptor?] = [:]
        var lines: [LineKey: Line] = [:]
    }
    private static let cache = Cache()

    static func font(_ typeface: GreetingTypeface, size: CGFloat) -> CTFont {
        cache.lock.lock()
        let cached = cache.descriptors[typeface]
        cache.lock.unlock()
        let descriptor: CTFontDescriptor?
        if let cached {
            descriptor = cached
        } else {
            descriptor = loadDescriptor(typeface)
            cache.lock.lock()
            cache.descriptors[typeface] = .some(descriptor)
            cache.lock.unlock()
        }
        if let descriptor { return CTFontCreateWithFontDescriptor(descriptor, size, nil) }
        return CTFontCreateWithName(fallbackPostScriptName as CFString, size, nil)
    }

    /// Whether the face itself (not the fallback) is available.
    static func isAvailable(_ typeface: GreetingTypeface) -> Bool {
        _ = font(typeface, size: 12)
        cache.lock.lock()
        defer { cache.lock.unlock() }
        return (cache.descriptors[typeface] ?? nil) != nil
    }

    private static func loadDescriptor(_ typeface: GreetingTypeface) -> CTFontDescriptor? {
        switch typeface.source {
        case let .bundled(file, weight):
            guard let url = resourceRoot?.appendingPathComponent(file),
                  let found = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first
            else { return nil }
            guard let weight else { return found }
            // 'wght' as a four-char code; CoreText keys variation axes by tag.
            let variation = [kCTFontVariationAttribute: [0x7767_6874: weight]] as CFDictionary
            return CTFontDescriptorCreateCopyWithAttributes(found, variation)
        case let .system(name):
            // CTFontCreateWithName never fails: an unknown name comes back as
            // a different face. Only keep it if it is the one asked for.
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            guard CTFontCopyPostScriptName(font) as String == name else { return nil }
            return CTFontCopyFontDescriptor(font)
        }
    }

    static func line(_ text: String, typeface: GreetingTypeface) -> Line {
        let key = LineKey(typeface: typeface, text: text)
        cache.lock.lock()
        if let hit = cache.lines[key] { cache.lock.unlock(); return hit }
        cache.lock.unlock()

        let unit: CGFloat = 1000
        let font = font(typeface, size: unit)
        let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName].map { $0 as! CTFont } ?? font
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                // Glyph space is y up; flip into em, y down.
                var transform = CGAffineTransform(a: 1 / unit, b: 0, c: 0, d: -1 / unit,
                                                  tx: position.x / unit, ty: -position.y / unit)
                if let outline = CTFontCreatePathForGlyph(runFont, glyph, &transform) { path.addPath(outline) }
            }
        }
        let advance = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil)) / unit
        let bounds = path.isEmpty ? CGRect(x: 0, y: -0.7, width: advance, height: 0.9) : path.boundingBoxOfPath
        let line = Line(path: path, advance: advance, bounds: bounds)
        cache.lock.lock()
        cache.lines[key] = line
        cache.lock.unlock()
        return line
    }

    /// The outlines in card points, `size` pt to the em, pen start at `origin`.
    static func path(_ line: Line, size: CGFloat, origin: CGPoint) -> CGPath {
        var transform = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: size, y: size)
        return line.path.copy(using: &transform) ?? line.path
    }
}
