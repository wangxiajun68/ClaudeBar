import SwiftUI
import AppKit

/// THESIS: the vector instrument itself floats on the desktop, without a card.
/// OWN-WORLD: jade fill, broad round contours and golden proportions; coral and gold details.
/// STORY: tap to strike; rapid manual taps reveal a word cloud and rhythm surprises.
/// FIRST VIEWPORT: wood/mallet only at rest; counts appear on hover; options live in the context menu.
/// FORM: a transparent, shaped desktop accessory; no idle decorative animation.
/// FINISH: unreviewed and undocumented is unfinished; this build ends with
/// the finish review, the verdict, and DESIGN.md.
struct WoodenFishView: View {
    @ObservedObject var model: WoodenFishModel
    @ObservedObject private var prefs = AppPreferences.shared
    let strike: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmReset = false
    @State private var bursts = WoodenFishBurstPool()

    private var showsCounts: Bool { model.isHovered || model.isAutomatic }

    var body: some View {
        VStack(spacing: 0) {
            // Reserve transparent space for the uppermost rapid-tap words.
            Color.clear.frame(height: 36).allowsHitTesting(false).accessibilityHidden(true)
            instrument
            counts
        }
        .frame(width: model.size.panelSize.width, height: model.size.panelSize.height, alignment: .topLeading)
        .preferredColorScheme(Theme.isDark ? .dark : .light)
        .alert("清空功德记录？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) { }
            Button("清空记录", role: .destructive) { bursts = .init(); model.resetCounts() }
        } message: { Text("今日与累计功德将归零，无法撤销。") }
        .onChange(of: model.strikeID) { previous, id in
            bursts.emit(from: previous, through: id, feedback: model.feedback)
        }
        .onExitCommand { model.isAutomatic = false; model.endInteraction() }
    }

    @ViewBuilder private var options: some View {
        Section("敲击控制") {
            Button(model.muted ? "开启音效" : "静音") { model.muted.toggle() }
            Button(model.isAutomatic ? "暂停自动敲击" : "开始自动敲击") { model.isAutomatic.toggle() }
        }
        Section("自动敲击间隔") {
            ForEach(WoodenFishModel.intervals, id: \.self) { interval in
                Button { model.interval = interval } label: {
                    Label("\(interval.formatted()) 秒", systemImage: model.interval == interval ? "checkmark" : "clock")
                }
            }
        }
        Section("木鱼大小") {
            ForEach(WoodenFishSize.allCases) { size in
                Button { model.size = size } label: {
                    Label(size.label, systemImage: model.size == size ? "checkmark" : "rectangle")
                }
            }
        }
        Divider()
        Button("清空功德记录…", role: .destructive) { confirmReset = true }
        Divider()
        Button("隐藏木鱼") { model.enabled = false }
    }

