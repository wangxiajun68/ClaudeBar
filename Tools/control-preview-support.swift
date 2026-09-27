// Fixture-side stand-ins for the app-side pieces the control sheet does not
// exercise (preferences, surface visibility, the decorative layer). Written by
// hand — unlike the `Interaction.swift` slices, these are not production code.

enum AppPreferences: Sendable {
    static let shared = Preferences()
    final class Preferences: @unchecked Sendable {
        var isDark = false
    }
}

private struct SurfaceVisibleKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var surfaceIsVisible: Bool {
        get { self[SurfaceVisibleKey.self] }
        set { self[SurfaceVisibleKey.self] = newValue }
    }
}
extension View {
    func resourceMonitorScope(_ scope: MonitorScope) -> some View { self }
}
enum MonitorScope { case dashboard, popup, idle }
