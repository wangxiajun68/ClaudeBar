import AppKit
import Combine
import CoreLocation

/// Requests CoreWLAN's SSID permission without starting location updates.
final class WiFiNameAuthorization: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WiFiNameAuthorization()
    @Published private(set) var status: CLAuthorizationStatus
    @Published private(set) var requesting = false
    @Published var showSettingsHelp = false
    private let manager: CLLocationManager
    private var requestTimeout: DispatchWorkItem?

    private override init() {
        manager = CLLocationManager()
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    // macOS exposes its granted state as authorizedAlways.
    var authorized: Bool { status == .authorizedAlways }

    func request() {
        guard !requesting else { return }
        status = manager.authorizationStatus
        guard status == .notDetermined else {
            openSettings()
            return
        }
        requesting = true
        // A menu-bar app can have a visible panel without being active.
        // Core Location ignores when-in-use requests from inactive apps.
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.manager.requestWhenInUseAuthorization()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.requesting else { return }
                self.status = self.manager.authorizationStatus
                self.requesting = false
                self.showSettingsHelp = !self.authorized
                self.requestTimeout = nil
            }
            self.requestTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        }
    }

    func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
        guard status != .notDetermined else { return }
        requestTimeout?.cancel()
        requestTimeout = nil
        requesting = false
        if authorized { showSettingsHelp = false }
    }
}