    private var instrument: some View {
        let reducedMotion = reduceMotion
        return Button(action: strike) {
            ZStack(alignment: .top) {
                WoodenFishArtwork(strikeID: model.strikeID)
                    .frame(width: 240, height: 180)
                    .padding(.top, 20)
                    .brightness(model.isHovered ? 0.025 : 0)
                    .animation(.easeOut(duration: 0.16), value: model.isHovered)
                    .keyframeAnimator(initialValue: Impact(), trigger: model.strikeID) { view, value in
                        view.scaleEffect(reducedMotion ? 1 : value.scale, anchor: .bottom)
                            .rotationEffect(.degrees(reducedMotion ? 0 : value.angle), anchor: .bottom)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(0.94, duration: 0.07)
                            SpringKeyframe(1, duration: 0.28, spring: .snappy)
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
        .contextMenu { options }
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel("敲一下木鱼")
        .accessibilityHint("每次敲击增加一份功德。空格敲击，按住 Option 拖动可移动，右键打开选项。")
        .help("点击或空格敲击 · ⌥拖动移动 · 右键选项 · Esc 暂停")
    }

    private var counts: some View {
        let celebration = bursts.celebration
        let combo = bursts.entries.last?.feedback.combo ?? 0
        return HStack(spacing: 5) {
            if let celebration {
                Text(celebration.message).foregroundStyle(Color(hex: 0xFFD58F))
            } else if combo >= 2 {
                Text("连击 \(combo) · 今日 \(model.today.formatted())")
            } else {
                Text("今日 \(model.today.formatted()) · 累计 \(model.total.formatted())")
            }
            if !model.soundAvailable {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xFFD58F))
            }
        }
        .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
        .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.black.opacity(0.72), in: Capsule())
        .frame(width: model.size.panelSize.width - 8, height: 28)
        .opacity(showsCounts || celebration != nil || combo >= 2 ? 1 : 0)
        .accessibilityLabel("今日功德 \(model.today)，累计功德 \(model.total)，连击 \(combo)" + (celebration.map { "，" + $0.message } ?? ""))
        .help(model.soundAvailable ? "连续手动敲击有连击彩蛋；每次只增加一份功德" : "音效不可用，请检查系统声音输出；仍可敲击计数")
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
            if !reduceMotion {
                ForEach([0, 2, 3, 4, 5, 6], id: \.self) { lane in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(lane.isMultiple(of: 3) ? Color(hex: 0xE3B8FF) :
                              lane.isMultiple(of: 2) ? Color(hex: 0x8CEAFF) : Color(hex: 0xFFD58F))
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
        Color(hex: colorScheme == .dark ? (isGolden ? 0xFFE1A3 : 0x91EEE2) :
                                 (isGolden ? 0xA8652C : 0x1D7C86))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3 / displayScale) {
            Text("Token")
                .font(.system(size: 10 / displayScale, weight: .semibold, design: .rounded))
                .tracking(0.15 / displayScale)
                .foregroundStyle(colorScheme == .dark ? ink : Color(hex: isGolden ? 0x824923 : 0x18565D))
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

/// A solid-colour vector instrument with broad round contours, a split lip
/// and a mallet. Only the surrounding desktop remains transparent.
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
            var lip = Path()
            lip.move(to: CGPoint(x: 151, y: 83))
            lip.addCurve(to: CGPoint(x: 170, y: 91),
                         control1: CGPoint(x: 167, y: 83), control2: CGPoint(x: 176, y: 86))
            lip.addCurve(to: CGPoint(x: 151, y: 110),
                         control1: CGPoint(x: 166, y: 98), control2: CGPoint(x: 157, y: 106))
            WoodenFishLineStyle.stroke(lip, in: &context, ink: WoodenFishLineStyle.carving, width: 10)
            var incision = Path()
            incision.move(to: CGPoint(x: 62, y: 88))
            incision.addCurve(to: CGPoint(x: 109, y: 68),
                              control1: CGPoint(x: 73, y: 70), control2: CGPoint(x: 88, y: 66))
            WoodenFishLineStyle.stroke(incision, in: &context, ink: WoodenFishLineStyle.accent, width: 8)
            WoodenFishLineStyle.stroke(Path(WoodenFishGeometry.eyePath()),
                                       in: &context, ink: WoodenFishLineStyle.carving, width: 5.2, fill: WoodenFishLineStyle.carving)

        }
        .overlay(alignment: .topTrailing) {
            WoodenFishMallet().frame(width: 74, height: 23)
                .rotationEffect(.degrees(-38)).offset(x: 7, y: 18)
                .keyframeAnimator(initialValue: MalletImpact(), trigger: strikeID) { view, value in
                    view.rotationEffect(.degrees(reducedMotion ? 0 : value.angle), anchor: .trailing)
                        .offset(y: reducedMotion ? 0 : value.drop)
                } keyframes: { _ in
                    KeyframeTrack(\.angle) {
                        CubicKeyframe(20, duration: 0.08)
                        LinearKeyframe(-24, duration: 0.075)
                        SpringKeyframe(7, duration: 0.16, spring: .snappy, startVelocity: 0)
                        CubicKeyframe(0, duration: 0.14)
                    }
                    KeyframeTrack(\.drop) {
                        CubicKeyframe(-7, duration: 0.08)
                        LinearKeyframe(6, duration: 0.075)
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
    static var bodyFill: Color { Theme.isDark ? Color(hex: 0x245D60) : Color(hex: 0xBDDCD1) }
    static var body: Color { Theme.isDark ? Color(hex: 0x68CDC7) : Color(hex: 0x23828C) }
    static var accent: Color { Theme.isDark ? Color(hex: 0x9ECFC3) : Color(hex: 0x478C82) }
    static var carving: Color { Theme.isDark ? Color(hex: 0xF29B86) : Color(hex: 0xB85B49) }
    static var malletHead: Color { Theme.isDark ? Color(hex: 0xE4BF77) : Color(hex: 0xAD7A32) }
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
