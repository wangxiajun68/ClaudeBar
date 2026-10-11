import SwiftUI
import AppKit

/// A tactile desktop object with only two pointer actions: strike and drag.
struct WoodenFishView: View {
    @ObservedObject var model: WoodenFishModel
    @ObservedObject private var prefs = AppPreferences.shared
    let strike: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bursts = WoodenFishBurstPool()

    private var showsCounts: Bool { model.isHovered || model.isAutomatic }

    var body: some View {
        VStack(spacing: 0) {
            // Reserve transparent space for the uppermost rapid-tap words.
            Color.clear.frame(height: 36).allowsHitTesting(false).accessibilityHidden(true)
            instrument
            counts
        }
        .frame(width: model.size.panelSize.width, height: model.size.panelSize.height, alignment: .top)
        .preferredColorScheme(Theme.isDark ? .dark : .light)
        .onChange(of: model.strikeID) { previous, id in
            bursts.emit(from: previous, through: id, feedback: model.feedback)
        }
        .onExitCommand { model.isAutomatic = false; model.endInteraction() }
        .onChange(of: model.isAutomatic) { _, _ in bursts = .init() }
        .onChange(of: model.total) { _, count in if count == 0 { bursts = .init() } }
    }

    private var instrument: some View {
        Button(action: strike) {
            WoodenFishScene(entries: bursts.entries, displayScale: model.size.scale,
                            isPressed: model.isPressed) { bursts.expire($0) }
            .frame(width: 260, height: 200)
            .scaleEffect(model.size.scale, anchor: .topLeading)
            .frame(width: 260 * model.size.scale, height: 200 * model.size.scale, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel("敲一下木鱼")
        .accessibilityValue("今日功德 \(model.today)，累计功德 \(model.total)")
        .accessibilityHint("每次敲击增加一份功德。拖动木鱼可移动，空格敲击，Esc 暂停。音效和节奏在应用设置中调整。")
        .help("点击敲击 · 直接拖动移动 · 空格敲击 · Esc 暂停")
    }

    private var counts: some View {
        let combo = bursts.entries.last?.feedback.combo ?? 0
        return VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("今日").font(.system(size: 10, weight: .medium))
                Text(model.today.formatted()).font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit().contentTransition(.numericText())
            }
            Text(bursts.celebration?.message ?? (combo >= 2 ? "连击 ×\(combo)" :
                 !model.soundAvailable ? "音效不可用 · 请检查输出" : model.isAutomatic ? "自动 · 每 \(model.interval.formatted()) 秒" : "累计 \(model.total.formatted())"))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color(hex: 0xFFE0A6))
        }
        .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.75)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color(hex: 0x29221C).opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
        .frame(width: model.size.panelSize.width - 8, height: 36)
        .opacity(showsCounts || !bursts.entries.isEmpty ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日功德 \(model.today)，累计功德 \(model.total)")
        .accessibilityHidden(!showsCounts && bursts.entries.isEmpty)
    }

}

/// A single, bounded drawing pass replaces independent animated text subtrees.
/// No refresh task exists at rest; fast tapping never adds more than four entries.
private struct WoodenFishScene: View {
    let entries: [WoodenFishBurstPool.Entry]
    let displayScale: CGFloat
    let isPressed: Bool
    @State private var frameDate = Date()
    let expire: (UInt) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        scene(at: entries.isEmpty ? .distantFuture : frameDate)
            .frame(width: 260, height: 200)
            .task(id: entries.last?.id) {
                guard let latest = entries.last else { return }
                frameDate = Date()
                do {
                    // Explicit sleep bounds work even when the hosting window's
                    // display cycle runs faster than the requested frame rate.
                    while Date().timeIntervalSince(latest.createdAt) < 1.42 {
                        try await Task.sleep(for: .milliseconds(34))
                        frameDate = Date()
                    }
                } catch { return }
                for entry in entries { expire(entry.id) }
            }
    }

    private func scene(at date: Date) -> some View {
        Canvas { context, _ in
            // Include the mallet's outer caps in the drawing surface. The shared
            // hit geometry places the instrument ten points into this canvas.
            context.translateBy(x: 10, y: 0)
            let age = entries.last.map { date.timeIntervalSince($0.createdAt) } ?? 10
            let impact: Double = reduceMotion || age >= 0.4 ? 0 :
                age < 0.045 ? max(0, age / 0.045) : exp(-(age - 0.045) * 14) * cos((age - 0.045) * 23)
            var instrument = context
            instrument.translateBy(x: 120, y: 200)
            let press = isPressed && !reduceMotion ? 0.94 : 1.0
            instrument.scaleBy(x: press * (1 - 0.10 * impact), y: press * (1 - 0.13 * impact))
            instrument.rotate(by: .degrees(-1.5 * impact))
            instrument.translateBy(x: -120, y: -200)
            WoodenFishArtwork.draw(in: &instrument, impact: impact)
            for entry in entries {
                let progress = max(0, date.timeIntervalSince(entry.createdAt)) / 1.35
                guard progress >= 0, progress < 1,
                      !reduceMotion || entry.id == entries.last?.id else { continue }
                let motion = WoodenFishMotion.word(progress: progress, id: entry.id,
                    reducedMotion: reduceMotion, displayScale: displayScale)
                var word = context
                word.translateBy(x: 120 + motion.offset.x / displayScale,
                                 y: 91 + motion.offset.y / displayScale)
                word.rotate(by: .degrees(motion.angle))
                word.scaleBy(x: motion.scale, y: motion.scale)
                word.opacity = reduceMotion ? max(0, min(1, (1 - progress) / 0.35)) : motion.opacity
                word.addFilter(.shadow(color: Color(hex: 0x382317).opacity(0.85),
                                       radius: 0.6 / displayScale, x: 0, y: 1 / displayScale))
                let ink = entry.feedback.isGolden ? Color(hex: 0xFFE0A6) : Color(hex: 0xFFF6E7)
                word.draw(Text("功德").font(.system(size: 10 / displayScale, weight: .semibold))
                    .foregroundColor(ink), at: CGPoint(x: -10 / displayScale, y: 0))
                word.draw(Text("+1").font(.system(size: 18 / displayScale, weight: .bold, design: .rounded))
                    .foregroundColor(ink), at: CGPoint(x: 14 / displayScale, y: -2 / displayScale))
                if !reduceMotion && entry.feedback.combo >= 8 {
                    for lane in [0, 2, 4] {
                        let particle = WoodenFishMotion.particle(progress: progress, lane: lane, reducedMotion: false)
                        var spark = context
                        spark.opacity = particle.opacity
                        let point = CGPoint(x: 120 + particle.offset.x, y: 91 + particle.offset.y)
                        spark.fill(Path(ellipseIn: CGRect(x: point.x, y: point.y,
                            width: 2.5 / displayScale, height: 2.5 / displayScale)), with: .color(ink))
                    }
                }
            }
        }
    }
}

