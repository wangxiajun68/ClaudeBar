import SwiftUI
import AppKit

/// THESIS: the vector instrument itself floats on the desktop, without a card.
/// OWN-WORLD: amber wood, curved grain, a jade cushion and transparent margins.
/// STORY: tap the wood to strike; hover reveals a small row of native tools.
/// FIRST VIEWPORT: wood/mallet only at rest; tools and counts appear on hover.
/// FORM: a transparent, shaped desktop accessory; no idle decorative animation.
/// FINISH: unreviewed and undocumented is unfinished; this build ends with
/// the finish review, the verdict, and DESIGN.md.
struct WoodenFishView: View {
    @ObservedObject var model: WoodenFishModel
    @ObservedObject private var prefs = AppPreferences.shared
    let strike: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmReset = false

    private var showsTools: Bool { model.isHovered || model.isAutomatic }

    var body: some View {
        VStack(spacing: 0) {
            tools
            instrument
            counts
        }
        .frame(width: model.size.panelSize.width, height: model.size.panelSize.height, alignment: .topLeading)
        .preferredColorScheme(Theme.isDark ? .dark : .light)
        .alert("清空功德记录？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) { }
            Button("清空记录", role: .destructive) { model.resetCounts() }
        } message: { Text("今日与累计功德将归零，无法撤销。") }
    }

