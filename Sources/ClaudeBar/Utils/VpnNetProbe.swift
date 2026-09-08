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

    func refreshIP() async {
        ipLoading = true
        ipError = nil
        let port = VpnManager.shared.mixedPortIfRunning
        if let info = await Self.fetchIP(proxyPort: port) {
            ipInfo = info
        } else {
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
        req.setValue(VpnHTTP.clashVergeUA, forHTTPHeaderField: "User-Agent")
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

    private static let ipEndpoints = [
        "https://api.ip.sb/geoip",
        "https://ipwho.is/",
        "https://get.geojs.io/v1/ip/geo.json",
    ]

    static func fetchIP(proxyPort: Int?) async -> VpnIPInfo? {
        let session = VpnHTTP.session(proxyPort: proxyPort)
        for url in ipEndpoints {
            guard let u = URL(string: url) else { continue }
            var req = URLRequest(url: u)
            req.timeoutInterval = 8
            req.setValue(VpnHTTP.clashVergeUA, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: req),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let info = parseIP(obj), !info.ip.isEmpty { return info }
        }
        return nil
    }

    private static func parseIP(_ obj: [String: Any]) -> VpnIPInfo? {
        let loc = obj["location"] as? [String: Any]
        let conn = obj["connection"] as? [String: Any]
        let asnRaw = obj["asn"]
        let asn: Int
        if let n = asnRaw as? Int { asn = n }
        else if let s = asnRaw as? String { asn = Int(s.replacingOccurrences(of: "AS", with: "")) ?? 0 }
        else { asn = JSONCoerce.intVal(conn?["asn"]) }
        let ip = (obj["ip"] as? String) ?? ""
        guard !ip.isEmpty else { return nil }
        return VpnIPInfo(
            ip: ip,
            country: (obj["country"] as? String) ?? (obj["country_name"] as? String)
                ?? (loc?["country"] as? String) ?? "",
            countryCode: {
                let raw = (obj["country_code"] as? String)
                    ?? (loc?["country_code"] as? String)
                    ?? (obj["countryCode"] as? String)
                    ?? ""
                return raw.count == 2 ? raw : ""
            }(),
            region: (obj["region"] as? String) ?? (loc?["state"] as? String) ?? "",
            city: (obj["city"] as? String) ?? (loc?["city"] as? String) ?? "",
            isp: (obj["organization"] as? String) ?? (obj["isp"] as? String)
                ?? (conn?["org"] as? String) ?? (conn?["isp"] as? String)
                ?? (obj["organization_name"] as? String) ?? "",
            asn: asn)
    }
}
