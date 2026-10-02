// Fixture-side stand-ins for the app-side pieces the control sheet does not
// exercise (preferences, surface visibility). Written by hand — unlike the
// `Interaction.swift` slices, these are not production code.
//
// Only members the sheet's compiled slice actually names belong here: an
// unused shim is a second, silently-diverging definition of a production API.

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
