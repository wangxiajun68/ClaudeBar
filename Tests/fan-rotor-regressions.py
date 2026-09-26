#!/usr/bin/env python3
"""Exercise the native fan layer: rendered symbol, continuous retiming and pause."""
from pathlib import Path
import subprocess
import tempfile
import shutil

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/Views/Shared/LucideRotor.swift').read_text()
layer = source[source.index('final class RotorLayerView'):]
probe = 'import AppKit\nimport QuartzCore\n' + layer + r'''
@main struct Probe {
    @MainActor static func main() {
        _ = NSApplication.shared
        let view = RotorLayerView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
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
