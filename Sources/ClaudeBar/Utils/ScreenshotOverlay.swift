import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import CoreGraphics
import UniformTypeIdentifiers

/// Region snip: native-pixel freeze (CALayer, no interpolation), window-edge
/// snap via `CGWindowList`, then Copy / Save / Pin — the CleanShot /
/// Snapzy / ZoomIt-for-Mac interaction, without their extra product chrome.
@MainActor
final class ScreenshotOverlayController {
    static let shared = ScreenshotOverlayController()

    fileprivate var canvases: [SnipCanvas] = []
    private var panels: [NSWindow] = []
    private var capturing = false
    fileprivate var pinPanels: [NSPanel] = []
    /// Session keyDown tap active only while capturing. The overlay panels
    /// are nonactivating, so the front app is never disturbed — which also
    /// means a local key monitor never sees Esc/Space/⌘C typed while another
    /// app is frontmost. The tap intercepts our editing keys system-wide and
    /// swallows *only* those; everything else passes through untouched.
    private var captureTap: CFMachPort?
    private var captureTapSource: CFRunLoopSource?
    /// Carbon fallback when the CGEventTap can't be created (no Accessibility
    /// trust): RegisterEventHotKey needs no permission and swallows the key
    /// system-wide, so Esc/Space/⌘C/⌘S still work during a capture.
    private var fallbackHandler: EventHandlerRef?
    private var fallbackKeys: [EventHotKeyRef?] = []
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    private init() {}

    func begin() {
        guard !capturing else { return }
        capturing = true
        Task { await run() }
    }

    private func run() async {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            capturing = false
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            return
        }
        // ClaudeBar's own windows (menu-bar panel etc.) stay exactly where
        // they are: the screen is captured as-is, frozen shots included.

        let screens = NSScreen.screens
        guard !screens.isEmpty else { capturing = false; return }

        var shots: [(NSScreen, CGImage)] = []
        for screen in screens {
            do {
                shots.append((screen, try await Self.captureDisplay(screen)))
            } catch {
                capturing = false
                NSSound.beep()
                return
            }
        }

