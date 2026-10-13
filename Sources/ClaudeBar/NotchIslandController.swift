import AppKit
import SwiftUI
import Combine

// MARK: - State

/// View-facing state of the notch island; the controller is its only writer.
@MainActor
final class NotchIslandState: ObservableObject {
    enum Mode { case collapsed, alert, expanded }

    @Published var mode: Mode = .collapsed
    @Published var geometry: NotchGeometry
    @Published var showsWings: Bool
    /// What the alert is about; set while `mode == .alert`.
    @Published var alert: IslandAlert?

    init(geometry: NotchGeometry, showsWings: Bool) {
        self.geometry = geometry
        self.showsWings = showsWings
    }

    var notch: CGSize { geometry.size }

    /// Nothing to draw: collapsed, no wings, and the hardware notch already
    /// looks exactly like the island would.
    var isCollapsedInvisible: Bool {
        mode == .collapsed && !showsWings && geometry.hasHardwareNotch
    }

    var collapsedSize: CGSize {
        if !geometry.hasHardwareNotch {
            return CGSize(width: showsWings ? 154 : 42, height: notch.height)
        }
        let wings = showsWings ? 2 * IslandStyle.wingWidth : 0
        return CGSize(width: notch.width + 2 * IslandStyle.topFlare + wings, height: notch.height)
    }

    var alertSize: CGSize {
        CGSize(width: max(IslandStyle.minAlertWidth, notch.width + 2 * IslandStyle.topFlare + 200),
               height: notch.height + IslandStyle.alertBodyHeight)
    }

    /// A fixed two-row grid with a compact readout. Scrolling never changes
    /// the island's height, regardless of the number of sessions.
    var sessionsLaneHeight: CGFloat { IslandStyle.expandedLaneHeight }

    var expandedSize: CGSize {
        let width = max(IslandStyle.minExpandedWidth, notch.width + 2 * IslandStyle.topFlare + 320)
        let height = notch.height + IslandStyle.contentTopGap + sessionsLaneHeight
            + IslandStyle.sectionGap + IslandStyle.usageCardHeight + IslandStyle.bottomPadding
        return CGSize(width: width, height: height)
    }

    var islandSize: CGSize {
        switch mode {
        case .collapsed: return collapsedSize
        case .alert: return alertSize
        case .expanded: return expandedSize
        }
    }

    var topFlare: CGFloat { geometry.hasHardwareNotch ? IslandStyle.topFlare : 0 }
    var bottomRadius: CGFloat {
        switch mode {
        case .collapsed: return geometry.hasHardwareNotch ? IslandStyle.collapsedBottomRadius : notch.height / 2
        case .alert: return IslandStyle.alertBottomRadius
        case .expanded: return IslandStyle.expandedBottomRadius
        }
    }
}

// MARK: - Controller

/// Owns a fixed, transparent panel on each enabled screen. Hardware notches
/// grow two wings; unnotched screens carry a detached capsule. One shared
/// model and one active-panel state machine serve every entry.
///
///     collapsed ──hover 120 ms──▶ expanded ──pointer away 250 ms──▶ collapsed
///         │                          ▲
///         └──session finished──▶ alert ──click──┘
///                                  └──6 s (paused while hovered) / 继续──▶ collapsed
///
/// Collapsed hardware entries ignore the mouse; capsules accept clicks only
/// inside their contour. A shared global + local mouse event
/// monitor watches the hot zone (mouse-only monitors need no Accessibility
/// permission). Open, the same monitors arm the mouse only while the pointer
/// is inside the island shape — the panel is a fixed transparent canvas, and
/// clicks outside the shape pass through to whatever is underneath. A 10 Hz
/// timer, alive only while the island is open, decides when to close: a
/// non-key panel does not get reliable `mouseMoved`.
@MainActor
final class NotchIslandController {
    private let providerStore: ProviderStore
    private let codexStore: CodexProviderStore
    private let prefs = AppPreferences.shared

