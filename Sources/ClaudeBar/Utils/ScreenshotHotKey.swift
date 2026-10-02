import AppKit
import Carbon
import CoreGraphics
import CoreServices
import Combine

/// Global ⌘⇧A. Two layers:
///
/// 1. `CGEventTap` (session tap, keyDown+keyUp, head-insert) — swallows ⌘⇧A
///    entirely so other apps that *observe* the combo (Feishu/Lark use event
///    observation, not exclusive registration) never see it. Falls back to
///    passive listening if the tap is not permitted.
/// 2. Carbon `RegisterEventHotKey` — belt-and-suspenders: still fires if the
///    tap is disabled by the user in Accessibility settings.
///
/// Only the tap swallows events; the hotkey handler is idempotent per
/// keypress (overlay guards `capturing`), so double delivery is harmless.
final class ScreenshotHotKey: ObservableObject {
    static let shared = ScreenshotHotKey()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handlerInstalled = false
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var wakeMonitor: Any?

    // Registration state is not published: `lastError` is the only fact any
    // surface reads (PermissionsSection's ⌘⇧A row), and a `tapSwallows` flag
    // had no reader at all — the tap's mode is re-decided on every
    // `register()`, so it is not state worth carrying.
    @Published private(set) var lastError: String?

    private init() {}

    func startIfEnabled() {
        guard AppPreferences.shared.screenshotHotkeyEnabled else { return }
        register()
        installWakeObserverIfNeeded()
    }

    func setEnabled(_ on: Bool) {
        if on {
            register()
            installWakeObserverIfNeeded()
        } else {
            unregister()
            removeWakeObserver()
        }
    }

    /// After sleep/lock, other apps may have grabbed ⌘⇧A in the meantime.
    /// Reclaim both the tap and the exclusive registration. Installed once —
    /// `startIfEnabled` and `setEnabled(true)` can both be reached.
    ///
    /// The handler re-checks the preference: the observer is installed while
    /// the feature is on and removed when it is turned off, so this is the
    /// second line of defence against a wake re-registering a hotkey the user
    /// has since disabled (which would swallow ⌘⇧A system-wide again, with the
    /// settings row still reading off).
    private func installWakeObserverIfNeeded() {
        guard wakeMonitor == nil else { return }
        wakeMonitor = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard AppPreferences.shared.screenshotHotkeyEnabled else { return }
            self?.register()
        }
    }

    private func removeWakeObserver() {
        guard let wakeMonitor else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(wakeMonitor)
        self.wakeMonitor = nil
    }

    /// Release the Carbon hot key and the wake observer. Called at
    /// termination — the event tap is a system-wide registration and the
    /// observer outlives the singleton otherwise.
    func stop() {
        unregister()
        removeWakeObserver()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
            handlerInstalled = false
        }
    }

    func register() {
        unregister()
        installHandlerIfNeeded()
        installTap()
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref)
        if err != noErr {
            // -9878 means another app holds the exclusive registration; our
            // event tap still swallows and fires, so treat as degraded, not dead.
            lastError = err == -9878 ? nil : Self.describe(err)
            hotKeyRef = err == noErr ? ref : nil
            return
        }
        hotKeyRef = ref
        lastError = nil
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
            tapSource = nil
        }
        tap = nil
    }

    // MARK: - CGEventTap: swallow ⌘⇧A before observer apps see it

    /// A tap callback cannot capture `self`, so the rule both taps share lives
    /// in these free functions: the match (flags + keycode), the dispatch to
    /// the overlay, and the swallow decision each exist once.
    private static func isScreenshotHotKey(_ event: CGEvent) -> Bool {
        let flags = event.flags
        return flags.contains(.maskCommand) && flags.contains(.maskShift)
            && event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_A)
    }

    private static func triggerOverlay() {
        DispatchQueue.main.async { ScreenshotOverlayController.shared.begin() }
    }

    private static func swallow() -> Unmanaged<CGEvent>? {
        triggerOverlay()
        return nil // swallowed — downstream apps (Feishu) never see it
    }

    private func installTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // swallow capability — needs Accessibility/Input Monitoring
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                if ScreenshotHotKey.isScreenshotHotKey(event) {
                    if type == .keyDown { return ScreenshotHotKey.swallow() }
                    return nil // the keyUp half is swallowed with it
                }
                // Pass unretained: a tap callback does not own the event (the
                // sibling overlay tap passes it the same way), and retaining
                // one per keystroke leaks every passthrough event in the
                // process.
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil) else {
            // Not trusted (yet): register a listen-only tap so at least our
            // own trigger works without the Carbon hotkey path.
            installPassiveTap(mask)
            return
        }
        tap = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        tapSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Listen-only fallback when the swallowing tap was denied. Registering
    /// it is also what keeps the overlay reachable when `RegisterEventHotKey`
    /// already lost the exclusive race (-9878): it triggers on a plain keyDown,
    /// and a delivery that *does* win that race is absorbed by the overlay's
    /// own `capturing` guard, so double delivery is harmless.
    private func installPassiveTap(_ mask: CGEventMask) {
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                if ScreenshotHotKey.isScreenshotHotKey(event), type == .keyDown { ScreenshotHotKey.triggerOverlay() }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil) else { return }
        tap = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        tapSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id)
                if id.signature == ScreenshotHotKey.signature {
                    DispatchQueue.main.async {
                        ScreenshotOverlayController.shared.begin()
                    }
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &handlerRef)
        handlerInstalled = status == noErr
        if status != noErr {
            lastError = Self.describe(status)
        }
    }

    private static let signature: OSType = 0x43425348 // 'CBSH'

    private static func describe(_ err: OSStatus) -> String {
        switch err {
        case -9878: return "快捷键已被其他程序占用"
        default: return "无法注册 ⌘⇧A（错误 \(err)）"
        }
    }
}