        let windows = WindowSnapper.windowsByScreen(screens)
        present(shots: shots, windows: windows)
    }

    private func present(shots: [(NSScreen, CGImage)], windows: [CGDirectDisplayID: [CGRect]]) {
        // Close a previous overlay without flipping `capturing` off — that flag
        // gates Esc/Space. `dismissOverlay` used to set it false here, so the
        // freeze was on screen but every key handler bailed out.
        tearDownPanels()
        capturing = true
        var first: SnipCanvas?
        for (screen, image) in shots {
            let id = screen.displayID
            let panel = CapturePanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false)
            panel.isFloatingPanel = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.hasShadow = false
            panel.sharingType = .none
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            // Full `NSScreen.frame`, including the menu bar. Default window
            // constraining shifts the panel down by the menu-bar height, which
            // stretched the freeze (blur) and offset every click/mark.
            panel.setFrame(screen.frame, display: true)

            let canvas = SnipCanvas(
                screenshot: image,
                screen: screen,
                windowRects: windows[id] ?? [],
                controller: self)
            panel.contentView = canvas
            panel.orderFrontRegardless()
            panels.append(panel)
            canvases.append(canvas)
            if first == nil { first = canvas }
        }
        if let panel = panels.first, let canvas = first {
            panel.makeKey()
            panel.makeFirstResponder(canvas)
        }

        installCaptureTap()
        installKeyMonitors()
    }

    fileprivate func lockOnly(_ canvas: SnipCanvas) {
        for c in canvases where c !== canvas { c.clearLock() }
    }

    fileprivate func copyAndClose(_ canvas: SnipCanvas) {
        guard let img = canvas.croppedImage() else { return }
        Self.writePasteboard(img)
        dismissOverlay(keepPins: true)
    }

    fileprivate func saveAndClose(_ canvas: SnipCanvas) {
        guard let img = canvas.croppedImage() else { return }
        dismissOverlay(keepPins: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "ClaudeBar-\(Self.stamp()).png"
        panel.canCreateDirectories = true
        panel.begin { result in
            if result == .OK, let url = panel.url {
                Self.writePNG(img, to: url)
            }
        }
    }

    fileprivate func pinAndClose(_ canvas: SnipCanvas) {
        guard let img = canvas.croppedImage(), let sel = canvas.selectionInScreen() else { return }
        let pin = ScreenshotPinPanel(image: img, origin: sel)
        pinPanels.append(pin)
        pin.orderFrontRegardless()
        dismissOverlay(keepPins: true)
    }

    func cancel() {
        dismissOverlay(keepPins: true)
    }

    /// Session-wide keyDown tap, active only during a capture. Swallows only
    /// the keys `handleKey` claims; everything else passes through untouched.
    private func installCaptureTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    DispatchQueue.main.async {
                        if let port = ScreenshotOverlayController.shared.captureTap {
                            CGEvent.tapEnable(tap: port, enable: true)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }
                var claimed = false
                let apply = {
                    claimed = ScreenshotOverlayController.shared.handleCGKey(event)
                }
                if Thread.isMainThread {
                    apply()
                } else {
                    DispatchQueue.main.sync(execute: apply)
                }
                return claimed ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: nil) else {
            installFallbackHotKeys()
            return
        }
        captureTap = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        captureTapSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Local monitor swallows Esc when a capture panel is key. Global monitor
    /// still *cancels* when another app is frontmost (nonactivating overlay).
    private func installKeyMonitors() {
        removeKeyMonitors()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.capturing else { return event }
            return self.handleKey(event) ? nil : event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.capturing else { return }
            _ = self.handleKey(event)
        }
    }

    private func removeKeyMonitors() {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        localKeyMonitor = nil
        globalKeyMonitor = nil
    }

    /// No-permission fallback: register the editing keys as Carbon hotkeys for
    /// the duration of the capture. RegisterEventHotKey consumes the key
    /// system-wide, so Esc still cancels even though no tap is installed.
    private func installFallbackHotKeys() {
        guard fallbackHandler == nil, let appTarget = GetApplicationEventTarget() else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            appTarget,
            { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard id.signature == 0x43425348 else { return noErr } // 'CBSH'
                let overlay = ScreenshotOverlayController.shared
                DispatchQueue.main.async { overlay.handleFallbackHotKey(id.id) }
                return noErr
            },
            1, &spec, nil, &handler)
        guard status == noErr else { return }
        fallbackHandler = handler

        // (keyCode, modifiers) pairs: Esc, Space, Return, keypad Enter, ⌘C, ⌘S.
        let keys: [(UInt32, UInt32, UInt32)] = [
            (UInt32(kVK_Escape), 0, 1),
            (UInt32(kVK_Space), 0, 2),
            (UInt32(kVK_Return), 0, 3),
            (UInt32(kVK_ANSI_KeypadEnter), 0, 4),
            (UInt32(8), UInt32(cmdKey), 5),          // 'C' = ANSI C
            (UInt32(1), UInt32(cmdKey), 6),          // 'S' = ANSI S
        ]
        for (keyCode, mods, idx) in keys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x43425348, id: idx)
            let err = RegisterEventHotKey(keyCode, mods, id, appTarget, 0, &ref)
            if err == noErr { fallbackKeys.append(ref) }
        }
    }

    fileprivate func handleFallbackHotKey(_ idx: UInt32) {
        guard capturing else { return }
        switch idx {
        case 1: cancel()
        case 2:
            if let c = canvases.first(where: { $0.screen.frame.contains(NSEvent.mouseLocation) })
                ?? canvases.first {
                c.selectFullScreen()
            }
        case 3, 5:
            if let c = canvases.first(where: { $0.hasSelection }) { copyAndClose(c) }
        case 6:
            if let c = canvases.first(where: { $0.hasSelection }) { saveAndClose(c) }
        default: break
        }
    }

    private func removeCaptureTap() {
        for ref in fallbackKeys {
            if let ref { UnregisterEventHotKey(ref) }
        }
        fallbackKeys = []
        if let h = fallbackHandler { RemoveEventHandler(h) }
        fallbackHandler = nil
        if let port = captureTap { CGEvent.tapEnable(tap: port, enable: false) }
        if let src = captureTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        captureTap = nil
        captureTapSource = nil
        removeKeyMonitors()
    }

    /// Bridge a CGEvent keyDown into `handleKey`. Returns true when the key
    /// was consumed (the tap should swallow it).
    private func handleCGKey(_ event: CGEvent) -> Bool {
        guard capturing else { return false }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags: NSEvent.ModifierFlags = {
            var f: NSEvent.ModifierFlags = []
            let m = event.flags
            if m.contains(.maskCommand) { f.insert(.command) }
            if m.contains(.maskShift) { f.insert(.shift) }
            if m.contains(.maskAlternate) { f.insert(.option) }
            if m.contains(.maskControl) { f.insert(.control) }
            return f
        }()
        let nse = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode) ?? NSEvent()
        return handleKey(nse)
    }

    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == UInt16(kVK_Escape) {
            cancel()
            return true
        }
        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            if let c = canvases.first(where: { $0.hasSelection }) { copyAndClose(c) }
            return true
        }
        if event.keyCode == UInt16(kVK_Space) {
            if let c = canvases.first(where: { $0.screen.frame.contains(NSEvent.mouseLocation) })
                ?? canvases.first {
                c.selectFullScreen()
            }
            return true
        }
        if flags.contains(.command) {
            if event.keyCode == 8 { // 'C' — synthetic events carry no characters
                if let c = canvases.first(where: { $0.hasSelection }) { copyAndClose(c) }
                return true
            }
            if event.keyCode == 1 { // 'S'
                if let c = canvases.first(where: { $0.hasSelection }) { saveAndClose(c) }
                return true
            }
        }
        return false
    }

    private func tearDownPanels() {
        removeCaptureTap()
        for p in panels { p.orderOut(nil) }
        panels = []
        canvases = []
    }

    private func dismissOverlay(keepPins: Bool) {
        tearDownPanels()
        capturing = false
        if !keepPins {
            for p in pinPanels { p.orderOut(nil) }
            pinPanels = []
        }
    }

    private static func captureDisplay(_ screen: NSScreen) async throws -> CGImage {
        let displayID = screen.displayID
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        // Match the overlay: NSScreen.frame in points × backing scale.
        // `.best` + SCDisplay pixel size often returns a *different* buffer
        // (native vs "looks like"), which CALayer then stretches — blur + offset.
        let scale = screen.backingScaleFactor
        let pixelW = max(1, Int((screen.frame.width * scale).rounded()))
        let pixelH = max(1, Int((screen.frame.height * scale).rounded()))
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = pixelW
        config.height = pixelH
        config.scalesToFit = false
        config.captureResolution = .nominal
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func writePasteboard(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        // Prefer PNG so pixel-exact Retina resolution survives the round
        // trip; TIFF is a fallback for apps that only read TIFF.
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            pb.setData(png, forType: .png)
        }
        pb.writeObjects([image])
        if let tiff = image.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    static func writePNG(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private enum CaptureError: Error { case noDisplay }
}

// MARK: - Window list (Quartz → Cocoa), Snapzy/CleanShot style

private enum WindowSnapper {
    /// The frontmost (z-order) candidate containing the point. Candidates are
    /// kept in CGWindowList order (front→back), so a small foreground window
    /// wins over a maximized one behind it — the CleanShot / Snipaste rule.
    static func frontmostWindow(contains p: NSPoint, in rects: [CGRect]) -> CGRect? {
        rects.first { $0.insetBy(dx: -4, dy: -4).contains(p) }
    }

    static func windowsByScreen(_ screens: [NSScreen]) -> [CGDirectDisplayID: [CGRect]] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        let originY = primary?.frame.maxY ?? 0

        // Keep candidates with enough area to be a real content window.
        // Deliberately NOT sorted: CGWindowListCopyWindowInfo returns windows
        // front→back in z-order, and hover must pick the *frontmost* window
        // under the cursor (CleanShot/Snipaste behavior), not the largest —
        // sorting by area used to make hover snap to a maximized window
        // behind the small one the user was pointing at.
        var candidates: [(CGRect, CGFloat)] = [] // (cocoa frame, area)
        for item in info {
            if (item[kCGWindowOwnerPID as String] as? pid_t) == selfPID { continue }
            if (item[kCGWindowLayer as String] as? Int ?? 0) != 0 { continue }
            let alpha = item[kCGWindowAlpha as String] as? Double ?? 1
            if alpha < 0.3 { continue }
            guard let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let x = cgFloat(bounds["X"]), let y = cgFloat(bounds["Y"]),
                  let w = cgFloat(bounds["Width"]), let h = cgFloat(bounds["Height"]),
                  w >= 120, h >= 80 else { continue }
            let cocoa = CGRect(x: x, y: originY - y - h, width: w, height: h)
            candidates.append((cocoa, w * h))
        }

        var result: [CGDirectDisplayID: [CGRect]] = [:]
        for screen in screens {
            var rects: [CGRect] = []
            for (cocoa, _) in candidates {
                let local = cocoa.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                let hit = local.intersection(CGRect(origin: .zero, size: screen.frame.size))
                // Require a meaningful chunk of the window on this screen so a
                // sliver from a neighboring display doesn't become a snap box.
                guard hit.width >= 120, hit.height >= 80,
                      hit.width * hit.height > cocoa.width * cocoa.height * 0.15 else { continue }
                rects.append(hit)
            }
            result[screen.displayID] = rects
        }
        return result
    }

    private static func cgFloat(_ any: Any?) -> CGFloat? {
        if let n = any as? CGFloat { return n }
        if let n = any as? Double { return CGFloat(n) }
        if let n = any as? Int { return CGFloat(n) }
        if let n = any as? NSNumber { return CGFloat(n.doubleValue) }
        return nil
    }
}

