#!/usr/bin/env python3
"""Production Sankey layer updates in invisible windows, without starting the app.

--compare runs alternating -O probes against a Git ref. CPU timings are
diagnostic, not CI thresholds or whole-app frame-rate measurements.
"""
from pathlib import Path
import argparse
import hashlib
import json
import platform
import statistics
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--compare', action='store_true')
parser.add_argument('--baseline-ref', default='HEAD')
parser.add_argument('--output-json', type=Path)
args = parser.parse_args()
path = 'Sources/ClaudeBar/Views/Shared/PowerFlowCard.swift'
current = (root / path).read_text()
interaction = (root / 'Sources/ClaudeBar/Views/Shared/Interaction.swift').read_text()
retime = interaction[interaction.index('// MARK: - Phase-preserving retiming'):interaction.index('// MARK: - Rolling figures')]


def declaration(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def harness(source):
    # Production colors, with only the unrelated HostStats model omitted.
    node = declaration(source, '    enum Node:')
    color = declaration(source, '    static func color(')
    ribbon = declaration(source, 'private struct RibbonShape:')
    span = declaration(source, '    struct Span:')
    theme = (root / 'Sources/ClaudeBar/Theme/Theme.swift').read_text()
    colors = '\n'.join(line for line in theme.splitlines()
                       if any('static let ' + name + ' =' in line
                              for name in ('chartGreen', 'chartBlue', 'chartAmber')))
    layer = source[source.index('private struct SankeyWave:'):]
    # Count writes in the harness only; instrumentation never enters an app.
    for target, counter in [('band.gradient.colors =', 'colorWrites'),
                            ('band.gradient.locations =', 'locationWrites'),
                            ('band.mask.path =', 'pathWrites')]:
        layer = layer.replace(target, 'Metrics.' + counter + ' += 1\n            ' + target)
    return r'''
import AppKit
import SwiftUI
import CryptoKit
func require(_ condition: @autoclosure () -> Bool, _ message: String = "", line: Int = #line) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL at line \(line): \(message)\n".utf8))
        exit(1)
    }
}
enum Metrics {
    static var colorWrites = 0, locationWrites = 0, pathWrites = 0
    static func reset() { colorWrites = 0; locationWrites = 0; pathWrites = 0 }
}
extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}
''' + 'enum Theme {\n' + colors + '\n}\nenum PowerFlow {\n' + node + '\n    static let adapterYellow = Color(hex: 0xFFD60A)\n' + color + '\n}\nprivate struct SankeyLayout {\n' + span + '\n}\n' + ribbon + retime + layer + r'''
final class FixtureWindow: NSWindow {
    var shown = true
    override var occlusionState: NSWindow.OcclusionState { shown ? [.visible] : [] }
}
@main struct Probe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let window = FixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SankeyWaveView()
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 160)
        window.contentView = view
        func waves(_ step: Int = 0, destination: PowerFlow.Node = .batteryIn) -> [SankeyWave] {
            let shift = CGFloat(step % 9)
            func path(_ top: CGFloat, _ height: CGFloat, _ rise: CGFloat) -> CGPath {
                RibbonShape(x0: 0, x1: view.bounds.width,
                            left: SankeyLayout.Span(top: top, bottom: top + height),
                            right: SankeyLayout.Span(top: top + rise, bottom: top + height + rise))
                    .path(in: .zero).cgPath
            }
            return [SankeyWave(id: "charge", path: path(20 + shift, 45, 25), destination: destination),
                    SankeyWave(id: "system", path: path(95 - shift, 40, -20), destination: .system)]
        }
        func apply(_ inputs: [SankeyWave], pace: Int = 2, dark: Bool = true,
                   active: Bool = true, to: CGFloat = 360) {
            view.apply(waves: inputs, animating: active, travel: (0, to), pace: pace, dark: dark)
        }
        apply(waves())
        view.layoutSubtreeIfNeeded()
        let clock = view.layer!.sublayers!.first!
        let originalLayers = clock.sublayers!.map(ObjectIdentifier.init)
        var samples: [String: Any] = [:]
        func measure(_ name: String, _ body: (Int) -> Void) {
            Metrics.reset()
            let start = CFAbsoluteTimeGetCurrent()
            for i in 1...2000 { autoreleasepool { body(i) } }
            samples[name] = ["milliseconds": (CFAbsoluteTimeGetCurrent() - start) * 1000,
                             "updates": 2000, "color_writes": Metrics.colorWrites,
                             "location_writes": Metrics.locationWrites, "path_writes": Metrics.pathWrites]
        }
        let fixed = waves()
        measure("unchanged") { _ in apply(fixed) }
        measure("pace") { i in apply(fixed, pace: i % 4 + 1) }
        measure("path") { i in apply(waves(i)) }
        measure("appearance") { i in apply(fixed, dark: i % 2 == 0) }
        require(clock.sublayers!.map(ObjectIdentifier.init) == originalLayers,
                     "Reading/appearance changes must preserve native layer identity")

        // Assert resulting geometry, palette and animation, independently of
        // the update implementation. Also record model-layer raster parity
        // between comparison arms; this is not a render-server/GPU benchmark.
        var rasters: [String] = []
        for (dark, destination, width, to) in [(true, PowerFlow.Node.batteryIn, CGFloat(360), CGFloat(360)),
                                              (false, .batteryOut, 360, 500),
                                              (false, .batteryIn, 1200, 500),
                                              (false, .batteryOut, 1200, 500)] {
            view.frame.size.width = width
            let input = waves(3, destination: destination)
            apply(input, dark: dark, active: false, to: to)
            view.layoutSubtreeIfNeeded()
            let containers = clock.sublayers!
            let period = max(240, min(480, to * 0.65))
            let repeats = max(3, Int(ceil(width / period)) + 2)
            for (index, container) in containers.enumerated() {
                let mask = container.mask as! CAShapeLayer
                let gradient = container.sublayers![0] as! CAGradientLayer
                require(mask.path == input[index].path)
                require(gradient.colors!.count == repeats * 4 + 1)
                require(gradient.locations!.first == 0 && gradient.locations!.last == 1)
                require(abs(gradient.frame.width - CGFloat(repeats) * period) < 1e-8)
                let alpha: [CGFloat] = dark ? [0.02, 0.05, 0.16, 0.05] : [0.01, 0.03, 0.11, 0.03]
                for (stop, item) in gradient.colors!.enumerated() {
                    let expected = NSColor(PowerFlow.color(input[index].destination))
                        .withAlphaComponent(alpha[stop % 4]).cgColor
                    require((item as! CGColor) == expected)
                }
                require(gradient.animationKeys()?.isEmpty != false)
            }
            let context = CGContext(data: nil, width: Int(width), height: 160, bitsPerComponent: 8,
                                    bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            view.layer!.render(in: context)
            let data = Data(bytes: context.data!, count: context.bytesPerRow * context.height)
            require(data.contains { $0 != 0 }, "Raster probe must draw visible pixels")
            rasters.append(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        view.frame.size.width = 360
        apply(waves())
        view.layoutSubtreeIfNeeded()
        let beforePace = clock.convertTime(CACurrentMediaTime(), from: nil)
        apply(waves(), pace: 4)
        require(abs(clock.convertTime(CACurrentMediaTime(), from: nil) - beforePace) < 0.02,
                     "Pace changes must preserve the animation phase")
        window.shown = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        require(clock.speed == 0)
        let frozen = clock.convertTime(CACurrentMediaTime(), from: nil)
        apply(waves(6), pace: 1, dark: false)
        require(clock.speed == 0 && abs(clock.convertTime(CACurrentMediaTime(), from: nil) - frozen) < 0.001)
        window.shown = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        require(clock.speed > 0 && abs(clock.convertTime(CACurrentMediaTime(), from: nil) - frozen) < 0.02)

        // Topology changes may introduce a new band without changing size,
        // travel or appearance. Its palette and geometry must still be ready.
        apply([])
        require(clock.sublayers?.isEmpty != false)
        apply(waves(), dark: false)
        require(clock.sublayers!.count == 2)
        for container in clock.sublayers! {
            let gradient = container.sublayers![0] as! CAGradientLayer
            require(gradient.colors?.isEmpty == false && gradient.locations?.isEmpty == false)
            require(gradient.animation(forKey: "sweep") != nil)
        }
        apply([waves()[1]], dark: false)
        require(clock.sublayers!.count == 1)
        view.removeFromSuperview()
        require(clock.speed == 0)
        view.stop()
        require(clock.sublayers!.allSatisfy { $0.sublayers![0].animationKeys()?.isEmpty != false })
        samples["raster_sha256"] = rasters
        print(String(data: try JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
'''


sources = {'working_tree': current}
if args.compare:
    sources['baseline'] = subprocess.check_output(['git', 'show', args.baseline_ref + ':' + path], cwd=root, text=True)
samples = {name: [] for name in sources}
with tempfile.TemporaryDirectory(prefix='claudebar-ui-animation-') as folder:
    folder = Path(folder)
    binaries = {}
    for name, source in sources.items():
        swift = folder / (name + '.swift')
        binary = folder / name
        swift.write_text(harness(source))
        subprocess.run(['swiftc', '-O', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
        binaries[name] = binary
    for round_index in range(3 if args.compare else 1):
        order = list(binaries) if round_index % 2 == 0 else list(reversed(binaries))
        for name in order:
            sample = json.loads(subprocess.check_output([str(binaries[name])], text=True))
            samples[name].append(sample)
    if args.compare:
        hashes = [sample['raster_sha256'] for arm in samples.values() for sample in arm]
        assert all(item == hashes[0] for item in hashes), 'Model-layer raster appearance changed'
result = {'baseline_ref': args.baseline_ref if args.compare else None,
          'baseline_commit': subprocess.check_output(['git', 'rev-parse', args.baseline_ref], cwd=root, text=True).strip() if args.compare else None,
          'environment': {'platform': platform.platform(), 'machine': platform.machine(),
                          'swift': subprocess.check_output(['swiftc', '--version'], text=True, stderr=subprocess.STDOUT).strip(),
                          'optimization': '-O', 'visible_windows': False},
          'source_sha256': {name: hashlib.sha256(source.encode()).hexdigest() for name, source in sources.items()},
          'samples': samples,
          'medians_ms': {name: {key: statistics.median(sample[key]['milliseconds'] for sample in arm)
                                for key in ('unchanged', 'pace', 'path', 'appearance')}
                         for name, arm in samples.items()}}
if args.output_json:
    args.output_json.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(result['medians_ms'], indent=2))
print('PASS: Sankey palette/path/geometry/topology; stable layers, phase, occlusion and detach' +
      ('; identical model-layer rasters across comparison arms' if args.compare else ''))
