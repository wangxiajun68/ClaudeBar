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
}

// MARK: - Controller

/// Owns the notch island: a fixed, transparent panel pinned to the top center
/// of the notched screen, and the state machine that grows the island out of
/// the notch and folds it back.
///
///     collapsed ──hover 120 ms──▶ expanded ──pointer away 250 ms──▶ collapsed
///         │                          ▲
///         └──session finished──▶ alert ──click──┘
///                                  └──6 s (paused while hovered) / 继续──▶ collapsed
///
/// Collapsed, the panel ignores the mouse and a global + local `mouseMoved`
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

    private var panel: NotchIslandPanel?
    private var state: NotchIslandState?
    private var model: IslandLiveModel?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var armTimer: Timer?
    private var tickTimer: Timer?
    /// Last value written to `panel.ignoresMouseEvents` (see
    /// `syncMouseCapture`). Cleared whenever the panel is replaced.
    private var mouseCapture: Bool?
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

    init(providerStore: ProviderStore, codexStore: CodexProviderStore) {
        self.providerStore = providerStore
        self.codexStore = codexStore
    }

    func start() {
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
                MainActor.assumeIsolated { self?.panel?.applyCollectionBehavior(inFullScreen: inFullScreen) }
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
    }

    // MARK: Install / uninstall

    private func install() {
        guard panel == nil, let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry(screen: screen)
        let state = NotchIslandState(geometry: geometry, showsWings: prefs.notchIslandShowsWings)
        let model = IslandLiveModel(providerStore: providerStore, codexStore: codexStore)
        model.setPeriodicRefresh(prefs.notchIslandShowsWings)
        self.state = state
        self.model = model
        bind(model, to: state)

        let actions = IslandActions(
            openSession: { [weak self] session in
                MainActor.assumeIsolated {
                    self?.model?.open(session)
                    self?.collapse(animated: true)
                }
            },
            openMainWindow: { [weak self] in
                MainActor.assumeIsolated {
                    NotificationCenter.default.post(name: .showMainWindow, object: nil)
                    self?.collapse(animated: true)
                }
            },
            expandFromAlert: { [weak self] in
                MainActor.assumeIsolated { self?.expand() }
            })

        let panel = NotchIslandPanel()
        panel.applyCollectionBehavior(inFullScreen: prefs.notchIslandInFullScreen)
        let hosting = NSHostingView(rootView: NotchIslandView(state: state, model: model, actions: actions))
        // No Auto Layout and no size feedback into the window: the panel is a
        // fixed canvas (same macOS 26 constraint-crash avoidance as the
        // menu-bar popup).
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(origin: .zero, size: IslandStyle.panelSize)
        let container = NSView(frame: hosting.frame)
        container.autoresizesSubviews = true
        container.addSubview(hosting)
        panel.contentView = container
        self.panel = panel
        mouseCapture = nil

        position(panel, geometry: geometry)
        panel.orderFrontRegardless()

        installMouseMonitors()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    private func uninstall() {
        collapse(animated: false)
        removeMouseMonitors()
        armTimer?.invalidate()
        armTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        state = nil
        modelCancellables.removeAll()
        model?.setPeriodicRefresh(false)
        model = nil
    }

    private func bind(_ model: IslandLiveModel, to state: NotchIslandState) {
        modelCancellables.removeAll()

        // No `model.$sessions` bridge: it used to write a `sessionCount` on the
        // state purely to animate the lane's height, but the strip has been a
        // fixed-height window since the island stopped resizing around its
        // sessions (see `NotchIslandState.sessionsLaneHeight`). The bridge only
        // produced a `morphSpring` animation and a state invalidation per poll
        // whose result nothing read.

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
    }

    private func applyWings(_ shows: Bool) {
        model?.setPeriodicRefresh(shows)
        withAnimation(IslandStyle.morphSpring) { state?.showsWings = shows }
    }

    private func screensChanged() {
        guard let panel, let state else { return }
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry(screen: screen)
        if geometry != state.geometry {
            collapse(animated: false)
            state.geometry = geometry
        }
        position(panel, geometry: geometry)
    }

    private func position(_ panel: NSPanel, geometry: NotchGeometry) {
        let size = IslandStyle.panelSize
        let frame = NSRect(x: geometry.screenFrame.midX - size.width / 2,
                           y: geometry.screenFrame.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }

    // MARK: Hit zones (global AppKit coordinates)

    /// A rect hanging from the top edge of the screen, centered on the notch.
    private func topRect(_ size: CGSize) -> CGRect {
        guard let state else { return .zero }
        let screen = state.geometry.screenFrame
        return CGRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Collapsed hot zone. Extends 2pt above the screen edge because the
    /// pointer pinned against the top reports `y == maxY`.
    private var collapsedHotZone: CGRect {
        guard let state else { return .zero }
        let size = state.collapsedSize
        return topRect(CGSize(width: size.width + 8, height: size.height + 2)).offsetBy(dx: 0, dy: 2)
    }

    private var openZone: CGRect {
        guard let state else { return .zero }
        return topRect(state.islandSize).insetBy(dx: -8, dy: -8)
    }

    // MARK: Mouse

    private func installMouseMonitors() {
        removeMouseMonitors()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
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

    /// Only the collapsed island arms on hover; the alert expands on click so
    /// its 继续 button stays reachable.
    private func pointerMoved() {
        guard let state else { return }
        if state.mode != .collapsed {
            syncMouseCapture()
            return
        }
        if collapsedHotZone.contains(NSEvent.mouseLocation) {
            guard armTimer == nil else { return }
            armTimer = Timer.scheduledTimer(withTimeInterval: Self.armDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.armTimer = nil
                    if self.state?.mode == .collapsed, self.collapsedHotZone.contains(NSEvent.mouseLocation) {
                        self.expand()
                    }
                }
            }
        } else {
            armTimer?.invalidate()
            armTimer = nil
        }
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
        guard let panel, let state else { return }
        let ignore: Bool
        switch state.mode {
        case .collapsed:
            ignore = true
        case .alert, .expanded:
            ignore = !islandHitZone.contains(NSEvent.mouseLocation)
        }
        guard ignore != mouseCapture else { return }
        mouseCapture = ignore
        panel.ignoresMouseEvents = ignore
    }

    private var islandHitZone: CGRect {
        guard let state else { return .zero }
        return topRect(state.islandSize)
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
        guard prefs.notchIslandAlertsEnabled, let state, state.mode != .expanded else { return }
        alertDeadline = Date().addingTimeInterval(Self.alertDuration)
        withAnimation(IslandStyle.alertSpring) {
            state.alert = alert
            state.mode = .alert
        }
        syncMouseCapture()
        startTicking()
    }

    private func startTicking() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
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
            if inside {
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
        panel?.ignoresMouseEvents = true
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
