import SwiftUI
import AppKit

enum Theme {
    static let chartGreen = Color(red: 0.11, green: 0.62, blue: 0.32)
    static let chartBlue = Color(red: 0.15, green: 0.44, blue: 0.92)
    static let cardSurface = Color(white: 0.98)
}

// The token below is replaced by Tests/machine-mark-regressions.py with the text
// of Sources/ClaudeBar/Views/Shared/HardwareIllustration.swift.
<<<HARDWARE_ILLUSTRATION>>>

/// Renders each case the test measures and writes them as PNGs beside the
/// output path. Decoding happens in Python rather than here on purpose:
/// `NSBitmapImageRep.colorAt` on a `CGImage`-backed rep reported the same
/// luminance for a lit and an idle core, so a probe built on it "passed" a mark
/// that drew nothing. The PNG round-trip is the same path a screenshot takes.
@main struct Probe {
    @MainActor static func main() {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        guard args.count > 1 else { fatalError("usage: probe <output-directory>") }
        let out = URL(fileURLWithPath: args[1])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        /// Mark + opaque white backdrop, so the raster carries absolute
        /// luminance that a decoder can read without alpha compositing.
        func write(_ name: String, _ mark: HardwareIllustration) {
            let renderer = ImageRenderer(content: ZStack { Color.white; mark }.frame(width: 112, height: 80))
            renderer.scale = 8
            guard let cg = renderer.cgImage else { fatalError("no image for \(name)") }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
                fatalError("no png for \(name)")
            }
            try? png.write(to: out.appendingPathComponent("\(name).png"))
        }

        let green = Theme.chartGreen, blue = Theme.chartBlue

        // CPU: one cell per logical core.
        write("cpu-12", HardwareIllustration(kind: .cpu, load: 0.95,
                                             tint: green, cells: Array(repeating: 0.95, count: 12)))
        write("cpu-10", HardwareIllustration(kind: .cpu, load: 0.95,
                                             tint: green, cells: Array(repeating: 0.95, count: 10)))
        write("cpu-8", HardwareIllustration(kind: .cpu, load: 0.95,
                                            tint: green, cells: Array(repeating: 0.95, count: 8)))
        write("cpu-idle", HardwareIllustration(kind: .cpu, load: 0.0,
                                               tint: green, cells: Array(repeating: 0.0, count: 12)))
        write("cpu-half", HardwareIllustration(kind: .cpu, load: 0.5, tint: green,
                                               cells: [0.95,0.95,0.95,0.95,0.95,0.95,0,0,0,0,0,0]))
        write("cpu-30", HardwareIllustration(kind: .cpu, load: 0.3,
                                             tint: green, cells: Array(repeating: 0.30, count: 12)))
        // No per-core reading → one aggregate plate.
        write("cpu-aggregate", HardwareIllustration(kind: .cpu, load: 0.62, tint: green))

        // GPU: one column per published sub-unit.
        write("gpu-full", HardwareIllustration(kind: .gpu, load: 1.0, tint: blue, cells: [1.0, 1.0, 1.0]))
        write("gpu-mixed", HardwareIllustration(kind: .gpu, load: 0.5, tint: blue, cells: [1.0, 0.5, 0.0]))
        write("gpu-empty", HardwareIllustration(kind: .gpu, load: 0.0, tint: blue, cells: [0.0, 0.0, 0.0]))
        write("gpu-aggregate", HardwareIllustration(kind: .gpu, load: 0.55, tint: blue))

        // The header as `ResourceStrip.meter` builds it: glyph, label, pill. A
        // `LoadRing` at 28pt puts ink in the corners of the glyph's box.
        let header = HStack(spacing: 6) {
            Image(systemName: "cpu").font(.system(size: 12, weight: .semibold))
                .foregroundColor(green).frame(width: 28, height: 28)
            Text("CPU").font(.system(size: 13))
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 14).frame(width: 300, height: 56)
        .background(Color.white)
        let hr = ImageRenderer(content: header)
        hr.scale = 8
        if let cg = hr.cgImage, let png = NSBitmapImageRep(cgImage: cg)
            .representation(using: NSBitmapImageRep.FileType.png, properties: [:]) {
            try? png.write(to: out.appendingPathComponent("header.png"))
        }

        print("wrote \(out.path)")
    }
}
