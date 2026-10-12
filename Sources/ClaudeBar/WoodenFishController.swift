import AppKit
import SwiftUI
import Combine

@MainActor
final class WoodenFishController: NSObject, NSWindowDelegate {
    private let model: WoodenFishModel
    private var panel: WoodenFishPanel?
    private var audio: WoodenFishAudio?
    private var automaticTimer: Timer?
    private var dayTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var positionSave: DispatchWorkItem?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    init(model: WoodenFishModel? = nil) { self.model = model ?? .shared }

    func start() {
        guard AppPresentation.allowsInterface, cancellables.isEmpty else { return }
        model.$enabled.removeDuplicates().sink { [weak self] enabled in
            MainActor.assumeIsolated {
                if enabled { self?.install() } else { self?.uninstall() }
            }
        }.store(in: &cancellables)
        Publishers.CombineLatest(model.$isAutomatic, model.$interval)
            .sink { [weak self] automatic, interval in
                MainActor.assumeIsolated { self?.configureTimer(automatic: automatic, interval: interval) }
            }.store(in: &cancellables)
        model.$size.dropFirst().removeDuplicates().sink { [weak self] size in
            MainActor.assumeIsolated { self?.resize(to: size) }
        }.store(in: &cancellables)
        model.$muted.dropFirst().sink { [weak self] muted in
            if muted { MainActor.assumeIsolated { self?.audio?.stop() } }
            else { DispatchQueue.main.async { self?.prepareAudio() } }
        }.store(in: &cancellables)
        model.$volume.dropFirst().removeDuplicates().sink { [weak self] volume in
            if volume <= 0 { MainActor.assumeIsolated { self?.audio?.stop() } }
            else { DispatchQueue.main.async { self?.prepareAudio() } }
        }.store(in: &cancellables)
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.model.isAutomatic = false
                    self?.panel?.cancelStrike()
                    self?.audio?.stop()
                }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.model.refreshDay(); self?.reposition() } })
    }

    func stop() {
        cancellables.removeAll()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        uninstall()
    }

    private func install() {
        guard AppPresentation.allowsInterface, panel == nil else { return }
        model.refreshDay()
        let panel = WoodenFishPanel(contentRect: placedFrame(size: model.size.panelSize))
        panel.onStrike = { [weak self] in self?.strike() }
        panel.onPress = { [weak self] pressed in self?.model.isPressed = pressed }
        panel.onDragEnd = { [weak self] in self?.reposition() }
        panel.onEscape = { [weak self] in
            self?.model.isAutomatic = false
            self?.model.endInteraction()
        }
        panel.delegate = self
        let host = NSHostingView(rootView: WoodenFishView(model: model) { [weak self] in self?.strike() })
        // The panel owns its fixed size; animation must not renegotiate it.
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        panel.orderFrontRegardless()
        prepareAudio()
        installMouseMonitors()
        syncPointer()
        dayTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshDay() }
        }
        dayTimer?.tolerance = 3
        if let timer = dayTimer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func uninstall() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil; localMouseMonitor = nil
        model.isHovered = false
        model.isPressed = false
        automaticTimer?.invalidate(); automaticTimer = nil
        dayTimer?.invalidate(); dayTimer = nil
        model.isAutomatic = false
        positionSave?.cancel(); positionSave = nil
        if let panel { model.saveOrigin(panel.frame.origin) }
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
        audio?.stop(); audio = nil
    }

    func strike(automatic: Bool = false) {
        guard AppPresentation.allowsInterface, panel?.isVisible == true else { return }
        model.strike(automatic: automatic)
        guard !model.muted, model.volume > 0 else { return }
        prepareAudio()
        guard let sound = audio else { return }
        sound.play(volume: model.volume) { [weak self, weak sound] success in
            guard let self, let sound, self.audio === sound,
                  AppPresentation.allowsInterface, self.panel?.isVisible == true,
                  !self.model.muted, self.model.volume > 0 else { return }
            self.model.soundAvailable = success
        }
    }

    private func prepareAudio() {
        guard AppPresentation.allowsInterface, panel?.isVisible == true,
              !model.muted, model.volume > 0, audio == nil else { return }
        audio = WoodenFishAudio()
    }

    private func configureTimer(automatic: Bool, interval: Double) {
        automaticTimer?.invalidate(); automaticTimer = nil
        guard automatic, AppPresentation.allowsInterface, panel != nil,
              WoodenFishModel.intervals.contains(interval) else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.strike(automatic: true) }
        }
        timer.tolerance = min(0.05, interval * 0.05)
        RunLoop.main.add(timer, forMode: .common)
        automaticTimer = timer
        syncPointer()
    }

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPointer() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.syncPointer() }
            return event
        }
    }

    private func syncPointer() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let scale = panel.frame.width / 260
        let point = CGPoint(x: mouse.x - panel.frame.minX,
                            y: panel.frame.maxY - mouse.y)
        // Outside the tiny panel, only this rectangle check runs. No path work,
        // allocations or SwiftUI publications follow ordinary desktop movement.
        let hovered = panel.frame.contains(mouse) && WoodenFishGeometry.captures(point, scale: scale)
        if model.isHovered != hovered { model.isHovered = hovered }
        let capture = panel.isTrackingStrike || hovered
        if panel.ignoresMouseEvents == capture { panel.ignoresMouseEvents = !capture }
    }

    private func placedFrame(size: CGSize, origin: CGPoint? = nil) -> CGRect {
        WoodenFishPlacement.frame(origin: origin ?? model.savedOrigin, size: size,
                                  screens: NSScreen.screens.map(\.visibleFrame))
    }

    private func resize(to size: WoodenFishSize) {
        guard let panel else { return }
        let origin = CGPoint(x: panel.frame.minX, y: panel.frame.maxY - size.panelSize.height)
        panel.setFrame(placedFrame(size: size.panelSize, origin: origin), display: true)
        syncPointer()
    }

    private func reposition() {
        guard let panel else { return }
        panel.setFrame(placedFrame(size: panel.frame.size, origin: panel.frame.origin), display: true)
        syncPointer()
    }

    func windowDidResignKey(_ notification: Notification) {
        panel?.cancelStrike()
        syncPointer()
    }

    func windowDidMove(_ notification: Notification) {
        syncPointer()
        positionSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                if let self, let panel = self.panel { self.model.saveOrigin(panel.frame.origin) }
            }
        }
        positionSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

