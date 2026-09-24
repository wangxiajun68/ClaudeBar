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
    /// Window-scoped observers registered by `observeVisibility(of:)`. Every
    /// `showWindow()` after the user closes the window builds a fresh
    /// `NSWindow`, and `addObserver(forName:object:queue:using:)` returns a
    /// token that is **not** auto-removed — without holding and removing them
    /// the old window's five blocks stay registered with the center (and keep
    /// the closed window alive) for every close/reopen cycle.
    private var windowObservers: [NSObjectProtocol] = []

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
        // Drop the previous window's registrations first (see
        // `windowObservers`); `window` is captured weakly below, but the
        // observer *blocks* would still pile up one set per reopen.
        for token in windowObservers { center.removeObserver(token) }
        windowObservers.removeAll()

        let sync: () -> Void = { [weak window] in
            guard let window else { return }
            UIWakePolicy.setMainWindowVisible(window.isVisible && !window.isMiniaturized
                && window.occlusionState.contains(.visible))
        }
        for name: NSNotification.Name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { _ in sync() })
        }
        windowObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            UIWakePolicy.setMainWindowVisible(false)
        })
        // isVisible is not yet true at this point in makeKeyAndOrderFront's
        // cycle on some launches; re-assert after the order-front settles.
        DispatchQueue.main.async { sync() }
    }

    // MARK: - Window construction

    private func makeWindow() -> NSWindow {
        let rootView = MainWindowView()
            .environmentObject(providerStore)
                .environment(\.providerSource, providerStore)
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
