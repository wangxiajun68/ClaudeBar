import AppKit
import CoreLocation

/// One location fix for the greeting card's weather.
///
/// Opt-in, like every other privacy switch. Creating the manager does not
/// prompt; `requestWhenInUseAuthorization` and `requestLocation` run only
/// after 设置 → 权限与隐私 → 当前位置 is on. A fix is a single
/// `requestLocation` at kilometre accuracy — enough to name a district,
/// not a trail of updates.
///
/// The system grant is the same one Wi-Fi 名称 uses. This switch is the
/// app's own gate for *reading coordinates*. Off means the coordinate is
/// dropped and the card goes back to `weatherCity`.
///
/// The build channel is the **second** gate, ahead of the switch, because a
/// grant is durable state in the user's TCC database: the request below is the
/// only thing in this file that can raise a system prompt, and a development
/// build must never leave one behind (see
/// `BuildChannel.promptsForSystemPermissions`). Every entry point therefore
/// guards on `requestFix()`, the single place that can reach the manager.
final class CurrentLocation: NSObject, CLLocationManagerDelegate {
    static let shared = CurrentLocation()

    private let manager: CLLocationManager
    private(set) var status: CLAuthorizationStatus
    private var coordinate: CLLocationCoordinate2D?
    private var pending = false
    /// The watchdog for a request in flight. Core Location has no timeout of
    /// its own: when the when-in-use prompt is ignored or the request is
    /// dropped, no delegate callback ever arrives, `pending` stays set and
    /// every later request is a no-op — the card would show 获取中 forever.
    private var fixTimeout: DispatchWorkItem?

    /// `lat,lon` for wttr.in, or nil until a fix lands.
    var query: String? {
        guard let coordinate else { return nil }
        return String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
    }

    private override init() {
        manager = CLLocationManager()
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// The switch just turned on. Ask if macOS has not, otherwise take a fix.
    func start() {
        requestFix()
    }

    /// The switch turned off. Forget the fix so the next fetch cannot use it.
    func stop() {
        pending = false
        coordinate = nil
        fixTimeout?.cancel()
        fixTimeout = nil
        manager.stopUpdatingLocation()
    }

    /// The card wants a position and does not have one yet.
    ///
    /// The one path to a system prompt. `PermissionGate` answers for the user's
    /// switch (`refreshIfStale` in `WeatherStore` gates too, for callers that
    /// only want a fix when one is already allowed); this answers for the build.
    func requestFix() {
        guard BuildChannel.promptsForSystemPermissions, PermissionGate.allows(.currentLocation) else { return }
        status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            pending = true
            NSApplication.shared.activate(ignoringOtherApps: true)
            manager.requestWhenInUseAuthorization()
            armFixTimeout()
        case .authorizedAlways, .authorizedWhenInUse:
            takeFix()
        default:
            Task { @MainActor in
                WeatherStore.shared.refreshFromCity(note: "定位未允许，显示天气城市")
            }
        }
    }

    private func takeFix() {
        guard !pending else { return }
        pending = true
        manager.requestLocation()
        armFixTimeout()
    }

    /// How long a fix may be outstanding before the request is treated as
    /// lost. The same 8 s window (plus slack) `WiFiNameAuthorization` uses.
    static let fixTimeoutSeconds: TimeInterval = 10

    /// Core Location delivers no callback for a prompt the user ignores or a
    /// when-in-use request dropped by an inactive app, and `pending` would
    /// then block every later request while `WeatherStore.loading` stayed
    /// true. The watchdog fails the attempt the way `didFailWithError` would,
    /// so the card falls back to the city and the next refresh can ask again.
    private func armFixTimeout() {
        fixTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pending else { return }
            self.pending = false
            self.fixTimeout = nil
            Task { @MainActor in
                WeatherStore.shared.refreshFromCity(note: "未能取得当前位置，显示天气城市")
            }
        }
        fixTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fixTimeoutSeconds, execute: work)
    }

    /// A callback arrived — the request is no longer outstanding.
    private func disarmFixTimeout() {
        fixTimeout?.cancel()
        fixTimeout = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let was = status
        status = manager.authorizationStatus
        if status != .notDetermined { disarmFixTimeout() }
        guard BuildChannel.promptsForSystemPermissions, PermissionGate.allows(.currentLocation) else { return }
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            // Only the grant itself starts a fix. A later callback (setting
            // the delegate, a repeat) must not cancel the request in flight.
            guard was == .notDetermined else { return }
            pending = false
            takeFix()
        case .denied, .restricted:
            pending = false
            coordinate = nil
            disarmFixTimeout()
            Task { @MainActor in
                WeatherStore.shared.refreshFromCity(note: "定位未允许，显示天气城市")
            }
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        pending = false
        disarmFixTimeout()
        guard let location = locations.last else { return }
        coordinate = location.coordinate
        Task { @MainActor in
            WeatherStore.shared.refresh()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        pending = false
        disarmFixTimeout()
        Task { @MainActor in
            WeatherStore.shared.refreshFromCity(note: "未能取得当前位置，显示天气城市")
        }
    }
}
