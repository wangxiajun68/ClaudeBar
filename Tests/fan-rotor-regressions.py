#!/usr/bin/env python3
"""Exercise the native fan layer: rendered symbol, continuous retiming and pause."""
from pathlib import Path
import subprocess
import tempfile
import shutil

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/Views/Shared/LucideRotor.swift').read_text()
layer = source[source.index('final class RotorLayerView'):]
# `RotorLayerView.setSpeed` retimes through `CALayer.retime(to:)`, declared in
# `Interaction.swift` — the one phase-preserving retime, shared by the rotor,
# the power-flow clock and the reading sweep. The rotor slice alone names a
# member the probe cannot see, so the declaration is spliced in beside it and
# the probe exercises the production freeze/restart either way.
interaction = (root / 'Sources/ClaudeBar/Views/Shared/Interaction.swift').read_text()
assert '// MARK: - Phase-preserving retiming' in interaction, \
    'Interaction.swift: CALayer.retime(to:) moved — the rotor probe no longer sees it'
retime = interaction[interaction.index('// MARK: - Phase-preserving retiming'):interaction.index('// MARK: - Rolling figures')]
probe = 'import AppKit\nimport QuartzCore\n' + layer + '\n' + retime + r'''
final class FixtureWindow: NSWindow {
    var shown = true
    override var occlusionState: NSWindow.OcclusionState { shown ? [.visible] : [] }
}
@main struct Probe {
    @MainActor static func main() {
        _ = NSApplication.shared
        let view = RotorLayerView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let window = FixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layout()
        view.apply(tint: .gray, degreesPerSecond: 24)
        let rotor = view.layer!.sublayers!.first!
        assert(rotor.animationKeys() == ["spin"])
        let image = rotor.contents as! CGImage
        assert(image.width > 0 && image.height > 0)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var ink = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if bitmap.colorAt(x: x, y: y)!.alphaComponent > 0.1 { ink += 1 }
            }
        }
        assert(ink > 100, "SF Symbol must render visible blades")
        let before = rotor.convertTime(CACurrentMediaTime(), from: nil)
        view.apply(tint: .gray, degreesPerSecond: 58)
        let after = rotor.convertTime(CACurrentMediaTime(), from: nil)
        assert(abs(after - before) < 0.02, "Changing RPM must preserve phase")
        assert(abs(rotor.speed - Float(58.0 / 360)) < 0.00001)
        view.apply(tint: .orange, degreesPerSecond: 0)
        let paused = rotor.convertTime(CACurrentMediaTime(), from: nil)
        assert(rotor.speed == 0)
        assert(rotor.convertTime(CACurrentMediaTime() + 10, from: nil) == paused)
        view.apply(tint: .gray, degreesPerSecond: 24)
        assert(abs(rotor.convertTime(CACurrentMediaTime(), from: nil) - paused) < 0.02)
        assert(rotor.animationKeys() == ["spin"], "Updates must not stack animations")
        assert(FanArtwork.image != nil, "Bundled illustration must decode")
        let left = FanArtwork.leftRotor!
        let right = FanArtwork.rightRotor!
        assert(left.width == 216 && left.height == 216)
        assert(right.width == 216 && right.height == 216)
        view.apply(tint: .gray, degreesPerSecond: 24, artwork: left)
        assert((rotor.contents as! CGImage) === left)
        assert(rotor.masksToBounds && rotor.cornerRadius == 32)
        view.apply(tint: .gray, degreesPerSecond: 58, artwork: right)
        assert((rotor.contents as! CGImage) === right)
        view.apply(tint: .gray, degreesPerSecond: 0)
        assert((rotor.contents as! CGImage) !== right, "Fallback must restore symbol contents")
        window.shown = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        assert(rotor.speed == 0, "An occluded rotor must pause")
        let hiddenPhase = rotor.convertTime(CACurrentMediaTime(), from: nil)
        view.apply(tint: .gray, degreesPerSecond: 58)
        assert(rotor.speed == 0, "A hidden RPM update must not restart playback")
        window.shown = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        assert(abs(rotor.speed - Float(58.0 / 360)) < 0.00001)
        assert(abs(rotor.convertTime(CACurrentMediaTime(), from: nil) - hiddenPhase) < 0.02)
        view.removeFromSuperview()
        assert(rotor.speed == 0, "A detached rotor must pause")
        view.stop()
        assert(rotor.animationKeys()?.isEmpty != false)
        print("PASS: illustration and turbine crops decode; symbol fallback renders; retiming, pause and resume preserve phase")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='claudebar-fan-') as folder:
    folder = Path(folder)
    swift = folder / 'Probe.swift'
    swift.write_text(probe)
    bundle = folder / 'Probe.app/Contents'
    (bundle / 'MacOS').mkdir(parents=True)
    (bundle / 'Resources').mkdir()
    shutil.copy(root / 'Sources/ClaudeBar/Resources/macbook-internals-illustration.png', bundle / 'Resources')
    binary = bundle / 'MacOS/probe'
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