    private var tools: some View {
        HStack(spacing: 4) {
            WoodenFishDragHandle().frame(width: 26, height: 26)
                .background(Color.black.opacity(0.72), in: Circle())
                .help("拖动把手移动木鱼")
                .accessibilityLabel("拖动悬浮木鱼")
            Button { model.muted.toggle() } label: {
                controlGlyph(model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }.buttonStyle(.plain)
                .accessibilityLabel(model.muted ? "开启木鱼音效" : "静音木鱼")
                .help(model.muted ? "开启音效" : "静音")
            Button { model.isAutomatic.toggle() } label: {
                controlGlyph(model.isAutomatic ? "pause.fill" : "play.fill",
                             color: model.isAutomatic ? Theme.chartGreen : .white)
            }.buttonStyle(.plain)
                .accessibilityLabel(model.isAutomatic ? "暂停自动敲击" : "开始自动敲击")
                .help(model.isAutomatic ? "暂停自动敲击" : "每 \(model.interval.formatted()) 秒自动敲击")
            Menu {
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
            } label: { Color.clear.frame(width: 26, height: 26) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(width: 26, height: 26)
            .overlay { controlGlyph("ellipsis").allowsHitTesting(false).accessibilityHidden(true) }
            .accessibilityLabel("木鱼选项").help("节奏、大小与功德记录")
            Button { model.enabled = false } label: { controlGlyph("xmark") }
                .buttonStyle(.plain).help("隐藏木鱼，可在设置中重新开启")
                .accessibilityLabel("隐藏桌面木鱼")
        }
        .frame(width: model.size.panelSize.width, height: 36)
        .opacity(showsTools ? 1 : 0)
        .allowsHitTesting(showsTools)
        .accessibilityHidden(!showsTools)
    }

    private var instrument: some View {
        let reducedMotion = reduceMotion
        return Button(action: strike) {
            ZStack(alignment: .top) {
                WoodenFishArtwork(strikeID: model.strikeID)
                    .frame(width: 240, height: 180)
                    .padding(.top, 20)
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
                WoodenFishBurstLayer(strikeID: model.strikeID, displayScale: model.size.scale)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .frame(width: 240, height: 200)
            .scaleEffect(model.size.scale, anchor: .topLeading)
            .frame(width: 240 * model.size.scale, height: 200 * model.size.scale, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel("敲一下木鱼")
        .accessibilityHint("每次敲击增加一份功德。也可按空格。")
        .help("点击敲击 · 悬停显示工具 · 空格也可以")
    }

    private var counts: some View {
        HStack(spacing: 5) {
            Text("今日 \(model.today.formatted()) · 累计 \(model.total.formatted())")
            if !model.soundAvailable {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xFFD58F))
            }
        }
            .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
            .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.black.opacity(0.72), in: Capsule())
            .frame(width: model.size.panelSize.width - 8, height: 28)
            .opacity(showsTools ? 1 : 0)
            .accessibilityLabel("今日功德 \(model.today)，累计功德 \(model.total)")
            .help(model.soundAvailable ? "今日与累计功德" : "音效不可用，请检查系统声音输出；仍可敲击计数")
    }

    private func controlGlyph(_ name: String, color: Color = .white) -> some View {
        Image(systemName: name).font(.system(size: 12, weight: .medium))
            .foregroundStyle(color).frame(width: 26, height: 26)
            .background(Color.black.opacity(0.72), in: Circle())
            .contentShape(Circle())
    }

    private struct Impact { var scale = 1.0; var angle = 0.0 }
}

private struct WoodenFishBurstLayer: View {
    let strikeID: UInt
    let displayScale: CGFloat
    @State private var pool = WoodenFishBurstPool()

    var body: some View {
        ZStack {
            ForEach(pool.ids, id: \.self) { id in
                WoodenFishBurst(strikeID: id, displayScale: displayScale) {
                    pool.expire(id)
                }
            }
        }
        .frame(width: 240, height: 200)
        .onChange(of: strikeID) { _, id in pool.emit(id) }
    }
}

private struct WoodenFishBurst: View {
    let strikeID: UInt
    let displayScale: CGFloat
    let expire: () -> Void
    @State private var progress = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(reduceMotion ? [1] : Array(0..<7), id: \.self) { lane in
                Group {
                    if lane == 1 {
                        Text("Token +1")
                            .font(.system(size: 12 / displayScale, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(hex: 0x8CEAFF))
                            .padding(.horizontal, 6 / displayScale).padding(.vertical, 3 / displayScale)
                            .background(Color.black.opacity(0.72), in: Capsule())
                    } else {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(lane.isMultiple(of: 3) ? Color(hex: 0xE3B8FF) :
                                  lane.isMultiple(of: 2) ? Color(hex: 0x8CEAFF) : Color(hex: 0xFFD58F))
                            .frame(width: 3 / displayScale, height: 3 / displayScale).rotationEffect(.degrees(45))
                    }
                }
                // Successive words take left/centre/right paths so native-size
                // labels remain separated above the smaller instrument.
                .modifier(WoodenFishParticleFlight(progress: progress,
                                                   lane: lane == 1 ? Int(strikeID % 3) : lane,
                                                   reducedMotion: reduceMotion))
            }
        }
        .frame(width: 240, height: 200)
        .offset(y: -9)
        .onAppear { withAnimation(.easeOut(duration: 0.85)) { progress = 1 } }
        .task {
            do { try await Task.sleep(for: .milliseconds(920)) }
            catch { return }
            expire()
        }
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

/// Native vector artwork scales crisply at all three sizes. The curved grain
/// is clipped to the resonator; the dark mouth is a carved slit, not a glyph.
struct WoodenFishArtwork: View {
    var strikeID: UInt = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let reducedMotion = reduceMotion
        return Canvas { context, size in
            context.scaleBy(x: size.width / 220, y: size.height / 172)
            let ground = CGRect(x: 41, y: 139, width: 148, height: 13)
            context.fill(Path(ellipseIn: ground), with: .color(.black.opacity(0.13)))
            let cushion = Path(WoodenFishGeometry.cushionPath())
            context.fill(cushion, with: .linearGradient(
                Gradient(colors: [Color(hex: 0x819889), Color(hex: 0x4A6859), Color(hex: 0x263E34)]),
                startPoint: CGPoint(x: 90, y: 125), endPoint: CGPoint(x: 100, y: 148)))
            var fabric = context
            fabric.clip(to: cushion)
            for index in 0..<9 {
                let x = CGFloat(index) * 18 + 36
                var fold = Path()
                fold.move(to: CGPoint(x: x, y: 127))
                fold.addQuadCurve(to: CGPoint(x: x + 10, y: 148), control: CGPoint(x: x - 2, y: 137))
                fabric.stroke(fold, with: .color(Color(hex: 0xC2D0BF, opacity: 0.10)), lineWidth: 0.6)
            }
            context.stroke(Path(WoodenFishGeometry.cushionRimPath()),
                           with: .color(Color(hex: 0xB7C6AE, opacity: 0.65)),
                           style: StrokeStyle(lineWidth: 0.65, lineCap: .round, dash: [1.5, 2.5]))
            let wood = Path(WoodenFishGeometry.bodyPath())
            var resonator = context
            resonator.addFilter(.shadow(color: .black.opacity(0.24), radius: 3, x: 0, y: 3))
            resonator.fill(wood, with: .linearGradient(
                Gradient(stops: [.init(color: Color(hex: 0xDDB378), location: 0),
                                 .init(color: Color(hex: 0xBE864C), location: 0.30),
                                 .init(color: Color(hex: 0x925529), location: 0.66),
                                 .init(color: Color(hex: 0x56311F), location: 1)]),
                startPoint: CGPoint(x: 70, y: 39), endPoint: CGPoint(x: 137, y: 141)))
            var grain = context
            grain.clip(to: wood)
            grain.fill(wood, with: .radialGradient(
                Gradient(colors: [Color(hex: 0xFFDFAC, opacity: 0.36), .clear]),
                center: CGPoint(x: 76, y: 62), startRadius: 0, endRadius: 93))
            // Sparse, unequal curves read as carved timber at desktop scale.
            for (index, y) in [55.0, 67, 80, 94, 109, 123].enumerated() {
                var line = Path()
                line.move(to: CGPoint(x: 29, y: y))
                line.addCurve(to: CGPoint(x: 204, y: y + 13),
                              control1: CGPoint(x: 72, y: y - 19 + Double(index)),
                              control2: CGPoint(x: 143, y: y + 27 - Double(index)))
                grain.stroke(line, with: .color(Color(hex: 0x64351C, opacity: index.isMultiple(of: 2) ? 0.22 : 0.12)),
                             lineWidth: index.isMultiple(of: 2) ? 0.8 : 0.45)
                grain.stroke(line.offsetBy(dx: 0, dy: 1),
                             with: .color(Color(hex: 0xF1CB92, opacity: 0.10)), lineWidth: 0.45)
            }
            for index in 0..<2 {
                let inset = CGFloat(index) * 6
                let knot = Path(ellipseIn: CGRect(x: 66 + inset, y: 87 + inset * 0.5,
                                                 width: 46 - inset * 2, height: 25 - inset))
                grain.stroke(knot, with: .color(Color(hex: 0x6B3D22, opacity: 0.15)), lineWidth: 0.65)
            }
            context.stroke(wood, with: .color(Color(hex: 0x6F4327, opacity: 0.28)), lineWidth: 0.7)
            var crown = Path()
            crown.move(to: CGPoint(x: 46, y: 74))
            crown.addCurve(to: CGPoint(x: 147, y: 53), control1: CGPoint(x: 64, y: 45), control2: CGPoint(x: 112, y: 42))
            context.stroke(crown, with: .color(Color(hex: 0xFFE0AD, opacity: 0.70)),
                           style: StrokeStyle(lineWidth: 1.15, lineCap: .round))
            var mouth = Path()
            mouth.move(to: CGPoint(x: 166, y: 70))
            mouth.addCurve(to: CGPoint(x: 190, y: 85), control1: CGPoint(x: 188, y: 71), control2: CGPoint(x: 200, y: 79))
            mouth.addCurve(to: CGPoint(x: 154, y: 105), control1: CGPoint(x: 184, y: 94), control2: CGPoint(x: 161, y: 96))
            mouth.addQuadCurve(to: CGPoint(x: 153, y: 100), control: CGPoint(x: 149, y: 105))
            mouth.addCurve(to: CGPoint(x: 184, y: 83), control1: CGPoint(x: 165, y: 90), control2: CGPoint(x: 183, y: 91))
            mouth.addQuadCurve(to: CGPoint(x: 166, y: 70), control: CGPoint(x: 193, y: 78))
            context.fill(mouth, with: .linearGradient(
                Gradient(colors: [Color(hex: 0x24180F), Color(hex: 0x4C2C1A)]),
                startPoint: CGPoint(x: 180, y: 76), endPoint: CGPoint(x: 157, y: 104)))
            context.stroke(mouth, with: .color(Color(hex: 0xE8B77B, opacity: 0.50)), lineWidth: 0.65)
            context.fill(Path(ellipseIn: CGRect(x: 163, y: 59, width: 4, height: 4)), with: .color(Color(hex: 0x714628)))
            context.stroke(Path(ellipseIn: CGRect(x: 162.5, y: 58.5, width: 5, height: 5)),
                           with: .color(Color(hex: 0xE9BE86, opacity: 0.65)), lineWidth: 0.55)

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
        Canvas { context, _ in
            context.fill(Path(WoodenFishGeometry.malletHandlePath()), with: .linearGradient(
                Gradient(colors: [Color(hex: 0xEAC58C), Color(hex: 0xA66831)]),
                startPoint: CGPoint(x: 40, y: 8), endPoint: CGPoint(x: 40, y: 15)))
            let head = Path(WoodenFishGeometry.malletHeadPath())
            context.fill(head, with: .linearGradient(
                Gradient(colors: [Color(hex: 0xF0D3A4), Color(hex: 0xB67D45), Color(hex: 0x734423)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 24, y: 22)))
            context.stroke(head, with: .color(Color(hex: 0x74411D, opacity: 0.35)), lineWidth: 0.65)
            var sheen = Path()
            sheen.addArc(center: CGPoint(x: 12, y: 11.5), radius: 8,
                         startAngle: .degrees(205), endAngle: .degrees(285), clockwise: false)
            context.stroke(sheen, with: .color(Color(hex: 0xFFF0CC, opacity: 0.55)),
                           style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            let handleSheen = Path(roundedRect: CGRect(x: 24, y: 9.1, width: 45, height: 0.7), cornerRadius: 0.35)
            context.fill(handleSheen, with: .color(Color(hex: 0xFFE6BB, opacity: 0.55)))
        }
        .shadow(color: .black.opacity(0.2), radius: 2, x: 1, y: 3)
    }
}

private struct WoodenFishDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ nsView: Handle, context: Context) { }

    final class Handle: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.withAlphaComponent(0.9).setFill()
            for x in [10.0, 15.0] {
                for y in [8.0, 13.0, 18.0] {
                    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2, height: 2)).fill()
                }
            }
        }
    }
}