// MARK: - Annotation marks

/// Markup drawn on a locked selection: red rectangle / ellipse / arrow /
/// freehand pen, Fluent-Screen-Recorder & Flameshot style. Geometry lives in
/// selection-relative view coordinates (y-up) so on-screen layers and the
/// composited crop share one space.
enum MarkTool {
    case rect, ellipse, arrow, pen
}

struct SnipMark {
    var tool: MarkTool
    var start: NSPoint
    var end: NSPoint
    /// Freehand polyline (view coords); empty for shape tools.
    var stroke: [NSPoint] = []

    /// CGPath in selection-relative coordinates (y-up).
    func path(in sel: CGRect) -> CGPath {
        let p = CGMutablePath()
        switch tool {
        case .rect:
            p.addRect(NSRect(from: start, to: end).insetBy(dx: 1.5, dy: 1.5))
        case .ellipse:
            p.addEllipse(in: NSRect(from: start, to: end).insetBy(dx: 1.5, dy: 1.5))
        case .arrow:
            p.addArrow(from: start, to: end)
        case .pen:
            guard let first = stroke.first else { return p }
            p.move(to: first)
            for pt in stroke.dropFirst() { p.addLine(to: pt) }
        }
        return p
    }
}

private extension NSRect {
    init(from a: NSPoint, to b: NSPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y),
                  width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

private extension NSMutablePath {
    func addArrow(from: NSPoint, to: NSPoint) {
        move(to: from)
        addLine(to: to)
        // Solid arrowhead, 30° wings.
        let angle = atan2(to.y - from.y, to.x - from.x)
        let head: CGFloat = 14
        for da in [CGFloat(.pi * 0.82), -CGFloat(.pi * 0.82)] {
            let wing = CGPoint(x: to.x + head * cos(angle + da),
                               y: to.y + head * sin(angle + da))
            move(to: to)
            addLine(to: wing)
        }
    }
}

typealias NSMutablePath = CGMutablePath

// MARK: - Canvas

private final class SnipCanvas: NSView {
    let screen: NSScreen
    private let cgImage: CGImage
    private let windowRects: [CGRect]
    private weak var controller: ScreenshotOverlayController?

