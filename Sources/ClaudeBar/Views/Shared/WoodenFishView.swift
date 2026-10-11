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
        let reducedMotion = reduceMotion
        return Button(action: strike) {
            ZStack(alignment: .top) {
                WoodenFishArtwork(strikeID: model.strikeID)
                    .frame(width: 240, height: 180)
                    .padding(.top, 20)
                    .scaleEffect(model.isPressed && !reducedMotion ? 0.94 : 1, anchor: .bottom)
                    .animation(.easeOut(duration: 0.08), value: model.isPressed)
                    .brightness(model.isHovered ? 0.025 : 0)
                    .animation(.easeOut(duration: 0.16), value: model.isHovered)
                    .keyframeAnimator(initialValue: Impact(), trigger: model.strikeID) { view, value in
                        view.scaleEffect(reducedMotion ? 1 : value.scale, anchor: .bottom)
                            .rotationEffect(.degrees(reducedMotion ? 0 : value.angle), anchor: .bottom)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(0.88, duration: 0.045)
                            SpringKeyframe(1, duration: 0.34, spring: .bouncy)
                        }
                        KeyframeTrack(\.angle) {
                            LinearKeyframe(-2, duration: 0.07)
                            SpringKeyframe(0, duration: 0.28, spring: .snappy)
                        }
                    }
                WoodenFishBurstLayer(entries: bursts.entries, displayScale: model.size.scale) { bursts.expire($0) }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .frame(width: 240, height: 200)
            .scaleEffect(model.size.scale, anchor: .topLeading)
            .frame(width: 240 * model.size.scale, height: 200 * model.size.scale, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(WoodenFishPressStyle(scale: 0.98))
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel("敲一下木鱼")
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

    private struct Impact { var scale = 1.0; var angle = 0.0 }
}

private struct WoodenFishPressStyle: ButtonStyle {
    var scale = 0.92
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1, anchor: .bottom)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct WoodenFishBurstLayer: View {
    let entries: [WoodenFishBurstPool.Entry]
    let displayScale: CGFloat
    let expire: (UInt) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(entries) { entry in
                WoodenFishBurst(entry: entry, showsWord: !reduceMotion || entry.id == entries.last?.id,
                                displayScale: displayScale) { expire(entry.id) }
            }
        }
        .frame(width: 240, height: 200)
    }
}

private struct WoodenFishBurst: View {
    let entry: WoodenFishBurstPool.Entry
    let showsWord: Bool
    let displayScale: CGFloat
    let expire: () -> Void
    @State private var progress = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if showsWord {
                WoodenFishTokenLabel(isGolden: entry.feedback.isGolden, displayScale: displayScale,
                                     progress: progress, reducedMotion: reduceMotion)
                    .modifier(WoodenFishWordFlight(progress: progress, id: entry.id, displayScale: displayScale,
                                                  reducedMotion: reduceMotion))
            }
            if !reduceMotion && entry.feedback.combo >= 8 {
                ForEach([0, 2, 4], id: \.self) { lane in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(lane.isMultiple(of: 3) ? Color(hex: 0xFFAC7D) :
                              lane.isMultiple(of: 2) ? Color(hex: 0xFFF2CD) : Color(hex: 0xFFD58F))
                        .frame(width: 3 / displayScale, height: 3 / displayScale).rotationEffect(.degrees(45))
                        .modifier(WoodenFishParticleFlight(progress: progress, lane: lane, reducedMotion: false))
                }
            }
        }
        .frame(width: 240, height: 200)
        .offset(y: -9)
        .onAppear { withAnimation(.linear(duration: 1.35)) { progress = 1 } }
        .task {
            do { try await Task.sleep(for: .milliseconds(1420)) }
            catch { return }
            expire()
        }
    }
}

