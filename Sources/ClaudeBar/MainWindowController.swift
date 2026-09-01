import AppKit
import SwiftUI

/// Owns the primary application window: a borderless-feeling, full-size-content
/// `NSWindow` with a deep vibrancy backdrop (`NSVisualEffectView`) hosting the
/// SwiftUI `MainWindowView`. The window is created once, kept alive across
/// close/reopen, and shared with the menu-bar popup via the single
/// `ProviderStore` injected into the SwiftUI environment.
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
        // Keep the traffic-light buttons but let content flow under the titlebar.
        window.standardWindowButton(.closeButton)?.superview?.isHidden = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ClaudeBarMainWindow")
        window.appearance = NSAppearance(named: .vibrantDark)
        window.collectionBehavior = [.fullScreenAuxiliary]

        // Translucent: the vibrancy view paints the background, not the window.
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true

        // Frosted-glass backdrop. `.underWindowBackground` is deeper than the
        // panel's `.menu` material — appropriate for a persistent main window.
        let vibe = NSVisualEffectView()
        vibe.material = .underWindowBackground
        vibe.blendingMode = .behindWindow
        vibe.state = .active
        vibe.wantsLayer = true

        window.contentView = vibe

        hosting.translatesAutoresizingMaskIntoConstraints = false
        vibe.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: vibe.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: vibe.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: vibe.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: vibe.bottomAnchor),
        ])
        return window
    }
}