    private var hoverWindow: CGRect?
    private var selection: CGRect?
    private var locked = false
    private var dragStart: NSPoint?
    private var dragging = false
    private var cursor: NSPoint = .zero
    private var activeHandle: Handle?
    private var resizeOrigin = CGRect.zero

    // Annotation state
    private var marks: [SnipMark] = []
    private var markTool: MarkTool?
    private var markDraft: SnipMark?
    private var markLayers: [CALayer] = []   // committed mark layers
    private var draftLayer: CAShapeLayer?

    private let freezeLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private let marksLayer = CALayer()
    private let toolbar = SnipToolbar()

    var hasSelection: Bool { selection != nil && (selection?.width ?? 0) >= 2 }

    init(screenshot: CGImage, screen: NSScreen, windowRects: [CGRect],
         controller: ScreenshotOverlayController) {
        self.cgImage = screenshot
        self.screen = screen
        self.windowRects = windowRects
        self.controller = controller
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsScale = screen.backingScaleFactor

        freezeLayer.contents = screenshot
        freezeLayer.contentsGravity = .resize
        freezeLayer.magnificationFilter = .nearest
        freezeLayer.minificationFilter = .nearest
        freezeLayer.contentsScale = CGFloat(screenshot.width) / max(screen.frame.width, 1)
        freezeLayer.isOpaque = true
        layer?.addSublayer(freezeLayer)

        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.38).cgColor
        dimLayer.fillRule = .evenOdd
        layer?.addSublayer(dimLayer)

        strokeLayer.fillColor = nil
        strokeLayer.strokeColor = NSColor.white.cgColor
        strokeLayer.lineWidth = 1 / screen.backingScaleFactor
        layer?.addSublayer(strokeLayer)

        marksLayer.anchorPoint = .zero
        marksLayer.zPosition = 5
        layer?.addSublayer(marksLayer)

        toolbar.controller = controller
        toolbar.canvas = self
        toolbar.isHidden = true
        addSubview(toolbar)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        freezeLayer.frame = bounds
        let scaleX = CGFloat(cgImage.width) / max(bounds.width, 1)
        freezeLayer.contentsScale = scaleX
        freezeLayer.contentsGravity = .resize
        dimLayer.frame = bounds
        strokeLayer.frame = bounds
        refreshMask()
        positionToolbar()
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.cancel()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func clearLock() {
        locked = false
        selection = nil
        dragging = false
        toolbar.isHidden = true
        toolbar.activeTool = nil
        markTool = nil
        clearMarkLayers()
        refreshMask()
    }

    // MARK: Annotation drawing

    /// Red stroke over the frozen pixels, like every markup tool.
    private static let markColor = NSColor(srgbRed: 0.92, green: 0.18, blue: 0.22, alpha: 1)

    func setMarkTool(_ tool: MarkTool?) {
        markTool = tool
        toolbar.activeTool = tool
    }

    func undoLastMark() {
        guard !marks.isEmpty else { return }
        if let last = markLayers.popLast() {
            last.removeFromSuperlayer()
        }
        marks.removeLast()
    }

    var canUndoMark: Bool { !marks.isEmpty }

    private func clearMarkLayers() {
        for l in markLayers { l.removeFromSuperlayer() }
        markLayers = []
        draftLayer?.removeFromSuperlayer()
        draftLayer = nil
    }

