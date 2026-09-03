import AppKit
import SwiftUI

/// Owns the primary application window: a full-size-content `NSWindow`
/// hosting SwiftUI `MainWindowView`. Opaque (no window-wide vibrancy) so
/// the GPU is not holding a full-size backdrop blur. Created once, kept
/// alive across close/reopen, shared with the menu-bar popup via the
/// single `ProviderStore`.
final class MainWindowController {
    private var window: NSWindow?
    private let providerStore: ProviderStore
    private let codexProviderStore: CodexProviderStore

    init(providerStore: ProviderStore, codexProviderStore: CodexProviderStore) {
        self.providerStore = providerStore
        self.codexProviderStore = codexProviderStore
    }

    /// Bring the window to the front, creating it on first call or recreating
    /// it if the user closed it. Single-instance: a second call while visible
    /// just focuses the existing window.
    func showWindow() {
        if let window = window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = makeWindow()
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Window construction

    private func makeWindow() -> NSWindow {
        let rootView = MainWindowView()
            .environmentObject(providerStore)
            .environmentObject(codexProviderStore)

        let hosting = NSHostingView(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Axon"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.superview?.isHidden = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ClaudeBarMainWindow")
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.fullScreenAuxiliary]
        // Opaque fill: a full-window NSVisualEffectView plus per-tile
        // glassEffect was ~100 MB of GPU backing stores on a Retina window.
        window.backgroundColor = NSColor(srgbRed: 13/255, green: 13/255, blue: 17/255, alpha: 1)
        window.isOpaque = true
        window.hasShadow = true
        window.contentView = hosting
        return window
    }
}
