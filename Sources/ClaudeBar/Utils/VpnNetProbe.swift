import Foundation

/// Outbound IP + geo, matching clash-verge-rev's home IP card
/// (`src/services/api.ts` IP_CHECK_SERVICES).
struct VpnIPInfo: Equatable {
    var ip: String = ""
    var country: String = ""
    var countryCode: String = ""
    var region: String = ""
    var city: String = ""
    var isp: String = ""
    var asn: Int = 0
}

/// One site on the connectivity strip (Apple / GitHub / Google / YouTube).
struct VpnSiteProbe: Identifiable, Equatable {
    let id: String
    let name: String
    let url: String
    /// nil = not tested; -1 = running; -2 = failed; else milliseconds.
    var delay: Int? = nil
}

/// clash-verge home modules: delay tests through mixed-port, and IP lookup.
@MainActor
final class VpnNetProbe: ObservableObject {
    static let shared = VpnNetProbe()

    @Published var sites: [VpnSiteProbe] = VpnNetProbe.defaultSites
    @Published var ipInfo: VpnIPInfo?
    @Published var ipError: String?
    @Published var ipLoading = false
    @Published var testingAll = false

    static let defaultSites: [VpnSiteProbe] = [
        VpnSiteProbe(id: "apple", name: "Apple", url: "https://www.apple.com"),
        VpnSiteProbe(id: "github", name: "GitHub", url: "https://www.github.com"),
        VpnSiteProbe(id: "google", name: "Google", url: "https://www.google.com"),
        VpnSiteProbe(id: "youtube", name: "YouTube", url: "https://www.youtube.com"),
        VpnSiteProbe(id: "chatgpt", name: "ChatGPT", url: "https://chatgpt.com"),
        VpnSiteProbe(id: "claude", name: "Claude", url: "https://claude.ai"),
        VpnSiteProbe(id: "gemini", name: "Gemini", url: "https://gemini.google.com"),
    ]

    private init() {}

    func reset() {
        sites = Self.defaultSites
        ipInfo = nil
        ipError = nil
        ipLoading = false
    }

    func testAll() async {
        testingAll = true
        await withTaskGroup(of: Void.self) { group in
            for site in sites {
                group.addTask { await self.test(id: site.id) }
            }
        }
        testingAll = false
    }

    func test(id: String) async {
        guard let idx = sites.firstIndex(where: { $0.id == id }) else { return }
        sites[idx].delay = -1
        let url = sites[idx].url
        let ms = await Self.measure(url: url, proxyPort: VpnManager.shared.mixedPortIfRunning)
        if let i = sites.firstIndex(where: { $0.id == id }) {
            sites[i].delay = ms
        }
    }