    private static func markShape(_ mark: SnipMark, in sel: CGRect) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.anchorPoint = .zero
        l.frame = CGRect(origin: .zero, size: sel.size)
        l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        l.path = mark.path(in: sel)
        l.strokeColor = Self.markColor.cgColor
        l.fillColor = nil
        l.lineWidth = 3
        l.lineCap = .round
        l.lineJoin = .round
        l.zPosition = 5
        return l
    }

    /// Convert view point → selection-relative (y-up) coords.
    private func localPoint(_ p: NSPoint) -> NSPoint {
        guard let sel = selection else { return p }
        return NSPoint(x: p.x - sel.minX, y: p.y - sel.minY)
    }

    private func redrawDraft() {
        guard let draft = markDraft, let sel = selection else { return }
        if draftLayer == nil {
            draftLayer = Self.markShape(draft, in: CGRect(origin: .zero, size: sel.size))
            marksLayer.addSublayer(draftLayer!)
        }
        draftLayer!.frame = CGRect(origin: .zero, size: sel.size)
        draftLayer!.path = draft.path(in: CGRect(origin: .zero, size: sel.size))
    }

    private func commitDraftLayer() {
        guard let sel = selection else { return }
        draftLayer?.removeFromSuperlayer()
        draftLayer = nil
        guard let last = marks.last else { return }
        let l = Self.markShape(last, in: CGRect(origin: .zero, size: sel.size))
        marksLayer.addSublayer(l)
        markLayers.append(l)
    }

    /// Composite the marks into the cropped image (selection-relative space).
    private func renderMarks(onto rep: NSBitmapImageRep, scaleX: CGFloat, scaleY: CGFloat) {
        guard let sel = selection else { return }
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let color = Self.markColor
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for mark in marks {
            let p = CGMutablePath()
            switch mark.tool {
            case .rect:
                p.addRect(NSRect(from: mark.start, to: mark.end).insetBy(dx: 1.5, dy: 1.5))
            case .ellipse:
                p.addEllipse(in: NSRect(from: mark.start, to: mark.end).insetBy(dx: 1.5, dy: 1.5))
            case .arrow:
                p.addArrow(from: mark.start, to: mark.end)
            case .pen:
                guard let first = mark.stroke.first else { continue }
                p.move(to: first)
                for pt in mark.stroke.dropFirst() { p.addLine(to: pt) }
            }
            path.append(NSBezierPath(cgPath: p))
        }
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    func selectFullScreen() {
        controller?.lockOnly(self)
        selection = bounds.insetBy(dx: 0, dy: 0)
        locked = true
        toolbar.isHidden = false
        refreshMask()
        positionToolbar()
    }

    func selectionInScreen() -> CGRect? {
        guard let s = selection else { return nil }
        return s.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
    }

    func croppedImage() -> NSImage? {
        guard let sel = selection else { return nil }
        let scaleX = CGFloat(cgImage.width) / bounds.width
        let scaleY = CGFloat(cgImage.height) / bounds.height
        let pixel = CGRect(
            x: sel.minX * scaleX,
            y: (bounds.height - sel.maxY) * scaleY,
            width: sel.width * scaleX,
            height: sel.height * scaleY).integral
        guard let sliced = cgImage.cropping(to: pixel), pixel.width >= 2 else { return nil }
        guard !marks.isEmpty else {
            return NSImage(cgImage: sliced, size: NSSize(width: sel.width, height: sel.height))
        }

        // Draw the crop + marks into a fresh 8-bit RGBA bitmap at native
        // resolution. (Drawing into the rep decoded from tiffRepresentation
        // silently no-ops on 16-bit HDR reps.) A bitmap CGContext's origin is
        // bottom-left (y-up) — the same space as the selection-relative mark
        // coords — so after scaling into crop pixels the paths drop in with
        // no extra flip. Flipping here used to mirror every mark vertically.
        let w = sliced.width, h = sliced.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(cgImage: sliced, size: NSSize(width: sel.width, height: sel.height)) }
        ctx.draw(sliced, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: CGFloat(w) / max(sel.width, 1), y: CGFloat(h) / max(sel.height, 1))
        let color = Self.markColor
        ctx.setStrokeColor(CGColor(srgbRed: color.redComponent, green: color.greenComponent,
                                   blue: color.blueComponent, alpha: 1))
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for mark in marks {
            ctx.addPath(mark.path(in: CGRect(origin: .zero, size: sel.size)))
            ctx.strokePath()
        }
        guard let outCG = ctx.makeImage() else {
            return NSImage(cgImage: sliced, size: NSSize(width: sel.width, height: sel.height))
        }
        return NSImage(cgImage: outCG, size: NSSize(width: sel.width, height: sel.height))
    }

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        if !locked, !dragging {
            hoverWindow = WindowSnapper.frontmostWindow(contains: cursor, in: windowRects)
            refreshMask()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursor = p
        if locked, markTool != nil, let sel = selection, sel.contains(p) {
            let local = NSPoint(x: p.x - sel.minX, y: p.y - sel.minY)
            markDraft = SnipMark(tool: markTool!, start: local, end: local, stroke: [local])
            return
        }
        if locked, let handle = handle(at: p) {
            activeHandle = handle
            resizeOrigin = selection ?? .zero
            return
        }
        if locked, toolbar.frame.contains(p) { return }
        controller?.lockOnly(self)
        locked = false
        toolbar.isHidden = true
        dragStart = p
        dragging = false
        selection = nil
        hoverWindow = WindowSnapper.frontmostWindow(contains: p, in: windowRects)
        refreshMask()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursor = p
        if markTool != nil, var draft = markDraft, let sel = selection {
            let local = NSPoint(x: p.x - sel.minX, y: p.y - sel.minY)
            draft.end = local
            if draft.tool == .pen { draft.stroke.append(local) }
            markDraft = draft
            redrawDraft()
            return
        }
        if let handle = activeHandle {
            selection = resize(resizeOrigin, handle: handle, to: p)
            refreshMask()
            positionToolbar()
            return
        }
        guard let start = dragStart else { return }
        if hypot(p.x - start.x, p.y - start.y) > 4 { dragging = true }
        if dragging {
            selection = NSRect(
                x: min(start.x, p.x), y: min(start.y, p.y),
                width: abs(a(start.x, p.x)), height: abs(a(start.y, p.y)))
            hoverWindow = nil
        }
        refreshMask()
    }

