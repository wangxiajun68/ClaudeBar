#!/usr/bin/env python3
"""Real view/controller preview; synthetic defaults, no sound or permissions.
--check only compiles; render uses ephemeral offscreen hosting windows.
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
out = root / '.build/wooden-fish-preview'
out.mkdir(parents=True, exist_ok=True)
theme = (root / 'Sources/ClaudeBar/Theme/Theme.swift').read_text()
source = theme[:theme.index('// MARK: - Soft drop shadow')] + '\n'
source += '\n'.join((root / path).read_text() for path in (
    'Sources/ClaudeBar/Models/WoodenFishModel.swift',
    'Sources/ClaudeBar/Utils/WoodenFishAudio.swift',
    'Sources/ClaudeBar/Utils/WoodenFishGeometry.swift',
    'Sources/ClaudeBar/Utils/WoodenFishMotion.swift',
    'Sources/ClaudeBar/Views/Shared/WoodenFishView.swift',
    'Sources/ClaudeBar/WoodenFishController.swift',
))
# accessibilityReduceMotion is read-only in SwiftUI; inject only the binding
# into this isolated preview to exercise the production reduced-motion branch.
if '--reduced-motion' in sys.argv:
    source = source.replace('@Environment(\\.accessibilityReduceMotion) private var reduceMotion',
                            'private let reduceMotion = true')
if '--measure' in sys.argv:
    source = source.replace('Canvas { context, _ in', 'Canvas { context, _ in\n PreviewDrawCounter.record()')
source += r'''
enum PreviewDrawCounter {
    static var count = 0
    static var times: [Double] = []
    static func record() {
        count += 1
        times.append(ProcessInfo.processInfo.systemUptime)
    }
}
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    @Published var isDark = false
}
enum AppPresentation { static var allowsInterface = true }

@main struct Preview {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let suite = "wooden-fish-preview-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = WoodenFishModel(defaults: defaults)
        if CommandLine.arguments.contains("--measure") {
            model.muted = true
            model.size = CommandLine.arguments.contains("--large") ? .large : .regular
            let host = NSHostingView(rootView: WoodenFishView(model: model, strike: {}))
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: model.size.panelSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.isOpaque = false
            window.backgroundColor = .clear
            let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            window.setFrameOrigin(CGPoint(x: screen.maxX - host.frame.width - 24, y: screen.minY + 24))
            window.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            func cpu() -> Double { Double(clock()) / Double(CLOCKS_PER_SEC) }
            let idleStart = cpu()
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            let idleCPU = cpu() - idleStart
            PreviewDrawCounter.count = 0
            PreviewDrawCounter.times.removeAll(keepingCapacity: true)
            let activeStart = cpu()
            let start = Date()
            for frame in 0..<180 {
                RunLoop.current.run(until: start.addingTimeInterval(Double(frame) / 60))
                if frame.isMultiple(of: 5) { model.strike() }
            }
            let activeCPU = cpu() - activeStart
            let activeDraws = PreviewDrawCounter.count
            let activeElapsed = Date().timeIntervalSince(start)
            let intervals = zip(PreviewDrawCounter.times.dropFirst(), PreviewDrawCounter.times)
                .map { $0 - $1 }.sorted()
            let p95 = intervals.isEmpty ? 0 : intervals[min(intervals.count - 1, Int(Double(intervals.count) * 0.95))]
            let slowFrames = intervals.filter { $0 > 0.025 }.count
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            let settledDrawStart = PreviewDrawCounter.count
            let settledStart = cpu()
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            let settledCPU = cpu() - settledStart
            let hitStart = cpu()
            var hits = 0
            for index in 0..<100_000 {
                if WoodenFishGeometry.captures(CGPoint(x: index % 188, y: index % 222), scale: model.size.scale) { hits += 1 }
            }
            print("MEASURE visible muted production-view fixture: idle_3s_cpu=\(idleCPU), 12_strikes_per_second_3s_cpu=\(activeCPU), settled_3s_cpu=\(settledCPU), settled_draws=\(PreviewDrawCounter.count - settledDrawStart), hit_test_100k_cpu=\(cpu() - hitStart), hits=\(hits), strikes=\(model.total), active_draws=\(activeDraws), draws_per_second=\(Double(activeDraws) / activeElapsed), p95_interval_ms=\(p95 * 1000), intervals_over_25ms=\(slowFrames)")
            window.orderOut(nil)
            window.contentView = nil
            return
        }
        if CommandLine.arguments.contains("--exercise") {
            model.enabled = true
            model.muted = true
            model.interval = 0.5
            let controller = WoodenFishController(model: model)
            controller.start()
            controller.strike()
            precondition(model.total == 1, "real manual strike route")
            model.isAutomatic = true
            let deadline = Date().addingTimeInterval(3)
            while model.total < 2, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            precondition(model.total >= 2 && model.feedback.combo == 0 && model.feedback.surprise == nil, "real repeating timer has automatic feedback")
            model.interval = 3
            let afterChange = model.total
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
            precondition(model.total == afterChange, "old cadence was invalidated")
            if let panel = NSApp.windows.first {
                let point = CGPoint(x: 110 * model.size.scale,
                                    y: panel.frame.height - (36 + 114 * model.size.scale))
                func mouse(_ type: NSEvent.EventType, _ location: CGPoint) {
                    panel.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
                }
                let beforeClick = model.total
                mouse(.leftMouseDown, point)
                precondition(model.isPressed && model.total == beforeClick, "press prepares without counting")
                mouse(.leftMouseUp, point)
                precondition(!model.isPressed && model.total == beforeClick + 1, "release strikes exactly once")
                mouse(.leftMouseUp, point)
                precondition(model.total == beforeClick + 1, "duplicate release cannot strike")
                mouse(.leftMouseDown, point)
                mouse(.leftMouseUp, CGPoint(x: point.x + 10, y: point.y))
                precondition(model.total == beforeClick + 1, "movement without drag delivery still cannot strike")
                panel.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
                panel.makeKey()
                panel.makeFirstResponder(panel.contentView)
                let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53)!
                panel.sendEvent(escape)
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                precondition(!model.isAutomatic, "real Escape handler pauses automatic strikes")
            } else { preconditionFailure("real controller panel missing") }
            model.enabled = false
            precondition(!model.isAutomatic, "hide stops automatic mode")
            let hidden = model.total
            controller.strike()
            precondition(model.total == hidden, "hidden panel refuses taps")
            model.enabled = true
            precondition(!model.isAutomatic, "show does not restart timer")
            model.isAutomatic = true
            AppPresentation.allowsInterface = false
            controller.strike()
            precondition(model.total == hidden, "performance mode rejects strikes")
            controller.stop()
            precondition(!model.isAutomatic && model.enabled, "teardown preserves preference but stops timer")
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            precondition(model.total == hidden, "no ticks after teardown")
            precondition(NSApp.windows.allSatisfy { !$0.isVisible }, "no panel left behind")
            print("PASS: manual strike, auto timer, cadence replacement, native Escape, hide/show and performance teardown")
            return
        }
        if CommandLine.arguments.contains("--motion") {
            AppPreferences.shared.isDark = CommandLine.arguments.contains("--dark")
            model.size = CommandLine.arguments.contains("--small") ? .small : .regular
            model.isHovered = CommandLine.arguments.contains("--hover")
            let host = NSHostingView(rootView: WoodenFishView(model: model, strike: {}))
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: model.size.panelSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = host
            window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let start = Date()
            var taps = 0
            for frame in 0..<360 {
                RunLoop.current.run(until: start.addingTimeInterval(Double(frame) / 60))
                // First strike, then 32 quick taps: cloud overlap and all combo tiers.
                if frame == 2 || (90...214).contains(frame) && (frame - 90).isMultiple(of: 4) {
                    model.strike()
                    taps += 1
                }
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("bitmap") }
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(
                    to: URL(fileURLWithPath: CommandLine.arguments[1])
                        .appendingPathComponent(String(format: "motion-%03d.png", frame)))
            }
            precondition(taps == 33 && model.total == 33, "animation preserves rapid-tap counts")
            precondition(model.feedback.combo == 32 && model.feedback.surprise == .cache, "real fast-tap rhythm reaches all tiers")
            window.orderOut(nil)
            window.contentView = nil
            print("Rendered real strike animation at 60fps, including overlapping rapid taps")
            return
        }
        for _ in 0..<108 { model.strike() }
        model.endInteraction()
        for dark in [false, true] {
            AppPreferences.shared.isDark = dark
            for size in WoodenFishSize.allCases {
                model.size = size
                model.isAutomatic = CommandLine.arguments.contains("--auto")
                model.isHovered = CommandLine.arguments.contains("--hover")
                let host = NSHostingView(rootView: WoodenFishView(model: model, strike: {}))
                host.sizingOptions = []
                host.frame = CGRect(origin: .zero, size: size.panelSize)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.contentView = host
                window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
                window.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("bitmap") }
                host.cacheDisplay(in: host.bounds, to: rep)
                let suffix = model.isAutomatic ? "-auto" : model.isHovered ? "-hover" : ""
                let name = "\(size.rawValue)-\(dark ? "dark" : "light")\(suffix).png"
                try rep.representation(using: .png, properties: [:])!.write(
                    to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name))
                window.orderOut(nil)
                window.contentView = nil
            }
        }
        print("Rendered production wooden fish (three sizes, both themes)")
    }
}
'''
path = out / 'Preview.swift'
path.write_text(source)
binary = out / 'preview'
subprocess.run(['swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macos15.0',
                str(path), '-o', str(binary)], check=True)
if '--check' not in sys.argv:
    subprocess.run([str(binary), str(out), *sys.argv[1:]], check=True)
else:
    print('PASS: production wooden-fish model, artwork, controls, audio and controller compile')
