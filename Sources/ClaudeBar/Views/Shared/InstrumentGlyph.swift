import SwiftUI

/// Quiet geometric marks: one silhouette, generous negative space, consistent weight.
/// Compact labels stay monochrome; only live instruments use semantic color.
struct InstrumentGlyph: View, Animatable {
    enum Kind { case cpu, gpu, memory, disk, link, ethernet, fan, config, sessions, tokens, vpn, refresh
        case overview, traffic, settings, help, power, notification, search, weather }
    var kind: Kind
    var tint: Color = Theme.chartBlue
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
        case "rectangle.stack", "rectangle.connected.to.line.below": return .sessions
        case "chart.bar": return .tokens
        case "square.grid.2x2": return .overview
        case "arrow.left.arrow.right", "waveform", "dot.radiowaves.left.and.right": return .traffic
        case "slider.horizontal.3", "gearshape": return .settings
        case "book.closed", "questionmark", "questionmark.circle": return .help
        case "globe", "shield", "shield.checkered": return .vpn
        case "power": return .power
        case "bell", "bell.fill": return .notification
        case "magnifyingglass": return .search
        case "arrow.clockwise": return .refresh
        case "cylinder": return .disk
        case "cloud.sun", "cloud.sun.fill", "sun.max": return .weather
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
            // No construction of this glyph sets a reading, so there is no
            // `level`/`detailed`/`active`: the marks are drawn at one weight.
            // A future meter that wants a fill adds the parameter back with
            // the value in hand (see `InstrumentBadge` for the intended shape).
            let ink = tint
            let track = ink.opacity(0.16)
            let stroke = StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round)
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
            case .gpu:
                LucideHardwarePaths.drawGPU(in: &c, tint: ink)
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
                line([CGPoint(x:9,y:17),CGPoint(x:15,y:17)],ink)
            case .link:
                arc(12,18,13,228,312,ink)
                arc(12,18,8,228,312,ink)
                circle(12,17,1.5+phase*0.5,ink,fill:true)
            case .ethernet:
                box(7,3,10,7,ink)
                line([CGPoint(x:12,y:10),CGPoint(x:12,y:16)],ink)
                line([CGPoint(x:5,y:20),CGPoint(x:5,y:16),CGPoint(x:19,y:16),CGPoint(x:19,y:20)],ink)
            case .fan:
                // A resolved symbol carries the environment's foreground,
                // not this glyph's `ink`: without the shading, the rotor
                // was the one mark on the grid that ignored its tint.
                var symbol = c.resolve(Image(systemName: "fanblades.fill"))
                symbol.shading = .color(ink)
                c.draw(symbol, in: CGRect(x: 3, y: 3, width: 18, height: 18))
            case .config:
                box(4,4,6,6,ink,radius:2)
                box(14,4,6,6,ink,radius:2)
                box(4,14,6,6,ink,radius:2)
                box(14,14-phase*2,6,6,ink,fill:true,radius:2)
            case .sessions:
                box(4,6,16,13,ink,radius:3)
                line([CGPoint(x:8,y:10),CGPoint(x:10.5,y:12.5),CGPoint(x:8,y:15)],ink)
                line([CGPoint(x:13,y:15),CGPoint(x:16,y:15)],ink)
            case .tokens:
                box(4,12,4,8,ink,fill:true)
                box(10,7,4,13,ink.opacity(0.7),fill:true)
                box(16,3,4,17,ink.opacity(0.4),fill:true)
            case .vpn:
                LucideHardwarePaths.drawVPN(in: &c, tint: ink)
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
            case .weather:
                // Sun behind a cloud: the card's own mark. The sun keeps the
                // shape hue so it reads on the ice canvas even at 26pt.
                circle(16.5, 7.5, 3.4, Theme.chartAmber, fill: true)
                for (dx, dy) in [(-1.0, -1.0), (0.0, -1.35), (1.0, -1.0),
                                 (-1.35, 0.0), (1.35, 0.0), (-1.0, 1.0),
                                 (0.0, 1.35), (1.0, 1.0)] {
                    line([CGPoint(x: 16.5 + dx * 4.4, y: 7.5 + dy * 4.4),
                          CGPoint(x: 16.5 + dx * 6.1, y: 7.5 + dy * 6.1)],
                         Theme.chartAmber.opacity(0.85))
                }
                var cloud = Path()
                cloud.addEllipse(in: CGRect(x: 3.0, y: 9.5, width: 7.6, height: 7.6))
                cloud.addEllipse(in: CGRect(x: 7.2, y: 7.4, width: 9.4, height: 9.4))
                cloud.addEllipse(in: CGRect(x: 12.4, y: 10.0, width: 7.2, height: 7.2))
                cloud.addRoundedRect(in: CGRect(x: 3.4, y: 12.4, width: 16.4, height: 6.4),
                                     cornerSize: CGSize(width: 3.2, height: 3.2))
                c.fill(cloud, with: .color(ink.opacity(0.16)))
                c.stroke(cloud, with: .color(ink), style: stroke)
            case .search:
                circle(10,10,6+phase,ink)
                line([CGPoint(x:15,y:15),CGPoint(x:21,y:21)],ink)
            case .refresh:
                arc(12,12,7,40,310,ink)
                line([CGPoint(x:12,y:6),CGPoint(x:17,y:6),CGPoint(x:17,y:1.5)],ink)
            }
        }
        .accessibilityHidden(true)
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
