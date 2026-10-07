import Foundation

/// Compiled into both app and widget. Runtime environment variables cannot
/// turn a development binary into a production binary.
#if CLAUDEBAR_DEV && CLAUDEBAR_RELEASE
#error("Choose exactly one ClaudeBar build channel")
#endif

/// Which build this is. `Sources/build-config.sh` always passes exactly one of
/// `CLAUDEBAR_DEV` / `CLAUDEBAR_RELEASE` to both targets' `swiftc`; **no macro
/// at all falls back to dev** — deliberately, and it is the one asymmetry here
/// worth stating. Every gate below is a restriction that only fails safe in
/// that direction: a build whose author believed it was a development build but
/// which claimed the release identity would start the VPN, rewrite system
/// proxy/DNS, install helpers and write durable TCC grants the user cannot tell
/// came from a throwaway build; the reverse mislabelling only disables
/// features. An unlabelled compile — a stray `swiftc` of this file, a future
/// tool that forgets the flags — must therefore land on dev.
enum BuildChannel {
#if CLAUDEBAR_RELEASE
    static let name = "release"
    static let appName = "ClaudeBar"
    static let bundleID = "com.claudebar.app"
    static let urlScheme = "claudebar"
    static let proxyPort = 15721
    static let vpnMixedPort = 7890
    static let vpnControllerPort = 9097
    static let allowsSystemIntegration = true
#else
    /// `CLAUDEBAR_DEV`, or no macro at all (see above).
    static let name = "dev"
    static let appName = "ClaudeBar Dev"
    static let bundleID = "com.claudebar.app.dev"
    static let urlScheme = "claudebar-dev"
    static let proxyPort = 15722
    static let vpnMixedPort = 17890
    static let vpnControllerPort = 19097
    static let allowsSystemIntegration = false
#endif
    static let widgetBundleID = bundleID + ".widget"
    static var cliExecutable: String { name == "release" ? "claudebar" : "claudebar-dev" }
    static var cliShortExecutable: String { name == "release" ? "mtx" : "mtx-dev" }
    static let appGroupID = widgetBundleID

    /// The snapshot contract between the app and its widget extension.
    ///
    /// Both sides have to agree on these two strings, and they are the one
    /// part of the contract no compiler checks: the app writes the payload
    /// under this key and file name, and the widget's four readers fall back to
    /// a placeholder if either is renamed on one side only. They live here —
    /// the file both targets compile — rather than in the app's `AppConfig`
    /// with a "keep in sync" comment, which is what they used to be.
    static let widgetSnapshotDefaultsKey = "widgetSnapshot"
    static let widgetSnapshotFileName = "claude-bar-widget-data.json"

    static let restrictionMessage = "开发／测试版本不接管系统 VPN、代理、DNS、硬件控制或外部客户端配置。请使用正式版本验证这些功能。"

    /// Whether this build may ask macOS for permissions that prompt.
    ///
    /// Same rule and the same reason as `allowsSystemIntegration`: a grant is
    /// written into the user's TCC database and **outlives the app that asked
    /// for it**. A throwaway dev build has no business leaving Location /
    /// Bluetooth / Screen Recording entries behind — and it is exactly those
    /// entries that make a rebuild re-prompt, because an ad-hoc or changed
    /// identity is a new app to TCC. Keeping prompts out of dev is therefore
    /// both the privacy boundary and what makes rebuilding stop nagging.
    static var promptsForSystemPermissions: Bool { allowsSystemIntegration }
}