    @MainActor private final class Surface {
        let id: String
        let panel: NotchIslandPanel
        let state: NotchIslandState
        var mouseCapture: Bool?
        var hitSize: CGSize = .zero
        var hitRadius: CGFloat = -1
        var hitPath: CGPath?

        init(id: String, panel: NotchIslandPanel, state: NotchIslandState) {
            self.id = id; self.panel = panel; self.state = state
        }

        func contains(_ pointer: CGPoint) -> Bool {
            let size = state.islandSize
            let rect = state.geometry.topRect(size)
            guard rect.contains(pointer) else { return false }
            if hitPath == nil || hitSize != size || hitRadius != state.bottomRadius {
                hitSize = size; hitRadius = state.bottomRadius
                hitPath = IslandShape(topFlare: state.topFlare, bottomRadius: state.bottomRadius,
                                      detached: !state.geometry.hasHardwareNotch)
                    .path(in: CGRect(origin: .zero, size: size)).cgPath
            }
            return hitPath?.contains(CGPoint(x: pointer.x - rect.minX, y: rect.maxY - pointer.y)) == true
        }
    }

    private var surfaces: [String: Surface] = [:]
    private var displays: [IslandDisplayOption] = []
    private var activeID: String?
    private var lastPointerID: String?
    private var armedID: String?
    private var panel: NotchIslandPanel? { activeID.flatMap { surfaces[$0]?.panel } }
    private var state: NotchIslandState? { activeID.flatMap { surfaces[$0]?.state } }
    private let screensProvider: @MainActor () -> [IslandDisplayOption]
    private var model: IslandLiveModel?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var armTimer: Timer?
    private var tickTimer: Timer?
    private var leaveDeadline: Date?
    private var alertDeadline: Date?
    private var screenObserver: NSObjectProtocol?
    private var prefsCancellables: Set<AnyCancellable> = []
    private var modelCancellables: Set<AnyCancellable> = []

    private static let armDelay: TimeInterval = 0.12
    private static let leaveDelay: TimeInterval = 0.25
    private static let alertDuration: TimeInterval = 6
    /// Minimum time left on the alert after the pointer leaves it.
    private static let alertGrace: TimeInterval = 2

    init(providerStore: ProviderStore, codexStore: CodexProviderStore,
         screensProvider: @escaping @MainActor () -> [IslandDisplayOption] = { IslandDisplayOption.current }) {
        self.providerStore = providerStore
        self.codexStore = codexStore
        self.screensProvider = screensProvider
    }