    override func mouseUp(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        if markTool != nil, var draft = markDraft {
            // Ignore tiny accidental marks (a click without a drag).
            let moved = hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y)
            if draft.tool == .pen ? draft.stroke.count > 2 : moved > 4 {
                marks.append(draft)
                commitDraftLayer()
            } else {
                draftLayer?.removeFromSuperlayer()
                draftLayer = nil
            }
            markDraft = nil
            return
        }
        if activeHandle != nil {
            activeHandle = nil
            locked = hasSelection
            toolbar.isHidden = !locked
            positionToolbar()
            refreshMask()
            return
        }
        if dragging, hasSelection {
            lockSelection()
        } else if let win = hoverWindow, (dragStart.map { hypot(cursor.x - $0.x, cursor.y - $0.y) } ?? 0) < 4 {
            selection = win
            lockSelection()
        } else if !hasSelection {
            selection = nil
            refreshMask()
        }
        dragging = false
        dragStart = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.cancel()
    }

    private func lockSelection() {
        locked = true
        toolbar.isHidden = false
        refreshMask()
        positionToolbar()
    }

    private func refreshMask() {
        // Mark layers draw in selection-relative coords. Anchor at (0,0) so
        // `frame = selection` puts local (0,0) on the selection's bottom-left
        // — default anchor (0.5, 0.5) shifted every rect/ellipse/arrow.
        marksLayer.anchorPoint = .zero
        marksLayer.frame = selection ?? .zero
        let highlight = selection ?? (locked ? nil : hoverWindow)
        let path = CGMutablePath()
        path.addRect(bounds)
        if let r = highlight, r.width > 0.5 {
            path.addRect(r)
        }
        dimLayer.path = path

        let hair = 1 / max(screen.backingScaleFactor, 1)
        strokeLayer.lineWidth = hair
        if let r = highlight, r.width > 0.5 {
            let inset = r.insetBy(dx: hair / 2, dy: hair / 2)
            strokeLayer.path = CGPath(rect: inset, transform: nil)
            strokeLayer.strokeColor = (selection != nil
                ? NSColor.white
                : NSColor(srgbRed: 0.31, green: 0.56, blue: 0.97, alpha: 1)).cgColor
        } else {
            strokeLayer.path = nil
        }

        // Handles
        layer?.sublayers?.filter { $0.name == "handle" }.forEach { $0.removeFromSuperlayer() }
        if locked, let sel = selection {
            for p in handlePoints(sel) {
                let h = CALayer()
                h.name = "handle"
                h.backgroundColor = NSColor.white.cgColor
                h.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
                h.borderWidth = hair
                h.frame = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
                layer?.addSublayer(h)
            }
        }
    }

    private func positionToolbar() {
        guard let sel = selection, !toolbar.isHidden else { return }
        toolbar.sizeToFit()
        let size = toolbar.frame.size
        var origin = NSPoint(x: sel.midX - size.width / 2, y: sel.minY - size.height - 10)
        if origin.y < 8 {
            origin.y = sel.maxY + 10
        }
        origin.x = min(max(8, origin.x), bounds.maxX - size.width - 8)
        toolbar.setFrameOrigin(origin)
    }

    private enum Handle { case n, s, e, w, ne, nw, se, sw }

    private func handlePoints(_ r: CGRect) -> [CGPoint] {
        [
            CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.midX, y: r.minY),
            CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.minX, y: r.midY),
            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
            CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.minY),
        ]
    }

    private func handle(at p: NSPoint) -> Handle? {
        guard let sel = selection else { return nil }
        let map: [(Handle, CGPoint)] = [
            (.n, CGPoint(x: sel.midX, y: sel.maxY)),
            (.s, CGPoint(x: sel.midX, y: sel.minY)),
            (.e, CGPoint(x: sel.maxX, y: sel.midY)),
            (.w, CGPoint(x: sel.minX, y: sel.midY)),
            (.ne, CGPoint(x: sel.maxX, y: sel.maxY)),
            (.nw, CGPoint(x: sel.minX, y: sel.maxY)),
            (.se, CGPoint(x: sel.maxX, y: sel.minY)),
            (.sw, CGPoint(x: sel.minX, y: sel.minY)),
        ]
        return map.first { hypot(p.x - $0.1.x, p.y - $0.1.y) < 8 }?.0
    }

    private func resize(_ r: CGRect, handle: Handle, to p: NSPoint) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case .n: maxY = p.y
        case .s: minY = p.y
        case .e: maxX = p.x
        case .w: minX = p.x
        case .ne: maxX = p.x; maxY = p.y
        case .nw: minX = p.x; maxY = p.y
        case .se: maxX = p.x; minY = p.y
        case .sw: minX = p.x; minY = p.y
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                       width: abs(maxX - minX), height: abs(maxY - minY))
    }

    private func a(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a - b }
}

