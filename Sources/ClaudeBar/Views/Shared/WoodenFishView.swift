import SwiftUI
import AppKit

/// THESIS: a tactile wooden instrument, with one obvious place to strike.
/// OWN-WORLD: the app's ice/graphite surfaces and SF Rounded controls; amber
/// wood and a jade cushion belong to the object, not a new app palette.
/// STORY: drag it beside your work, tap, hear a short knock, see merit rise.
/// FIRST VIEWPORT: grip/title, floating merit, a large woodcut, counts, controls.
/// FORM: a compact native desktop accessory; no continuous decorative motion.
/// FINISH: unreviewed and undocumented is unfinished; this build ends with
/// the finish review, the verdict, and DESIGN.md.
struct WoodenFishView: View {
    @ObservedObject var model: WoodenFishModel
    @ObservedObject private var prefs = AppPreferences.shared
    let strike: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: 0) {
            header
            instrument
            counts
            controls
        }
        .padding(.horizontal, 18)
        .padding(.top, 14).padding(.bottom, 16)
        .frame(width: 240, height: 310)
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Theme.hairline))
        .compositingGroup()
        .shadow(color: .black.opacity(Theme.isDark ? 0.28 : 0.13), radius: 9, x: 0, y: 5)
        .padding(10)
        .scaleEffect(model.size.scale, anchor: .topLeading)
        .frame(width: model.size.panelSize.width, height: model.size.panelSize.height, alignment: .topLeading)
        .preferredColorScheme(Theme.isDark ? .dark : .light)
        .alert("清空功德记录？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) { }
            Button("清空记录", role: .destructive) { model.resetCounts() }
        } message: { Text("今日与累计功德将归零，无法撤销。") }
    }

    private var header: some View {
        HStack(spacing: 8) {
            WoodenFishDragHandle().frame(width: 22, height: 26)
                .help("拖动木鱼到桌面任意位置")
                .accessibilityLabel("拖动悬浮木鱼")
            Text("木鱼").font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Menu {
                Section("自动敲击间隔") {
                    ForEach(WoodenFishModel.intervals, id: \.self) { interval in
                        Button {
                            model.interval = interval
                        } label: {
                            Label("\(interval.formatted()) 秒", systemImage: model.interval == interval ? "checkmark" : "clock")
                        }
                    }
                }
                Section("悬浮窗大小") {
                    ForEach(WoodenFishSize.allCases) { size in
                        Button { model.size = size } label: {
                            Label(size.label, systemImage: model.size == size ? "checkmark" : "rectangle")
                        }
                    }
                }
                Divider()
                Button("清空功德记录…", role: .destructive) { confirmReset = true }
            } label: { controlGlyph("ellipsis", color: Theme.textSecondary) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .accessibilityLabel("木鱼选项").help("节奏、大小与功德记录")
            Button { model.enabled = false } label: {
                controlGlyph("xmark", color: Theme.textSecondary)
            }
            .buttonStyle(.plain).help("隐藏木鱼，可在设置中重新开启")
            .accessibilityLabel("隐藏桌面木鱼")
        }
        .frame(height: 28)
    }

    private var instrument: some View {
        let reducedMotion = reduceMotion
        return Button(action: strike) {
            ZStack(alignment: .top) {
                WoodenFishArtwork(strikeID: model.strikeID)
                    .frame(width: 204, height: 152)
                    .padding(.top, 12)
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
                Text("功德 +1")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.Ink.warning)
                    .keyframeAnimator(initialValue: Merit(), trigger: model.strikeID) { view, value in
                        view.opacity(value.opacity).offset(y: reducedMotion ? 0 : value.rise)
                    } keyframes: { _ in
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(1, duration: 0.04)
                            LinearKeyframe(1, duration: 0.2)
                            LinearKeyframe(0, duration: 0.42)
                        }
                        KeyframeTrack(\.rise) {
                            LinearKeyframe(4, duration: 0.01)
                            CubicKeyframe(-12, duration: 0.65)
                        }
                    }
            }
            .frame(width: 204, height: 164)
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel("敲一下木鱼")
        .accessibilityHint("每次敲击增加一份功德。也可按空格。")
        .help("点击敲击 · 空格也可以")
    }

    private var counts: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            counter("今日功德", value: model.today)
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 27).padding(.horizontal, 16)
            counter("累计功德", value: model.total)
        }
        .padding(.top, 3).padding(.bottom, 16)
    }

    private func counter(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textSecondary)
            Text(value.formatted()).font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(Theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { model.muted.toggle() } label: {
                controlGlyph(model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                             color: Theme.textSecondary)
                    .frame(width: 34, height: 30)
                    .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain)
                .accessibilityLabel(model.muted ? "开启木鱼音效" : "静音木鱼")
                .help(model.muted ? "开启音效" : "静音")
            Button { model.isAutomatic.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: model.isAutomatic ? "pause.fill" : "play.fill").font(.system(size: 10))
                    Text(model.isAutomatic ? "暂停自动" : "自动敲击")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Spacer(minLength: 0)
                    Text("\(model.interval.formatted())s").font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                }
                .foregroundStyle(model.isAutomatic ? Theme.Ink.success : Theme.textPrimary)
                .padding(.horizontal, 11).frame(height: 30)
                .background(model.isAutomatic ? Theme.chartGreen.opacity(0.12) : Theme.bgSecondary,
                            in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain)
                .accessibilityLabel(model.isAutomatic ? "暂停自动敲击" : "开始自动敲击")
        }
        .overlay(alignment: .bottom) {
            if !model.soundAvailable {
                Text("音效不可用，仍可敲击计数").font(.system(size: 9))
                    .foregroundStyle(Theme.Ink.warning).offset(y: 14)
            }
        }
    }

    private func controlGlyph(_ name: String, color: Color) -> some View {
        Image(systemName: name).font(.system(size: 12, weight: .medium))
            .foregroundStyle(color).frame(width: 28, height: 28).contentShape(Rectangle())
    }

    private struct Impact { var scale = 1.0; var angle = 0.0 }
    private struct Merit { var opacity = 0.0; var rise = 4.0 }
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
            let ground = CGRect(x: 26, y: 139, width: 163, height: 18)
            context.fill(Path(ellipseIn: ground), with: .color(.black.opacity(0.10)))
            let cushion = Path(roundedRect: CGRect(x: 29, y: 121, width: 163, height: 26), cornerRadius: 13)
            context.fill(cushion, with: .linearGradient(
                Gradient(colors: [Color(hex: 0x729B8E), Color(hex: 0x375F53)]),
                startPoint: CGPoint(x: 100, y: 122), endPoint: CGPoint(x: 100, y: 148)))
            context.stroke(Path(ellipseIn: CGRect(x: 35, y: 118, width: 151, height: 20)),
                           with: .color(Color(hex: 0xA7C4B2)), lineWidth: 1.5)
            let wood = bodyPath()
            var resonator = context
            resonator.addFilter(.shadow(color: .black.opacity(0.22), radius: 4, x: 0, y: 4))
            resonator.fill(wood, with: .linearGradient(
                Gradient(stops: [.init(color: Color(hex: 0xE3B675), location: 0),
                                 .init(color: Color(hex: 0xB77337), location: 0.45),
                                 .init(color: Color(hex: 0x71401F), location: 1)]),
                startPoint: CGPoint(x: 60, y: 37), endPoint: CGPoint(x: 142, y: 144)))
            var grain = context
            grain.clip(to: wood)
            for index in 0..<12 {
                let y = CGFloat(index) * 8 + 46
                var line = Path()
                line.move(to: CGPoint(x: 26, y: y))
                line.addCurve(to: CGPoint(x: 203, y: y + 17),
                              control1: CGPoint(x: 73, y: y - 22), control2: CGPoint(x: 145, y: y + 32))
                grain.stroke(line, with: .color(Color(hex: 0x613315, opacity: index.isMultiple(of: 3) ? 0.22 : 0.10)),
                             lineWidth: index.isMultiple(of: 3) ? 1.1 : 0.65)
            }
            var crown = Path()
            crown.move(to: CGPoint(x: 46, y: 74))
            crown.addCurve(to: CGPoint(x: 145, y: 53), control1: CGPoint(x: 63, y: 44), control2: CGPoint(x: 113, y: 42))
            context.stroke(crown, with: .color(Color(hex: 0xFFE0A7, opacity: 0.62)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
            var mouth = Path()
            mouth.move(to: CGPoint(x: 164, y: 70))
            mouth.addCurve(to: CGPoint(x: 193, y: 89), control1: CGPoint(x: 190, y: 69), control2: CGPoint(x: 208, y: 77))
            mouth.addCurve(to: CGPoint(x: 146, y: 112), control1: CGPoint(x: 187, y: 96), control2: CGPoint(x: 158, y: 96))
            mouth.addCurve(to: CGPoint(x: 147, y: 101), control1: CGPoint(x: 137, y: 114), control2: CGPoint(x: 137, y: 106))
            mouth.addCurve(to: CGPoint(x: 183, y: 85), control1: CGPoint(x: 155, y: 90), control2: CGPoint(x: 185, y: 92))
            mouth.addQuadCurve(to: CGPoint(x: 164, y: 70), control: CGPoint(x: 194, y: 79))
            context.fill(mouth, with: .color(Color(hex: 0x342112)))
            context.stroke(mouth, with: .color(Color(hex: 0xE7B477, opacity: 0.5)), lineWidth: 0.8)
            // Small fish-eye carving and circular grain over the belly.
            context.fill(Path(ellipseIn: CGRect(x: 165, y: 58, width: 6, height: 6)), with: .color(Color(hex: 0x704020)))
            context.fill(Path(ellipseIn: CGRect(x: 165.5, y: 58, width: 2, height: 2)), with: .color(Color(hex: 0xEDC184)))
            for index in 0..<3 {
                let inset = CGFloat(index) * 7
                let ring = Path(ellipseIn: CGRect(x: 53 + inset, y: 72 + inset * 0.45,
                                                width: 70 - inset * 2, height: 40 - inset))
                context.stroke(ring, with: .color(Color(hex: 0x6D3B1B, opacity: 0.19)), lineWidth: 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            WoodenFishMallet().frame(width: 74, height: 23)
                .rotationEffect(.degrees(-38)).offset(x: 7, y: 18)
                .keyframeAnimator(initialValue: 0.0, trigger: strikeID) { view, angle in
                    view.rotationEffect(.degrees(reducedMotion ? 0 : angle), anchor: .trailing)
                } keyframes: { _ in
                    LinearKeyframe(-18, duration: 0.06)
                    SpringKeyframe(0, duration: 0.24, spring: .snappy)
                }
        }
        .accessibilityHidden(true)
    }

    private func bodyPath() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 36, y: 83))
        path.addCurve(to: CGPoint(x: 113, y: 40), control1: CGPoint(x: 41, y: 52), control2: CGPoint(x: 81, y: 34))
        path.addCurve(to: CGPoint(x: 181, y: 65), control1: CGPoint(x: 145, y: 42), control2: CGPoint(x: 165, y: 47))
        path.addCurve(to: CGPoint(x: 198, y: 91), control1: CGPoint(x: 207, y: 66), control2: CGPoint(x: 211, y: 80))
        path.addCurve(to: CGPoint(x: 164, y: 127), control1: CGPoint(x: 192, y: 114), control2: CGPoint(x: 184, y: 122))
        path.addCurve(to: CGPoint(x: 56, y: 126), control1: CGPoint(x: 137, y: 142), control2: CGPoint(x: 84, y: 144))
        path.addCurve(to: CGPoint(x: 36, y: 83), control1: CGPoint(x: 40, y: 116), control2: CGPoint(x: 29, y: 100))
        path.closeSubpath()
        return path
    }

}

private struct WoodenFishMallet: View {
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(LinearGradient(colors: [Color(hex: 0xEAC58C), Color(hex: 0xA66831)],
                                         startPoint: .top, endPoint: .bottom))
                .frame(width: 62, height: 7).offset(x: 12)
            Ellipse().fill(LinearGradient(colors: [Color(hex: 0xEBC58F), Color(hex: 0x925424)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 24, height: 22)
                .overlay(Ellipse().strokeBorder(Color(hex: 0x74411D, opacity: 0.35), lineWidth: 1))
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
            NSColor.secondaryLabelColor.withAlphaComponent(0.7).setFill()
            for x in [8.0, 13.0] {
                for y in [8.0, 13.0, 18.0] {
                    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2, height: 2)).fill()
                }
            }
        }
    }
}
