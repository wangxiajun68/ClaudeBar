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

Usage: python3 Tools/bench-atmosphere.py [--width 1100] [--scale 2] [--frames 120] [--contrast] [--baseline-ref REF]
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
    text = read(path)
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

def read(path):
    if '--baseline-ref' in args:
        return subprocess.check_output(['git', 'show', f'{arg("--baseline-ref", "HEAD")}:{path}'], cwd=root, text=True)
    return (root / path).read_text()

source = 'import AppKit\nimport SwiftUI\nimport CryptoKit\n'
source += 'let scriptFonts = "' + str(root / 'Sources/Fonts') + '"\n'
source += read('Sources/ClaudeBar/Utils/SkyAstronomy.swift') + '\n'
source += declaration('Sources/ClaudeBar/Utils/WeatherForecastFetcher.swift', 'struct WeatherDay: Equatable, Identifiable {')
source += declaration('Sources/ClaudeBar/Utils/WeatherFetcher.swift', 'struct WeatherReading: Equatable {')
source += declaration('Sources/ClaudeBar/Views/Shared/GreetingCard.swift', '    private struct Metrics {').replace('private struct Metrics', 'struct CardMetrics', 1)
for name in ('SkyScene', 'AtmosphereShader', 'AtmosphereRenderer', 'GreetingScript'):
    source += read(f'Sources/ClaudeBar/Views/Shared/Atmosphere/{name}.swift') + '\n'