private final class SnipToolbar: NSView {
    weak var controller: ScreenshotOverlayController?
    weak var canvas: SnipCanvas?
    /// Currently selected annotation tool (nil = none); drives tint +Undo.
    var activeTool: MarkTool? { didSet { refreshTints() } }

    private var toolButtons: [(NSButton, MarkTool)] = []
    private var undoButton: NSButton?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        // Annotation tools (SF Symbols), then a divider, then actions.
        let tools: [(String, MarkTool, String)] = [
            ("rectangle", .rect, "红框"),
            ("circle", .ellipse, "圆圈"),
            ("arrow.up.right", .arrow, "箭头"),
            ("pencil.tip", .pen, "画笔"),
        ]
        var x: CGFloat = 8
        for (symbol, tool, tip) in tools {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!,
                             target: self, action: #selector(toolTap(_:)))
            b.tag = toolButtons.count
            b.isBordered = false
            b.contentTintColor = .white.withAlphaComponent(0.75)
            b.toolTip = tip
            b.setFrameSize(NSSize(width: 30, height: 24))
            b.frame = NSRect(x: x, y: 6, width: 30, height: 24)
            addSubview(b)
            toolButtons.append((b, tool))
            x = b.frame.maxX
        }

        let divider = NSView(frame: NSRect(x: x + 2, y: 8, width: 1, height: 20))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        addSubview(divider)
        x = divider.frame.maxX + 4

        let undo = NSButton(title: "撤销", target: self, action: #selector(undoTap))
        undo.isBordered = false
        undo.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        undo.contentTintColor = .white.withAlphaComponent(0.55)
        undo.sizeToFit()
        undo.frame = NSRect(x: x, y: 6, width: max(undo.frame.width + 10, 40), height: 24)
        addSubview(undo)
        undoButton = undo
        x = undo.frame.maxX + 4

        let titles = ["复制", "保存", "钉住", "取消"]
        for (i, title) in titles.enumerated() {
            let b = NSButton(title: title, target: self, action: #selector(tap(_:)))
            b.tag = i
            b.bezelStyle = .inline
            b.isBordered = false
            b.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            b.contentTintColor = i == 3 ? NSColor.white.withAlphaComponent(0.55) : .white
            b.sizeToFit()
            b.frame = NSRect(x: x, y: 6, width: max(b.frame.width + 10, 44), height: 24)
            addSubview(b)
            x = b.frame.maxX + 4
        }
        setFrameSize(NSSize(width: x + 4, height: 36))
    }

    required init?(coder: NSCoder) { nil }

    private func refreshTints() {
        for (b, tool) in toolButtons {
            let on = tool == activeTool
            b.contentTintColor = on ? NSColor(srgbRed: 0.92, green: 0.18, blue: 0.22, alpha: 1)
                : .white.withAlphaComponent(0.75)
        }
        undoButton?.contentTintColor = (canvas?.canUndoMark ?? false)
            ? .white : .white.withAlphaComponent(0.35)
    }

    override var intrinsicContentSize: NSSize { frame.size }

    func sizeToFit() {
        var w: CGFloat = 8
        for v in subviews { w = max(w, v.frame.maxX) }
        setFrameSize(NSSize(width: w + 8, height: 36))
    }

    @objc private func toolTap(_ sender: NSButton) {
        guard let (b, tool) = toolButtons.first(where: { $0.0 === sender }) else { return }
        _ = b
        // Toggle: picking the active tool again puts the cursor back to
        // selection/resize mode.
        canvas?.setMarkTool(activeTool == tool ? nil : tool)
    }

    @objc private func undoTap() {
        canvas?.undoLastMark()
        refreshTints()
    }

    @objc private func tap(_ sender: NSButton) {
        guard let canvas else { return }
        switch sender.tag {
        case 0: controller?.copyAndClose(canvas)
        case 1: controller?.saveAndClose(canvas)
        case 2: controller?.pinAndClose(canvas)
        default: controller?.cancel()
        }
    }
}

/// CleanShot-style pin: the crop stays on a floating panel. Draggable by
/// background, with a small hover chrome bar (close / copy / resize ±).
private final class ScreenshotPinPanel: NSPanel {
    private let image: NSImage
    private let imageView = NSImageView()
    /// Scale vs. the original capture (1 = native size), stepped by ±.
    private var scale: CGFloat = 1
    /// Hover chrome sits outside the photo; extra window padding hides it
    /// until the cursor enters.
    private let chromeBar = PinChromeBar()
    private let padding: CGFloat = 34

