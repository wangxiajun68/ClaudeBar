#!/usr/bin/env python3
"""Render the production atmosphere shader for every solar band × weather.

Compiles `SkyScene`, `AtmosphereShader` and `AtmosphereRenderer` from the app
sources into a small probe, renders each combination off-screen through the same
Metal pipeline the card uses, and writes:

  .build/atmosphere-preview/matrix.png   8 × 8 contact sheet (bands × weather)
  .build/atmosphere-preview/<band>-<weather>.png   full-size stills

Usage: python3 Tools/render-atmosphere-preview.py [--width 1100] [--only band-weather]
Synthetic fixture (Guangzhou, 2026-09-28); no live service is read.
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
out = root / '.build/atmosphere-preview'
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
width = args[args.index('--width') + 1] if '--width' in args else '1100'
only = args[args.index('--only') + 1] if '--only' in args else ''

source = 'import AppKit\nimport SwiftUI\n'
source += 'let scriptFonts = "' + str(root / 'Sources/Fonts') + '"\n'
source += (root / 'Sources/ClaudeBar/Utils/SkyAstronomy.swift').read_text() + '\n'
source += declaration('Sources/ClaudeBar/Utils/WeatherForecastFetcher.swift', 'struct WeatherDay: Equatable, Identifiable {')
source += declaration('Sources/ClaudeBar/Utils/WeatherFetcher.swift', 'struct WeatherReading: Equatable {')
for name in ('SkyScene', 'AtmosphereShader', 'AtmosphereRenderer', 'GreetingScript'):
    source += (root / f'Sources/ClaudeBar/Views/Shared/Atmosphere/{name}.swift').read_text() + '\n'
source += '''
@main struct AtmosphereProbe {
    @MainActor static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        GreetingScript.resourceRoot = URL(fileURLWithPath: scriptFonts)
        let width = CGFloat(Double(CommandLine.arguments[2]) ?? 1100)
        let only = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""
        let gpu: AtmosphereGPU
        do { gpu = try AtmosphereGPU() } catch { fatalError("Metal pipeline failed: \\(error)") }
        let sill: CGFloat = 56
        let skyHeight = (min(390, max(250, width * 0.34))).rounded()
        let size = CGSize(width: width, height: skyHeight + sill)
        let margin: CGFloat = width >= 900 ? 32 : 24
        // Local times in Guangzhou (UTC+8) chosen to land in each solar band.
        let bands: [(String, String, String)] = [
            ("night", "2026-09-27T16:30:00Z", "Still up,"), ("dawn", "2026-09-27T21:52:00Z", "Morning,"),
            ("sunrise", "2026-09-27T22:24:00Z", "Morning,"), ("morning", "2026-09-28T01:00:00Z", "Good morning,"),
            ("noon", "2026-09-28T04:30:00Z", "Good afternoon,"), ("afternoon", "2026-09-28T07:40:00Z", "Good afternoon,"),
            ("sunset", "2026-09-28T10:14:00Z", "Good evening,"), ("dusk", "2026-09-28T10:52:00Z", "Good evening,")]
        let weathers: [(String, WeatherReading.Sky, Int)] = [
            ("clear", .clear, 0), ("cloudy", .partly, 10), ("overcast", .cloudy, 20), ("lightRain", .rain, 40),
            ("heavyRain", .rain, 90), ("thunder", .thunder, 90), ("snow", .snow, 30), ("fog", .fog, 10)]
        let thumb = CGSize(width: size.width / 2, height: size.height / 2)
        let label: CGFloat = 26
        let sheetW = Int(thumb.width) * weathers.count, sheetH = Int(thumb.height + label) * bands.count + Int(label)
        let sheet = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        sheet.setFillColor(CGColor(gray: 0.1, alpha: 1))
        sheet.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
        func text(_ string: String, at point: CGPoint) {
            let attributed = NSAttributedString(string: string, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor(white: 0.85, alpha: 1)])
            sheet.textPosition = point
            CTLineDraw(CTLineCreateWithAttributedString(attributed), sheet)
        }
        let iso = ISO8601DateFormatter()
        for (row, band) in bands.enumerated() {
            let date = iso.date(from: band.1)!
            let astronomy = SkyAstronomy.snapshot(date: date, latitude: 23.13, longitude: 113.26)
            for (column, weather) in weathers.enumerated() {
                let key = "\\(band.0)-\\(weather.0)"
                if !only.isEmpty && key != only { continue }
                let scene = SkyScene.make(sky: weather.1, rainChance: weather.2, windKph: 12, windDirection: "东南",
                                          astronomy: astronomy)
                let layout = GreetingTypesetter.layout(band.2, name: "Xiajun Wang", cardWidth: width, skyHeight: skyHeight, margin: margin)
                let renderer = AtmosphereRenderer(gpu: gpu)
                renderer.input = .init(scene: scene, layout: layout, skyHeight: skyHeight,
                                       darkInk: scene.prefersDarkInk, darkAppearance: false, reduceMotion: false,
                                       rainbow: band.0 == "afternoon" && weather.0 == "cloudy")
                guard let image = renderer.snapshot(size: size, scale: 2, time: 37) else { fatalError("render failed") }
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\\(key).png"))
                let y = CGFloat(sheetH) - CGFloat(row + 1) * (thumb.height + label) - label
                sheet.draw(image, in: CGRect(x: CGFloat(column) * thumb.width, y: y, width: thumb.width, height: thumb.height))
                if column == 0 { text("\\(band.0)  sun \\(Int(astronomy.sun.altitude))°  \\(scene.band.rawValue)", at: CGPoint(x: 8, y: y + thumb.height + 6)) }
                if row == 0 { text(weather.0, at: CGPoint(x: CGFloat(column) * thumb.width + 8, y: CGFloat(sheetH) - label + 6)) }
            }
        }
        // Lightning at the peak of a return stroke, one channel per seed.
        for (band, seed) in [("night", Float(11.3)), ("dusk", Float(27.9)), ("afternoon", Float(42.6))] where only.isEmpty || only == "strike" {
            let entry = bands.first { $0.0 == band }!
            let astronomy = SkyAstronomy.snapshot(date: iso.date(from: entry.1)!, latitude: 23.13, longitude: 113.26)
            let scene = SkyScene.make(sky: .thunder, rainChance: 90, windKph: 12, windDirection: "东南", astronomy: astronomy)
            let renderer = AtmosphereRenderer(gpu: gpu)
            renderer.input = .init(scene: scene, layout: GreetingTypesetter.layout(entry.2, name: "Xiajun Wang", cardWidth: width,
                                                                                    skyHeight: skyHeight, margin: margin),
                                   skyHeight: skyHeight, darkInk: scene.prefersDarkInk, darkAppearance: false,
                                   reduceMotion: false, rainbow: false)
            renderer.stillFlash = SIMD4(0.9, 0.3 + Float(seed.truncatingRemainder(dividingBy: 5)) * 0.1, seed, 1)
            guard let image = renderer.snapshot(size: size, scale: 2, time: 37) else { fatalError("render failed") }
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: out.appendingPathComponent("strike-\\(band).png"))
        }
        if only.isEmpty, let image = sheet.makeImage() {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: out.appendingPathComponent("matrix.png"))
        }
        print("Rendered atmosphere preview to \\(out.path)")
    }
}
'''
probe = out / 'Probe.swift'
probe.write_text(source)
binary = out / 'probe'
subprocess.run(['swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macos15.0', str(probe),
                '-o', str(binary)], check=True)
subprocess.run([str(binary), str(out), width] + ([only] if only else []), check=True)