/// Warm lacquer colours and a single recessed curl give the toy its identity.
/// The shared outer path is also the native pointer capture boundary.
private enum WoodenFishArtwork {
    static func draw(in original: inout GraphicsContext, impact: Double) {
        var context = original
        context.translateBy(x: 0, y: 20)
        context.scaleBy(x: 240.0 / 220, y: 240.0 / 220)
        WoodenFishLineStyle.stroke(Path(WoodenFishGeometry.basePath()), in: &context,
                                   ink: WoodenFishLineStyle.accent, width: WoodenFishGeometry.baseStrokeWidth)
        WoodenFishLineStyle.stroke(Path(WoodenFishGeometry.bodyPath()), in: &context,
                                   ink: WoodenFishLineStyle.body, width: WoodenFishGeometry.bodyStrokeWidth,
                                   fill: WoodenFishLineStyle.bodyFill)
        // One continuous recessed carving connects the mouth and its curl.
        var carving = Path()
        carving.move(to: CGPoint(x: 186, y: 99))
        carving.addCurve(to: CGPoint(x: 120, y: 110),
                         control1: CGPoint(x: 166, y: 96), control2: CGPoint(x: 145, y: 117))
        carving.addCurve(to: CGPoint(x: 128, y: 77),
                         control1: CGPoint(x: 94, y: 100), control2: CGPoint(x: 104, y: 77))
        carving.addCurve(to: CGPoint(x: 139, y: 98),
                         control1: CGPoint(x: 151, y: 76), control2: CGPoint(x: 155, y: 99))
        context.stroke(carving, with: .color(WoodenFishLineStyle.carving),
                       style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
        var grain = Path()
        grain.move(to: CGPoint(x: 54, y: 82))
        grain.addCurve(to: CGPoint(x: 101, y: 61),
                       control1: CGPoint(x: 64, y: 66), control2: CGPoint(x: 82, y: 60))
        context.stroke(grain, with: .color(WoodenFishLineStyle.accent),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round))

        var mallet = original
        mallet.translateBy(x: 247, y: 49.5 + 6 * impact)
        mallet.rotate(by: .degrees(-24 * impact))
        mallet.translateBy(x: -37, y: 0)
        mallet.rotate(by: .degrees(-38))
        mallet.translateBy(x: -37, y: -11.5)
        WoodenFishLineStyle.stroke(Path(WoodenFishGeometry.malletHandlePath()), in: &mallet,
            ink: WoodenFishLineStyle.body, width: WoodenFishGeometry.malletStrokeWidth,
            fill: WoodenFishLineStyle.body)
        WoodenFishLineStyle.stroke(Path(WoodenFishGeometry.malletHeadPath()), in: &mallet,
            ink: WoodenFishLineStyle.malletHead, width: WoodenFishGeometry.malletStrokeWidth,
            fill: WoodenFishLineStyle.malletHead)
    }
}

/// A narrow contrasting keyline keeps the drawing visible on wallpapers.
/// Both strokes follow one path; the solid instrument has no shadow or panel.
private enum WoodenFishLineStyle {
    static var bodyFill: Color { Theme.isDark ? Color(hex: 0xD99558) : Color(hex: 0xF5CC91) }
    static var body: Color { Theme.isDark ? Color(hex: 0xFFE1AA) : Color(hex: 0x764426) }
    static var accent: Color { Theme.isDark ? Color(hex: 0xFCE0AD) : Color(hex: 0xB57B40) }
    static var carving: Color { Theme.isDark ? Color(hex: 0x69361F) : Color(hex: 0x884725) }
    static var malletHead: Color { Theme.isDark ? Color(hex: 0xF5D09B) : Color(hex: 0xDB9B52) }
    private static var keyline: Color {
        Theme.isDark ? Color(hex: 0x101D24, opacity: 0.90) : Color(hex: 0xF6FCFA, opacity: 0.90)
    }
    static func stroke(_ path: Path, in context: inout GraphicsContext, ink: Color, width: CGFloat, fill: Color? = nil) {
        context.stroke(path, with: .color(keyline),
                       style: StrokeStyle(lineWidth: width + WoodenFishGeometry.keylineWidth, lineCap: .round, lineJoin: .round))
        // Opaque fill covers the inner keyline so solid parts have no hollow rings.
        if let fill { context.fill(path, with: .color(fill)) }
        context.stroke(path, with: .color(ink),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}
