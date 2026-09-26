#!/usr/bin/env python3
"""The menu-bar strip must fit inside the width it declares, and the battery
cell must keep the silhouette it was drawn to.

Two separate pieces of arithmetic. The battery cell is one object — a capsule
gauge plus the percentage beside it — so its slot is derived from the glyph's
own constants; a terminal nub bolted onto the right edge used to be painted
*outside* that slot, which is the overhang this test was written for. The nub is
gone (it carried no reading and pushed the capsule's optical centre off its
geometric one); re-adding it, or widening the capsule without re-deriving the
cell, must fail here rather than in the menu bar.


`VpnMenuBarRateView` draws into a fixed frame on top of the status item and
paints a dark capsule behind the digits. Its declared width and its laid-out
width are two separate pieces of arithmetic, and nothing in the type system
connects them — adding the battery to the layout without adding it to
`fullWidth` paints 8pt past the capsule, which is how this test came to exist.

Parses the production constants and asserts the geometry, no app launch.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/MenuBarController.swift').read_text()
start = source.index('private final class VpnMenuBarRateView: NSView {')
# The custom battery gauge follows the strip class in the same file.
body = source[start:]

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
                           view.batteryLabelFrameMaxX, view.batteryDetailFrameMaxX].max() ?? 0
            precondition(painted <= width + 0.5,
                         "\(hasBattery ? "with" : "without") a battery the strip paints to "
                         + "\(painted) inside a declared \(width)pt — the capsule would clip it")

            // And it must actually fill its width, or the capsule has a gap.
            precondition(width - painted < 4,
                         "declared \(width)pt but only paints to \(painted)pt, leaving a gap")

            // Hidden views must not contribute: a desktop has no battery cell.
            if !hasBattery {
                precondition(view.batteryIconIsHidden && view.batteryLabelIsHidden
                             && view.batteryDetailIsHidden,
                             "a Mac without a battery must hide the whole cell")
            }
        }

        // The gauge is a capsule with no post, and its width is the golden
        // rectangle of its height — a ratio, not a length. The band is the part
        // that reads as a *cell*: below it the shape is a dot, above it a bar,
        // and with the liquid inset it is the liquid's whole runway.
        let golden = 1.618
        let ratio = VpnMenuBarRateView.batteryGlyphWidth
            / VpnMenuBarRateView.batteryGlyphHeight
        precondition(abs(VpnMenuBarRateView.batteryGlyphHeight - 21) < 0.01,
                     "the gauge height is the capsule's short side and must stay 21pt")
        precondition(abs(ratio - golden) < 0.002,
                     "the capsule must stay the golden rectangle (1.618:1), got "
                     + "\(VpnMenuBarRateView.batteryGlyphWidth)"
                     + ":\(VpnMenuBarRateView.batteryGlyphHeight) = \(ratio)")
        precondition(ratio < 2.2,
                     "past 2.2:1 a capsule reads as a bar, not a cell — got \(ratio)")
        // The liquid's runway is the slot minus the wall inset on both sides.
        // It has to stay positive, or the capsule is all container.
        let runway = VpnMenuBarRateView.batteryGlyphWidth - 2 * (0.5 + 1.7)
        precondition(runway > VpnMenuBarRateView.batteryGlyphHeight * 0.5,
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
              + "the gauge is a 21pt-tall 1.618:1 capsule with no terminal post; "
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
