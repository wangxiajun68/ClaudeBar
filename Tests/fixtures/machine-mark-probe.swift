import SwiftUI
import AppKit

enum Theme {
    static let chartGreen = Color(red: 0.11, green: 0.62, blue: 0.32)
    static let chartBlue = Color(red: 0.15, green: 0.44, blue: 0.92)
    static let chartAmber = Color(red: 0.92, green: 0.62, blue: 0.10)
    static let chartPurple = Color(red: 0.55, green: 0.32, blue: 0.85)
    static let textSecondary = Color.gray
}

/// The probe compiles `HardwareIllustration`, `InstrumentGlyph` and the
/// geometry/paths files they call standalone. `HardwareIllustration` names
/// `InstrumentGlyph.Kind` in its bridge from the app's shared symbol table to
/// these marks; the real enum has no bearing on the geometry, but the *body* is
/// what the header check below measures, so the production type is sliced in
/// whole rather than stubbed.
struct ProbeKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var surfaceIsVisible: Bool { get { self[ProbeKey.self] } set { self[ProbeKey.self] = newValue } }
}

// The tokens below are replaced by the Python suites with the production
// source: the generated geometry, the hardware paths the badge draws, the tile
// badge itself, the mark, and the shared `CALayer.retime(to:)` its sweep calls.
<<<RETIME>>>

<<<LUCIDE_GEOMETRY>>>

<<<LUCIDE_PATHS>>>

<<<INSTRUMENT_GLYPH>>>

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

        let frame = CGSize(width: 128, height: 104)

        // The lane and bar rects the mark itself computed, printed for the
        // Python side to measure. The suite used to mirror `placement(in:)` and
        // `laneBars(...)` in Python, and that copy silently stopped matching the
        // drawing when the lane split was refactored (aa9ea5a); the numbers are
        // read off the production functions now.
        let placed = HardwareIllustration.placement(in: frame)
        print("LANE \(placed.lane.minX) \(placed.lane.minY) "
              + "\(placed.lane.width) \(placed.lane.height)")

        func write(_ name: String, _ mark: HardwareIllustration) {
            for (index, bar) in HardwareIllustration.laneBars(kind: mark.kind, level: mark.load,
                                                             cells: mark.cells, wells: mark.wells,
                                                             lane: placed.lane).enumerated() {
                print("BAR \(name) \(index) \(bar.rect.minX) \(bar.rect.minY) "
                      + "\(bar.rect.width) \(bar.rect.height)")
            }
            // The sweep is an AppKit layer. ImageRenderer snapshots that view
            // over the canvas, so the fixture measures the bars with it off.
            let renderer = ImageRenderer(content: ZStack { Color.white; mark }
                .environment(\.rendersHardwareSweep, false)
                .frame(width: frame.width, height: frame.height))
            renderer.scale = 8
            guard let cg = renderer.cgImage else { fatalError("no image for \(name)") }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
                fatalError("no png for \(name)")
            }
            try? png.write(to: out.appendingPathComponent("\(name).png"))
        }

        // The tile badge at the frame `ResourceStrip.meter` hands it. The old
        // fixture drew an SF Symbol stand-in here, whose ink sat ~8pt inside the
        // box: the margin probe could not touch a glyph, let alone an ornament
        // around one. This renders the badge the app actually draws.
        func writeBadge(_ name: String, _ kind: InstrumentGlyph.Kind) {
            let renderer = ImageRenderer(content: ZStack {
                Color.white
                InstrumentBadge(kind: kind, tint: Theme.chartGreen).frame(width: 26, height: 26)
            }.frame(width: 26, height: 26))
            renderer.scale = 8
            guard let cg = renderer.cgImage else { fatalError("no image for \(name)") }
            guard let png = NSBitmapImageRep(cgImage: cg)
                .representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
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
        // No published sub-units → the same fallback the CPU render exercises.
        write("gpu-aggregate", HardwareIllustration(kind: .gpu, load: 0.55, tint: blue))

        // 内存 / 硬盘.
        write("mem", HardwareIllustration(kind: .memory, load: 0.79, tint: amber,
                                          wells: [0.42, 0.12, 0.08]))
        write("disk", HardwareIllustration(kind: .disk, load: 0.82, tint: purple,
                                           wells: [0.82]))

        writeBadge("badge-cpu", .cpu)
        writeBadge("badge-gpu", .gpu)
        writeBadge("badge-memory", .memory)
        writeBadge("badge-disk", .disk)

        print("wrote \(out.path)")
    }
}
