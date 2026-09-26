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
    /// Set when the click-outside monitor dismissed the popup for a mouse-down
    /// that landed on the status item itself. AppKit runs that monitor *before*
    /// the item's action for the same mouse-down, so without this the action
    /// saw a popup that had just been hidden and re-opened it — the icon could
    /// never dismiss its own popup. Set and cleared on the main thread only.
    private var closingFromStatusItem = false
    /// Re-positions the open panel when the display arrangement changes (a
    /// monitor unplugged, a resolution switch). `sizeAndPosition` re-derives
    /// the screen on every `show()`, but nothing re-ran it while the panel was
    /// already up, so the popup stayed clamped to the old screen until it was
    /// closed and reopened. The island registers the same notification.
    private var screenObserver: NSObjectProtocol?

    init(providerStore: ProviderStore, codexProviderStore: CodexProviderStore) {
        self.providerStore = providerStore
        self.codexProviderStore = codexProviderStore
        super.init()
    }

    private var rateAccessory: VpnMenuBarRateView?
    private var rateCancel: AnyCancellable?
    private var batteryTimer: Timer?
    private var menuBarBattery: VpnMenuBarRateView.BatteryReading?
    private var batteryRefreshPending = false
    private lazy var rateIcon = MenuBarMark.image(side: 16)
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
        // The general host sampler sleeps when no window is open. Read only
        // battery sensors here, off the main thread, while this strip is
        // visible; the fixed eight-second cadence keeps watts useful without
        // waking the whole CPU/GPU sampling pipeline.
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMenuBarBattery() }
        }
        tickVpnRate()
        refreshMenuBarBattery()
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
        batteryTimer?.invalidate()
        batteryTimer = nil
        menuBarBattery = nil
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
            let down = VpnMenuBarRateView.rateText(VpnLiveRates.shared.speedDown)
            let up = VpnMenuBarRateView.rateText(VpnLiveRates.shared.speedUp)
            let host = ProcessSampler.shared.host
            let fallback = VpnMenuBarRateView.BatteryReading(
                installed: host.batteryInstalled,
                percent: host.batteryPercent,
                charging: host.batteryCharging,
                externalPower: host.batteryExternalPower,
                watts: host.powerBatteryWatts,
                estimated: host.powerIsEstimated)
            let battery = menuBarBattery ?? fallback
            if menuBarBattery == nil { refreshMenuBarBattery() }
            // The key uses the displayed watt precision: sensor noise below
            // one watt must not resize or repaint the menu-bar accessory.
            let key = "\(down)|\(up)|\(battery.displayKey)"
            guard key != lastRateKey else { return }
            lastRateKey = key
            button.image = nil
            accessory.isHidden = false
            accessory.update(icon: rateIcon, down: down, up: up, battery: battery)
            let width = VpnMenuBarRateView.stripWidth(battery: battery.installed)
            let length = width + 6
            // Rate text never changes this length. Measuring "999.9K" against
            // "1.0M" used to resize the status item and shove the whole strip.
            if accessory.frame.width != width {
                accessory.frame = NSRect(x: 0, y: 1, width: width, height: 20)
            }
            if statusItem.length != length { statusItem.length = length }
            button.toolTip = battery.installed
                ? "下载 \(down) · 上传 \(up)\n\(battery.tooltip)"
                : "下载 \(down) · 上传 \(up)"
        } else {
            menuBarBattery = nil
            guard lastRateKey != nil else { return }
            lastRateKey = nil
            accessory.isHidden = true
            accessory.frame = .zero
            button.image = MenuBarMark.image()
            button.toolTip = "ClaudeBar"
            statusItem.length = NSStatusItem.squareLength
        }
    }

    @MainActor
    private func refreshMenuBarBattery() {
        guard VpnManager.shared.isRunning, !batteryRefreshPending else { return }
        batteryRefreshPending = true
        Task { [weak self] in
            let sample = await Task.detached(priority: .utility) {
                let battery = HardwareSensors.batteryStatus()
                return (battery.installed, battery.percent, battery.charging,
                        battery.externalPower, battery.batteryWatts, battery.powerIsEstimated)
            }.value
            guard let self else { return }
            self.batteryRefreshPending = false
            guard VpnManager.shared.isRunning else { return }
            self.menuBarBattery = VpnMenuBarRateView.BatteryReading(
                installed: sample.0, percent: sample.1, charging: sample.2,
                externalPower: sample.3, watts: sample.4, estimated: sample.5)
            self.tickVpnRate()
        }
    }

    @objc private func statusItemClicked() {
        // The click that got here was already seen by the dismissal monitor
        // (the icon is outside the panel rect), which hid the popup. Reopening
        // it would make the icon a no-op toggle — see `closingFromStatusItem`.
        if closingFromStatusItem {
            closingFromStatusItem = false
            return
        }
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
        // Establish a fixed viewport; only the session module scrolls.
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
        observeScreenChanges()
    }

    private func hide() {
        hide(deferringMonitorRemoval: false)
    }

    /// `hide()` is reachable from inside the local monitor's own callback
    /// (`handleLocalMouseDown` → here), and `removeMonitors()` would then tear
    /// down the very monitor whose handler is still on the stack — while that
    /// handler is still going to return the event to the dispatcher. Nothing
    /// provably breaks today, but dismantling a monitor from within its own
    /// invocation is not a supported shape, so that path defers it a turn.
    private func hide(deferringMonitorRemoval: Bool) {
        closingFromStatusItem = false
        panel?.orderOut(nil)
        hostingView?.removeFromSuperview()
        hostingView = nil
        isOpen = false
        UIWakePolicy.setPopupOpen(false)
        if deferringMonitorRemoval {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isOpen else { return }
                self.removeMonitors()
            }
        } else {
            removeMonitors()
        }
    }

    // MARK: - Panel

    private func makeHostingView() {
        let rootView = AnyView(
            MenuBarView(providerStore: providerStore, codexStore: codexProviderStore)
                .environmentObject(providerStore)
                .environment(\.providerSource, providerStore)
                .environmentObject(codexProviderStore)
        )
        let hosting = NSHostingView(rootView: rootView)
        // Autoresizing 而非 Auto Layout 约束：macOS 26 上 NSHostingView 在显示周期内
        // 触发 setNeedsUpdateConstraints 会抛 "may not modify constraints during layout"
        // 并中止（点击菜单栏图标崩溃）。AutoresizingMask 同样铺满且不参与约束引擎。
        hosting.autoresizingMask = [.width, .height]
        // Same arrangement as the main window and the notch island: no size
        // feedback into AppKit. The default sizing options make *every* layout
        // pass walk the whole view graph (`invalidateSizeConstraints` →
        // `minSize()` → `sizeThatFits`), and a popup that is opened, resized by
        // its own content and scrolled re-lays out constantly. `sizeAndPosition`
        // supplies an explicit viewport; only the session list scrolls inside
        // its allocated space.
        hosting.sizingOptions = []
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
        // Follow the actual status-item screen, including secondary displays.
        guard let screen = statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        guard hostingView != nil else { return }
        let width: CGFloat = 424
        // A scroll view has no useful intrinsic height. Measuring fittingSize
        // here compressed the sessions to a sliver and clipped the other cards.
        let height = min(CGFloat(820), max(1, screen.visibleFrame.height - 8))

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
        if let content = panel.contentView { hostingView?.frame = content.bounds }
    }

    /// Dismissal (click outside) for the rectangular panel.
    ///
    /// The panel's *rect* is not the popup: `PanelState`'s popovers
    /// (`HeaderSwitchChip`, `CompactBatteryChargeControl`) open as separate
    /// `_NSPopoverWindow`s that AppKit places outside it — measured on a
    /// 1728×1117 screen, the battery control lands 189pt left of the panel and
    /// 40pt below it. A click there is "outside the panel" by frame, so the old
    /// test dismissed the popup on the first click anywhere in those popovers,
    /// which is why the charging modes and the model switcher needed a second
    /// click. They are child windows of the panel (`window.parent`), so that is
    /// the test: inside the panel rect, or inside a window hanging off it.
    ///
    /// `parent` is the right member for a *popover*. A `confirmationDialog` /
    /// `.alert` off a panel is an `_NSAlertPanel` attached by `sheetParent`
    /// instead — measured, see `docs/technical/17-ui-audit-backlog.md` §6 — so
    /// the day a dialog lands in this panel it needs its own clause here.
    ///
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
        if panel.frame.contains(NSEvent.mouseLocation) { return }
        if let window = event.window, window !== panel, window.parent === panel { return }
        hide(deferringMonitorRemoval: true)
        // Only the status item's own mouse-down is followed by
        // `statusItemClicked`, and only that one has to be swallowed. Matching
        // on the item's window (not its frame) keeps a click on any other
        // window from arming a suppression that would eat the next icon click.
        if let window = event.window, window === statusItem.button?.window {
            closingFromStatusItem = true
        }
    }

    /// Only while open: a closed panel has no position to fix, and `show()`
    /// re-derives everything anyway.
    private func observeScreenChanges() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOpen, let panel = self.panel else { return }
                self.sizeAndPosition(panel)
            }
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

    /// Every offset `layout()` uses is derived from these, so the declared
    /// width and the painted width cannot drift apart. (They did once: the
    /// battery was added to the frame but not to the capsule, and it painted
    /// 8pt past the backing.)
    private static let iconToArrow: CGFloat = 2
    private static let arrowColumn: CGFloat = 7
    private static let arrowToText: CGFloat = 2

    /// Five characters at most: 9.8K, 99.9K, 999K, then 1.0M.
    /// Precision follows magnitude instead of reserving seven padded characters.
    static func rateText(_ bytes: Int64) -> String {
        let units = ["K", "M", "G", "T", "P", "E"]
        var value = Double(max(0, bytes)) / 1024
        var unit = 0
        while value >= 999.5 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: value < 99.95 ? "%.1f%@" : "%.0f%@", value, units[unit])
    }

    static let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
    static let rateWidth: CGFloat = ceil(("99.9M" as NSString).size(withAttributes: [.font: rateFont]).width) + 1

    /// One cell: a battery capsule tall enough to hold its state mark, then
    /// the percentage. Charging, direct power and drain are drawn inside the
    /// gauge, so there is no second line of status text.
    ///
    /// **No terminal nub.** The positive post was the one part of this cell
    /// that carried no reading — the level is the liquid, the state is the
    /// mark, the number is beside it — and it was the part that made the
    /// silhouette lopsided: 2.4pt of ink bolted to the right edge pushed the
    /// shape's optical centre off its geometric one, so the capsule looked
    /// off-centre inside a cell it in fact filled.
    ///
    /// **The proportion is the reading, not a decoration.** A capsule *is* its
    /// ratio: at 1 ∶ 1 it is a dot, past ~2.2 ∶ 1 it is a bar, and a battery
    /// glyph has to sit between those to read as a cell. This one is
    /// **φ² ∶ 1 ≈ 1.618 ∶ 1** — 34 × 21 — the golden rectangle itself, so the
    /// width is a *function* of the height and the two can never disagree.
    /// That is what the previous proportions got wrong: 23.4×13.4 was 1.75 ∶ 1
    /// (the ratio of a business card, arbitrary next to an 11pt rounded
    /// reading), and the first pass after dropping the nub overshot to 45×18,
    /// i.e. 2.5 ∶ 1, which is a *bar* — three and a half millimetres of empty
    /// ellipse either side of a short liquid column. A cell that is most empty
    /// space reads as a container with nothing in it, which is the opposite of
    /// what a gauge is for.
    ///
    /// At this ratio the corner arcs take exactly a quarter of the width each,
    /// so the liquid gets the middle half: real travel for the surface, a
    /// silhouette that is unmistakably a cell, and 11pt less strip than the
    /// overshoot. When the liquid is full the whole capsule is ink and the
    /// same 1.618 : 1 is what makes a *solid* rectangle look intentional.
    static let batteryGap: CGFloat = 8
    static let batteryGlyphHeight: CGFloat = 21
    /// The golden rectangle: `φ² · height`. See the note above — a ratio, so it
    /// is written as one instead of as a measured length.
    static let batteryGlyphWidth: CGFloat = 21 * 1.618
    static let batteryTextGap: CGFloat = 4
    static let batteryTextWidth: CGFloat = 36

    struct BatteryReading {
        enum Mode: String { case charging, discharging, pluggedDischarge, holding }

        let installed: Bool
        let percent: Int
        let charging: Bool
        let externalPower: Bool
        /// Positive = charging; negative = discharging. Nil means unavailable.
        let watts: Double?
        let estimated: Bool

        var level: Int { min(100, max(0, percent)) }

        var mode: Mode {
            guard externalPower else { return .discharging }
            if let watts, watts.isFinite, watts < -0.5 { return .pluggedDischarge }
            if charging { return .charging }
            if let watts, watts.isFinite, watts > 0.5 { return .charging }
            return .holding
        }

        private var roundedWatts: Int? {
            guard mode != .holding, let watts, watts.isFinite, abs(watts) >= 0.5 else { return nil }
            if mode == .charging && watts <= 0 { return nil }
            if mode != .charging && watts >= 0 { return nil }
            return Int(abs(watts).rounded())
        }

        var detail: String {
            if let roundedWatts {
                let verb: String
                switch mode {
                case .charging: verb = "充"
                case .discharging: verb = "耗"
                case .pluggedDischarge: verb = "放"
                case .holding: verb = ""
                }
                return "\(verb) \(roundedWatts)W"
            }
            switch mode {
            case .charging: return "充电中"
            case .discharging: return "放电中"
            case .pluggedDischarge: return "接电放电"
            case .holding: return "电源直供"
            }
        }

        var displayKey: String { "\(installed)|\(level)|\(mode.rawValue)|\(detail)|\(estimated)" }

        var tooltip: String {
            let state: String
            switch mode {
            case .charging: state = "充入电池"
            case .discharging: state = "电池供电"
            case .pluggedDischarge: state = "接电期间电池放电"
            case .holding: state = "已接电源，电池未充放电"
            }
            let power = roundedWatts.map { " · \($0) W\(estimated ? "（估算）" : "")" } ?? ""
            return "电量 \(level)% · \(state)\(power)"
        }

        var color: NSColor {
            if level <= 20 && mode != .charging && mode != .holding {
                return NSColor(srgbRed: 1, green: 0.42, blue: 0.38, alpha: 1)
            }
            if level <= 40 && mode == .discharging {
                return NSColor(srgbRed: 1, green: 0.75, blue: 0.41, alpha: 1)
            }
            switch mode {
            case .charging: return NSColor(srgbRed: 0.45, green: 0.90, blue: 0.62, alpha: 1)
            case .pluggedDischarge: return NSColor(srgbRed: 1, green: 0.72, blue: 0.38, alpha: 1)
            case .discharging, .holding: return .white
            }
        }

        /// What is drawn inside the gauge. Words stay in the tooltip.
        var mark: BatteryMenuBarGlyph.Mark {
            switch mode {
            case .charging: return .bolt
            case .holding: return .plug
            case .pluggedDischarge: return .drain
            case .discharging: return .none
            }
        }
    }

    /// Room for the battery cell. Hidden entirely on a Mac without one, so a
    /// desktop never pays for the width — `stripWidth(battery:)` is what the
    /// controller asks for.
    ///
    /// The cell is one *object* — gauge plus reading — so its width is derived
    /// from the gauge instead of restating a glyph slot that has to be kept in
    /// step with it by hand: `batteryGlyphWidth` is the capsule's two numbers,
    /// and this only adds the divider lead-in and the gap before the digits.
    static var batteryWidth: CGFloat {
        batteryGap + batteryGlyphWidth + batteryTextGap + batteryTextWidth
    }
    static var ratesWidth: CGFloat {
        iconSide + iconToArrow + arrowColumn + arrowToText + rateWidth
    }
    static var fullWidth: CGFloat { ratesWidth + batteryWidth }

    /// The width this instance actually wants: the rates always, the battery
    /// only when the machine has one.
    static func stripWidth(battery: Bool) -> CGFloat {
        battery ? fullWidth : ratesWidth
    }

    func displayedWidth(battery: Bool) -> CGFloat { Self.stripWidth(battery: battery) }

    private let iconView = NSImageView()
    private let downLabel = VpnMenuBarRateView.makeLabel()
    private let upLabel = VpnMenuBarRateView.makeLabel()
    private let downArrow = VpnMenuBarRateView.makeArrow("arrow.down")
    private let upArrow = VpnMenuBarRateView.makeArrow("arrow.up")
    private let batteryDivider = NSView()
    private let batteryIcon = BatteryMenuBarGlyph()
    private let batteryLabel = VpnMenuBarRateView.makeLabel()
    private let batteryDetail = VpnMenuBarRateView.makeLabel()
    private var batteryInstalled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Fixed dark capsule behind the digits — the menu bar is translucent,
        // so wallpaper can be any brightness. A constant dark backing keeps
        // white digits readable without guessing the background.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .white
        batteryDivider.wantsLayer = true
        batteryDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        batteryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        batteryLabel.alignment = .left
        batteryDetail.isHidden = true
        addSubview(iconView)
        addSubview(downArrow)
        addSubview(upArrow)
        addSubview(downLabel)
        addSubview(upLabel)
        addSubview(batteryDivider)
        addSubview(batteryIcon)
        addSubview(batteryLabel)
        addSubview(batteryDetail)
    }

    required init?(coder: NSCoder) { nil }

    func update(icon: NSImage?, down: String, up: String,
                battery: BatteryReading) {
        iconView.image = icon
        downLabel.stringValue = down
        upLabel.stringValue = up
        needsLayout = true
        batteryInstalled = battery.installed
        if battery.installed {
            batteryIcon.level = battery.level
            batteryIcon.fillColor = battery.color
            batteryIcon.mark = battery.mark
            batteryLabel.stringValue = "\(battery.level)%"
            batteryLabel.textColor = .white
        }
        batteryDivider.isHidden = !battery.installed
        batteryIcon.isHidden = !battery.installed
        batteryLabel.isHidden = !battery.installed
        batteryDetail.isHidden = true
        // All labels use white over the fixed dark capsule, independent of the
        // menu bar's appearance and whatever wallpaper sits underneath it.
        let downColor = Self.rateColor(down)
        let upColor = Self.rateColor(up)
        downLabel.textColor = downColor
        upLabel.textColor = upColor
        downArrow.contentTintColor = downColor
        upArrow.contentTintColor = upColor
    }

    /// Bright activity → full-strength label; idle → dimmed.
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
        if kb < 1 { return NSColor.white.withAlphaComponent(0.55) }
        if kb < 1024 { return NSColor.white.withAlphaComponent(0.8) }
        return .white
    }

    // MARK: Test accessors
    //
    // The strip's whole job is geometry, and geometry cannot be asserted from
    // outside a private subview list. These read the frames `layout()` produced
    // so `Tests/menubar-strip-regressions.py` can prove the painted width fits
    // the declared one — the bug that shipped when the battery was added.

    /// A hidden view contributes nothing to the painted width, so these report
    /// zero for it — otherwise a stale frame from a previous battery reading
    /// would read as overhang.
    private func paintedMaxX(_ view: NSView) -> CGFloat {
        view.isHidden ? 0 : view.frame.maxX
    }

    var iconFrameMaxX: CGFloat { paintedMaxX(iconView) }
    var downArrowFrameMaxX: CGFloat { paintedMaxX(downArrow) }
    var upArrowFrameMaxX: CGFloat { paintedMaxX(upArrow) }
    var downLabelFrameMaxX: CGFloat { paintedMaxX(downLabel) }
    var upLabelFrameMaxX: CGFloat { paintedMaxX(upLabel) }
    var batteryDividerFrameMaxX: CGFloat { paintedMaxX(batteryDivider) }
    var batteryIconFrameMaxX: CGFloat { paintedMaxX(batteryIcon) }
    var batteryLabelFrameMaxX: CGFloat { paintedMaxX(batteryLabel) }
    var batteryDetailFrameMaxX: CGFloat { paintedMaxX(batteryDetail) }
    var batteryIconIsHidden: Bool { batteryIcon.isHidden }
    var batteryLabelIsHidden: Bool { batteryLabel.isHidden }
    var batteryDetailIsHidden: Bool { batteryDetail.isHidden }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.fullWidth, height: 20) }
    override var fittingSize: NSSize { intrinsicContentSize }

    override func layout() {
        super.layout()
        let h = bounds.height
        iconView.frame = NSRect(x: 0, y: (h - Self.iconSide) / 2, width: Self.iconSide, height: Self.iconSide)
        let ax = Self.iconSide + Self.iconToArrow
        downArrow.frame = NSRect(x: ax, y: 10, width: 7, height: 9)
        upArrow.frame = NSRect(x: ax, y: 1, width: 7, height: 9)
        let nx = ax + Self.arrowColumn + Self.arrowToText
        downLabel.frame = NSRect(x: nx, y: 9, width: Self.rateWidth, height: 11)
        upLabel.frame = NSRect(x: nx, y: 0, width: Self.rateWidth, height: 11)
        // The gauge carries the state. The percentage sits on its midline.
        guard batteryInstalled else { return }
        let bx = nx + Self.rateWidth + Self.batteryGap
        batteryDivider.frame = NSRect(x: bx - 5, y: 3, width: 1, height: h - 6)
        // Width comes off the glyph's own constants (see `batteryGlyphWidth`),
        // height off the strip's declared height: the gauge is a capsule, so
        // its height and its width are the same kind of decision and must not
        // drift apart in two places.
        batteryIcon.frame = NSRect(x: bx, y: 0,
                                   width: Self.batteryGlyphWidth, height: h)
        let tx = bx + Self.batteryGlyphWidth + Self.batteryTextGap
        batteryLabel.frame = NSRect(x: tx, y: (h - 14) / 2, width: Self.batteryTextWidth, height: 14)
        batteryDetail.frame = .zero
    }

    private static func makeLabel() -> NSTextField {
        let f = NSTextField(labelWithString: "0.0K")
        f.font = rateFont
        f.textColor = NSColor.labelColor.withAlphaComponent(0.45)
        f.alignment = .left
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

/// A battery capsule — the whole cell, and **not** a cell with a post on it.
/// The liquid's surface ripples, and a bright band travels through it: toward
/// the high end while charging, out of the cell while discharging. Holding
/// (plugged, idle) stays still.
///
/// With no terminal nub there is no "positive end" for the ink to lean on, so
/// direction is carried by the *travel* of the two layers and by the state mark
/// alone (see `drawSheen`, `drawState`). That is the reading the nub only
/// pretended to give: a 2.4pt stub on a 24pt mark said "battery" to someone
/// who already knew, and said "clipped" to everyone else.
private final class BatteryMenuBarGlyph: NSView {
    enum Mark { case none, bolt, plug, drain }

    var level = 0 { didSet { needsDisplay = true } }
    var fillColor: NSColor = .white { didSet { needsDisplay = true } }
    var mark: Mark = .none {
        didSet {
            guard mark != oldValue else { return }
            needsDisplay = true
            updateWaveTimer()
        }
    }
    private var waveTimer: Timer?
    private var phase: CGFloat = 0

    /// Crests move toward the terminal (right) when charging, and out of the
    /// cell when the battery is supplying power. Holding has no travel.
    private var flowsTowardTerminal: Bool? {
        switch mark {
        case .bolt: return true
        case .drain, .none: return false
        case .plug: return nil
        }
    }

    override var isHidden: Bool {
        didSet { updateWaveTimer() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWaveTimer()
    }

    private func updateWaveTimer() {
        guard flowsTowardTerminal != nil, window != nil, !isHiddenOrHasHiddenAncestor,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            waveTimer?.invalidate()
            waveTimer = nil
            return
        }
        guard waveTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.window != nil, !self.isHiddenOrHasHiddenAncestor,
                  self.flowsTowardTerminal != nil,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                timer.invalidate()
                self.waveTimer = nil
                return
            }
            self.phase += 0.34
            if self.phase > .pi * 2 { self.phase -= .pi * 2 }
            self.needsDisplay = true
        }
        waveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { waveTimer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // A capsule, not a rounded rectangle: the height *is* the radius, and
        // it fills the slot `layout()` handed over — declared width and painted
        // width are the same rectangle (see the geometry note in
        // `VpnMenuBarRateView`). The 0.5pt inset on each edge is the hairline's
        // own breathing room, not a second, smaller capsule.
        let outlineInset: CGFloat = 0.5
        let body = bounds.insetBy(dx: outlineInset, dy: outlineInset)
        let radius = body.height / 2
        let outline = NSColor.white.withAlphaComponent(0.88)
        let shell = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        outline.setStroke()
        shell.lineWidth = 1.15
        shell.stroke()

        // The liquid is inset by the wall thickness plus the stroke's half, so
        // the fill only ever meets the wall — it never eats the outline.
        let inner = body.insetBy(dx: 1.7, dy: 1.7)
        let innerRadius = inner.height / 2
        let fraction = CGFloat(min(100, max(0, level))) / 100
        let liquid = liquidColor
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: inner, xRadius: innerRadius, yRadius: innerRadius).addClip()
        if fraction > 0 {
            // A hair of air at full charge keeps the surface visible. The
            // percentage beside the glyph is the exact reading.
            let surface = inner.minY + 0.7 + (inner.height - 1.6) * fraction
            let flowing = flowsTowardTerminal != nil
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let signed = phase * (flowsTowardTerminal == true ? -1 : 1)
            if flowing {
                drawWave(in: inner, surface: surface + 0.55, phase: signed + 1.6,
                         amplitude: 0.7, color: liquid.withAlphaComponent(0.38))
                drawWave(in: inner, surface: surface, phase: signed,
                         amplitude: 0.85, color: liquid)
                drawSheen(in: inner, surface: surface, phase: signed,
                          towardTerminal: flowsTowardTerminal == true)
            } else {
                drawWave(in: inner, surface: surface, phase: 0, amplitude: 0, color: liquid)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        drawState(in: inner)
    }

    /// Charging is green. Drain keeps the level color (white, amber, or red)
    /// so a low battery still reads as low while the sheen says which way.
    private var liquidColor: NSColor {
        switch mark {
        case .bolt:
            return NSColor(srgbRed: 0.34, green: 0.91, blue: 0.57, alpha: 1)
        case .drain, .none, .plug:
            return fillColor.withAlphaComponent(0.94)
        }
    }

    /// A soft vertical band crossing the liquid. One pass is one `phase`
    /// cycle; charging runs left → right, discharging runs right → left. With
    /// no nub there is no drawn terminal to name, so the ends are just the ends
    /// of the liquid. Clipped to the liquid so the highlight never floats in
    /// the empty air.
    private func drawSheen(in rect: NSRect, surface: CGFloat, phase: CGFloat, towardTerminal: Bool) {
        let travel = self.phase / (.pi * 2)
        let band: CGFloat = 6
        let span = rect.width + band
        let x = towardTerminal
            ? rect.minX - band + span * travel
            : rect.maxX - span * travel
        NSGraphicsContext.saveGraphicsState()
        wavePath(in: rect, surface: surface + 1.2, phase: phase, amplitude: 0.85).addClip()
        let sheen = NSRect(x: x, y: rect.minY - 1, width: band,
                           height: max(2, surface - rect.minY + 3))
        NSGradient(colors: [
            NSColor.white.withAlphaComponent(0),
            NSColor.white.withAlphaComponent(0.75),
            NSColor.white.withAlphaComponent(0)
        ])?.draw(in: sheen, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawState(in rect: NSRect) {
        guard mark != .none else { return }
        // Hand-drawn at menu-bar size, with a dark keyline rather than a
        // blurred shadow or a filled badge. Both edges survive white/green fill.
        let x = rect.midX, y = rect.midY
        let path = NSBezierPath()
        switch mark {
        case .bolt:
            path.move(to: NSPoint(x: x + 1, y: y + 5))
            path.line(to: NSPoint(x: x - 3, y: y - 0.5))
            path.line(to: NSPoint(x: x, y: y - 0.5))
            path.line(to: NSPoint(x: x - 1, y: y - 5))
            path.line(to: NSPoint(x: x + 3, y: y + 0.5))
            path.line(to: NSPoint(x: x, y: y + 0.5))
            path.close()
        case .plug:
            path.move(to: NSPoint(x: x - 2, y: y + 4.5))
            path.line(to: NSPoint(x: x - 2, y: y + 2))
            path.move(to: NSPoint(x: x + 2, y: y + 4.5))
            path.line(to: NSPoint(x: x + 2, y: y + 2))
            path.move(to: NSPoint(x: x - 3, y: y + 2))
            path.line(to: NSPoint(x: x + 3, y: y + 2))
            path.line(to: NSPoint(x: x + 3, y: y))
            path.curve(to: NSPoint(x: x - 3, y: y),
                       controlPoint1: NSPoint(x: x + 3, y: y - 3),
                       controlPoint2: NSPoint(x: x - 3, y: y - 3))
            path.close()
            path.move(to: NSPoint(x: x, y: y - 2))
            path.line(to: NSPoint(x: x, y: y - 4.5))
        case .drain:
            path.move(to: NSPoint(x: x, y: y + 4))
            path.line(to: NSPoint(x: x, y: y - 4))
            path.move(to: NSPoint(x: x - 3, y: y - 1))
            path.line(to: NSPoint(x: x, y: y - 4))
            path.line(to: NSPoint(x: x + 3, y: y - 1))
        case .none: return
        }
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        NSColor.black.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 2.6
        path.stroke()
        NSColor.white.setStroke()
        path.lineWidth = 1.2
        path.stroke()
        if mark == .bolt { NSColor.white.setFill(); path.fill() }
    }

    private func drawWave(in rect: NSRect, surface: CGFloat, phase: CGFloat,
                          amplitude: CGFloat, color: NSColor) {
        color.setFill()
        wavePath(in: rect, surface: surface, phase: phase, amplitude: amplitude).fill()
    }

    private func wavePath(in rect: NSRect, surface: CGFloat, phase: CGFloat,
                          amplitude: CGFloat) -> NSBezierPath {
        let wave = NSBezierPath()
        wave.move(to: NSPoint(x: rect.minX, y: rect.minY))
        for step in 0...32 {
            let progress = CGFloat(step) / 32
            let y = surface + sin(progress * .pi * 2 + phase) * amplitude
            wave.line(to: NSPoint(x: rect.minX + rect.width * progress, y: y))
        }
        wave.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        wave.close()
        return wave
    }
}