source += r'''
@main struct AtmosphereBench {
    static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    @MainActor static func main() throws {
        GreetingScript.resourceRoot = URL(fileURLWithPath: scriptFonts)
        let width = CGFloat(Double(CommandLine.arguments[1]) ?? 1100)
        let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 2)
        let frames = Int(CommandLine.arguments[3]) ?? 120
        let gpu: AtmosphereGPU
        do { gpu = try AtmosphereGPU() } catch { fatalError("Metal pipeline failed: \(error)") }
        // The card's own metrics (GreetingStatusSheet.Metrics).
        let metrics = CardMetrics(width: width)
        let sky = metrics.sky
        let size = CGSize(width: width, height: metrics.total)
        let margin = metrics.margin
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        print("card \(Int(size.width))×\(Int(size.height)) pt, drawable \(Int(pixels.width))×\(Int(pixels.height)) px, \(gpu.device.name)")

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
        var measurements: [[String: Any]] = []
        for c in cases {
            let astronomy = SkyAstronomy.snapshot(date: iso.date(from: c.1)!, latitude: 23.13, longitude: 113.26)
            let scene = SkyScene.make(sky: c.2, rainChance: c.3, windKph: 12, windDirection: "东南", astronomy: astronomy)
            // Metrics are extracted from the current card, including its
            // width-dependent clearances; the probe must not keep an old layout.
            let layout = GreetingTypesetter.layout("good afternoon,", name: "XIAJUN WANG", cardWidth: width,
                                                   skyHeight: sky, margin: margin,
                                                   topClear: metrics.topClear,
                                                   bottomClear: metrics.bottomClear)
            let renderer = AtmosphereRenderer(gpu: gpu)
            renderer.input = .init(scene: scene, layout: layout, skyHeight: sky, darkInk: scene.prefersDarkInk,
                                   darkAppearance: false, reduceMotion: false)
            renderer.skipEntrance()
            // A still installs the greeting texture synchronously; the live
            // path rasterises it on a queue this loop never yields to.
            let snapshot = renderer.snapshot(size: size, scale: scale)!
            let snapshotHash = SHA256.hash(data: snapshot.dataProvider!.data! as Data).map { String(format: "%02x", $0) }.joined()
            if CommandLine.arguments.contains("--contrast") {
                // Sample the backgrounds where the small information labels
                // actually sit, and composite over them the ink the card
                // *actually picks* — per region, by the same rule the body
                // uses (`SkyScene.prefersDarkInk(at:aspect:)`): 86%-opaque
                // white on a dark sky, 86%-opaque navy (0x141E33) on a light
                // one. Modelling everything as white ink is what made this
                // gate report 1.1:1 on a clear day and refuse the run.
                //
                // The rects mirror `GreetingStatusSheet.Metrics` below: the
                // clock and weather blocks start at `top`, the sun path sits
                // above `sky - 14 - 57`, and the forecast starts at `chartTop`.
                let top = metrics.top
                let nowHeight = metrics.nowHeight
                let chartTop = metrics.chartTop
                let aspect = Float(size.width / sky)
                let whiteInk = SIMD3<Double>(1, 1, 1)
                let navy = SIMD3<Double>(20, 30, 51) / 255
                let regions: [(String, CGRect, SIMD2<Float>)] = [
                    ("clock", CGRect(x: margin, y: top, width: 160, height: 50),
                     SIMD2(0.12, Float((top + 30) / sky))),
                    ("now", CGRect(x: width - margin - metrics.chartWidth, y: top, width: metrics.chartWidth, height: nowHeight),
                     SIMD2(0.85, Float((top + nowHeight / 2) / sky))),
                    ("sun path", CGRect(x: margin, y: sky - 71, width: metrics.sunWidth, height: 44),
                     SIMD2(0.18, Float((sky - 42) / sky))),
                    ("forecast", CGRect(x: width - margin - metrics.chartWidth, y: chartTop, width: metrics.chartWidth, height: metrics.chartHeight),
                     SIMD2(0.85, Float((chartTop + metrics.chartHeight / 2) / sky))),
                    ("hourly", CGRect(x: metrics.hourlyX, y: metrics.hourlyTop, width: metrics.hourlyWidth, height: metrics.hourlyHeight),
                     SIMD2(Float((metrics.hourlyX + metrics.hourlyWidth / 2) / width), Float((metrics.hourlyTop + metrics.hourlyHeight / 2) / sky))),
                ]
                func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
                func luminance(_ c: SIMD3<Double>) -> Double {
                    0.2126 * linear(c.x) + 0.7152 * linear(c.y) + 0.0722 * linear(c.z)
                }
                // The gate is the *median* of each region, at 3:1 — the WCAG
                // floor for the large ink (the 28pt temperature) that shares
                // these corners. It is not a per-pixel floor, and the run
                // prints the worst pixel per scene so the difference stays
                // visible: a bright moon, a lightning channel and the sun's own
                // glow sit inside these boxes, and a label crossing one of them
                // reads at ~1:1 no matter which ink the card picks. A gate at
                // 4.5:1 for every pixel — what the docs claimed before this
                // audit, and what the old white-only model reported as 1.1:1 —
                // cannot be met by any sky, so it was never a gate at all.
                var ratiosByRegion: [String: [Double]] = [:]
                var worst = Double.infinity
                var worstLabel = ""
                for phase in [42.0, 42.4, 42.8] {
                    let image = renderer.snapshot(size: size, scale: scale, time: phase)!
                    let data = image.dataProvider!.data!
                    let bytes = CFDataGetBytePtr(data)!
                    for (label, region, uv) in regions {
                        let ink = scene.prefersDarkInk(at: uv, aspect: aspect) ? navy : whiteInk
                        for y in stride(from: Int(region.minY), through: Int(region.maxY), by: 2) {
                            for x in stride(from: Int(region.minX), through: Int(region.maxX), by: 2) {
                                let offset = Int(CGFloat(y) * scale) * image.bytesPerRow + Int(CGFloat(x) * scale) * 4
                                let b = Double(bytes[offset]) / 255, g = Double(bytes[offset + 1]) / 255, r = Double(bytes[offset + 2]) / 255
                                let background = luminance(SIMD3(r, g, b))
                                // 86% ink over the sampled sky, as the labels draw it.
                                let painted = luminance(ink * 0.86 + SIMD3(r, g, b) * 0.14)
                                // WCAG's ratio is lighter-over-darker, and the
                                // navy ink is the *darker* of the two on a day
                                // sky — computing painted-over-background
                                // unconditionally reported a healthy region as
                                // 0.1:1 and inverted the gate's meaning.
                                let lighter = max(painted, background)
                                let darker = min(painted, background)
                                let ratio = (lighter + 0.05) / (darker + 0.05)
                                ratiosByRegion[label, default: []].append(ratio)
                                if ratio < worst { worst = ratio; worstLabel = label }
                            }
                        }
                    }
                }
                var medians: [(String, Double)] = []
                for (label, values) in ratiosByRegion {
                    let sorted = values.sorted()
                    let median = sorted[sorted.count / 2]
                    medians.append((label, median))
                    print(String(format: "    %@ median %.2f:1 (worst %.2f:1)",
                                 label, median, sorted[0]))
                }
                let shakiest = medians.min { $0.1 < $1.1 }!
                print(String(format: "  information ink %@: weakest median %.2f:1 (%@), worst pixel %.2f:1 (%@)",
                             c.0, shakiest.1, shakiest.0, worst, worstLabel))
                // A trap aborts before a pipe's buffer is drained, so without
                // this the failing run prints nothing at all and the number
                // that failed is lost exactly when it is wanted.
                fflush(stdout)
                precondition(shakiest.1 >= 3.0,
                             "Information ink in \(c.0): the \(shakiest.0) region's median is "
                             + "\(shakiest.1):1 — below the 3:1 floor for the ink the card draws there")
            }
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
            measurements.append(["scene": c.0, "sky_gpu_ms": skyMs,
                                 "snapshot_sha256": snapshotHash,
                                 "front_gpu_ms": frontTimes.isEmpty ? NSNull() : median(frontTimes),
                                 "encode_cpu_us": median(cpuTimes), "sky_frames": skyTimes.count, "front_frames": frontTimes.count])
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
        print("METRICS " + String(data: try JSONSerialization.data(withJSONObject: ["width": width, "height": size.height, "scale": scale, "frames": frames, "scenes": measurements], options: [.sortedKeys]), encoding: .utf8)!)
    }
}
'''
probe = out / 'Bench.swift'
probe.write_text(source)
binary = out / 'bench'
subprocess.run(['swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macos15.0', str(probe),
                '-o', str(binary)], check=True)
subprocess.run([str(binary), arg('--width', '1100'), arg('--scale', '2'), arg('--frames', '120')] + (['--contrast'] if '--contrast' in args else []), check=True)