/// Floating lettering: a quiet word, a bold reward, and a short ink flourish.
/// The keyline follows the glyphs rather than enclosing them in a surface.
private struct WoodenFishTokenLabel: View {
    let isGolden: Bool
    let displayScale: CGFloat
    let progress: Double
    let reducedMotion: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var ink: Color {
        Color(hex: colorScheme == .dark ? (isGolden ? 0xFFE1A3 : 0xFFE9C6) :
                                 (isGolden ? 0xA8652C : 0x88451E))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3 / displayScale) {
            Text("功德")
                .font(.system(size: 10 / displayScale, weight: .semibold, design: .rounded))
                .tracking(0.15 / displayScale)
                .foregroundStyle(colorScheme == .dark ? ink : Color(hex: isGolden ? 0x824923 : 0x713517))
            Text("+1")
                .font(.system(size: 18 / displayScale, weight: .heavy, design: .rounded))
                .italic().monospacedDigit()
                .overlay(alignment: .bottom) {
                    if !reducedMotion {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: 3 / displayScale))
                            path.addQuadCurve(to: CGPoint(x: 20 / displayScale, y: 0),
                                              control: CGPoint(x: 9 / displayScale, y: 0))
                        }
                        .trim(from: 0, to: max(0, 1 - progress))
                        .stroke(ink.opacity(0.65), style: StrokeStyle(lineWidth: 1.2 / displayScale, lineCap: .round))
                        .frame(width: 20 / displayScale, height: 3 / displayScale)
                        .offset(y: 3 / displayScale)
                    }
                }
        }
        .foregroundStyle(ink)
        // A sub-point outline keeps bare lettering legible over desktop artwork.
        .shadow(color: edge, radius: 0, x: 0.65 / displayScale, y: 0)
        .shadow(color: edge, radius: 0, x: -0.65 / displayScale, y: 0)
        .shadow(color: edge, radius: 0, x: 0, y: 0.65 / displayScale)
        .shadow(color: edge, radius: 0, x: 0, y: -0.65 / displayScale)
    }

    private var edge: Color {
        Color(hex: colorScheme == .dark ? 0x101D24 : 0xF6FCFA).opacity(0.95)
    }
}

private struct WoodenFishWordFlight: AnimatableModifier {
    var progress: Double
    let id: UInt
    let displayScale: CGFloat
    let reducedMotion: Bool
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let value = WoodenFishMotion.word(progress: progress, id: id, reducedMotion: reducedMotion,
                                         displayScale: displayScale)
        return content.offset(x: value.offset.x / displayScale, y: value.offset.y / displayScale)
            .scaleEffect(value.scale).rotationEffect(.degrees(value.angle)).opacity(value.opacity)
    }
}

private struct WoodenFishParticleFlight: AnimatableModifier {
    var progress: Double
    let lane: Int
    let reducedMotion: Bool
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let motion = WoodenFishMotion.particle(progress: progress, lane: lane, reducedMotion: reducedMotion)
        return content.offset(x: motion.offset.x, y: motion.offset.y)
            .scaleEffect(motion.scale).rotationEffect(.degrees(motion.angle)).opacity(motion.opacity)
    }
}

/// Warm lacquer colours and a single recessed curl give the toy its identity.
/// The shared outer path is also the native pointer capture boundary.
struct WoodenFishArtwork: View {
    var strikeID: UInt = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let reducedMotion = reduceMotion
        return Canvas { context, size in
            context.scaleBy(x: size.width / 220, y: size.width / 220)
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

        }
        .overlay(alignment: .topTrailing) {
            WoodenFishMallet().frame(width: 74, height: 23)
                .rotationEffect(.degrees(-38)).offset(x: 7, y: 18)
                .keyframeAnimator(initialValue: MalletImpact(), trigger: strikeID) { view, value in
                    view.rotationEffect(.degrees(reducedMotion ? 0 : value.angle), anchor: .trailing)
                        .offset(y: reducedMotion ? 0 : value.drop)
                } keyframes: { _ in
                    KeyframeTrack(\.angle) {
                        LinearKeyframe(-24, duration: 0.045)
                        SpringKeyframe(7, duration: 0.16, spring: .snappy, startVelocity: 0)
                        CubicKeyframe(0, duration: 0.14)
                    }
                    KeyframeTrack(\.drop) {
                        LinearKeyframe(6, duration: 0.045)
                        SpringKeyframe(-2, duration: 0.16, spring: .snappy, startVelocity: 0)
                        CubicKeyframe(0, duration: 0.14)
                    }
                }
        }
        .accessibilityHidden(true)
    }


    private struct MalletImpact { var angle = 0.0; var drop = 0.0 }
}

private struct WoodenFishMallet: View {
    var body: some View {
        let inset = ceil(WoodenFishGeometry.malletWidth / 2) + 1
        return Canvas { context, _ in
            context.translateBy(x: inset, y: inset)
            WoodenFishLineStyle.stroke(Path(WoodenFishGeometry.malletHandlePath()), in: &context,
                                       ink: WoodenFishLineStyle.body, width: WoodenFishGeometry.malletStrokeWidth,
                                       fill: WoodenFishLineStyle.body)
            WoodenFishLineStyle.stroke(Path(WoodenFishGeometry.malletHeadPath()), in: &context,
                                       ink: WoodenFishLineStyle.malletHead, width: WoodenFishGeometry.malletStrokeWidth,
                                       fill: WoodenFishLineStyle.malletHead)
        }
        // An expanded drawing surface protects round caps from Canvas clipping.
        // Centering it in the original frame cancels the drawing translation,
        // preserving the mallet's rotation pivot and shared capture coordinates.
        .frame(width: 74 + inset * 2, height: 23 + inset * 2)
        .frame(width: 74, height: 23)
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
