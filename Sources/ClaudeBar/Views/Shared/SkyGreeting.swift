import SwiftUI

/// `HELLO wangxiajun` — one line, opening.
///
/// It starts compressed (tight tracking, slightly narrowed) and eases out to
/// its full width over a couple of seconds. That is the whole motion: a title
/// unfolding, not a per-letter bounce. Afterwards a sheen crosses the line.
/// The sheen is the only thing on a timeline; the unfold is one animation
/// keyed on appear, so it does not keep a transaction in flight.
struct SkyGreeting: View {
    let name: String
    let palette: SkyPalette
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.surfaceIsVisible) private var surfaceVisible

    @State private var start = Date()
    @State private var opened = false

    private var running: Bool { animated && !reduceMotion && surfaceVisible && opened }

    var body: some View {
        phrase(tracked: opened)
            .foregroundStyle(palette.ink)
            .scaleEffect(x: opened ? 1 : 0.72, y: 1, anchor: .leading)
            .opacity(opened ? 1 : 0)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .animation(reduceMotion ? nil : .easeOut(duration: 1.8), value: opened)
            .overlay {
                if running {
                    TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !running)) { timeline in
                        sheen(t: timeline.date.timeIntervalSince(start))
                    }
                }
            }
            .onAppear {
                start = Date()
                opened = true
            }
            .accessibilityLabel("Hello，\(name)")
    }

    private func phrase(tracked: Bool) -> some View {
        Text("HELLO \(name)")
            .font(.system(size: 52, weight: .bold, design: .rounded))
            .tracking(tracked ? -1.4 : -10)
    }

    private func sheen(t: TimeInterval) -> some View {
        let phase = t.truncatingRemainder(dividingBy: 9) / 9
        return GeometryReader { geo in
            Rectangle()
                .fill(LinearGradient(
                    colors: [.white.opacity(0), palette.highlight.opacity(0.75), .white.opacity(0)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: max(18, geo.size.width * 0.14))
                .rotationEffect(.degrees(14))
                .offset(x: geo.size.width * (phase * 1.35 - 0.16))
                .blendMode(.plusLighter)
        }
        .mask(phrase(tracked: true))
        .allowsHitTesting(false)
    }
}