    func start() {
        guard AppPresentation.allowsInterface else { return }
        // Watch for parks from the moment the app runs, so a disabled island (no
        // panel, no strip) still posts the fallback banner.
        ensureModel()

        prefs.$notchIslandEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    if enabled { self?.install() } else { self?.uninstall() }
                }
            }
            .store(in: &prefsCancellables)

        prefs.$notchIslandShowsWings
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] shows in
                MainActor.assumeIsolated { self?.applyWings(shows) }
            }
            .store(in: &prefsCancellables)

        prefs.$notchIslandInFullScreen
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] inFullScreen in
                MainActor.assumeIsolated {
                    self?.surfaces.values.forEach { $0.panel.applyCollectionBehavior(inFullScreen: inFullScreen) }
                }
            }
            .store(in: &prefsCancellables)

        prefs.$notchIslandAlertsEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    guard let self, !enabled, self.state?.mode == .alert else { return }
                    self.collapse(animated: true)
                }
            }
            .store(in: &prefsCancellables)
        Publishers.CombineLatest(prefs.$notchIslandDisplayPolicy.removeDuplicates(),
                                 prefs.$notchIslandSelectedDisplay.removeDuplicates())
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanged() }
            }
            .store(in: &prefsCancellables)
    }

    func stop() {
        prefsCancellables.removeAll()
        uninstall()
        modelCancellables.removeAll()
        model?.setPeriodicRefresh(false)
        model = nil
    }

    // MARK: Install / uninstall

    private func install() {
        guard AppPresentation.allowsInterface, screenObserver == nil else { return }
        ensureModel()
        installMouseMonitors()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        reconcileSurfaces()
    }

    private func createSurface(_ display: IslandDisplayOption) -> Surface {
        let state = NotchIslandState(geometry: display.geometry, showsWings: prefs.notchIslandShowsWings)
        let id = display.id
        let actions = IslandActions(
            openSession: { [weak self] session in
                MainActor.assumeIsolated {
                    guard let self, self.activeID == id, self.surfaces[id]?.state === state else { return }
                    self.model?.open(session)
                    self.collapse(animated: true)
                }
            },
            openMainWindow: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.activeID == id, self.surfaces[id]?.state === state else { return }
                    NotificationCenter.default.post(name: .showMainWindow, object: nil)
                    self.collapse(animated: true)
                }
            },
            expandFromAlert: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.surfaces[id]?.state === state else { return }
                    self.activate(id)
                    self.expand()
                }
            },
            dismissAlert: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.activeID == id, self.surfaces[id]?.state === state else { return }
                    self.collapse(animated: true)
                }
            })
        let panel = NotchIslandPanel()
        panel.applyCollectionBehavior(inFullScreen: prefs.notchIslandInFullScreen)
        let hosting = NSHostingView(rootView: NotchIslandView(state: state, model: ensureModel(), actions: actions))
        // Fixed canvases never negotiate their size during an animation.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(origin: .zero, size: IslandStyle.panelSize)
        let container = NSView(frame: hosting.frame)
        container.autoresizesSubviews = true
        container.addSubview(hosting)
        panel.contentView = container
        position(panel, geometry: display.geometry)
        panel.orderFrontRegardless()
        return Surface(id: id, panel: panel, state: state)
    }

    private func reconcileSurfaces() {
        let pendingAlert = state?.mode == .alert ? state?.alert : nil
        let pendingDeadline = alertDeadline
        cancelArming()
        displays = IslandDisplaySelection.eligible(screensProvider(), policy: prefs.notchIslandDisplayPolicy,
                                                  selected: prefs.notchIslandSelectedDisplay)
        let ids = Set(displays.map(\.id))
        for id in Array(surfaces.keys) where !ids.contains(id) {
            if activeID == id { collapse(animated: false); activeID = nil }
            if let surface = surfaces.removeValue(forKey: id) {
                surface.panel.orderOut(nil)
                surface.panel.contentView = nil
                surface.panel.close()
            }
        }
        for display in displays {
            if let surface = surfaces[display.id] {
                if surface.state.geometry != display.geometry {
                    if activeID == display.id { collapse(animated: false) }
                    surface.state.geometry = display.geometry
                    surface.hitPath = nil
                }
                position(surface.panel, geometry: display.geometry)
            } else {
                surfaces[display.id] = createSurface(display)
            }
        }
        if activeID == nil {
            activeID = IslandDisplaySelection.target(displays, pointer: NSEvent.mouseLocation, last: lastPointerID)
        }
        model?.setPeriodicRefresh(!surfaces.isEmpty && prefs.notchIslandShowsWings)
        // Disconnects carry the remaining alert, without replaying its event or
        // extending its lifetime. Opening a different entry stays deliberate.
        if state?.mode == .collapsed, let pendingAlert, let pendingDeadline,
           pendingDeadline > Date() {
            state?.alert = pendingAlert
            state?.mode = .alert
            alertDeadline = pendingDeadline
            startTicking()
        }
        syncMouseCapture()
    }

    private func uninstall() {
        collapse(animated: false)
        removeMouseMonitors()
        cancelArming()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for surface in surfaces.values {
            surface.panel.orderOut(nil)
            surface.panel.contentView = nil
            surface.panel.close()
        }
        surfaces.removeAll()
        displays.removeAll()
        activeID = nil; lastPointerID = nil
        // Alert edges outlive all panels; only periodic wing refresh stops.
        model?.setPeriodicRefresh(false)
    }

    private func activate(_ id: String) {
        guard surfaces[id] != nil, activeID != id else { return }
        collapse(animated: true)
        activeID = id
    }

    /// Create the model on first use and wire its alert edges exactly once.
    ///
    /// The edges are subscribed here, not in `install()`, because they must
    /// survive the panel: a disabled island still has to notice a session
    /// parking on the user (the fallback banner in `showAlert` is the point).
    @discardableResult
    private func ensureModel() -> IslandLiveModel {
        if let model { return model }
        let model = IslandLiveModel(providerStore: providerStore, codexStore: codexStore)
        self.model = model

        // No `model.$sessions` bridge: it used to write a `sessionCount` on the
        // state purely to animate the lane's height, but the strip has been a
        // fixed-height window since the island stopped resizing around its
        // sessions (see `NotchIslandState.sessionsLaneHeight`).

        model.quotaReset
            .sink { [weak self] window in
                MainActor.assumeIsolated { self?.showAlert(for: .quotaReset(window)) }
            }
            .store(in: &modelCancellables)

        model.finished
            .sink { [weak self] session in
                MainActor.assumeIsolated { self?.showAlert(for: .finished(session)) }
            }
            .store(in: &modelCancellables)

        // The other "your move" edge. The strip is the preferred surface — a
        // permission prompt is answered where it was asked — but it is not
        // always available, and a parked session must never go unannounced
        // while the menu-bar icon reads *idle*. `showAlert` falls back to a
        // system banner exactly when the strip cannot carry it.
        model.needsInput
            .sink { [weak self] session in
                MainActor.assumeIsolated { self?.showAlert(for: .needsInput(session)) }
            }
            .store(in: &modelCancellables)

        return model
    }

    private func applyWings(_ shows: Bool) {
        model?.setPeriodicRefresh(shows && prefs.notchIslandEnabled)
        withAnimation(IslandStyle.morphSpring) {
            surfaces.values.forEach { $0.state.showsWings = shows; $0.hitPath = nil }
        }
        syncMouseCapture()
    }

    private func screensChanged() {
        guard prefs.notchIslandEnabled, screenObserver != nil else { return }
        reconcileSurfaces()
    }

    private func position(_ panel: NSPanel, geometry: NotchGeometry) {
        panel.setFrame(geometry.topRect(IslandStyle.panelSize), display: true)
    }

    // MARK: Hit zones (global AppKit coordinates)

    private func collapsedHotZone(_ surface: Surface) -> CGRect {
        let state = surface.state
        if state.geometry.hasHardwareNotch {
            return state.geometry.topRect(CGSize(width: state.collapsedSize.width + 8,
                                                 height: state.collapsedSize.height + 2)).offsetBy(dx: 0, dy: 2)
        }
        return state.geometry.topRect(state.collapsedSize).insetBy(dx: -3, dy: -3)
    }

    private var openZone: CGRect {
        guard let state else { return .zero }
        return state.geometry.topRect(state.islandSize).insetBy(dx: -8, dy: -8)
    }

    // MARK: Mouse

    private func installMouseMonitors() {
        removeMouseMonitors()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
    }

    private func removeMouseMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func cancelArming() {
        armTimer?.invalidate()
        armTimer = nil; armedID = nil
    }

    private func pointerMoved() {
        let pointer = NSEvent.mouseLocation
        let pointerID = displays.first(where: { $0.geometry.screenFrame.contains(pointer) })?.id
        if let id = pointerID {
            lastPointerID = id
        }
        syncMouseCapture()
        // Dragging a window or scrubbing a chart never opens another island.
        guard NSEvent.pressedMouseButtons == 0,
              let display = displays.first(where: { display in
                  guard pointerID == nil || pointerID == display.id,
                        let surface = surfaces[display.id] else { return false }
                  return surface.state.mode == .collapsed && collapsedHotZone(surface).contains(pointer)
              }) else { cancelArming(); return }
        guard let surface = surfaces[display.id] else { cancelArming(); return }
        guard armedID != surface.id else { return }
        cancelArming()
        let id = surface.id
        armedID = id
        let delay = state?.mode == .expanded ? Self.leaveDelay : Self.armDelay
        armTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.armTimer = nil; self.armedID = nil
                guard NSEvent.pressedMouseButtons == 0, let surface = self.surfaces[id],
                      surface.state.mode == .collapsed,
                      self.collapsedHotZone(surface).contains(NSEvent.mouseLocation) else { return }
                self.activate(id)
                self.expand()
            }
        }
        if let armTimer { RunLoop.main.add(armTimer, forMode: .common) }
    }

    // MARK: Transitions

    /// The window only receives clicks that land on the drawn island. The rest
    /// of the fixed panel stays click-through, including while an alert is up.
    ///
    /// Guarded on the last value written: this is called from the pointer
    /// monitors (once per `mouseMoved`) *and* from the 10 Hz close timer, and
    /// `ignoresMouseEvents` is not a cheap flag to re-set — each write re-runs
    /// the window's mouse-handling re-evaluation, which shows up in a sample
    /// as `_NSWindowSetIgnoresMouseEvents` under the pointer-move stack.
    private func syncMouseCapture() {
        let pointer = NSEvent.mouseLocation
        for surface in surfaces.values {
            // Keep the target of an in-progress click or drag until release.
            if surface.state.mode != .collapsed && NSEvent.pressedMouseButtons != 0 { continue }
            let ignore = surface.state.isCollapsedInvisible ||
                (surface.state.mode == .collapsed && surface.state.geometry.hasHardwareNotch) ||
                !surface.contains(pointer)
            guard ignore != surface.mouseCapture else { continue }
            surface.mouseCapture = ignore
            surface.panel.ignoresMouseEvents = ignore
        }
    }

    private func expand() {
        guard let state, state.mode != .expanded else { return }
        alertDeadline = nil
        withAnimation(IslandStyle.expandSpring) {
            state.mode = .expanded
            state.alert = nil
        }
        syncMouseCapture()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        UIWakePolicy.setIslandExpanded(true)
        model?.reloadUsage()
        model?.requestFreshIndex()
        leaveDeadline = nil
        startTicking()
    }

    /// Surfaces an alert in the strip below the notch. A newer alert replaces
    /// the one on screen; nothing interrupts an expanded island, which already
    /// lists the sessions (and the quota it shows).
    ///
    /// Finished sessions and quota rollovers share this path — both are
    /// "something you were waiting for just became true", both auto-dismiss on
    /// the same deadline, and both expand the island on click.
    private func showAlert(for alert: IslandAlert) {
        // The strip is the primary surface, but it is not always available:
        // alerts can be off, the island can be off, and a strip already open
        // (`.expanded`) refuses an alert by design. For a *finished* turn that
        // is acceptable — the expanded strip lists it and the system banner
        // still fires from `ProviderStore`. For a **parked** session it is not:
        // the strip alert is a one-shot edge with no retry, the menu-bar icon
        // reads *idle* while a session waits, and nothing else would tell the
        // user. So when the strip cannot carry the park, post the system banner
        // instead — the one channel that survives a hidden island, a disabled
        // island, and an open strip alike.
        if case .needsInput(let session) = alert, !canShowStripAlert {
            notifyParkedFallback(for: session)
            return
        }
        guard canShowStripAlert else { return }
        // A visible alert owns its screen until dismissal or deliberate opening.
        if state?.mode != .alert,
           let id = IslandDisplaySelection.target(displays, pointer: NSEvent.mouseLocation, last: lastPointerID) {
            activate(id)
        }
        guard let state else { return }
        alertDeadline = Date().addingTimeInterval(Self.alertDuration)
        withAnimation(IslandStyle.alertSpring) {
            state.alert = alert
            state.mode = .alert
        }
        syncMouseCapture()
        startTicking()
    }

    /// Whether the notch strip could take an alert *right now*.
    ///
    /// Disabled alerts, no connected entries, or already-expanded details use
    /// the existing parked-session notification fallback instead.
    private var canShowStripAlert: Bool {
        prefs.notchIslandEnabled && prefs.notchIslandAlertsEnabled && !surfaces.isEmpty && state?.mode != .expanded
    }

    /// The banner that stands in for a strip that could not show a park. Claude
    /// carries the reason ("等待你确认 · Bash"); Cursor's is its one plan line.
    private func notifyParkedFallback(for session: IslandSession) {
        switch session.agent {
        case .claude:
            // `IslandSession` is the island's flattened view; the banner wants
            // the store's richer session, keyed by the pid `flatten` stamped.
            guard let pid = session.pid,
                  let real = providerStore.sessions.first(where: { $0.pid == pid }) else { return }
            NotificationService.shared.notifyNeedsInput(session: real)
        case .cursor:
            guard let composer = providerStore.cursorSessions.first(where: { $0.composerId == session.sessionId })
            else { return }
            NotificationService.shared.notifyNeedsInput(cursor: composer)
        case .codex:
            // Codex never reports a park (see `ExternalSessionInfo.isWaiting`),
            // so there is no banner to post; the branch is here so a future
            // signal is wired, not silently dropped.
            break
        }
    }

    private func startTicking() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let tickTimer { RunLoop.main.add(tickTimer, forMode: .common) }
    }

    private func tick() {
        guard let state else { return }
        let now = Date()
        syncMouseCapture()
        let inside = openZone.contains(NSEvent.mouseLocation)
        switch state.mode {
        case .collapsed:
            stopTicking()
        case .alert:
            guard let deadline = alertDeadline else { return }
            if inside {
                alertDeadline = max(deadline, now.addingTimeInterval(Self.alertGrace))
            } else if now >= deadline {
                collapse(animated: true)
            }
        case .expanded:
            if inside || NSEvent.pressedMouseButtons != 0 {
                leaveDeadline = nil
            } else if let deadline = leaveDeadline {
                if now >= deadline { collapse(animated: true) }
            } else {
                leaveDeadline = now.addingTimeInterval(Self.leaveDelay)
            }
        }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
        leaveDeadline = nil
        alertDeadline = nil
    }

    private func collapse(animated: Bool) {
        stopTicking()
        guard let state, state.mode != .collapsed else { return }
        let wasExpanded = state.mode == .expanded
        // Written through the bookkeeping, not around it: `syncMouseCapture`
        // skips its write when the flag it computes matches `mouseCapture`, so
        // setting `ignoresMouseEvents` directly left the two disagreeing — the
        // *next* expand computed `ignore == false`, matched a stale
        // `mouseCapture == false`, and returned without ever giving the mouse
        // back. The island then opened under the pointer and stayed
        // click-through until the pointer left its rect and came back.
        if let id = activeID, let surface = surfaces[id] {
            surface.mouseCapture = true
            surface.panel.ignoresMouseEvents = true
        }
        let apply = {
            state.mode = .collapsed
            state.alert = nil
        }
        if animated {
            withAnimation(IslandStyle.collapseSpring, apply)
        } else {
            apply()
        }
        if wasExpanded { UIWakePolicy.setIslandExpanded(false) }
        syncMouseCapture()
    }
}

// MARK: - Panel

/// Borderless, non-activating, never-key panel above the menu bar.
private final class NotchIslandPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(origin: .zero, size: IslandStyle.panelSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func applyCollectionBehavior(inFullScreen: Bool) {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if inFullScreen { behavior.insert(.fullScreenAuxiliary) }
        collectionBehavior = behavior
    }
}
