#!/usr/bin/env python3
"""The menu-bar strip must fit inside the width it declares, and the rates it
carries must say which side of the tunnel they came from.

Two pieces of arithmetic and one of meaning. The battery cell is one object — a
capsule gauge plus the percentage beside it — so its slot is derived from the
glyph's own constants; a terminal nub bolted onto the right edge used to be
painted *outside* that slot, which is the overhang this test was written for.
The nub is gone (it carried no reading and pushed the capsule's optical centre
off its geometric one); re-adding it, or widening the capsule without
re-deriving the cell, must fail here rather than in the menu bar.

The meaning is the colour. The strip is now always up — the rates belong to the
machine when no tunnel is running and to the proxy when one is — so the two
readings are distinguished by hue: green through the tunnel, resting white
otherwise. A green number over a stopped tunnel would claim traffic was being
proxied when nothing is, and a white number while mihomo is carrying the traffic
would hide the fact that it is. Both directions are asserted on the colours the
production code hands to the labels, and the tunnel state must not be able to
change the widths (the strip no longer changes shape with the VPN).


`VpnMenuBarRateView` draws into a fixed frame on top of the status item and
paints a dark capsule behind the digits. Its declared width and its laid-out
width are two separate pieces of arithmetic, and nothing in the type system
connects them — adding the battery to the layout without adding it to
`fullWidth` paints 8pt past the capsule, which is how this test came to exist.

Parses the production constants and asserts the geometry, no app launch.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/MenuBarController.swift').read_text()
start = source.index('private final class VpnMenuBarRateView: NSView {')
# The custom battery gauge follows the strip class in the same file.
body = source[start:]

# Source-level: nothing on this strip may be gated on the tunnel again. The
# battery refresh and the rate sampler both answer machine questions that are
# true with the VPN down, and gating them meant a Mac with no VPN (and a MacBook
# with one stopped) showed a bare mark — the readings that do not need a VPN
# were exactly the ones that refused to appear without one.
controller = source[source.index('final class MenuBarController'):start]
refresh = controller[controller.index('private func refreshMenuBarBattery'):]
refresh = refresh[:refresh.index('\n    }\n')]
assert 'VpnManager.shared.isRunning' not in refresh, (
    'the menu-bar battery refresh is gated on the VPN again — a MacBook with the '
    'tunnel down would show a bare mark instead of its charge')
tick = controller[controller.index('private func tickVpnRate'):]
tick = tick[:tick.index('\n    }\n')]
assert 'SystemThroughput.shared' in tick, (
    'the strip no longer reads the machine throughput, so its rates would be '
    'blank (or stale) whenever no tunnel is up')

# The popup's width is two constants that must stay equal: `MenuBarView`'s own
# `.frame(width:)` and the panel frame `MenuBarController.sizeAndPosition`
# computes from `let width: CGFloat = 460`. The values are read from the two
# sources and compared here — the divergence would not fail anywhere else; the
# popup would just clip or letterbox against its panel (finding 685).
menu_bar_view = (root / 'Sources/ClaudeBar/Views/MenuBarView.swift').read_text()
view_width = menu_bar_view[menu_bar_view.index('.frame(width:'):]
view_width = float(view_width[len('.frame(width:'):].split(')')[0].strip())
panel_width = source[source.index('let width: CGFloat ='):]
panel_width = float(panel_width[len('let width: CGFloat ='):].split('\n')[0].strip())
assert view_width == panel_width, (
    f'the popup shell frames itself at {view_width}pt but the panel is positioned '
    f'at {panel_width}pt — the two must name the same width')

swift = r'''
import AppKit

BODY

@main struct Regression {
    @MainActor static func main() {
        _ = NSApplication.shared
        let view = VpnMenuBarRateView()
        let h: CGFloat = 20

        for hasBattery in [true, false] {
            let width = VpnMenuBarRateView.stripWidth(battery: hasBattery)
            precondition(width > 0, "a strip must declare a positive width")

            // Re-run the production layout at this width and measure the
            // right-most painted edge. `layout()` reads `batteryInstalled`, so
            // drive it through the same flag the controller sets.
            view.update(icon: nil, down: "999.9K", up: "999.9K",
                        tunneled: true,
                        battery: .init(installed: hasBattery, percent: 42, charging: false,
                                       externalPower: false, watts: -16, estimated: false))
            view.frame = NSRect(x: 0, y: 0, width: width, height: h)
            view.layout()

            func rightEdge(_ v: NSView?) -> CGFloat {
                guard let v, !v.isHidden else { return 0 }
                return v.frame.maxX
            }
            let painted = [view.iconFrameMaxX, view.downArrowFrameMaxX, view.upArrowFrameMaxX,
                           view.downLabelFrameMaxX, view.upLabelFrameMaxX,
                           view.batteryDividerFrameMaxX, view.batteryIconFrameMaxX,
                           view.batteryLabelFrameMaxX].max() ?? 0
            precondition(painted <= width + 0.5,
                         "\(hasBattery ? "with" : "without") a battery the strip paints to "
                         + "\(painted) inside a declared \(width)pt — the capsule would clip it")

            // And it must actually fill its width, or the capsule has a gap.
            precondition(width - painted < 4,
                         "declared \(width)pt but only paints to \(painted)pt, leaving a gap")

            // Hidden views must not contribute: a desktop has no battery cell.
            if !hasBattery {
                precondition(view.batteryIconIsHidden && view.batteryLabelIsHidden,
                             "a Mac without a battery must hide the whole cell")
            } else {
                // The capsule fills the strip's height: `layout()` frames it at
                // `bounds.height`, not at the 21pt design number the width's
                // ratio is defined against. Read the frame back (the width
                // checks are arithmetic on the constants and cannot see this):
                // a gauge drawn at the design height would either overflow the
                // 20pt accessory or float inside it.
                precondition(abs(view.batteryIconFrameHeight - h) < 0.01,
                             "the drawn capsule is \(view.batteryIconFrameHeight)pt tall "
                             + "in a \(h)pt strip — it must run the strip's full height")
            }

            // The tunnel state must not change the strip's shape. The rates are
            // on both sides of it now, so a width that tracked `isRunning` would
            // resize the status item on every connect / disconnect.
            let greenColour = view.downLabelTextColor
            let greenLabelMaxX = view.downLabelFrameMaxX
            view.update(icon: nil, down: "999.9K", up: "999.9K",
                        tunneled: false,
                        battery: .init(installed: hasBattery, percent: 42, charging: false,
                                       externalPower: false, watts: -16, estimated: false))
            view.frame = NSRect(x: 0, y: 0, width: width, height: h)
            view.layout()
            let whiteColour = view.downLabelTextColor
            precondition(view.downLabelFrameMaxX == greenLabelMaxX,
                         "the rate column moved when the tunnel state changed")
            // Green only while the traffic is the tunnel's: a green number over a
            // stopped proxy claims a proxy that is not there.
            precondition(greenColour != whiteColour,
                         "the rates must be coloured differently on either side of the "
                         + "tunnel, got \(greenColour) both times")
            guard let green = greenColour.usingColorSpace(.sRGB),
                  let white = whiteColour.usingColorSpace(.sRGB) else {
                preconditionFailure("the rate colours must be convertible sRGB values")
            }
            precondition(green.greenComponent > green.redComponent + 0.3
                         && green.greenComponent > green.blueComponent + 0.3,
                         "the tunnel colour must read as green, got \(green)")
            precondition(abs(white.redComponent - white.greenComponent) < 0.05
                         && abs(white.greenComponent - white.blueComponent) < 0.05,
                         "the untunnelled colour must read as the resting white, got \(white)")
        }

        // The gauge is a capsule with no post, and its width is the golden
        // rectangle of its height — a ratio, not a length. The band is the part
        // that reads as a *cell*: below it the shape is a dot, above it a bar,
        // and with the liquid inset it is the liquid's whole runway.
        let golden = 1.618
        // `batteryGlyphHeight` is the height the *design* measured the golden
        // rectangle at, and `batteryGlyphWidth` is derived from it, so those
        // two numbers must keep the exact φ² : 1 ratio. The drawn capsule is
        // the width over the *strip's* own height (`layout()` frames the gauge
        // at `bounds.height`, not at this design number), and the strip height
        // is the 20pt the accessory is installed at — a value pinned two
        // blocks up by `let h`. Asserting the design constant against a
        // literal is not enough: a layout() that stopped drawing at the strip
        // height (the pre-a195764 behaviour) would leave the ratio intact and
        // still fail here, which is the point of reading the frame back.
        precondition(abs(VpnMenuBarRateView.batteryGlyphHeight - 21) < 0.01,
                     "the design height of the gauge is the capsule's short side "
                     + "and must stay 21pt")
        precondition(abs(VpnMenuBarRateView.batteryGlyphWidth
                         / VpnMenuBarRateView.batteryGlyphHeight - golden) < 0.002,
                     "the declared width must stay φ² × the design height, got "
                     + "\(VpnMenuBarRateView.batteryGlyphWidth) : "
                     + "\(VpnMenuBarRateView.batteryGlyphHeight)")
        // The rectangle actually drawn is that width over the strip's own
        // height, which is 1pt shorter — still the same reading, and still
        // inside the dot↔bar band that makes it a cell rather than a bar.
        let drawn = VpnMenuBarRateView.batteryGlyphWidth / h
        precondition(drawn > 1.3 && drawn < 2.2,
                     "the drawn capsule is \(drawn):1 — outside the range that reads "
                     + "as a cell (1.3–2.2:1) at a \(h)pt strip height")
        // The liquid's runway is the slot minus the wall inset on both sides.
        // It has to stay positive, or the capsule is all container.
        let runway = VpnMenuBarRateView.batteryGlyphWidth - 2 * (0.5 + 1.7)
        precondition(runway > h * 0.5,
                     "only \(runway)pt of liquid runway: the cell is wider than it "
                     + "is a cell — a terminal post may have been put back on, or "
                     + "the capsule widened without re-deriving the slot")

        let charging = VpnMenuBarRateView.BatteryReading(
            installed: true, percent: 80, charging: true,
            externalPower: true, watts: 16.3, estimated: false)
        precondition(charging.detail == "充 16W" && charging.mode == .charging)
        let discharging = VpnMenuBarRateView.BatteryReading(
            installed: true, percent: 80, charging: false,
            externalPower: false, watts: -16.3, estimated: false)
        precondition(discharging.detail == "耗 16W" && discharging.mode == .discharging)
        let holding = VpnMenuBarRateView.BatteryReading(
            installed: true, percent: 80, charging: false,
            externalPower: true, watts: 0, estimated: false)
        precondition(holding.detail == "电源直供" && holding.mode == .holding)

        print("PASS: menu-bar strip fits its declared width with and without a battery; "
              + "the rates are green through the tunnel and resting white outside it, "
              + "without changing the strip's shape; "
              + "the gauge is a strip-height 1.618:1 capsule with no terminal post; "
              + "charging, discharging, and holding have distinct labels")
    }
}
'''.replace('BODY', body)
with tempfile.TemporaryDirectory(prefix='claudebar-strip-tests-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
