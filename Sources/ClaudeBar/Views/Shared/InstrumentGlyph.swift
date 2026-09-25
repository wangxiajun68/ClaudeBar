import SwiftUI

/// Quiet geometric marks: one silhouette, generous negative space, consistent weight.
/// Compact labels stay monochrome; only live instruments use semantic color.
struct InstrumentGlyph: View, Animatable {
    enum Kind { case cpu, gpu, memory, disk, link, ethernet, fan, config, balance, sessions, tokens, quota, vpn, battery, refresh
        case overview, traffic, settings, help, power, notification, folder, search, appearance, camera, cost }
    var kind: Kind
    var tint: Color = Theme.chartBlue
    var level: Double = 0
    var detailed = false
    var active = true
    var phase: Double = 0

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    static func kind(for symbol: String) -> Kind? {
        switch symbol {
        case "cpu": return .cpu
        case "square.3.layers.3d": return .gpu
        case "memorychip": return .memory
        case "internaldrive": return .disk
        case "antenna.radiowaves.left.and.right", "wifi", "wifi.slash", "wifi.exclamationmark": return .link
        case "network": return .ethernet
        case "fanblades": return .fan
        case "cube": return .config
        case "yensign.circle": return .balance
        case "rectangle.stack", "rectangle.connected.to.line.below": return .sessions
        case "chart.bar": return .tokens
        case "square.grid.2x2": return .overview
        case "arrow.left.arrow.right", "waveform", "dot.radiowaves.left.and.right": return .traffic
        case "slider.horizontal.3", "gearshape": return .settings
        case "book.closed", "questionmark", "questionmark.circle": return .help
        case "globe", "shield", "shield.checkered": return .vpn
        case "power": return .power
        case "bell", "bell.fill": return .notification
        case "folder", "folder.fill": return .folder
        case "magnifyingglass": return .search
        case "paintpalette", "circle.lefthalf.filled": return .appearance
        case "camera": return .camera
        case "banknote": return .cost
        case "arrow.clockwise": return .refresh
        case "cylinder": return .disk
        default: return nil
        }
    }