    init(image: NSImage, origin: CGRect) {
        self.image = image
        let size = image.size
        let rect = NSRect(
            x: origin.midX - size.width / 2,
            y: origin.midY - size.height / 2,
            width: size.width + padding, height: size.height + padding)
        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        imageView.layer?.shadowColor = NSColor.black.cgColor
        imageView.layer?.shadowOpacity = 0.5
        imageView.layer?.shadowRadius = 6
        contentView = chromeView()
        layoutContent()
    }

    private func chromeView() -> NSView {
        let host = NSView()
        chromeBar.frame = NSRect(x: 0, y: 0, width: 96, height: 24)
        chromeBar.onSubmit = { [weak self] action in
            guard let self else { return }
            switch action {
            case .close: self.closePin()
            case .copy: self.copyPin()
            case .bigger: self.rescale(by: 1.25)
            case .smaller: self.rescale(by: 0.8)
            }
        }
        host.addSubview(imageView)
        host.addSubview(chromeBar)
        return host
    }

    private func layoutContent() {
        let photo = frame.size  // includes padding
        let photoSize = NSSize(width: photo.width - padding, height: photo.height - padding)
        imageView.frame = NSRect(x: padding / 2, y: padding / 2, width: photoSize.width, height: photoSize.height)
        chromeBar.frame = NSRect(x: photo.width - chromeBar.frame.width - 2,
                                 y: photo.height - chromeBar.frame.height + 8, width: chromeBar.frame.width,
                                 height: chromeBar.frame.height)
    }

    private func rescale(by factor: CGFloat) {
        scale = min(max(scale * factor, 0.25), 4)
        let base = image.size
        let newSize = NSSize(width: base.width * scale + padding, height: base.height * scale + padding)
        let center = frame.center
        setFrame(NSRect(origin: NSPoint(x: center.x - newSize.width / 2,
                                        y: center.y - newSize.height / 2),
                        size: newSize), display: true, animate: false)
        layoutContent()
    }

    private func closePin() {
        orderOut(nil)
    }

    private func copyPin() {
        ScreenshotOverlayController.writePasteboard(image)
    }
}

extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

/// Tiny hover toolbar on a pinned screenshot: close / copy / bigger / smaller.
private final class PinChromeBar: NSView {
    enum Action { case close, copy, bigger, smaller }
    var onSubmit: ((Action) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        let items: [(String, Action)] = [
            ("xmark", .close), ("doc.on.doc", .copy),
            ("plus.magnifyingglass", .bigger), ("minus.magnifyingglass", .smaller),
        ]
        var x: CGFloat = 4
        for (symbol, action) in items {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
                             target: self, action: #selector(tap(_:)))
            b.tag = action.hashValue
            b.isBordered = false
            b.contentTintColor = .white.withAlphaComponent(0.8)
            b.setFrameSize(NSSize(width: 22, height: 20))
            b.frame = NSRect(x: x, y: 2, width: 22, height: 20)
            addSubview(b)
            x = b.frame.maxX
        }
        setFrameSize(NSSize(width: x + 4, height: 24))
    }

    required init?(coder: NSCoder) { nil }

    @objc private func tap(_ sender: NSButton) {
        // Order matches items above.
        switch sender.frame.minX {
        case ..<30: onSubmit?(.close)
        case 30..<55: onSubmit?(.copy)
        case 55..<80: onSubmit?(.bigger)
        default: onSubmit?(.smaller)
        }
    }
}

private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func cancelOperation(_ sender: Any?) {
        ScreenshotOverlayController.shared.cancel()
    }

    override func keyDown(with event: NSEvent) {
        if ScreenshotOverlayController.shared.handleKey(event) { return }
        super.keyDown(with: event)
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

private let kVK_Space: Int = 0x31
