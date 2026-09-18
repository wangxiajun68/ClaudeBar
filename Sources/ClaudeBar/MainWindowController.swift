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
    /// Outlives the traffic page's mount — see `TrafficPageState`.
    let trafficState = TrafficPageState()

    private var appearanceObs: NSObjectProtocol?

    init(providerStore: ProviderStore, codexProviderStore: CodexProviderStore) {
        self.providerStore = providerStore
        self.codexProviderStore = codexProviderStore
        appearanceObs = NotificationCenter.default.addObserver(
            forName: .appearanceDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.window?.appearance = Theme.nsAppearance
            self.window?.backgroundColor = Theme.windowNSColor
        }
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
        observeVisibility(of: window)
    }

    /// Feed the window's on-screen state to `UIWakePolicy` so the pollers can
    /// drop to their sleep cadence when nothing is visible. Without this the
    /// app burns ~60% of a core on scans whose results nobody is looking at.
    private func observeVisibility(of window: NSWindow) {
        let center = NotificationCenter.default
        let sync: () -> Void = { [weak window] in
            guard let window else { return }
            UIWakePolicy.setMainWindowVisible(window.isVisible && !window.isMiniaturized)
        }
        for name: NSNotification.Name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ] {
            center.addObserver(forName: name, object: window, queue: .main) { _ in sync() }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            UIWakePolicy.setMainWindowVisible(false)
        }
        // isVisible is not yet true at this point in makeKeyAndOrderFront's
        // cycle on some launches; re-assert after the order-front settles.
        DispatchQueue.main.async { sync() }
    }

    // MARK: - Window construction

    private func makeWindow() -> NSWindow {
        let rootView = MainWindowView()
            .environmentObject(providerStore)
            .environmentObject(codexProviderStore)
            .environmentObject(trafficState)

        let hosting = NSHostingView(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ClaudeBar"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.superview?.isHidden = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ClaudeBarMainWindow")
        window.appearance = Theme.nsAppearance
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.backgroundColor = Theme.windowNSColor
        window.isOpaque = true
        window.hasShadow = true
        window.contentView = hosting
        return window
    }
}
