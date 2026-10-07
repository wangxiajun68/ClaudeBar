#!/usr/bin/env python3
"""Pinned-screenshot geometry and capture plumbing, driven through the real panels.

`ScreenshotOverlay.swift` has no dedicated suite and its failure modes are
visual: a pin's chrome bar used to be laid out 8 pt *above* its own window's top
edge (`photo.height - barHeight + 8`), and a window clips its content at its own
frame — so every pinned screenshot showed the close / copy / zoom symbols shaved
flat at the top, with a comment claiming the extra padding hid the bar "until
the cursor enters" describing a hover-hide path that does not exist. The whole
file compiles into the probe against the shared `BuildChannel.swift` identity,
so `ScreenshotPinPanel` and `SnipToolbar` are the shipped classes, not a
restatement; no capture, no pasteboard write and no app launch is involved.

Pins the two contracts the fixes established:

1. Every `ScreenshotPinPanel` layout (and every rescale) keeps the chrome bar
   and all four of its buttons inside the window frame, positioned by the
   photo's top edge.
2. `SnipToolbar`'s frame is final the moment `init` returns — the `sizeToFit()`
   that used to run on every `positionToolbar()` (i.e. per drag event) was a
   no-op on a size that cannot change.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
overlay = (root / 'Sources/ClaudeBar/Utils/ScreenshotOverlay.swift').read_text()
build_channel = (root / 'Sources/Shared/BuildChannel.swift').read_text()

# Accessors for `private` state, added on the *same types* — a follow-up
# extension of the sliced class in the harness below cannot see private members.
probe = build_channel + '\n' + overlay + r'''

extension ScreenshotPinPanel {
    var probeChromeBar: PinChromeBar { chromeBar }
    var probeImageView: NSImageView { imageView }
    var probePadding: CGFloat { padding }
    func probeRescale(_ factor: CGFloat) { rescale(by: factor) }
}

extension SnipToolbar {
    /// The width `init` chose, restated exactly as `init` computes it.
    var probeLaidOutWidth: CGFloat {
        var w: CGFloat = 8
        for v in subviews { w = max(w, v.frame.maxX) }
        return w + 8
    }
}

@main struct Probe {
    @MainActor static func main() {
        _ = NSApplication.shared
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: 300, height: 200))

        func checkChrome(_ label: String, _ pin: ScreenshotPinPanel) {
            let host = pin.contentView!
            let bar = pin.probeChromeBar
            let tolerance: CGFloat = 0.001
            // 1. The whole bar stays inside the content view — a window clips
            //    its content at its own frame, which is what shaved the SF
            //    Symbols when the bar overdrew the top edge by 8pt.
            assert(bar.frame.maxY <= host.bounds.maxY + tolerance,
                   "\(label): chrome bar top (\\(bar.frame.maxY)) must stay inside the window (\\(host.bounds.maxY))")
            assert(bar.frame.minY >= host.bounds.minY - tolerance,
                   "\(label): chrome bar bottom must stay inside the window")
            // 2. It hangs off the photo's top edge: top-aligned with it, so it
            //    sits in the band below the edge rather than floating in the
            //    padding band above (which is only 17pt tall, less than the
            //    bar's 24pt).
            let photoTop = host.bounds.maxY - pin.probePadding / 2
            assert(abs(bar.frame.maxY - photoTop) <= 2,
                   "\(label): chrome bar top (\\(bar.frame.maxY)) must align with the photo's top edge (\\(photoTop))")
            assert(bar.frame.minY >= photoTop - bar.frame.height - 2,
                   "\(label): chrome bar must not cover more than its own height of the photo")
            // 3. Every button too — they are 20pt tall inside the 24pt bar.
            for (i, button) in bar.subviews.enumerated() {
                let inHost = button.convert(button.bounds, to: host)
                assert(inHost.maxY <= host.bounds.maxY + tolerance,
                       "\(label): chrome button \(i) top (\\(inHost.maxY)) is clipped by the window (\\(host.bounds.maxY))")
                assert(inHost.minY >= host.bounds.minY - tolerance,
                       "\(label): chrome button \(i) bottom is outside the window")
            }
        }

        let first = ScreenshotPinPanel(image: image, origin: NSRect(x: 100, y: 100, width: 300, height: 200))
        checkChrome("initial layout", first)
        assert(first.probeImageView.frame.maxY == first.probePadding / 2 + image.size.height,
               "initial layout: photo image geometry unchanged")

        let pin = ScreenshotPinPanel(image: image, origin: NSRect(x: 0, y: 0, width: 100, height: 100))
        checkChrome("second pin", pin)
        pin.probeRescale(1.25)
        checkChrome("rescale 1.25x", pin)
        assert(pin.probeImageView.frame.maxY == pin.probePadding / 2 + image.size.height * 1.25,
               "rescale: photo must grow with the pin")
        pin.probeRescale(0.2)
        checkChrome("rescale 0.2x", pin)
        assert(pin.frame.height == image.size.height * 0.25 + pin.probePadding,
               "rescale: the ± steps clamp to 0.25x..4x")

        // `positionToolbar` re-runs on every drag frame; its `sizeToFit()` was
        // recomputing a width that `init` had already fixed.
        let toolbar = SnipToolbar(frame: .zero)
        assert(toolbar.frame.width == toolbar.probeLaidOutWidth,
               "SnipToolbar must leave init with its final size (got \\(toolbar.frame.width), expected \\(toolbar.probeLaidOutWidth))")
        assert(toolbar.frame.height == 36, "SnipToolbar keeps its 36pt height")
        assert(toolbar.subviews.count >= 10, "toolbar keeps its buttons/dividers")

        print("PASS: pin chrome bar and buttons stay inside the window across layout and rescale; toolbar size is final at init")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='claudebar-screenshot-overlay-') as folder:
    path = Path(folder) / 'Probe.swift'
    path.write_text(probe)
    binary = Path(folder) / 'probe'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
