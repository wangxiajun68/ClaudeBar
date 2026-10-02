import SwiftUI

/// Status dot: filled + haloed while `isOn`, muted gray otherwise.
///
/// The halo is *static* (`BusyPulseRing` is a scaled, low-opacity ring, not an
/// animation) — the name is a leftover from when it pulsed. See that type for
/// why.
struct PulsingStatusDot: View {
    let isOn: Bool
    let color: Color
    var big: Bool = false

    var body: some View {
        Circle()
            .fill(isOn ? color : Theme.Ink.idle)
            .frame(width: big ? 8 : 6, height: big ? 8 : 6)
            .overlay {
                if isOn {
                    // The ring only exists while busy. It used to carry a
                    // `repeatForever` pulse, which kept the render server
                    // ticking for every live dot on the page whether or not it
                    // was on screen. `BusyPulseRing` is now a static shape.
                    BusyPulseRing(color: color, big: big)
                }
            }
    }
}

/// Static halo for a busy session. Animated rings hitch scrolling, and a
/// `repeatForever` pulse kept a display link running for every live tile.
///
/// One declaration for both session pages: the dashboard and the sessions page
/// used to carry private copies, and the main-window preview fixture had to
/// strip and re-declare them so two same-name types could coexist in one file.
struct BusyPulseRing: View {
    let color: Color
    /// The 8pt dots on the full-page tiles. The dashboard's 6pt dot matches
    /// the default.
    var big: Bool = false
    /// The 4pt activity-line dot, which needs a tighter ring around it.
    var compact: Bool = false

    var body: some View {
        Circle()
            .strokeBorder(color.opacity(0.35), lineWidth: compact ? 1.5 : (big ? 2.5 : 2))
            .scaleEffect(compact ? 1.8 : 1.7)
            .opacity(0.45)
    }
}

/// Status dot for an overview tile: tinted + ringed while busy, muted tint
/// while idle.
struct OverviewStatusDot: View {
    let tint: Color
    let isBusy: Bool

    var body: some View {
        Circle()
            .fill(isBusy ? tint : tint.opacity(0.35))
            .frame(width: 6, height: 6)
            .overlay {
                if isBusy { BusyPulseRing(color: tint) }
            }
    }
}
