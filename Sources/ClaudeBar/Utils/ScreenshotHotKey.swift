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

    @Published private(set) var isRegistered = false
    @Published private(set) var tapSwallows = false
    @Published private(set) var lastError: String?

    private init() {}

    func startIfEnabled() {
        guard AppPreferences.shared.screenshotHotkeyEnabled else { return }
        register()
        // After sleep/lock, other apps may have grabbed ⌘⇧A in the meantime.
        // Reclaim both the tap and the exclusive registration.
        wakeMonitor = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.register()
        }
    }

    func setEnabled(_ on: Bool) {
        if on {
            register()
            if wakeMonitor == nil {
                wakeMonitor = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.register()
                }
            }
        } else {
            unregister()
        }
    }

    /// Release the Carbon hot key and the wake observer. Called at
    /// termination — the event tap is a system-wide registration and the
    /// observer outlives the singleton otherwise.
    func stop() {
        unregister()
        if let wakeMonitor {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeMonitor)
            self.wakeMonitor = nil
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
            isRegistered = err == noErr
            hotKeyRef = err == noErr ? ref : nil
            return
        }
        hotKeyRef = ref
        isRegistered = true
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
        isRegistered = false
        tapSwallows = false
    }

    // MARK: - CGEventTap: swallow ⌘⇧A before observer apps see it

    private func installTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // swallow capability — needs Accessibility/Input Monitoring
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                let flags = event.flags
                if flags.contains(.maskCommand), flags.contains(.maskShift),
                   event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_A) {
                    if type == .keyDown {
                        DispatchQueue.main.async {
                            ScreenshotOverlayController.shared.begin()
                        }
                    }
                    return nil // swallowed — downstream apps (Feishu) never see it
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: nil) else {
            // Not trusted (yet): register a listen-only tap so at least our
            // own trigger works without the Carbon hotkey path.
            tapSwallows = false
            installPassiveTap(mask)
            return
        }
        tap = port
        tapSwallows = true
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        tapSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Listen-only fallback when the swallowing tap was denied. We don't
    /// trigger from here (Carbon hotkey already covers the enabled case);
    /// it exists only to detect that the combo was pressed when the tap is
    /// passive, so the overlay can still open even if RegisterEventHotKey
    /// lost the exclusive race.
    private func installPassiveTap(_ mask: CGEventMask) {
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                let flags = event.flags
                if type == .keyDown, flags.contains(.maskCommand), flags.contains(.maskShift),
                   event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_A) {
                    DispatchQueue.main.async {
                        ScreenshotOverlayController.shared.begin()
                    }
                }
                return Unmanaged.passRetained(event)
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
