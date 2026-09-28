import SwiftUI
import CoreText

/// The greeting is the signature on the window, the name is its small colophon.
/// A cached CoreText outline writes in once; pointer movement never replays it.
///
/// **The colophon is bold, not a hairline.** It used to be `Songti SC` — a
/// serif that at 23–30pt with 8pt of tracking reads as a *faint* line, and next
/// to the heavy script above it the only thing that light was the name. It is
/// now a rounded bold face, which is the weight the rest of the card already
/// speaks in (`Theme.Font.displayMetric` and every figure on the dock are
/// rounded). The name arrives from `MachineIdentity` already Latinised
/// (`Xiajun Wang`), so the face is a Latin one; `Songti` had no Latin bold to
/// fall back to at this size and would have set the transliteration in the same
/// thin serif. SF Rounded has no `tracking`-heavy tradition, so the tracking
/// comes down from 8 to 4: the name is short and reads as one word rather than
/// as spread-out letters.
struct SkyGreeting: View {
    let name: String
    let palette: SkyPalette
    var phrase: GreetingPhrase.Phrase = GreetingPhrase.forDate(Date())
    var lightX: Double = 0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presented = false

    var body: some View {
        GeometryReader { geo in
            let size = min(180, geo.size.width * 0.175)
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    ScriptOutline(text: phrase.script)
                        .trim(from: 0, to: presented || reduceMotion ? 1 : 0)
                        .stroke(palette.ink.opacity(presented ? 0 : 0.9), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 1.4), value: presented)
                    Text(phrase.script)
                        .font(.custom("SnellRoundhand-Bold", size: size))
                        .lineLimit(1).minimumScaleFactor(0.55)
                        .foregroundStyle(LinearGradient(colors: [palette.ink, palette.ink.opacity(0.86)], startPoint: .top, endPoint: .bottom))
                        .opacity(presented || reduceMotion ? 1 : 0.18)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: presented || reduceMotion ? geo.size.width : 0)
                        }
                        .animation(reduceMotion ? nil : .easeOut(duration: 1.4), value: presented)
                        .shadow(color: palette.highlight.opacity(palette.isLightGround ? 0 : 0.28), radius: 1, x: lightX < 0.5 ? -1 : 1, y: -1)
                        .shadow(color: .black.opacity(palette.isLightGround ? 0 : 0.18), radius: 20, x: 0, y: 6)
                }
                .frame(height: size * 1.12)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 18) {
                    if let aside = phrase.aside {
                        Text(aside).font(.system(size: 10, weight: .medium)).foregroundStyle(palette.ink.opacity(0.65))
                    }
                    Spacer(minLength: 0)
                    Text(name).font(.system(size: geo.size.width < 650 ? 24 : 31, weight: .bold, design: .rounded))
                        .tracking(4).lineLimit(1).minimumScaleFactor(0.6)
                    SignatureRibbon().trim(from: 0, to: presented || reduceMotion ? 1 : 0)
                        .stroke(palette.ink.opacity(0.68), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        .frame(width: geo.size.width < 650 ? 58 : 105, height: 25)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).delay(0.7), value: presented)
                }
                .foregroundStyle(palette.ink.opacity(0.92))
                .padding(.trailing, geo.size.width * 0.12)
                .opacity(presented || reduceMotion ? 1 : 0)
                .offset(y: presented || reduceMotion ? 0 : 8)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.7).delay(0.7), value: presented)
            }
        }
        .onAppear { presented = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(phrase.script)，\(name)")
    }
}

private struct SignatureRibbon: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: rect.height * 0.7))
            p.addCurve(to: CGPoint(x: rect.width, y: rect.height * 0.45),
                       control1: CGPoint(x: rect.width * 0.8, y: -rect.height * 0.15),
                       control2: CGPoint(x: rect.width * 0.32, y: rect.height * 1.3))
            p.addCurve(to: CGPoint(x: rect.width * 0.72, y: rect.height * 0.64),
                       control1: CGPoint(x: rect.width * 1.1, y: rect.height * 0.28),
                       control2: CGPoint(x: rect.width * 0.91, y: rect.height * 0.4))
        }
    }
}

private struct ScriptOutline: Shape {
    let text: String
    func path(in rect: CGRect) -> Path {
        let path = ScriptGlyphCache.path(for: text)
        let bounds = path.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return Path() }
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                                          tx: (rect.width - bounds.width * scale) / 2 - bounds.minX * scale,
                                          ty: (rect.height - bounds.height * scale) / 2 + bounds.maxY * scale)
        return Path(path).applying(transform)
    }
}

private enum ScriptGlyphCache {
    static let cache = NSCache<NSString, CGPath>()
    static func path(for text: String) -> CGPath {
        if let cached = cache.object(forKey: text as NSString) { return cached }
        let font = CTFontCreateWithName("SnellRoundhand-Bold" as CFString, 120, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for i in 0..<count {
                if let glyph = CTFontCreatePathForGlyph(font, glyphs[i], nil) {
                    path.addPath(glyph, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
                }
            }
        }
        cache.setObject(path, forKey: text as NSString)
        return path
    }
}
