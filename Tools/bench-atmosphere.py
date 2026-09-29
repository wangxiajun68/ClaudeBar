#!/usr/bin/env python3
"""Measure the greeting card's per-frame cost on this Mac.

Compiles the production `SkyScene`, `AtmosphereShader`, `AtmosphereRenderer`
and `GreetingScript` into a probe (-O) and reports, per representative scene:

  sky ms    median GPU time of a frame that also redrew the cloud deck
  front ms  median GPU time of a frame that only sampled the deck and drew
            precipitation, the greeting and the drops
  cpu µs    median CPU time to encode that frame (uniforms, fades, events)

and the one-off CPU costs on the main thread: greeting layout, greeting
rasterisation (the texture upload's CPU half) and `SkyScene.make`.

Usage: python3 Tools/bench-atmosphere.py [--width 1100] [--scale 2] [--frames 120]
A frame budget is 16.7 ms at 60 Hz and 8.3 ms at 120 Hz; the sky should use a
small fraction of it, since the window server and SwiftUI share the GPU.
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
out = root / '.build/atmosphere-bench'
out.mkdir(parents=True, exist_ok=True)


def declaration(path, start):
    text = (root / path).read_text()
    pos = text.index(start)
    opening = text.index('{', pos)
    level, end = 1, opening + 1
    while level:
        level += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[pos:end] + '\n'


args = sys.argv[1:]
def arg(name, default):
    return args[args.index(name) + 1] if name in args else default

source = 'import AppKit\nimport SwiftUI\n'
source += 'let scriptFonts = "' + str(root / 'Sources/Fonts') + '"\n'
source += (root / 'Sources/ClaudeBar/Utils/SkyAstronomy.swift').read_text() + '\n'
source += declaration('Sources/ClaudeBar/Utils/WeatherForecastFetcher.swift', 'struct WeatherDay: Equatable, Identifiable {')
source += declaration('Sources/ClaudeBar/Utils/WeatherFetcher.swift', 'struct WeatherReading: Equatable {')
for name in ('SkyScene', 'AtmosphereShader', 'AtmosphereRenderer', 'GreetingScript'):
    source += (root / f'Sources/ClaudeBar/Views/Shared/Atmosphere/{name}.swift').read_text() + '\n'
source += '''
@main struct AtmosphereBench {
    static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    @MainActor static func main() throws {
        GreetingScript.resourceRoot = URL(fileURLWithPath: scriptFonts)
        let width = CGFloat(Double(CommandLine.arguments[1]) ?? 1100)
        let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 2)
        let frames = Int(CommandLine.arguments[3]) ?? 120
        let gpu: AtmosphereGPU
        do { gpu = try AtmosphereGPU() } catch { fatalError("Metal pipeline failed: \\(error)") }
        // The card's own metrics (GreetingStatusSheet.Metrics).
        let sky = min(430, max(330, width * 0.38)).rounded()
        let size = CGSize(width: width, height: sky + 56)
        let margin: CGFloat = width >= 900 ? 32 : 24
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        print("card \\(Int(size.width))×\\(Int(size.height)) pt, drawable \\(Int(pixels.width))×\\(Int(pixels.height)) px, \\(gpu.device.name)")

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: AtmosphereGPU.pixelFormat,
            width: Int(pixels.width), height: Int(pixels.height), mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        let target = gpu.device.makeTexture(descriptor: descriptor)!

        let iso = ISO8601DateFormatter()
        let cases: [(String, String, WeatherReading.Sky, Int)] = [
            ("day clear", "2026-09-28T04:30:00Z", .clear, 0),
            ("day cloudy", "2026-09-28T04:30:00Z", .partly, 10),
            ("day overcast", "2026-09-28T04:30:00Z", .cloudy, 20),
            ("day heavy rain", "2026-09-28T04:30:00Z", .rain, 90),
            ("day thunder", "2026-09-28T04:30:00Z", .thunder, 90),
            ("day snow", "2026-09-28T04:30:00Z", .snow, 30),
            ("day fog", "2026-09-28T04:30:00Z", .fog, 10),
            ("sunset cloudy", "2026-09-28T10:14:00Z", .partly, 10),
            ("night clear", "2026-09-27T16:30:00Z", .clear, 0),
            ("night cloudy", "2026-09-27T16:30:00Z", .partly, 10),
            ("night rain", "2026-09-27T16:30:00Z", .rain, 90)]
        print("scene               sky ms  front ms   cpu µs")
        for c in cases {
            let astronomy = SkyAstronomy.snapshot(date: iso.date(from: c.1)!, latitude: 23.13, longitude: 113.26)
            let scene = SkyScene.make(sky: c.2, rainChance: c.3, windKph: 12, windDirection: "东南", astronomy: astronomy)
            let layout = GreetingTypesetter.layout("good afternoon,", name: "XIAJUN WANG", cardWidth: width,
                                                   skyHeight: sky, margin: margin,
                                                   topClear: margin - 8 + 88 + 6, bottomClear: sky - 14 - 80 - 6)
            let renderer = AtmosphereRenderer(gpu: gpu)
            renderer.input = .init(scene: scene, layout: layout, skyHeight: sky, darkInk: scene.prefersDarkInk,
                                   darkAppearance: false, reduceMotion: false)
            renderer.skipEntrance()
            // A still installs the greeting texture synchronously; the live
            // path rasterises it on a queue this loop never yields to.
            _ = renderer.snapshot(size: size, scale: scale)
            var skyTimes: [Double] = [], frontTimes: [Double] = [], cpuTimes: [Double] = []
            let t0 = CACurrentMediaTime()
            for i in 0..<(frames + 10) {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                let buffer = gpu.queue.makeCommandBuffer()!
                let c0 = CACurrentMediaTime()
                renderer.encode(pass: pass, commandBuffer: buffer, pixelSize: pixels, scale: scale,
                                now: t0 + Double(i) / 60)
                let c1 = CACurrentMediaTime()
                buffer.commit()
                buffer.waitUntilCompleted()
                // The first frames upload the greeting texture and warm caches.
                // `sky` is a frame that also redrew the cloud deck; `front` only
                // sampled it and drew precipitation, the greeting and the drops.
                if i >= 10 {
                    let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                    if renderer.drewSky { skyTimes.append(ms) } else { frontTimes.append(ms) }
                    cpuTimes.append((c1 - c0) * 1_000_000)
                }
            }
            let skyMs = skyTimes.isEmpty ? 0 : median(skyTimes)
            let front = frontTimes.isEmpty ? "     —" : String(format: "%6.2f", median(frontTimes))
            print(c.0.padding(toLength: 18, withPad: " ", startingAt: 0),
                  String(format: "%6.2f  ", skyMs) + front + String(format: "   %6.1f", median(cpuTimes)))
        }

        func time(_ label: String, runs: Int = 20, _ body: () -> Void) {
            var values: [Double] = []
            for _ in 0..<runs { let a = CACurrentMediaTime(); body(); values.append((CACurrentMediaTime() - a) * 1000) }
            print(label.padding(toLength: 34, withPad: " ", startingAt: 0), String(format: "%7.3f ms", median(values)))
        }
        print("")
        let astronomy = SkyAstronomy.snapshot(date: iso.date(from: "2026-09-28T04:30:00Z")!, latitude: 23.13, longitude: 113.26)
        time("SkyScene.make") { _ = SkyScene.make(sky: .partly, rainChance: 10, windKph: 12, windDirection: "东南", astronomy: astronomy) }
        time("SkyAstronomy.snapshot") { _ = SkyAstronomy.snapshot(date: Date(), latitude: 23.13, longitude: 113.26) }
        let layout = GreetingTypesetter.layout("good afternoon,", name: "XIAJUN WANG", cardWidth: width, skyHeight: sky, margin: margin)
        time("GreetingTypesetter.layout (cached)") {
            _ = GreetingTypesetter.layout("good afternoon,", name: "XIAJUN WANG", cardWidth: width, skyHeight: sky, margin: margin)
        }
        time("GreetingTypesetter.rasterize", runs: 10) { _ = GreetingTypesetter.rasterize(layout, scale: scale) }
        time("GreetingScript first line/face", runs: 1) { _ = GreetingScript.line("good evening,", typeface: .zapfino) }
    }
}
'''
probe = out / 'Bench.swift'
probe.write_text(source)
binary = out / 'bench'
subprocess.run(['swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macos15.0', str(probe),
                '-o', str(binary)], check=True)
subprocess.run([str(binary), arg('--width', '1100'), arg('--scale', '2'), arg('--frames', '120')], check=True)
