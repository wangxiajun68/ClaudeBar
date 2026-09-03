import AppKit
import SwiftUI

/// Owns the menu-bar status item and a manually-positioned panel that hosts
/// the SwiftUI menu. The panel is centered horizontally on the screen (its
/// vertical center axis) just below the menu bar, instead of being anchored
/// to the status-item icon's corner.
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let providerStore: ProviderStore
    private var isOpen = false

    init(providerStore: ProviderStore) {
        self.providerStore = providerStore
        super.init()
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else {
            NSLog("[ClaudeBar] statusItem.button is nil — aborting")
            return
        }
        button.image = Self.menuBarImage()
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        NSLog("[ClaudeBar] status item created OK")
    }

    private static func menuBarImage() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            let fallback = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "ClaudeBar")
            fallback?.isTemplate = true
            return fallback
        }
        image.isTemplate = true
        // Optical size matches SF Symbols “medium” in the menu bar (~20pt).
        image.size = NSSize(width: 20, height: 20)
        return image
    }

    @objc private func statusItemClicked() {
        if isOpen { hide() } else { show() }
    }

    /// Programmatic show — called from widget tap URL handler.
    func showPanel() {
        if !isOpen { show() }
    }

    // MARK: - Show / Hide

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        sizeAndPosition(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        isOpen = true
        installMonitors()
    }

    private func hide() {
        panel?.orderOut(nil)
        isOpen = false
        removeMonitors()
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let rootView = AnyView(
            MenuBarView()
                .environmentObject(providerStore)
        )
        let hosting = NSHostingView(rootView: rootView)
        hostingView = hosting

        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                                 styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Translucent: the vibrancy view paints the background, not the panel.
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .vibrantDark)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        // Frosted-glass backdrop (macOS vibrancy). `.menu` matches the
        // material used by system menu-bar dropdowns.
        let vibe = NSVisualEffectView()
        vibe.material = .menu
        vibe.blendingMode = .behindWindow
        vibe.state = .followsWindowActiveState
        vibe.wantsLayer = true
        vibe.layer?.cornerRadius = 10
        vibe.layer?.masksToBounds = true

        panel.contentView = vibe

        hosting.translatesAutoresizingMaskIntoConstraints = false
        vibe.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: vibe.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: vibe.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: vibe.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: vibe.bottomAnchor),
        ])
        return panel
    }

    /// Position the panel so its horizontal center axis passes through the
    /// status-item icon — i.e. the icon sits at the top-center of the panel.
    private func sizeAndPosition(_ panel: NSPanel) {
        // The status item lives on the menu bar, which is always on the
        // primary screen (NSScreen.screens[0]). NSScreen.main may be a
        // secondary display with a negative origin — wrong reference.
        guard let screen = NSScreen.screens.first else { return }
        guard let hosting = hostingView else { return }
        let fit = hosting.fittingSize
        let width = max(560, fit.width)
        let height = max(200, min(fit.height, screen.visibleFrame.height - 8))

        // Horizontal: center on the icon. The status-item button lives in its
        // own borderless window; combine the window's global origin with the
        // button's offset within it to get the icon's true screen x.
        var x = screen.frame.midX
        if let button = statusItem.button {
            let btnInWindow = button.superview?.convert(button.frame, to: nil) ?? button.frame
            let windowOriginX = button.window?.frame.origin.x ?? 0
            let globalIconX = windowOriginX + btnInWindow.midX
            x = globalIconX - width / 2
        }
        // Clamp so the panel stays on the menu-bar screen.
        x = max(screen.visibleFrame.minX + 4, min(x, screen.visibleFrame.maxX - width - 4))

        // Vertical: top edge just below the menu bar.
        // visibleFrame.maxY is exactly the menu-bar bottom in global coords.
        let y = screen.visibleFrame.maxY - height - 4

        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    // MARK: - Dismissal (click outside)

    /// Local monitor catches mouse-downs delivered to OUR app windows.
    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .otherMouseDown
        ]) { [weak self] event in
            self?.handleLocalMouseDown(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .otherMouseDown
        ]) { [weak self] _ in
            DispatchQueue.main.async { self?.hide() }
        }
    }

    private func handleLocalMouseDown(_ event: NSEvent) {
        guard let panel = panel, isOpen else { return }
        // If the click is not in our panel, dismiss.
        let location = NSEvent.mouseLocation
        if !panel.frame.contains(location) {
            hide()
        }
    }

    private func removeMonitors() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }
}

/// Borderless panel that is allowed to become the key window (so SwiftUI
/// alerts and controls work) without activating the application.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
