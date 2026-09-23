import SwiftUI

/// Two compact rotors. Each click toggles that fan between max RPM and auto.
struct CompactFanPair: View {
    let fans: [FanInfo]
    var onToggle: (FanInfo) -> Void = { _ in }

    private var shown: [FanInfo] {
        fans.isEmpty ? [] : Array(fans.prefix(2))
    }

    var body: some View {
        HStack(spacing: 6) {
            if shown.isEmpty {
                SoftRotor(rpm: 0, maxRPM: 1, tint: Theme.statusIdle, forced: false, size: 44)
            } else {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, fan in
                    Button {
                        onToggle(fan)
                    } label: {
                        VStack(spacing: 2) {
                            SoftRotor(
                                rpm: fan.rpm,
                                maxRPM: fan.maxRPM,
                                tint: bladeTint(fan),
                                forced: !fan.mode.isAutomatic,
                                size: 42
                            )
                            Text(shortName(fan, index: index))
                                .font(.system(size: 8, weight: .medium, design: .rounded))
                                .foregroundColor(fan.mode.isAutomatic ? Theme.textTertiary() : bladeTint(fan))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(help(fan))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortName(_ fan: FanInfo, index: Int) -> String {
        let raw = fan.name.trimmingCharacters(in: .whitespaces)
        if raw.localizedCaseInsensitiveContains("left") || raw.contains("左") { return "左" }
        if raw.localizedCaseInsensitiveContains("right") || raw.contains("右") { return "右" }
        return index == 0 ? "左" : "右"
    }

    private func help(_ fan: FanInfo) -> String {
        if fan.mode.isAutomatic {
            return "\(fan.name) 自动 \(fan.rpm) rpm · 点击拉到最大"
        }
        return "\(fan.name) 手动 \(fan.rpm) / \(fan.maxRPM) rpm · 点击恢复自动"
    }

    private func bladeTint(_ fan: FanInfo) -> Color {
        if !fan.mode.isAutomatic { return Theme.chartAmber }
        let load = Double(fan.rpm) / Double(max(fan.maxRPM, 1))
        if load > 0.88 { return Theme.statusError }
        if load > 0.65 { return Theme.chartAmber }
        return Theme.claude
    }
}

/// Accumulates angle from dt so RPM changes don't snap the blades back.
private final class SpinPhase {
    var last: TimeInterval?
    var deg: Double = 18

    func tick(_ now: TimeInterval, dps: Double) -> Double {
        if let last {
            deg += min(now - last, 0.2) * dps
        }
        last = now
        if deg > 1_000_000 { deg = deg.truncatingRemainder(dividingBy: 360) }
        return deg
    }
}

/// Open three-blade rotor. Visual spin tracks RPM, capped so a full turn is
/// never faster than ~6s. Drawn in Canvas so SwiftUI won't interpolate the
/// angle back to rest on parent refresh.
struct SoftRotor: View {
    var rpm: Int
    var maxRPM: Int
    var tint: Color
    var forced: Bool
    var size: CGFloat = 48

    @State private var phase = SpinPhase()
    @State private var mounted = false
    @State private var windowVisible = UIWakePolicy.shouldAnimate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spinning: Bool { mounted && windowVisible && rpm >= 80 && !reduceMotion }

    /// 12°/s at the floor, 58°/s at rated max — about 30s … 6s per turn.
    private var degreesPerSecond: Double {
        guard spinning else { return 0 }
        let load = min(1, Double(rpm) / Double(max(maxRPM, 1)))
        return 12 + load * 46
    }

    var body: some View {
        // `paused:` is load-bearing. `PeriodicTimelineSchedule` has no paused
        // flag, so an idle rotor kept an unconditional 20 Hz display link for
        // the life of the app and every tick cost a full main-thread layout
        // pass. `.animation(minimumInterval:paused:)` is the same schedule the
        // rest of the motion in this app uses and is the only pausable one.
        // The angle is accumulated from wall-clock time in `SpinPhase`, so the
        // blades pick up where they left off when unpaused.
        TimelineView(.animation(minimumInterval: spinning ? 1.0 / 20.0 : 30,
                                paused: !spinning)) { timeline in
            let deg = spinning
                ? phase.tick(timeline.date.timeIntervalSinceReferenceDate, dps: degreesPerSecond)
                : 18
            Canvas { ctx, canvasSize in
                let s = min(canvasSize.width, canvasSize.height)
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                if forced {
                    let ring = CGRect(x:center.x-s*0.46,y:center.y-s*0.46,width:s*0.92,height:s*0.92)
                    ctx.stroke(Path(ellipseIn:ring),with:.color(tint.opacity(0.25)),lineWidth:1)
                }
                var rotor = ctx
                rotor.translateBy(x:center.x,y:center.y)
                rotor.rotate(by:.degrees(deg))
                for i in 0..<3 {
                    var blade = rotor
                    blade.rotate(by:.degrees(Double(i)*120))
                    blade.fill(RotorBlade().path(in:CGRect(x:-s/2,y:-s/2,width:s,height:s)),
                               with:.color(tint.opacity(0.85)))
                }
                let hub = CGRect(x:center.x-s*0.045,y:center.y-s*0.045,width:s*0.09,height:s*0.09)
                ctx.fill(Path(ellipseIn:hub),with:.color(tint))
            }
            .frame(width: size, height: size)
        }
        .onAppear { mounted = true; windowVisible = UIWakePolicy.shouldAnimate }
        .onDisappear { mounted = false }
        .onReceive(UIWakePolicy.changes) { windowVisible = UIWakePolicy.shouldAnimate }
    }
}
