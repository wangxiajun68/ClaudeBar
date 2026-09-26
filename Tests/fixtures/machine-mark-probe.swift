import SwiftUI
import AppKit

enum Theme {
    static let chartGreen = Color(red: 0.11, green: 0.62, blue: 0.32)
    static let chartBlue = Color(red: 0.15, green: 0.44, blue: 0.92)
    static let chartAmber = Color(red: 0.92, green: 0.62, blue: 0.10)
    static let chartPurple = Color(red: 0.55, green: 0.32, blue: 0.85)
    static let cardSurface = Color(white: 0.98)
}

/// The probe compiles `HardwareIllustration` standalone, and that file now names
/// `InstrumentGlyph.Kind` in its bridge from the app's shared symbol table to
/// these marks. The real enum is a 28-case view-layer type with no bearing on the
/// geometry, so the probe carries the four cases the bridge can return.
enum InstrumentGlyph {
    enum Kind { case cpu, gpu, memory, disk }
}

struct ProbeKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var surfaceIsVisible: Bool { get { self[ProbeKey.self] } set { self[ProbeKey.self] = newValue } }
}

// The tokens below are replaced by Tests/machine-mark-regressions.py with the
// text of the generated geometry and the mark itself.
<<<LUCIDE_GEOMETRY>>>

<<<HARDWARE_ILLUSTRATION>>>

/// Renders each case and writes it as a PNG beside the output path. Decoding
/// happens in Python: `NSBitmapImageRep.colorAt` on a `CGImage`-backed rep
/// reported the same luminance for a lit and an idle bar, so a probe built on it
/// "passed" a mark that drew nothing. The PNG round-trip is the path a
/// screenshot takes.
@main struct Probe {
    @MainActor static func main() {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        guard args.count > 1 else { fatalError("usage: probe <output-directory>") }
        let out = URL(fileURLWithPath: args[1])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        func write(_ name: String, _ mark: HardwareIllustration) {
            let renderer = ImageRenderer(content: ZStack { Color.white; mark }.frame(width: 128, height: 104))
            renderer.scale = 8
            guard let cg = renderer.cgImage else { fatalError("no image for \(name)") }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
                fatalError("no png for \(name)")
            }
            try? png.write(to: out.appendingPathComponent("\(name).png"))
        }

        let green = Theme.chartGreen, blue = Theme.chartBlue,
            amber = Theme.chartAmber, purple = Theme.chartPurple

        // CPU: one bar per logical core.
        write("cpu-12", HardwareIllustration(kind: .cpu, load: 0.95, tint: green,
                                             cells: Array(repeating: 0.95, count: 12)))
        write("cpu-10", HardwareIllustration(kind: .cpu, load: 0.95, tint: green,
                                             cells: Array(repeating: 0.95, count: 10)))
        write("cpu-8", HardwareIllustration(kind: .cpu, load: 0.95, tint: green,
                                            cells: Array(repeating: 0.95, count: 8)))
        write("cpu-idle", HardwareIllustration(kind: .cpu, load: 0.0, tint: green,
                                               cells: Array(repeating: 0.0, count: 12)))
        write("cpu-half", HardwareIllustration(kind: .cpu, load: 0.5, tint: green,
                                               cells: [0.95,0.95,0.95,0.95,0.95,0.95,0,0,0,0,0,0]))
        write("cpu-30", HardwareIllustration(kind: .cpu, load: 0.3, tint: green,
                                             cells: Array(repeating: 0.30, count: 12)))
        // No per-core reading → one bar at the aggregate.
        write("cpu-aggregate", HardwareIllustration(kind: .cpu, load: 0.62, tint: green))

        // GPU: one bar per published sub-unit.
        write("gpu-full", HardwareIllustration(kind: .gpu, load: 1.0, tint: blue,
                                               cells: [1.0, 1.0, 1.0]))
        write("gpu-mixed", HardwareIllustration(kind: .gpu, load: 0.5, tint: blue,
                                                cells: [1.0, 0.5, 0.1]))
        write("gpu-aggregate", HardwareIllustration(kind: .gpu, load: 0.55, tint: blue))

        // 内存 / 硬盘.
        write("mem", HardwareIllustration(kind: .memory, load: 0.79, tint: amber,
                                          wells: [0.42, 0.12, 0.08]))
        write("disk", HardwareIllustration(kind: .disk, load: 0.82, tint: purple,
                                           wells: [0.82]))

        // The header as `ResourceStrip.meter` builds it: glyph, label, pill.
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
