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
    'Sources/ClaudeBar/Views/Shared/WoodenFishView.swift',
    'Sources/ClaudeBar/WoodenFishController.swift',
))
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
            precondition(model.total >= 2, "real repeating timer")
            model.interval = 3
            let afterChange = model.total
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
            precondition(model.total == afterChange, "old cadence was invalidated")
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
            print("PASS: manual strike, auto timer, cadence replacement, hide/show and performance teardown")
            return
        }
        for _ in 0..<108 { model.strike() }
        for dark in [false, true] {
            AppPreferences.shared.isDark = dark
            for size in WoodenFishSize.allCases {
                model.size = size
                model.isAutomatic = dark
                let host = NSHostingView(rootView: WoodenFishView(model: model, strike: {})
                    .background(Theme.bgPrimary))
                host.frame = CGRect(origin: .zero, size: size.panelSize)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
                window.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("bitmap") }
                host.cacheDisplay(in: host.bounds, to: rep)
                let name = "\(size.rawValue)-\(dark ? "dark" : "light").png"
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
