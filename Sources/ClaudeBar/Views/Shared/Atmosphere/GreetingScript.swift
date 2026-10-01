import AppKit
import CoreText

/// The faces the greeting can be written in, chosen in 设置 → 问候字体.
///
/// Bundled Chinese display faces and Latin scripts ship with their licences.
/// Four additional Latin faces are supplied by macOS. Display fonts load from
/// the mutable local library; bundled originals seed and restore that library.
///
/// The raw value is what `AppPreferences` persists: never rename a case's
/// string, or a saved choice silently resets to the default.
enum GreetingTypeface: String, CaseIterable, Identifiable, Sendable {
    case chillRoundBold
    case chillRoundHeavy
    case zcoolKuaiLe
    case zcoolQingKeHuangYou
    case zcoolXiaoWei
    case maShanZheng
    case smileySans
    case zhiMangXing
    case longCang
    case liuJianMaoCao
    case fredoka
    case baloo2
    case chewy
    case shrikhand
    case bungee
    case bungeeShade
    case luckiestGuy
    case lilitaOne
    case berkshireSwash
    case oleoScript
    case righteous
    case rampartOne
    case monoton
    case rubikBubbles
    case caveat
    case chillRoundFull
    case lxgwZhenKai
    case yozai
    case lxgwMarkerGothic
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

    static let standard: GreetingTypeface = .chillRoundBold

    static let chineseFaces: [GreetingTypeface] = [
        .chillRoundBold, .chillRoundHeavy, .zcoolKuaiLe, .zcoolQingKeHuangYou,
        .smileySans, .maShanZheng, .zcoolXiaoWei,
        .zhiMangXing, .longCang, .liuJianMaoCao, .chillRoundFull, .lxgwZhenKai, .yozai, .lxgwMarkerGothic
    ]
    var supportsChinese: Bool { Self.chineseFaces.contains(self) }

    static func available(chinese: Bool, removed: Set<String>) -> [GreetingTypeface] {
        allCases.filter { $0.supportsChinese == chinese && !removed.contains($0.rawValue) }
    }

    static func resolved(_ preferred: GreetingTypeface, chinese: Bool, removed: Set<String>) -> GreetingTypeface {
        let faces = available(chinese: chinese, removed: removed)
        if faces.contains(preferred) { return preferred }
        let fallback: GreetingTypeface = chinese ? .standard : .borel
        return faces.contains(fallback) ? fallback : (faces.first ?? fallback)
    }

    static func canRemove(_ face: GreetingTypeface, removed: Set<String>) -> Bool {
        let faces = available(chinese: face.supportsChinese, removed: removed)
        return face.isBundled && faces.contains(face) && faces.count > 1
    }

