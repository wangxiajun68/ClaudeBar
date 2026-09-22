import AppKit
import SwiftUI
import Combine

extension NSColor {
    convenience init(hex: UInt, opacity: CGFloat = 1.0) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: opacity)
    }
}

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
    private let codexProviderStore: CodexProviderStore
    private var isOpen = false

    init(providerStore: ProviderStore, codexProviderStore: CodexProviderStore) {
        self.providerStore = providerStore
        self.codexProviderStore = codexProviderStore
        super.init()
    }

    private var rateAccessory: VpnMenuBarRateView?
    private var rateCancel: AnyCancellable?
    private var lastRateKey: String?
    private var appearanceObs: NSObjectProtocol?

    @MainActor
    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else {
            NSLog("[ClaudeBar] statusItem.button is nil — aborting")
            return
        }
        button.image = MenuBarMark.image()
        button.imagePosition = .imageLeft
        button.title = ""
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        installVpnRateDisplay(button: button)
        appearanceObs = NotificationCenter.default.addObserver(
            forName: .appearanceDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyPanelAppearance()
        }
    }

    /// ClashX-style: a 22pt-tall two-line accessory, not NSStatusBarButton's
    /// attributedTitle (which cannot wrap, so ↓/↑ never updated visibly).
    ///
    /// Event-driven, not a 1 Hz timer: the old loop re-rasterized the icon and
    /// rebuilt two `NSImage`s every second even with the VPN stopped. Rate
    /// changes come from `VpnManager`'s own publishes, and the menu-bar image
    /// is only redrawn when a displayed value actually changes.
    @MainActor
    private func installVpnRateDisplay(button: NSStatusBarButton) {
        let accessory = VpnMenuBarRateView()
        rateAccessory = accessory
        button.addSubview(accessory)
        rateCancel = VpnLiveRates.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .merge(with: VpnManager.shared.objectWillChange.receive(on: DispatchQueue.main))
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.tickVpnRate() }
            }
        tickVpnRate()
    }

    /// The accessory is owned by AppKit, not by ARC: `removeFromSuperview` on
    /// a view reachable only from the status-bar button's subview list drops
    /// the last owning reference while `rateAccessory` — a plain strong
    /// property — keeps a dangling pointer to it, and `tickVpnRate()` would
    /// then write through freed memory. Call this before dropping anything
    /// that can tear the status item down, and before `setup()` builds a new
    /// one; `installVpnRateDisplay` re-creates it.
    @MainActor
    func teardownVpnRateDisplay() {
        rateCancel?.cancel()
        rateCancel = nil
        guard let accessory = rateAccessory else { return }
        accessory.removeFromSuperview()
        rateAccessory = nil
        lastRateKey = nil
    }

    @MainActor
    private func tickVpnRate() {
        guard let button = statusItem.button, let accessory = rateAccessory else { return }
        let running = VpnManager.shared.isRunning
        if running {
            let down = VpnFormat.compact(VpnLiveRates.shared.speedDown)
            let up = VpnFormat.compact(VpnLiveRates.shared.speedUp)
            // Both rates unchanged → the accessory already shows them; skip
            // the icon rasterization and label re-layout entirely.
            let key = "\(down)|\(up)"
            guard key != lastRateKey else { return }
            lastRateKey = key
            button.image = nil
            accessory.isHidden = false
            accessory.update(icon: MenuBarMark.image(side: 16), down: down, up: up)
            accessory.frame = NSRect(x: 0, y: 1, width: VpnMenuBarRateView.fullWidth, height: 20)
            statusItem.length = VpnMenuBarRateView.fullWidth + 6
        } else {
            guard lastRateKey != nil else { return }
            lastRateKey = nil
            accessory.isHidden = true
            accessory.frame = .zero
            button.image = MenuBarMark.image()
            statusItem.length = NSStatusItem.squareLength
        }
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
        // Rebuild the hosting view on open rather than keeping a hidden one
        // alive. An ordered-out panel still owns a live SwiftUI graph: its
        // 2s fan poll, 1 Hz VPN chart and body re-evaluation all keep running
        // for a window nobody can see. The panel and vibrancy container are
        // reused, so only the content is remade (~50–150 ms).
        if hostingView == nil { makeHostingView() }
        guard let hosting = hostingView else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Size to the new content first: sizeAndPosition reads fittingSize.
        if let content = panel.contentView {
            hosting.frame = content.bounds
            content.addSubview(hosting)
        }
        sizeAndPosition(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        isOpen = true
        UIWakePolicy.setPopupOpen(true)
        installMonitors()
    }

    private func hide() {
        panel?.orderOut(nil)
        hostingView?.removeFromSuperview()
        hostingView = nil
        isOpen = false
        UIWakePolicy.setPopupOpen(false)
        removeMonitors()
    }

    // MARK: - Panel

    private func makeHostingView() {
        let rootView = AnyView(
            MenuBarView()
                .environmentObject(providerStore)
                .environmentObject(codexProviderStore)
        )
        let hosting = NSHostingView(rootView: rootView)
        // Autoresizing 而非 Auto Layout 约束：macOS 26 上 NSHostingView 在显示周期内
        // 触发 setNeedsUpdateConstraints 会抛 "may not modify constraints during layout"
        // 并中止（点击菜单栏图标崩溃）。AutoresizingMask 同样铺满且不参与约束引擎。
        hosting.autoresizingMask = [.width, .height]
        hostingView = hosting
    }

    private func applyPanelAppearance() {
        let fill = Theme.windowNSColor
        panel?.appearance = Theme.nsAppearance
        panel?.backgroundColor = .clear
        panel?.isOpaque = false
        panel?.contentView?.layer?.backgroundColor = fill.cgColor
        panel?.contentView?.layer?.cornerRadius = 22
        panel?.contentView?.layer?.cornerCurve = .continuous
        panel?.contentView?.layer?.masksToBounds = true
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                                 styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = Theme.nsAppearance
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = Theme.windowNSColor.cgColor
        host.layer?.cornerRadius = 22
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true

        panel.contentView = host
        host.autoresizesSubviews = true
        panel.onCancel = { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
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
        let width = max(400, fit.width)
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
///
/// Esc closes it. The panel is on the highest-frequency surface of the app and
/// the only dismissal was a mouse-down outside, so a keyboard user had to move
/// the pointer and click. `cancelOperation` is what AppKit sends along the
/// responder chain for Esc; SwiftUI does not consume it for a plain panel.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        // 53 = Escape. Some key paths deliver `keyDown` without the
        // `cancelOperation` interpretation, so handle it explicitly and only
        // forward what we did not consume.
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

/// 16pt tri-blade, transparent, template — the PNG has an opaque mint
/// square, so `isTemplate` painted a solid block in the menu bar.
enum MenuBarMark {
    /// The mark is a pure function of `side` and only two sizes are ever
    /// asked for, but `NSImage(size:flipped:)` re-runs the whole bezier
    /// rasterization on each call (and the menu-bar update path calls it
    /// every second while the VPN is up).
    private static var cache: [CGFloat: NSImage] = [:]
    private static let cacheLock = NSLock()

    static func image(side: CGFloat = 18) -> NSImage {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[side] { return hit }
        let made = make(side: side)
        cache[side] = made
        return made
    }

    private static func make(side: CGFloat) -> NSImage {
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.set()
            let stroke = max(1.4, side * 0.14)
            let r = side * 0.30
            let cx = rect.midX
            let cy = rect.midY + side * 0.07
            let ring = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            ring.lineWidth = stroke
            ring.stroke()
            let barH = max(1.35, side * 0.11)
            let barW = side * 0.78
            let bar = NSBezierPath(
                roundedRect: NSRect(
                    x: (side - barW) / 2,
                    y: side * 0.07,
                    width: barW,
                    height: barH),
                xRadius: barH / 2,
                yRadius: barH / 2)
            bar.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Icon + two-line rates. Arrows are SF Symbols; numbers are tabular, not
/// unicode arrows glued to the digits.
private final class VpnMenuBarRateView: NSView {
    static let iconSide: CGFloat = 16
    /// Sized for the widest compact rate, `999.9K` (7 chars at 9.5pt
    /// monospaced digits ≈ 41pt) — anything narrower lets three-digit rates
    /// paint past the capsule backing.
    static let rateWidth: CGFloat = 46
    static var fullWidth: CGFloat { iconSide + 4 + rateWidth }

    private let iconView = NSImageView()
    private let downLabel = VpnMenuBarRateView.makeLabel()
    private let upLabel = VpnMenuBarRateView.makeLabel()
    private let downArrow = VpnMenuBarRateView.makeArrow("arrow.down")
    private let upArrow = VpnMenuBarRateView.makeArrow("arrow.up")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Fixed dark capsule behind the digits — the menu bar is translucent,
        // so wallpaper can be any brightness. A constant dark backing keeps
        // white digits readable without guessing the background.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .white
        addSubview(iconView)
        addSubview(downArrow)
        addSubview(upArrow)
        addSubview(downLabel)
        addSubview(upLabel)
    }

    required init?(coder: NSCoder) { nil }

    func update(icon: NSImage?, down: String, up: String) {
        iconView.image = icon
        downLabel.stringValue = down
        upLabel.stringValue = up
        // Contrast follows the system appearance (labelColor flips with light/
        // dark menu bar), so it stays readable over any wallpaper. Add a soft
        // dark shadow for light wallpaper + light mode, where black text on a
        // translucent strip still needs separation.
        let downColor = Self.rateColor(down)
        let upColor = Self.rateColor(up)
        downLabel.textColor = downColor
        upLabel.textColor = upColor
        downArrow.contentTintColor = downColor
        upArrow.contentTintColor = upColor
    }

    /// Bright activity → full-strength label; idle → dimmed. Both track the
    /// system appearance, which is what the translucent menu bar matches.
    private static func rateColor(_ text: String) -> NSColor {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let value = Double(trimmed.dropLast(1)) ?? 0 // strip unit letter
        let unit = trimmed.last.map(String.init) ?? ""
        let kb: Double
        switch unit {
        case "G": kb = value * 1024 * 1024
        case "M": kb = value * 1024
        default: kb = value
        }
        if kb < 1 { return NSColor.labelColor.withAlphaComponent(0.45) }
        if kb < 1024 { return NSColor.labelColor.withAlphaComponent(0.75) }
        return .labelColor
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.fullWidth, height: 20) }
    override var fittingSize: NSSize { intrinsicContentSize }

    override func layout() {
        super.layout()
        let h = bounds.height
        iconView.frame = NSRect(x: 0, y: (h - Self.iconSide) / 2, width: Self.iconSide, height: Self.iconSide)
        let ax: CGFloat = Self.iconSide + 3
        downArrow.frame = NSRect(x: ax, y: 10, width: 7, height: 9)
        upArrow.frame = NSRect(x: ax, y: 1, width: 7, height: 9)
        let nx = ax + 8
        let nw = bounds.width - nx
        downLabel.frame = NSRect(x: nx, y: 9, width: nw, height: 11)
        upLabel.frame = NSRect(x: nx, y: 0, width: nw, height: 11)
    }

    private static func makeLabel() -> NSTextField {
        let f = NSTextField(labelWithString: "  0.0K")
        f.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        f.textColor = NSColor.labelColor.withAlphaComponent(0.45)
        f.alignment = .right
        f.lineBreakMode = .byClipping
        f.drawsBackground = false
        f.isBezeled = false
        f.isEditable = false
        return f
    }

    private static func makeArrow(_ name: String) -> NSImageView {
        let v = NSImageView()
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.isTemplate = true
        v.image = img
        v.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .semibold)
        v.contentTintColor = NSColor.labelColor.withAlphaComponent(0.45)
        v.imageScaling = .scaleProportionallyDown
        return v
    }
}
