import Foundation

/// Compiled into both app and widget. Runtime environment variables cannot
/// turn a development binary into a production binary.
#if CLAUDEBAR_DEV && CLAUDEBAR_RELEASE
#error("Choose exactly one ClaudeBar build channel")
#endif

enum BuildChannel {
#if CLAUDEBAR_DEV
    static let name = "dev"
    static let appName = "ClaudeBar Dev"
    static let bundleID = "com.claudebar.app.dev"
    static let urlScheme = "claudebar-dev"
    static let proxyPort = 15722
    static let vpnMixedPort = 17890
    static let vpnControllerPort = 19097
    static let allowsSystemIntegration = false
#else
    static let name = "release"
    static let appName = "ClaudeBar"
    static let bundleID = "com.claudebar.app"
    static let urlScheme = "claudebar"
    static let proxyPort = 15721
    static let vpnMixedPort = 7890
    static let vpnControllerPort = 9097
    static let allowsSystemIntegration = true
#endif
    static let widgetBundleID = bundleID + ".widget"
    static let appGroupID = widgetBundleID
    static let restrictionMessage = "开发／测试版本不接管系统 VPN、代理、DNS、硬件控制或外部客户端配置。请使用正式版本验证这些功能。"
}