    var character: String {
        switch self {
        case .chillRoundBold: return "圆润粗体 · 温暖清晰"
        case .chillRoundHeavy: return "圆润特粗 · 饱满有力"
        case .zcoolKuaiLe: return "童趣手绘 · 活泼可爱"
        case .zcoolQingKeHuangYou: return "复古美术 · 紧凑厚实"
        case .smileySans: return "倾斜黑体 · 灵动俏皮"
        case .maShanZheng: return "毛笔手写 · 潇洒自在"
        case .zcoolXiaoWei: return "文艺宋体 · 复古优雅"
        case .zhiMangXing: return "行书笔意 · 流畅洒脱"
        case .longCang: return "随性书写 · 毛边质感"
        case .liuJianMaoCao: return "奔放草书 · 自由灵动"
        case .fredoka: return "圆润粗体 · 柔软亲切"
        case .baloo2: return "饱满圆体 · 活泼厚实"
        case .chewy: return "卡通手绘 · 胖胖俏皮"
        case .shrikhand: return "复古胖斜体 · 奶油质感"
        case .bungee: return "招牌块体 · 城市海报"
        case .bungeeShade: return "立体阴影 · 复古招牌"
        case .luckiestGuy: return "漫画海报 · 不规则粗体"
        case .lilitaOne: return "短胖标题 · 柔和有力"
        case .berkshireSwash: return "复古花体 · 卷曲装饰"
        case .oleoScript: return "流动手写 · 温柔厚实"
        case .righteous: return "装饰艺术 · 几何复古"
        case .rampartOne: return "立体轮廓 · 纸上积木"
        case .monoton: return "多线轮廓 · 复古霓虹"
        case .rubikBubbles: return "泡泡字形 · 软萌夸张"
        case .caveat: return "随笔手写 · 自然轻松"
        case .chillRoundFull: return "全圆笔画 · 软糯温暖"
        case .lxgwZhenKai: return "厚实楷书 · 温润书卷"
        case .yozai: return "随笔手写 · 松弛自然"
        case .lxgwMarkerGothic: return "马克笔字 · 漫画气质"
        case .pacifico: return "复古圆笔 · 海报手写"
        case .borel: return "柔软连笔 · 温暖圆润"
        case .playwriteUSModern, .playwriteUSTrad, .playwriteGBS, .playwriteNZ: return "书写练习 · 自然笔意"
        case .dancingScript, .yellowtail, .satisfy, .cookie, .damion: return "流动手写 · 轻松亲切"
        case .grandHotel, .lobster, .playball, .kaushanScript: return "复古招牌 · 厚实连笔"
        case .greatVibes, .sacramento, .parisienne, .ooohBaby, .grapeNuts: return "轻盈花体 · 随笔装饰"
        case .signPainter, .snellRoundhand, .savoye, .zapfino: return "系统花体 · 优雅书写"
        }
    }

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
        case .chillRoundBold: return "寒蝉圆黑 · 粗体"
        case .chillRoundHeavy: return "寒蝉圆黑 · 特粗"
        case .zcoolKuaiLe: return "站酷快乐体"
        case .zcoolQingKeHuangYou: return "站酷庆科黄油体"
        case .zcoolXiaoWei: return "站酷小薇体"
        case .maShanZheng: return "马善政毛笔体"
        case .smileySans: return "得意黑"
        case .zhiMangXing: return "志莽行书"
        case .longCang: return "龙藏体"
        case .liuJianMaoCao: return "刘建毛草"
        case .fredoka: return "Fredoka"
        case .baloo2: return "Baloo 2"
        case .chewy: return "Chewy"
        case .shrikhand: return "Shrikhand"
        case .bungee: return "Bungee"
        case .bungeeShade: return "Bungee Shade"
        case .luckiestGuy: return "Luckiest Guy"
        case .lilitaOne: return "Lilita One"
        case .berkshireSwash: return "Berkshire Swash"
        case .oleoScript: return "Oleo Script Bold"
        case .righteous: return "Righteous"
        case .rampartOne: return "Rampart One"
        case .monoton: return "Monoton"
        case .rubikBubbles: return "Rubik Bubbles"
        case .caveat: return "Caveat Bold"
        case .chillRoundFull: return "寒蝉全圆体"
        case .lxgwZhenKai: return "霞鹜臻楷"
        case .yozai: return "悠哉字体"
        case .lxgwMarkerGothic: return "霞鹜漫黑"
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
        case .chillRoundBold: return .bundled(file: "ChillRoundGothic-Bold.otf")
        case .chillRoundHeavy: return .bundled(file: "ChillRoundGothic-Heavy.otf")
        case .zcoolKuaiLe: return .bundled(file: "ZCOOLKuaiLe-Regular.ttf")
        case .zcoolQingKeHuangYou: return .bundled(file: "ZCOOLQingKeHuangYou-Regular.ttf")
        case .zcoolXiaoWei: return .bundled(file: "ZCOOLXiaoWei-Regular.ttf")
        case .maShanZheng: return .bundled(file: "MaShanZheng-Regular.ttf")
        case .smileySans: return .bundled(file: "SmileySans-Oblique.otf")
        case .zhiMangXing: return .bundled(file: "ZhiMangXing-Regular.ttf")
        case .longCang: return .bundled(file: "LongCang-Regular.ttf")
        case .liuJianMaoCao: return .bundled(file: "LiuJianMaoCao-Regular.ttf")
        case .fredoka: return .bundled(file: "Fredoka[wdth,wght].ttf", weight: 700)
        case .baloo2: return .bundled(file: "Baloo2[wght].ttf", weight: 800)
        case .chewy: return .bundled(file: "Chewy-Regular.ttf")
        case .shrikhand: return .bundled(file: "Shrikhand-Regular.ttf")
        case .bungee: return .bundled(file: "Bungee-Regular.ttf")
        case .bungeeShade: return .bundled(file: "BungeeShade-Regular.ttf")
        case .luckiestGuy: return .bundled(file: "LuckiestGuy-Regular.ttf")
        case .lilitaOne: return .bundled(file: "LilitaOne-Regular.ttf")
        case .berkshireSwash: return .bundled(file: "BerkshireSwash-Regular.ttf")
        case .oleoScript: return .bundled(file: "OleoScript-Bold.ttf")
        case .righteous: return .bundled(file: "Righteous-Regular.ttf")
        case .rampartOne: return .bundled(file: "RampartOne-Regular.ttf")
        case .monoton: return .bundled(file: "Monoton-Regular.ttf")
        case .rubikBubbles: return .bundled(file: "RubikBubbles-Regular.ttf")
        case .caveat: return .bundled(file: "Caveat[wght].ttf", weight: 700)
        case .chillRoundFull: return .bundled(file: "ChillRoundF.ttf")
        case .lxgwZhenKai: return .bundled(file: "LXGWZhenKaiGB-Regular.ttf")
        case .yozai: return .bundled(file: "Yozai-Medium.ttf")
        case .lxgwMarkerGothic: return .bundled(file: "LXGWMarkerGothic-Regular.ttf")
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
        var localRoot: URL?
    }
    private static let cache = Cache()

    /// Called on a worker: materialize the mutable library outside the signed bundle.
    /// Removed faces are never reseeded, including on the next launch.
    static func prepareLocalFiles(directory: URL, removed: Set<String>) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Complete copies before deletions: a missing restore resource must
        // not delete the current choice while the preference remains unchanged.
        for face in GreetingTypeface.allCases where !removed.contains(face.rawValue) {
            guard case let .bundled(file, _) = face.source else { continue }
            let target = directory.appendingPathComponent(file)
            guard !fm.fileExists(atPath: target.path) else { continue }
            guard let source = resourceRoot?.appendingPathComponent(file) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let staging = directory.appendingPathComponent(UUID().uuidString + ".tmp")
            defer { try? fm.removeItem(at: staging) }
            try fm.copyItem(at: source, to: staging)
            try fm.moveItem(at: staging, to: target)
        }
        for face in GreetingTypeface.allCases where removed.contains(face.rawValue) {
            guard case let .bundled(file, _) = face.source else { continue }
            let target = directory.appendingPathComponent(file)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        }
        cache.lock.lock()
        cache.localRoot = directory
        cache.descriptors.removeAll()
        cache.lines.removeAll()
        cache.lock.unlock()
    }

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
        if typeface.supportsChinese {
            return CTFontCreateWithName("PingFangSC-Semibold" as CFString, size, nil)
        }
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
            cache.lock.lock()
            let root = cache.localRoot ?? resourceRoot
            cache.lock.unlock()
            guard let url = root?.appendingPathComponent(file),
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
