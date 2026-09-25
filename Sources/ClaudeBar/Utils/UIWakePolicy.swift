import AppKit
import Combine
import SwiftUI

/// Central "is any of our UI actually on screen" signal.
///
/// The app is an always-resident menu-bar process: before this existed, every
/// poller (session scan, SMC fan sampling, FSEvents re-index, VPN status) ran
/// at full cadence whether or not a single window was visible. That is the
/// bulk of the idle CPU cost — not the rendering, the work that feeds it.
///
/// Writers (MainWindowController, MenuBarController) push state in; readers
/// ask `hasVisibleWindow` and scale their cadence, or subscribe with
/// `observe` and stop/start outright.
enum UIWakePolicy {
    /// Main window is on screen and not miniaturized.
    private static var mainWindowVisible = false
    /// Menu-bar popup panel is open.
    private static var popupOpen = false
    /// Notch island is grown out of the notch (its collapsed wings do not count).
    private static var islandExpanded = false

    private static let subject = PassthroughSubject<Void, Never>()
    private static let lock = NSLock()

    /// Any surface a user could be looking at. When false the app is
    /// background-only and polling should drop to its sleep cadence.
    static var hasVisibleWindow: Bool {
        lock.lock(); defer { lock.unlock() }
        return mainWindowVisible || popupOpen || islandExpanded
    }

    static var hasVisibleMainWindow: Bool {
        lock.lock(); defer { lock.unlock() }
        return mainWindowVisible
    }

    /// Subscribe to visibility *changes* only. Fires on the main thread.
    static func observe(_ body: @escaping () -> Void) -> AnyCancellable {
        subject.receive(on: DispatchQueue.main).sink { _ in body() }
    }

    /// SwiftUI-facing form of `observe` (`.onReceive(UIWakePolicy.changes)`).
    /// The publisher carries no payload — read `hasVisibleWindow` on receipt.
    static var changes: AnyPublisher<Void, Never> {
        subject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    static func setMainWindowVisible(_ visible: Bool) {
        lock.lock()
        guard mainWindowVisible != visible else { lock.unlock(); return }
        mainWindowVisible = visible
        lock.unlock()
        subject.send()
    }

    static func setPopupOpen(_ open: Bool) {
        lock.lock()
        guard popupOpen != open else { lock.unlock(); return }
        popupOpen = open
        lock.unlock()
        subject.send()
    }

    static func setIslandExpanded(_ expanded: Bool) {
        lock.lock()
        guard islandExpanded != expanded else { lock.unlock(); return }
        islandExpanded = expanded
        lock.unlock()
        subject.send()
    }
}

/// Visibility of the owning surface, independent of other open windows.
/// Popup content is destroyed on close; the persistent main window overrides it.
private struct SurfaceVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var surfaceIsVisible: Bool {
        get { self[SurfaceVisibleKey.self] }
        set { self[SurfaceVisibleKey.self] = newValue }
    }
}
