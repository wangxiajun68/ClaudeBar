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

/// Soft three-petal rotor. Visual spin tracks RPM, capped so a full turn is
/// never faster than ~6s. Drawn in Canvas so SwiftUI won't interpolate the
/// angle back to rest on parent refresh.
struct SoftRotor: View {
    var rpm: Int
    var maxRPM: Int
    var tint: Color
    var forced: Bool
    var size: CGFloat = 48

    @State private var phase = SpinPhase()

    private var spinning: Bool { rpm >= 80 }

    /// 12°/s at the floor, 58°/s at rated max — about 30s … 6s per turn.
    private var degreesPerSecond: Double {
        guard spinning else { return 0 }
        let load = min(1, Double(rpm) / Double(max(maxRPM, 1)))
        return 12 + load * 46
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: spinning ? 1.0 / 20.0 : 30)) { timeline in
            let deg = spinning
                ? phase.tick(timeline.date.timeIntervalSinceReferenceDate, dps: degreesPerSecond)
                : 18
            Canvas { ctx, canvasSize in
                let s = min(canvasSize.width, canvasSize.height)
                let origin = CGPoint(x: (canvasSize.width - s) / 2, y: (canvasSize.height - s) / 2)
                let housing = CGRect(x: origin.x, y: origin.y, width: s, height: s)
                ctx.fill(Path(ellipseIn: housing),
                         with: .color(forced ? tint.opacity(0.16) : Theme.cardFill(0.06)))
                ctx.stroke(Path(ellipseIn: housing.insetBy(dx: 0.5, dy: 0.5)),
                           with: .color(forced ? tint.opacity(0.55) : Theme.hairline),
                           lineWidth: forced ? 1.6 : 1)

                var petals = ctx
                petals.translateBy(x: housing.midX, y: housing.midY)
                petals.rotate(by: .degrees(deg))
                let bladeW = s * 0.22
                let bladeH = s * 0.52
                for i in 0..<3 {
                    var arm = petals
                    arm.rotate(by: .degrees(Double(i) * 120))
                    let rect = CGRect(x: -bladeW / 2, y: -bladeH * 0.72, width: bladeW, height: bladeH)
                    arm.fill(Path(roundedRect: rect, cornerRadius: bladeW / 2, style: .continuous),
                             with: .color(tint.opacity(0.55)))
                }

                let hub = CGRect(x: housing.midX - s * 0.14, y: housing.midY - s * 0.14,
                                 width: s * 0.28, height: s * 0.28)
                ctx.fill(Path(ellipseIn: hub), with: .color(Theme.cardSurface))
                ctx.stroke(Path(ellipseIn: hub),
                           with: .color(forced ? tint.opacity(0.45) : Theme.hairline), lineWidth: 0.8)
                let pin = CGRect(x: housing.midX - s * 0.05, y: housing.midY - s * 0.05,
                                 width: s * 0.10, height: s * 0.10)
                ctx.fill(Path(ellipseIn: pin), with: .color(tint.opacity(0.95)))
            }
            .frame(width: size, height: size)
        }
    }
}

/// Wi-Fi / Bluetooth / wired lamps for the links meter.
struct LinkLamps: View {
    var wifiOn: Bool
    var bluetoothOn: Bool
    var wiredOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            lamp("wifi", on: wifiOn, tint: Theme.chartBlue)
            lamp("dot.radiowaves.left.and.right", on: bluetoothOn, tint: Theme.chartPurple)
            lamp("cable.connector", on: wiredOn, tint: Theme.chartGreen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lamp(_ symbol: String, on: Bool, tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(on ? tint : Theme.textTertiary(0.45))
            Circle()
                .fill(on ? tint : Theme.cardFill(0.18))
                .frame(width: 5, height: 5)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A package IC: pads around a ceramic body, die grid fills with load.
struct CPUChip: View {
    var load: Double
    var tint: Color = Theme.chartGreen

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let origin = CGPoint(x: (size.width - s) / 2, y: (size.height - s) / 2)
            let body = CGRect(x: origin.x + s * 0.16, y: origin.y + s * 0.16,
                              width: s * 0.68, height: s * 0.68)
            let pad: CGFloat = s * 0.055
            let padLen: CGFloat = s * 0.09
            let n = 5
            for i in 0..<n {
                let t = (CGFloat(i) + 0.5) / CGFloat(n)
                let x = body.minX + body.width * t - pad / 2
                let y = body.minY + body.height * t - pad / 2
                ctx.fill(Path(roundedRect: CGRect(x: x, y: origin.y + s * 0.04, width: pad, height: padLen),
                              cornerRadius: 0.8), with: .color(Theme.base4))
                ctx.fill(Path(roundedRect: CGRect(x: x, y: origin.y + s - padLen - s * 0.04, width: pad, height: padLen),
                              cornerRadius: 0.8), with: .color(Theme.base4))
                ctx.fill(Path(roundedRect: CGRect(x: origin.x + s * 0.04, y: y, width: padLen, height: pad),
                              cornerRadius: 0.8), with: .color(Theme.base4))
                ctx.fill(Path(roundedRect: CGRect(x: origin.x + s - padLen - s * 0.04, y: y, width: padLen, height: pad),
                              cornerRadius: 0.8), with: .color(Theme.base4))
            }

            ctx.fill(Path(roundedRect: body, cornerRadius: s * 0.06, style: .continuous),
                     with: .color(Theme.cardFill(0.14)))
            ctx.stroke(Path(roundedRect: body, cornerRadius: s * 0.06, style: .continuous),
                       with: .color(Theme.hairline), lineWidth: 1)

            let die = body.insetBy(dx: s * 0.08, dy: s * 0.08)
            ctx.fill(Path(roundedRect: die, cornerRadius: 2, style: .continuous),
                     with: .color(Theme.cardFill(0.10)))

            let cols = 6
            let rows = 6
            let gap: CGFloat = 1.4
            let cw = (die.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let ch = (die.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            let lit = Int((min(max(load, 0), 1) * Double(cols * rows)).rounded())
            for r in 0..<rows {
                for c in 0..<cols {
                    let i = r * cols + c
                    let cell = CGRect(
                        x: die.minX + CGFloat(c) * (cw + gap),
                        y: die.maxY - ch - CGFloat(r) * (ch + gap),
                        width: cw, height: ch)
                    let on = i < lit
                    ctx.fill(Path(roundedRect: cell, cornerRadius: 0.7),
                             with: .color(on ? tint.opacity(0.55 + 0.45 * load) : Theme.cardFill(0.10)))
                }
            }
        }
        .accessibilityLabel("CPU 负载 \(Int((load * 100).rounded()))%")
    }
}
