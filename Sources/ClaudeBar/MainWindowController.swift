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
    /// The page the window was last showing. The hosting view is torn down on
    /// close (see `releaseContent`), so the selection has to live outside the
    /// view graph or every reopen would snap back to 概览.
    private var lastPage: AppPage = .dashboard

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

    /// Bring the window to the front, creating it on first call, rebuilding its
    /// content if it was torn down on close, or focusing it if it is already up.
    func showWindow() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if let window {
            // Reused shell: the AppKit window (and its autosaved frame)
            // survives the close, only the SwiftUI content is remade.
            installContent(in: window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            observeVisibility(of: window)
            return
        }
        let window = makeWindow()
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        observeVisibility(of: window)
    }

    /// Drop the SwiftUI graph when the window closes.
    ///
    /// `isReleasedWhenClosed = false` keeps the `NSWindow` alive across
    /// close/reopen, which also keeps its `NSHostingView` alive — and an
    /// ordered-out hosting view keeps driving a full display cycle. Measured
    /// with the window closed and nothing on screen: ~18–20 % of a core, all
    /// of it on the main thread inside `UC::DriverCore::continueProcessing` →
    /// `CA::Transaction::commit` → `NSDisplayCycleFlush` →
    /// `NSHostingView.layout()` → `ViewGraph.renderDisplayList` → glyph
    /// rasterisation. Clearing `contentView` took the same app to 0.0–0.7 %.
    /// The window is cheap to keep (it owns the autosaved frame and the AppKit
    /// shell); only the view graph has to go, and `showWindow` rebuilds it in
    /// ~50–150 ms.
    private func releaseContent() {
        UIWakePolicy.setMainWindowVisible(false)
        // `willClose` fires while the close is still in flight; dropping the
        // view graph inside that notification tears down layers mid-animation,
        // so land the teardown on the next main-queue turn instead.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !window.isVisible else { return }
            window.contentView = nil
        }
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
        windowObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.releaseContent()
        })
        // isVisible is not yet true at this point in makeKeyAndOrderFront's
        // cycle on some launches; re-assert after the order-front settles.
        DispatchQueue.main.async { sync() }
    }

    // MARK: - Window construction

    private func installContent(in window: NSWindow) {
        let rootView = MainWindowView(initialPage: lastPage) { [weak self] page in
            self?.lastPage = page
        }
            .environmentObject(providerStore)
            .environment(\.providerSource, providerStore)
            .environmentObject(codexProviderStore)
            .environmentObject(trafficState)

        let hosting = NSHostingView(rootView: rootView)
        // No size feedback into AppKit. `NSHostingView`'s default sizing
        // options make every layout pass call `invalidateSizeConstraints`
        // → `minSize()` → a full `sizeThatFits` walk of the entire view
        // graph. Sampling the idle app showed that walk at ~16 % of a core
        // with every window ordered out. The window owns the geometry
        // (contentRect + `setFrameAutosaveName`), and `autoresizingMask`
        // keeps the host filling it without entering the constraint engine —
        // the same arrangement the notch island and the menu-bar popup use.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
    }

    private func makeWindow() -> NSWindow {
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
        installContent(in: window)
        return window
    }
}
