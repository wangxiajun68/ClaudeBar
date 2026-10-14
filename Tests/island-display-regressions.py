#!/usr/bin/env python3
"""Production controller, geometry and view; only stores/system input are inert.
Synthetic offscreen displays, no real preferences, sessions, notifications,
network, haptics or pointer movement. Native panels are torn down before exit.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
subprocess.run(['python3', str(root/'Tools/render-island-preview.py'), '--check'], check=True)
prefix = (root/'.build/island-preview/Probe.swift').read_text().split('@main struct Probe {')[0]
controller = (root/'Sources/ClaudeBar/NotchIslandController.swift').read_text()
controller = controller[controller.index('// MARK: - Controller'):]
# Replace only system-input boundaries and the haptic side effect in the probe.
controller = controller.replace('private ', '')
controller = controller.replace('NSEvent.mouseLocation', 'Pointer.location')
controller = controller.replace('NSEvent.pressedMouseButtons', 'Pointer.buttons')
controller = controller.replace('NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)', '// Haptics are inert in the isolated fixture.')
source = prefix + r'''
@MainActor enum MainWindowEvents { static var count = 0 }
@MainActor enum Pointer { static var location = CGPoint.zero; static var buttons = 0 }
@MainActor enum AppPresentation { static var allowsInterface = true }
@MainActor enum UIWakePolicy {
    static var expanded = false
    static func setIslandExpanded(_ value: Bool) { expanded = value }
}
extension Notification.Name { static let showMainWindow = Notification.Name("fixture.show-main-window") }
@MainActor final class NotificationService {
    static let shared = NotificationService()
    var parks = 0
    func notifyNeedsInput(session: ProviderStore.Session) { parks += 1 }
    func notifyNeedsInput(cursor: ProviderStore.CursorSession) { parks += 1 }
}
''' + controller + r'''
func expect(_ ok: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !ok() { print("FAIL: line \(line): \(message)"); fflush(stdout); exit(1) }
}
@main struct Regression {
    @MainActor static func pause(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        ProductBrandMark.resourceRoot = brandMarkRoot
        let a = IslandDisplayOption(id: "builtin", name: "MacBook", isBuiltIn: true,
            geometry: NotchGeometry(size: CGSize(width: 200, height: 46), hasHardwareNotch: true,
                                    screenFrame: CGRect(x: 20000, y: 20000, width: 1512, height: 982)))
        var externalGeometry = NotchGeometry(size: CGSize(width: 0, height: 28), hasHardwareNotch: false,
            screenFrame: CGRect(x: 21512, y: 20000, width: 1920, height: 1080))
        externalGeometry.topInset = 36
        let b = IslandDisplayOption(id: "external", name: "Studio Display", isBuiltIn: false, geometry: externalGeometry)
        var connected = [a, b]
        expect(IslandDisplaySelection.eligible(connected, policy: .all, selected: "").count == 2, "two extended viewports")
        expect(IslandDisplaySelection.eligible([b], policy: .builtIn, selected: "").first?.id == b.id, "clamshell fallback")
        expect(IslandDisplaySelection.eligible([a], policy: .selected, selected: b.id).first?.id == a.id, "missing selected screen fallback")
        let mirrored = IslandDisplayOption(id: "mirror", name: "Mirror", isBuiltIn: false, geometry: a.geometry)
        expect(IslandDisplaySelection.eligible([mirrored, a], policy: .all, selected: "").map(\.id) == [a.id], "mirrors deduplicate and retain hardware notch")
        let left = IslandDisplayOption(id: "left", name: "Left", isBuiltIn: false,
            geometry: NotchGeometry(size: CGSize(width: 0, height: 28), hasHardwareNotch: false,
                                    screenFrame: CGRect(x: -1920, y: -200, width: 1920, height: 1080)))
        expect(IslandDisplaySelection.target([a, left], pointer: CGPoint(x: -20, y: 500), last: a.id) == left.id, "negative display origins route normally")
        expect(IslandDisplaySelection.target(connected, pointer: .zero, last: b.id) == b.id, "offscreen pointer uses last connected screen")
        let prefs = AppPreferences.shared
        let store = ProviderStore()
        store.sessions = [.init(pid: 1)]
        let controller = NotchIslandController(providerStore: store, codexStore: CodexProviderStore(), screensProvider: { connected })
        controller.start()
        let model = controller.model!
        expect(controller.surfaces.count == 2 && IslandLiveModel.instances == 1, "two panels share one model")
        let external = controller.surfaces[b.id]!
        expect(external.state.collapsedSize == CGSize(width: 440, height: 48), "compact external capsule has no hardware gap")
        expect(external.panel.frame.maxY == b.geometry.anchorY, "capsule canvas starts below the menu bar")
        let mainWindowObserver = NotificationCenter.default.addObserver(forName: .showMainWindow, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MainWindowEvents.count += 1 }
        }
        let collapsedHost = external.panel.contentView!.subviews[0] as! NSHostingView<NotchIslandView>
        collapsedHost.rootView.actions.openMainWindow()
        expect(MainWindowEvents.count == 1 && external.state.mode == .collapsed,
               "brand opens workbench from inactive collapsed display without expanding")
        NotificationCenter.default.removeObserver(mainWindowObserver)

        let entry = b.geometry.topRect(external.state.collapsedSize)
        expect(!external.contains(CGPoint(x: entry.minX + 1, y: entry.maxY - 1)), "rounded transparent corners pass through")
        expect(external.contains(CGPoint(x: entry.midX, y: entry.midY)), "capsule center receives a click")
        let cached = external.hitPath
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100_000 { _ = external.contains(CGPoint(x: entry.midX, y: entry.midY)) }
        let hitTime = ProcessInfo.processInfo.systemUptime - started
        expect(external.hitPath === cached, "pointer moves reuse the shape path")
        expect(controller.tickTimer == nil, "collapsed islands have no close timer")
        let idleStarted = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100_000 { controller.pointerMoved() }
        let idlePointerTime = ProcessInfo.processInfo.systemUptime - idleStarted
        expect(controller.armTimer == nil && controller.tickTimer == nil, "ordinary pointer movement starts no timers")
        Pointer.location = CGPoint(x: entry.midX, y: entry.midY)
        controller.pointerMoved()
        pause(0.08)
        expect(external.state.mode == .collapsed, "passing pointer does not open external HUD")
        pause(0.14)
        expect(controller.activeID == b.id && external.state.mode == .expanded, "external hover opens details directly without a click")
        expect(controller.surfaces[a.id]?.state.mode == .collapsed && UIWakePolicy.expanded && !external.panel.acceptsKeyboard, "hover opens full details without stealing keyboard focus")
        let aEntry = a.geometry.topRect(controller.surfaces[a.id]!.state.collapsedSize)
        Pointer.buttons = 1
        Pointer.location = CGPoint(x: aEntry.midX, y: aEntry.midY)
        controller.pointerMoved(); controller.tick(); pause(0.3)
        expect(controller.armedID == nil && external.state.mode == .expanded, "held click or drag cannot migrate/collapse details")
        Pointer.buttons = 0
        controller.pointerMoved(); pause(0.32)
        expect(controller.activeID == a.id && controller.state?.mode == .expanded, "deliberate cross-screen hover hands over details")
        expect(external.state.mode == .collapsed && controller.model === model, "handoff keeps one expanded state and shared model")
        controller.collapse(animated: false)
        Pointer.location = CGPoint(x: entry.midX, y: entry.midY)
        let externalHost = external.panel.contentView!.subviews[0] as! NSHostingView<NotchIslandView>
        externalHost.rootView.actions.expandFromAlert()
        expect(external.state.mode == .expanded && controller.clickOpened, "click opens persistent external details")
        expect(external.state.expandedSize == CGSize(width: 440, height: 212), "external details use a compact fixed layout")
        expect(controller.tickTimer == nil && external.panel.acceptsKeyboard, "click details accept Escape without a polling timer")
        Pointer.location = CGPoint(x: aEntry.midX, y: aEntry.midY)
        controller.pointerMoved(); controller.tick(); pause(0.35)
        expect(external.state.mode == .expanded && controller.armTimer == nil, "pointer exit and other-screen hover preserve clicked details")
        let outsideClick = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        controller.handlePointerEvent(outsideClick)
        expect(external.state.mode == .collapsed && !controller.clickOpened && !external.panel.acceptsKeyboard,
               "outside click releases keyboard and closes details")
        controller.cancelArming()
        Pointer.location = CGPoint(x: entry.midX, y: entry.midY)
        externalHost.rootView.actions.expandFromAlert()
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: external.panel.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        expect(controller.handleKeyEvent(escape) && external.state.mode == .collapsed,
               "Escape dismisses click-open details")
        expect(!controller.handleKeyEvent(escape), "collapsed entry does not swallow keyboard input")
        controller.pointerMoved(); pause(0.35)
        expect(external.state.mode == .expanded, "hover details reopen after dismissal")
        Pointer.location = .zero
        controller.tick(); pause(0.35)
        expect(external.state.mode == .collapsed && controller.tickTimer == nil,
               "leaving preview closes it and releases polling")
        Pointer.location = CGPoint(x: entry.midX, y: entry.midY)
        var session = fixtureSessions()[0]
        session.pid = 1
        model.finished.send(session)
        expect(controller.activeID == b.id && external.state.mode == .alert, "alert routes to pointer screen once")
        let deadline = controller.alertDeadline!
        Pointer.location = CGPoint(x: a.geometry.screenFrame.midX, y: a.geometry.screenFrame.midY)
        controller.pointerMoved()
        model.finished.send(fixtureSessions()[1])
        expect(controller.activeID == b.id, "subsequent alert stays on the already visible screen")
        let alertID = controller.state?.alert?.id
        let currentDeadline = controller.alertDeadline!
        let staleHost = external.panel.contentView!.subviews[0] as! NSHostingView<NotchIslandView>
        let staleActions = staleHost.rootView.actions
        connected = [a]
        controller.screensChanged()
        expect(controller.surfaces.count == 1 && controller.activeID == a.id, "unplug removes stale panel")
        expect(controller.state?.alert?.id == alertID && controller.alertDeadline == currentDeadline, "unplug carries remaining alert without resetting lifetime")
        expect(!external.panel.isVisible, "disconnected panel closes")
        staleActions.expandFromAlert(); staleActions.dismissAlert(); staleActions.openSession(session)
        expect(controller.state?.mode == .alert && model.openedSessions == 0,
               "disconnected view callbacks cannot open/dismiss another screen or reveal a session")
        expect(deadline <= currentDeadline, "new event may refresh alert deadline")
        controller.collapse(animated: false)
        prefs.notchIslandSelectedDisplay = b.id
        prefs.notchIslandDisplayPolicy = .selected
        pause(0.03)
        expect(controller.displays.map(\.id) == [a.id] && prefs.notchIslandSelectedDisplay == b.id, "fallback preserves saved display identity")
        connected = [a, b]; controller.screensChanged()
        expect(controller.displays.map(\.id) == [b.id], "reconnect restores chosen screen")
        staleActions.expandFromAlert()
        expect(controller.state?.mode == .collapsed, "reconnected UUID cannot grant ownership to an old panel callback")
        prefs.notchIslandDisplayPolicy = .all; pause(0.03)
        prefs.notchIslandInFullScreen = true
        expect(controller.surfaces.values.allSatisfy { $0.panel.collectionBehavior.contains(.fullScreenAuxiliary) }, "full screen preference applies to every display")
        prefs.notchIslandShowsWings = false
        expect(controller.surfaces[b.id]?.state.collapsedSize.width == 44 && !model.periodicRefresh, "minimal external entry survives hidden readouts without usage timer")
        prefs.notchIslandShowsWings = true
        expect(model.periodicRefresh, "one shared usage refresh resumes")
        controller.activate(a.id); controller.expand()
        model.needsInput.send(session)
        expect(NotificationService.shared.parks == 1, "expanded panel retains parked-session fallback")
        controller.collapse(animated: false)
        connected = []; controller.screensChanged()
        expect(controller.surfaces.isEmpty && !model.periodicRefresh, "no screen releases display refresh")
        model.needsInput.send(session)
        expect(NotificationService.shared.parks == 2, "missing screen cannot silently lose a parked session")
        let above = IslandDisplayOption(id: "above", name: "Above", isBuiltIn: false,
            geometry: NotchGeometry(size: CGSize(width: 0, height: 28), hasHardwareNotch: false,
                screenFrame: CGRect(x: 20000, y: a.geometry.screenFrame.maxY, width: 1920, height: 1080)))
        connected = [a, above]; controller.screensChanged()
        Pointer.location = CGPoint(x: a.geometry.screenFrame.midX, y: a.geometry.screenFrame.maxY + 1)
        controller.pointerMoved()
        expect(controller.armTimer == nil, "top-edge extension cannot activate the lower screen from an upper display")
        connected = [a, b]; controller.screensChanged()
        Pointer.location = CGPoint(x: entry.midX, y: entry.midY)
        controller.pointerMoved()
        expect(controller.armTimer != nil, "hover armed before teardown")
        controller.stop(); pause(0.08)
        expect(controller.surfaces.isEmpty && controller.armTimer == nil && controller.tickTimer == nil && controller.model == nil,
               "teardown cancels pending open, ticks, models and panels")
        expect(controller.globalMonitor == nil && controller.localMonitor == nil && !UIWakePolicy.expanded,
               "teardown removes event monitors and visible-interface ownership")
        expect(NSApp.windows.allSatisfy { !$0.isVisible }, "no fixture windows remain visible")
        print("PASS: dual-screen routing, shape capture/cache, single expansion/model, drag ownership, alert pinning/transfer, mirror/negative origins, disconnect/reconnect, settings and teardown")
        print("MEASURE: 100000 cached capsule hits: \(hitTime * 1000) ms; 100000 idle dual-screen pointer moves: \(idlePointerTime * 1000) ms")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='claudebar-island-display-') as folder:
    file = Path(folder)/'Regression.swift'; binary = Path(folder)/'regression'
    file.write_text(source)
    subprocess.run(['swiftc','-O','-parse-as-library','-target','arm64-apple-macos15.0',str(file),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