    var body: some View {
        Canvas { context, size in
            // One 24-point grid, with optical weight adjusted for the large marks.
            let scale = min(size.width, size.height) / 24
            var c = context
            c.translateBy(x: (size.width - scale * 24) / 2, y: (size.height - scale * 24) / 2)
            c.scaleBy(x: scale, y: scale)
            let ink = active ? tint : Theme.textSecondary
            let track = ink.opacity(0.16)
            let amount = min(1, max(0, level.isFinite ? level : 0))
            let stroke = StrokeStyle(lineWidth: detailed ? 0.85 : 1.65, lineCap: .round, lineJoin: .round)
            func line(_ points: [CGPoint], _ color: Color) {
                guard let first = points.first else { return }
                var path = Path(); path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                c.stroke(path, with: .color(color), style: stroke)
            }
            func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                     _ color: Color, fill: Bool = false, radius: CGFloat = 2) {
                let path = Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: radius)
                if fill { c.fill(path, with: .color(color)) }
                else { c.stroke(path, with: .color(color), style: stroke) }
            }
            func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ color: Color, fill: Bool = false) {
                let path = Path(ellipseIn: CGRect(x: x-radius, y: y-radius, width: radius*2, height: radius*2))
                if fill { c.fill(path, with: .color(color)) }
                else { c.stroke(path, with: .color(color), style: stroke) }
            }
            func arc(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ start: Double, _ end: Double, _ color: Color) {
                var path = Path()
                path.addArc(center: CGPoint(x: x, y: y), radius: radius,
                            startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
                c.stroke(path, with: .color(color), style: stroke)
            }
            switch kind {
            case .cpu:
                box(6, 6, 12, 12, ink, radius: 3)
                for p in [CGFloat(9), 15] {
                    line([CGPoint(x:p,y:3),CGPoint(x:p,y:6)],ink)
                    line([CGPoint(x:p,y:18),CGPoint(x:p,y:21)],ink)
                    line([CGPoint(x:3,y:p),CGPoint(x:6,y:p)],ink)
                    line([CGPoint(x:18,y:p),CGPoint(x:21,y:p)],ink)
                }
                box(9-phase,9-phase,6+2*phase,6+2*phase,track,fill:true,radius:1.5)
                if detailed, amount > 0 {
                    var fill = c
                    fill.clip(to: Path(roundedRect: CGRect(x:9,y:9,width:6,height:6),cornerRadius:1.5))
                    fill.fill(Path(CGRect(x:9,y:15-6*amount,width:6,height:6*amount)),with:.color(ink))
                }
            case .gpu:
                LucideHardwarePaths.drawGPU(in: &c, tint: ink, level: amount, detailed: detailed)
            case .memory:
                box(2,6,20,11,ink,radius:2)
                box(5,9,5,5,track,fill:true,radius:1)
                box(13,9,5,5,track,fill:true,radius:1)
                for x in [CGFloat(5),8,11,16,19] {
                    line([CGPoint(x:x,y:17),CGPoint(x:x,y:20)],ink)
                }
            case .disk:
                box(5,3.5,14,17,ink,radius:4)
                circle(12,10,3.5,track,fill:true)
                circle(12,10,1,ink,fill:true)
                line([CGPoint(x:9,y:17),CGPoint(x:15,y:17)],track)
                if !detailed || amount > 0 {
                    line([CGPoint(x:9,y:17),CGPoint(x:9+6*(detailed ? amount : 1),y:17)],ink)
                }
            case .link:
                arc(12,18,13,228,312,ink)
                arc(12,18,8,228,312,ink)
                circle(12,17,1.5+phase*0.5,ink,fill:true)
                if !active { line([CGPoint(x:4,y:4),CGPoint(x:20,y:20)],ink) }
            case .ethernet:
                box(7,3,10,7,ink)
                line([CGPoint(x:12,y:10),CGPoint(x:12,y:16)],ink)
                line([CGPoint(x:5,y:20),CGPoint(x:5,y:16),CGPoint(x:19,y:16),CGPoint(x:19,y:20)],ink)
            case .fan:
                for i in 0..<3 {
                    var blade = c
                    blade.translateBy(x:12,y:12)
                    blade.rotate(by:.degrees(Double(i)*120 + phase*35))
                    blade.fill(RotorBlade().path(in:CGRect(x:-10,y:-10,width:20,height:20)),with:.color(ink))
                }
            case .config:
                box(4,4,6,6,ink,radius:2)
                box(14,4,6,6,ink,radius:2)
                box(4,14,6,6,ink,radius:2)
                box(14,14-phase*2,6,6,ink,fill:true,radius:2)
            case .balance:
                circle(12,12,8,ink)
                line([CGPoint(x:9,y:8),CGPoint(x:12,y:11),CGPoint(x:15,y:8)],ink)
                line([CGPoint(x:9,y:13),CGPoint(x:15,y:13)],ink)
                line([CGPoint(x:12,y:11),CGPoint(x:12,y:16)],ink)
            case .cost:
                // A banknote, not the ¥-in-a-circle of `.balance`: the two sit
                // in the same grid and must not read as the same instrument.
                box(2.5,6,19,12,ink,radius:3)
                circle(12,12,3.2,ink)
                line([CGPoint(x:12,y:10.4),CGPoint(x:12,y:13.6)],ink)
                line([CGPoint(x:5.5,y:9),CGPoint(x:5.5,y:15)],track)
                line([CGPoint(x:18.5,y:9),CGPoint(x:18.5,y:15)],track)
            case .sessions:
                box(4,6,16,13,ink,radius:3)
                line([CGPoint(x:8,y:10),CGPoint(x:10.5,y:12.5),CGPoint(x:8,y:15)],ink)
                line([CGPoint(x:13,y:15),CGPoint(x:16,y:15)],ink)
            case .tokens:
                box(4,12,4,8,ink,fill:true)
                box(10,7,4,13,ink.opacity(0.7),fill:true)
                box(16,3,4,17,ink.opacity(0.4),fill:true)
            case .quota:
                // Open circular meter with two window markers: immediately
                // reads as allowance remaining without looking like currency.
                let quotaLevel = detailed ? amount : 0.68
                arc(12,12,8,-52,232,track)
                arc(12,12,8,-52,-52 + 284 * quotaLevel,ink)
                circle(12,12,2.2,ink,fill:true)
                line([CGPoint(x:12,y:12),CGPoint(x:16.5,y:8.5)],ink)
                circle(5.7,17,1.1,ink.opacity(0.75),fill:true)
                circle(18.3,17,1.1,ink.opacity(0.42),fill:true)
            case .vpn:
                LucideHardwarePaths.drawVPN(in: &c, tint: ink, active: active)
            case .battery:
                box(3,7,16,10,ink,radius:3)
                line([CGPoint(x:22,y:10),CGPoint(x:22,y:14)],ink)
                if amount > 0 { box(5,9,12*amount,6,ink,fill:true,radius:min(1.5,6*amount)) }
            case .overview:
                box(3,3,8,10+phase*2,ink,radius:2.5)
                box(14,3,7,6,ink.opacity(0.4),fill:true,radius:2)
                box(3,16+phase*2,8,5-phase*2,ink.opacity(0.35),fill:true,radius:2)
                box(14,12,7,9,ink,radius:2.5)
            case .traffic:
                let shift = phase*2
                line([CGPoint(x:3+shift,y:7),CGPoint(x:19,y:7),CGPoint(x:16,y:4)],ink)
                line([CGPoint(x:21-shift,y:17),CGPoint(x:5,y:17),CGPoint(x:8,y:20)],ink)
                circle(7+shift,12,1,ink.opacity(0.4),fill:true)
                circle(12,12,1,ink.opacity(0.65),fill:true)
                circle(17-shift,12,1,ink,fill:true)
            case .settings:
                for i in 0..<3 {
                    let y = CGFloat(5+i*7)
                    let x: CGFloat = i == 1 ? 15-phase*3 : 8+phase*3
                    line([CGPoint(x:3,y:y),CGPoint(x:21,y:y)],track)
                    line([CGPoint(x:3,y:y),CGPoint(x:x-2,y:y)],ink)
                    circle(x,y,2.5,ink)
                }
            case .help:
                box(5,3,15,18,ink,radius:3)
                line([CGPoint(x:8,y:3),CGPoint(x:8,y:21)],ink.opacity(0.45))
                line([CGPoint(x:12,y:8),CGPoint(x:16,y:8)],ink)
                line([CGPoint(x:12,y:12),CGPoint(x:16-phase*2,y:12)],ink.opacity(0.6))
                line([CGPoint(x:12,y:16),CGPoint(x:14+phase*2,y:16)],ink.opacity(0.4))
            case .power:
                arc(12,13,8,-48+phase*10,228-phase*10,ink)
                line([CGPoint(x:12,y:2),CGPoint(x:12,y:11)],ink)
            case .notification:
                var bell = Path()
                bell.move(to:CGPoint(x:4,y:17))
                bell.addQuadCurve(to:CGPoint(x:7,y:9),control:CGPoint(x:7,y:14))
                bell.addCurve(to:CGPoint(x:17,y:9),control1:CGPoint(x:7,y:2),control2:CGPoint(x:17,y:2))
                bell.addQuadCurve(to:CGPoint(x:20,y:17),control:CGPoint(x:17,y:14))
                bell.closeSubpath()
                c.stroke(bell,with:.color(ink),style:stroke)
                arc(12+phase,19,2,0,180,ink)
                circle(19,4,1+phase,ink.opacity(0.5),fill:true)
            case .folder:
                var folder = Path()
                folder.move(to:CGPoint(x:3,y:7))
                folder.addLines([CGPoint(x:3,y:4),CGPoint(x:9,y:4),CGPoint(x:12,y:7),CGPoint(x:21,y:7),CGPoint(x:21,y:20),CGPoint(x:3,y:20),CGPoint(x:3,y:7)])
                c.stroke(folder,with:.color(ink),style:stroke)
                line([CGPoint(x:7,y:12-phase),CGPoint(x:17,y:12-phase)],ink.opacity(0.4))
            case .search:
                circle(10,10,6+phase,ink)
                line([CGPoint(x:15,y:15),CGPoint(x:21,y:21)],ink)
            case .appearance:
                circle(12,12,9,ink)
                var half = c
                half.clip(to:Path(CGRect(x:12,y:2,width:10,height:20)))
                half.fill(Path(ellipseIn:CGRect(x:5,y:5,width:14,height:14)),with:.color(ink.opacity(0.7)))
                circle(8,12,1+phase*0.5,ink,fill:true)
            case .camera:
                box(3,6,18,14,ink,radius:3)
                line([CGPoint(x:8,y:6),CGPoint(x:9,y:3),CGPoint(x:15,y:3),CGPoint(x:16,y:6)],ink)
                circle(12,13,4+phase,ink)
                circle(18,9,0.8,ink,fill:true)
            case .refresh:
                arc(12,12,7,40,310,ink)
                line([CGPoint(x:12,y:6),CGPoint(x:17,y:6),CGPoint(x:17,y:1.5)],ink)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A single flowing silhouette shared by the static icon and live rotor.
struct RotorBlade: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x:rect.minX+x*rect.width,y:rect.minY+y*rect.height)
        }
        path.move(to:p(0.47,0.42))
        path.addCurve(to:p(0.67,0.08),control1:p(0.38,0.19),control2:p(0.49,0.03))
        path.addCurve(to:p(0.55,0.44),control1:p(0.92,0.16),control2:p(0.73,0.41))
        path.addQuadCurve(to:p(0.47,0.42),control:p(0.51,0.48))
        path.closeSubpath()
        return path
    }
}

struct InstrumentBadge: View {
    var kind: InstrumentGlyph.Kind
    var size: CGFloat = 24
    var tint: Color = Theme.textSecondary
    var engaged = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        InstrumentGlyph(kind: kind, tint: tint, phase: engaged && !reduceMotion ? 1 : 0)
            .frame(width: size, height: size)
            .scaleEffect(engaged && !reduceMotion ? 1.06 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.76), value: engaged)
    }
}
