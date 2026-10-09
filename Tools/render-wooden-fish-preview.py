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
source += r'''
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
            model.size = CommandLine.arguments.contains("--small") ? .small : .regular
            model.isHovered = CommandLine.arguments.contains("--hover")
            let host = NSHostingView(rootView: WoodenFishView(model: model, strike: {}))
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
            for frame in 0..<180 {
                RunLoop.current.run(until: start.addingTimeInterval(Double(frame) / 30))
                // First strike, then 32 quick taps: cloud overlap and all combo tiers.
                if frame == 1 || (45...107).contains(frame) && (frame - 45).isMultiple(of: 2) {
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
            print("Rendered real strike animation at 30fps, including overlapping rapid taps")
            return
        }
        for _ in 0..<108 { model.strike() }
        model.endInteraction()
        for dark in [false, true] {
            AppPreferences.shared.isDark = dark
            for size in WoodenFishSize.allCases {
                model.size = size
                model.isAutomatic = false
                model.isHovered = CommandLine.arguments.contains("--hover")
                let host = NSHostingView(rootView: WoodenFishView(model: model, strike: {}))
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
                let suffix = model.isHovered ? "-hover" : ""
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