    /// Look up the egress IP through mixed-port.
    ///
    /// `afterNodeSwitch` waits for the tunnel to actually move before the
    /// first attempt — otherwise ipify/ip-api race the old exit or fail
    /// while CONNECT is resetting.
    func refreshIP(afterNodeSwitch: Bool = false) async {
        ipLoading = true
        ipError = nil
        if afterNodeSwitch {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let port = VpnManager.shared.mixedPortIfRunning
        let attempts = afterNodeSwitch ? 2 : 1
        for attempt in 0..<attempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(400_000_000) * UInt64(attempt))
            }
            if let info = await Self.fetchIP(proxyPort: port) {
                ipInfo = info
                ipError = nil
                ipLoading = false
                return
            }
        }
        if ipInfo == nil {
            ipError = port == nil ? "内核未运行" : "无法取得出口 IP"
        }
        ipLoading = false
    }

    /// clash-verge `test_delay`: HTTP(S) through mixed-port when the core is up.
    static func measure(url: String, proxyPort: Int?) async -> Int {
        guard let target = URL(string: url) else { return -2 }
        var req = URLRequest(url: target)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 10
        req.setValue(ipUA, forHTTPHeaderField: "User-Agent")
        let session = VpnHTTP.session(proxyPort: proxyPort)
        let start = Date()
        do {
            let (_, response) = try await session.data(for: req)
            let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
            if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                return min(ms, 9_999)
            }
            // Some CDNs reject HEAD — retry GET.
            req.httpMethod = "GET"
            let start2 = Date()
            _ = try await session.data(for: req)
            return max(1, Int(Date().timeIntervalSince(start2) * 1000))
        } catch {
            return -2
        }
    }

    /// Clash Verge `IP_CHECK_SERVICES`, then two plain echo servers.
    /// Tried one at a time. Firing all of them together through the current
    /// node filled its connection slots and every request timed out.
    private static let ipEndpoints: [IPEndpoint] = [
        IPEndpoint(url: "https://api.ip.sb/geoip", json: true),
        IPEndpoint(url: "https://ipapi.co/json", json: true),
        IPEndpoint(url: "https://ipwho.is/", json: true),
        IPEndpoint(url: "https://get.geojs.io/v1/ip/geo.json", json: true),
        IPEndpoint(url: "http://ip-api.com/json/?fields=status,query,country,countryCode,regionName,city,isp,as", json: true),
        IPEndpoint(url: "https://api.ipify.org?format=json", json: true),
        IPEndpoint(url: "https://icanhazip.com", json: false),
    ]

    private struct IPEndpoint {
        let url: String
        let json: Bool
    }

    /// Browser-like UA: IP echo services rate-limit or 403 `clash-verge/*`.
    private static let ipUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func fetchIP(proxyPort: Int?) async -> VpnIPInfo? {
        for endpoint in ipEndpoints.prefix(4) {
            if let info = await fetchOne(endpoint, proxyPort: proxyPort), !info.ip.isEmpty {
                return info
            }
        }
        return nil
    }

    private static func fetchOne(_ endpoint: IPEndpoint, proxyPort: Int?) async -> VpnIPInfo? {
        guard let u = URL(string: endpoint.url) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = 6
        req.setValue(ipUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        let session = VpnHTTP.session(proxyPort: proxyPort)
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty
        else { return nil }
        if endpoint.json,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parseIP(obj)
        }
        return parsePlainIP(data)
    }

    private static func parsePlainIP(_ data: Data) -> VpnIPInfo? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let ip = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isIPAddress(ip) else { return nil }
        return VpnIPInfo(ip: ip)
    }

    private static func isIPAddress(_ s: String) -> Bool {
        if s.contains(":") {
            return s.count >= 3 && s.count <= 45 && !s.contains(" ")
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let n = Int(part), (0...255).contains(n) else { return false }
            return true
        }
    }

    private static func parseIP(_ obj: [String: Any]) -> VpnIPInfo? {
        if let status = obj["status"] as? String, status.lowercased() == "fail" { return nil }
        if let success = obj["success"] as? Bool, success == false { return nil }
        let loc = obj["location"] as? [String: Any]
        let conn = obj["connection"] as? [String: Any]
        let asnRaw = obj["asn"] ?? obj["as"]
        let asn: Int
        if let n = asnRaw as? Int { asn = n }
        else if let s = asnRaw as? String {
            let digits = s.replacingOccurrences(of: "AS", with: "").split(separator: " ").first.map(String.init) ?? s
            asn = Int(digits) ?? 0
        } else { asn = JSONCoerce.intVal(conn?["asn"]) }
        let ip = (obj["ip"] as? String)
            ?? (obj["query"] as? String)
            ?? (obj["ipAddress"] as? String)
            ?? (obj["ip_address"] as? String)
            ?? ""
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isIPAddress(trimmed) else { return nil }
        return VpnIPInfo(
            ip: trimmed,
            country: (obj["country"] as? String) ?? (obj["country_name"] as? String)
                ?? (loc?["country"] as? String) ?? "",
            countryCode: {
                let raw = (obj["country_code"] as? String)
                    ?? (loc?["country_code"] as? String)
                    ?? (obj["countryCode"] as? String)
                    ?? ""
                return raw.count == 2 ? raw : ""
            }(),
            region: (obj["region"] as? String) ?? (obj["regionName"] as? String)
                ?? (loc?["state"] as? String) ?? "",
            city: (obj["city"] as? String) ?? (loc?["city"] as? String) ?? "",
            isp: (obj["organization"] as? String) ?? (obj["isp"] as? String)
                ?? (obj["org"] as? String)
                ?? (conn?["org"] as? String) ?? (conn?["isp"] as? String)
                ?? (obj["organization_name"] as? String) ?? "",
            asn: asn)
    }
}
