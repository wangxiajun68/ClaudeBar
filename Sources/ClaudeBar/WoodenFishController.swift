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
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: WoodenFishView(model: model) { [weak self] in self?.strike() })
        self.panel = panel
        panel.orderFrontRegardless()
        dayTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshDay() }
        }
        dayTimer?.tolerance = 3
        if let timer = dayTimer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func uninstall() {
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

    func strike() {
        guard AppPresentation.allowsInterface, panel?.isVisible == true else { return }
        model.strike()
        guard !model.muted, model.volume > 0 else { return }
        if audio == nil {
            audio = WoodenFishAudio()
            model.soundAvailable = audio?.available == true
        }
        audio?.play(volume: model.volume)
    }

    private func configureTimer(automatic: Bool, interval: Double) {
        automaticTimer?.invalidate(); automaticTimer = nil
        guard automatic, AppPresentation.allowsInterface, panel != nil,
              WoodenFishModel.intervals.contains(interval) else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.strike() }
        }
        timer.tolerance = min(0.05, interval * 0.05)
        RunLoop.main.add(timer, forMode: .common)
        automaticTimer = timer
    }

    private func placedFrame(size: CGSize, origin: CGPoint? = nil) -> CGRect {
        WoodenFishPlacement.frame(origin: origin ?? model.savedOrigin, size: size,
                                  screens: NSScreen.screens.map(\.visibleFrame))
    }

    private func resize(to size: WoodenFishSize) {
        guard let panel else { return }
        let origin = CGPoint(x: panel.frame.minX, y: panel.frame.maxY - size.panelSize.height)
        panel.setFrame(placedFrame(size: size.panelSize, origin: origin), display: true)
    }

    private func reposition() {
        guard let panel else { return }
        panel.setFrame(placedFrame(size: panel.frame.size, origin: panel.frame.origin), display: true)
    }

    func windowDidMove(_ notification: Notification) {
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
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        title = "桌面木鱼"
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
