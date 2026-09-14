import Foundation

/// URLSession helpers that never inherit the macOS system proxy.
/// clash-verge's NetworkManager uses ProxyType::None for the controller;
/// if we don't, `/version` `/traffic` `/proxies` loop through mixed-port
/// and the UI looks like the proxy is dead.
enum VpnHTTP {
    /// Airports inspect UA and only attach `subscription-userinfo` for Clash Verge.
    static let clashVergeUA = "clash-verge/v2.4.3"

    /// Cached per (proxyPort, direct?) shape. Every `/connections` poll used to
    /// build a fresh `URLSession` and most call sites never invalidated it, so
    /// the process accumulated one connection pool per poll — the 2s status
    /// loop alone leaked a session every tick. The config is a pure function
    /// of the proxy port, so one session per shape is all we ever need.
    private static let cacheLock = NSLock()
    private static var cache: [Int: URLSession] = [:]
    /// Sentinel key for the direct (proxy-less) session.
    private static let directKey = -1

    static func session(proxyPort: Int? = nil) -> URLSession {
        let key = proxyPort ?? directKey
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = cache[key] { return existing }
        let created = makeSession(proxyPort: proxyPort)
        cache[key] = created
        return created
    }

    private static func makeSession(proxyPort: Int?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": clashVergeUA]
        config.timeoutIntervalForRequest = 30
        if let port = proxyPort {
            config.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": "127.0.0.1",
                "HTTPPort": port,
                "HTTPSEnable": 1,
                "HTTPSProxy": "127.0.0.1",
                "HTTPSPort": port,
                "SOCKSEnable": 0,
            ]
        } else {
            config.connectionProxyDictionary = [
                "HTTPEnable": 0,
                "HTTPSEnable": 0,
                "SOCKSEnable": 0,
            ]
        }
        return URLSession(configuration: config)
    }
}