private final class WoodenFishPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onStrike: (() -> Void)?
    var onPress: ((Bool) -> Void)?
    var onDragEnd: (() -> Void)?
    private var gesture = WoodenFishPointerGesture()
    var isTrackingStrike: Bool { gesture.isTracking }

    func cancelStrike() {
        gesture.cancel()
        onPress?(false)
    }

    override func sendEvent(_ event: NSEvent) {
        let point = CGPoint(x: event.locationInWindow.x, y: frame.height - event.locationInWindow.y)
        if event.type == .keyDown, event.keyCode == 53 {
            cancelStrike()
            onEscape?()
            return
        }
        if event.type == .leftMouseDown,
           WoodenFishGeometry.captures(point, scale: frame.width / 260) {
            if event.modifierFlags.contains(.option) {
                cancelStrike()
                performDrag(with: event)
                onDragEnd?()
            } else {
                makeKey()
                gesture.begin(at: point)
                onPress?(true)
            }
            return
        }
        if event.type == .leftMouseDragged, gesture.isTracking {
            if gesture.shouldDrag(to: point) {
                cancelStrike()
                performDrag(with: event)
                onDragEnd?()
            }
            return
        }
        if event.type == .leftMouseUp, gesture.isTracking {
            let shouldStrike = gesture.end(at: point)
                && WoodenFishGeometry.captures(point, scale: frame.width / 260)
            onPress?(false)
            if shouldStrike { onStrike?() }
            return
        }
        super.sendEvent(event)
    }

    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        title = "桌面木鱼"
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
