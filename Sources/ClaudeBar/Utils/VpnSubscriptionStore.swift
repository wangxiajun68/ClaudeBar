import Foundation
import AppKit

// MARK: - Model

/// A subscription downloaded from a URL, persisted as YAML under vpn/profiles.
struct VpnSubscription: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var url: String
    /// Traffic info from the `subscription-userinfo` header.
    var upload: Int64 = 0
    var download: Int64 = 0
    var total: Int64 = 0
    var expires: Date? = nil
    var lastUpdated: Date? = nil
    var nodeCount: Int = 0
    /// Airport web console, from `profile-web-page-url`.
    var homeURL: String? = nil

    var usedBytes: Int64 { upload + download }
    var remainingBytes: Int64 { max(0, total - usedBytes) }
    var usedRatio: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(total))
    }
}

/// File format for `vpn/subscriptions.json`.
private struct VpnSubscriptionsFile: Codable {
    var subscriptions: [VpnSubscription] = []
    var activeID: UUID? = nil
}

// MARK: - Store

/// Manages VPN subscriptions: download (with optional routing through the
/// running mihomo port, mirroring clash-verge's `self_proxy`), YAML parsing
/// (node count + `subscription-userinfo` header), periodic refresh, and the
/// mihomo config assembly that inlines the active subscription's proxies.
@MainActor
final class VpnSubscriptionStore: ObservableObject {
    static let shared = VpnSubscriptionStore()

    @Published var subscriptions: [VpnSubscription] = []
    @Published var activeID: UUID? = nil
    @Published var errorMessage: String? = nil
    @Published var isUpdating = false

    private var refreshTimer: Timer?
    /// Set by VpnManager at startup; when non-nil, profile downloads go
    /// through 127.0.0.1:<port> (some airport domains are blocked directly).
    weak var manager: VpnManager?

    var activeSubscription: VpnSubscription? {
        subscriptions.first { $0.id == activeID }
    }

    private init() {
        load()
    }

    // MARK: Persistence

    func load() {
        guard let data = try? Data(contentsOf: FilePaths.vpnSubscriptionsFile),
              let file = try? JSONDecoder().decode(VpnSubscriptionsFile.self, from: data) else { return }
        subscriptions = file.subscriptions
        activeID = file.activeID
    }

    func save() {
        let file = VpnSubscriptionsFile(subscriptions: subscriptions, activeID: activeID)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: FilePaths.vpnSubscriptionsFile, options: .atomic)
    }

    private func profileURL(_ id: UUID) -> URL {
        FilePaths.vpnProfilesDir.appendingPathComponent(id.uuidString + ".yaml")
    }

    func profileText(_ id: UUID) -> String? {
        try? String(contentsOf: profileURL(id), encoding: .utf8)
    }

    // MARK: Add / Remove

    /// Download `url`, validate it looks like a clash profile, persist.
    func addSubscription(name: String, url: String) async {
        await updateError(nil)
        do {
            let (text, headers) = try await downloadProfile(url: url)
            guard Self.validateProfile(text) else {
                await updateError("订阅内容不是有效的 Clash 配置（缺少 proxies / proxy-providers）。")
                return
            }
            let sub = VpnSubscription(name: name.isEmpty ? Self.defaultName(from: url) : name, url: url)
            try? FileManager.default.createDirectory(at: FilePaths.vpnProfilesDir, withIntermediateDirectories: true)
            try? text.write(to: profileURL(sub.id), atomically: true, encoding: .utf8)
            var stored = sub
            stored.lastUpdated = Date()
            Self.applyUserInfo(headers: headers, body: text, to: &stored)
            if stored.name == Self.defaultName(from: url),
               let filename = Self.filename(from: headers), !filename.isEmpty {
                stored.name = filename
            }
            subscriptions.append(stored)
            if activeID == nil { activeID = stored.id }
            save()
        } catch {
            await updateError("下载订阅失败：\(error.localizedDescription)")
        }
    }

    func removeSubscription(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: profileURL(id))
        if activeID == id { activeID = subscriptions.first?.id }
        save()
    }

    func setActive(_ id: UUID?) {
        activeID = id
        save()
    }

    /// Re-download and refresh metadata; returns true on success.
    @discardableResult
    func refresh(_ id: UUID) async -> Bool {
        guard let sub = subscriptions.first(where: { $0.id == id }) else { return false }
        await updateError(nil)
        do {
            let (text, headers) = try await downloadProfile(url: sub.url)
            guard Self.validateProfile(text) else {
                await updateError("订阅返回内容无效。")
                return false
            }
            try? text.write(to: profileURL(id), atomically: true, encoding: .utf8)
            if let idx = subscriptions.firstIndex(where: { $0.id == id }) {
                Self.applyUserInfo(headers: headers, body: text, to: &subscriptions[idx])
                subscriptions[idx].lastUpdated = Date()
            }
            save()
            return true
        } catch {
            await updateError("更新订阅失败：\(error.localizedDescription)")
            return false
        }
    }

    func rename(_ id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[idx].name = trimmed
        save()
    }

    /// Change the remote URL and re-download the profile.
    func replaceURL(_ id: UUID, url: String) async -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return false }
        subscriptions[idx].url = trimmed
        save()
        return await refresh(id)
    }

    /// Fetch `subscription-userinfo` without swapping the on-disk profile
    /// (clash-verge "refresh extra"). Used for remaining traffic / expiry.
    @discardableResult
    func queryInfo(_ id: UUID) async -> Bool {
        guard let sub = subscriptions.first(where: { $0.id == id }) else { return false }
        await updateError(nil)
        do {
            let (headers, body) = try await downloadHeaders(url: sub.url)
            if let idx = subscriptions.firstIndex(where: { $0.id == id }) {
                Self.applyUserInfo(headers: headers, body: body ?? "", to: &subscriptions[idx])
                subscriptions[idx].lastUpdated = Date()
                if subscriptions[idx].total == 0 && subscriptions[idx].expires == nil {
                    await updateError("未返回流量/有效期。确认链接可用，且机场对 clash-verge UA 下发 subscription-userinfo。")
                    save()
                    return false
                }
            }
            save()
            return true
        } catch {
            await updateError("查询失败：\(error.localizedDescription)")
            return false
        }
    }

    func queryAll() async {
        for sub in subscriptions {
            _ = await queryInfo(sub.id)
        }
    }

    func copyURL(_ id: UUID) {
        guard let url = subscriptions.first(where: { $0.id == id })?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    /// Periodic refresh (30 min), mirroring clash-verge's timer.
    func startAutoRefresh() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let id = self.activeID, !self.isUpdating else { return }
                if await self.refresh(id) { self.manager?.reloadConfig() }
            }
        }
    }

    // MARK: Download

    private func downloadProfile(url: String) async throws -> (body: String, headers: [AnyHashable: Any]) {
        guard let comps = URLComponents(string: url), let target = comps.url else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: target)
        request.timeoutInterval = 30
        request.setValue(VpnHTTP.clashVergeUA, forHTTPHeaderField: "User-Agent")
        // Airports only emit extra headers when the client looks like Clash Verge.
        request.setValue("text/plain, text/yaml, application/octet-stream, */*", forHTTPHeaderField: "Accept")

        let session = VpnHTTP.session(proxyPort: manager?.mixedPortIfRunning)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let body = try Self.text(from: data, response: http)
        return (body, http.allHeaderFields)
    }

    /// HEAD first (cheap userinfo); fall back to GET. Body is nil on HEAD.
    private func downloadHeaders(url: String) async throws -> (headers: [AnyHashable: Any], body: String?) {
        guard let comps = URLComponents(string: url), let target = comps.url else {
            throw URLError(.badURL)
        }
        let session = VpnHTTP.session(proxyPort: manager?.mixedPortIfRunning)
        func request(_ method: String) -> URLRequest {
            var r = URLRequest(url: target)
            r.httpMethod = method
            r.timeoutInterval = 20
            r.setValue(VpnHTTP.clashVergeUA, forHTTPHeaderField: "User-Agent")
            r.setValue("text/plain, text/yaml, application/octet-stream, */*", forHTTPHeaderField: "Accept")
            return r
        }
        if let (headData, headResp) = try? await session.data(for: request("HEAD")),
           let http = headResp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           Self.userInfoRaw(from: http.allHeaderFields) != nil {
            _ = headData
            return (http.allHeaderFields, nil)
        }
        let (data, response) = try await session.data(for: request("GET"))
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let body = try? Self.text(from: data, response: http)
        return (http.allHeaderFields, body)
    }

    private static func text(from data: Data, response: HTTPURLResponse) throws -> String {
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        // Airports may serve base64-encoded node lists instead of YAML.
        let raw = String(decoding: data, as: UTF8.self)
        if raw.contains("proxies:") || raw.contains("proxy-providers:") { return raw }
        if let decoded = VpnBase64.decode(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           decoded.contains("proxies:") {
            return
                """
                # Converted from base64 node list by ClaudeBar
                proxies:
                \(VpnNodeListConverter.toYAMLProxies(decoded) ?? "")
                """
        }
        return raw
    }

    // MARK: Parsing

    /// A valid profile declares proxies or providers.
    static func validateProfile(_ text: String) -> Bool {
        text.contains("proxies:") || text.contains("proxy-providers:")
    }

    /// clash-verge reads `subscription-userinfo` from HTTP headers (also
    /// `x-*-subscription-userinfo`). YAML comments are a fallback only.
    static func applyUserInfo(headers: [AnyHashable: Any], body: String, to sub: inout VpnSubscription) {
        if !body.isEmpty { sub.nodeCount = countProxies(in: body) }
        var raw = userInfoRaw(from: headers)
        if raw == nil, !body.isEmpty {
            raw = body.split(separator: "\n")
                .first(where: { $0.lowercased().contains("subscription-userinfo") })
                .map(String.init)
        }
        if let home = headerValue(headers, suffix: "profile-web-page-url") {
            sub.homeURL = home
        }
        guard let info = raw else { return }
        parseUserInfo(info, into: &sub)
    }

    static func userInfoRaw(from headers: [AnyHashable: Any]) -> String? {
        headerValue(headers, suffix: "subscription-userinfo") { prefix in
            prefix.isEmpty || prefix.hasSuffix("-")
        }
    }

    static func filename(from headers: [AnyHashable: Any]) -> String? {
        guard let disp = headerValue(headers, suffix: "content-disposition") else { return nil }
        let decoded = disp.removingPercentEncoding ?? disp
        for key in ["filename*", "filename"] {
            if let v = parseHeaderParam(decoded, key: key) {
                let name = v.replacingOccurrences(of: "\"", with: "")
                    .split(separator: "'").last.map(String.init) ?? v
                let stem = (name as NSString).deletingPathExtension
                return stem.isEmpty ? name : stem
            }
        }
        return nil
    }

    private static func headerValue(
        _ headers: [AnyHashable: Any],
        suffix: String,
        prefixOK: ((String) -> Bool)? = nil
    ) -> String? {
        for (key, value) in headers {
            let name = "\(key)".lowercased()
            guard name.hasSuffix(suffix) else { continue }
            let prefix = String(name.dropLast(suffix.count))
            if let prefixOK, !prefixOK(prefix) { continue }
            if let s = value as? String { return s }
            if let arr = value as? [String] { return arr.first }
            return "\(value)"
        }
        return nil
    }

    private static func parseHeaderParam(_ raw: String, key: String) -> String? {
        let needle = key.lowercased() + "="
        guard let range = raw.lowercased().range(of: needle) else { return nil }
        var rest = String(raw[range.upperBound...])
        if rest.hasPrefix("\"") {
            rest.removeFirst()
            if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
        }
        return rest.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    static func parseUserInfo(_ raw: String, into sub: inout VpnSubscription) {
        let decoded = raw.removingPercentEncoding ?? raw
        for pair in decoded.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "upload": sub.upload = Int64(parts[1]) ?? sub.upload
            case "download": sub.download = Int64(parts[1]) ?? sub.download
            case "total": sub.total = Int64(parts[1]) ?? sub.total
            case "expire":
                if var t = TimeInterval(parts[1]), t > 0 {
                    if t > 10_000_000_000 { t /= 1000 } // milliseconds
                    sub.expires = Date(timeIntervalSince1970: t)
                }
            default: break
            }
        }
    }

    /// Count proxy entries under the top-level `proxies:` key. Handles both
    /// inline (`- {name: …}` / `- name: …`) and split style:
    ///   proxies:
    ///     -
    ///       name: HK-1
    /// (each bare `-` line starts one entry).
    static func countProxies(in yaml: String) -> Int {
        var counting = false
        var indent = 0
        var n = 0
        for line in yaml.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !counting {
                if line.hasPrefix("proxies:") { counting = true; indent = 0 }
                continue
            }
            if trimmed.isEmpty { continue }
            let isListItem = trimmed.hasPrefix("-")
            let lineIndent = line.count - line.drop { $0 == " " }.count
            if !isListItem && lineIndent <= indent {
                break // next top-level key — proxies section ended
            }
            if isListItem {
                if lineIndent == 0 { break } // safety: a top-level list isn't proxies
                if n == 0 { indent = lineIndent }
                // A new entry: inline item, or a bare "-" (fields on following lines)
                if trimmed.hasPrefix("- ") || trimmed == "-" || trimmed.hasPrefix("-{") {
                    n += 1
                }
            }
        }
        return n
    }

    private static func defaultName(from url: String) -> String {
        URL(string: url)?.host ?? "订阅"
    }

    private func updateError(_ msg: String?) async {
        await MainActor.run { errorMessage = msg }
    }
}

// MARK: - Config assembly

/// Builds the runtime config.yaml handed to `mihomo -f`. Mirrors the
/// clash-verge `enhance` pipeline's essentials: the active profile's YAML is
/// sanitized (external-controller/ports forced to ours) and merged with the
/// settings-derived base keys.
enum VpnConfigBuilder {
    static func build(profileText: String?, prefs: AppPreferences) -> String {
        var yaml = ""

        if let text = profileText {
            yaml = sanitizeProfile(text, prefs: prefs)
        } else {
            yaml =
                """
                proxies: []
                rules:
                  - MATCH,DIRECT
                """
        }

        // Force the controller + ports to ClaudeBar's values regardless of
        // what the subscription declares. Our header keys replace any
        // top-level duplicates from the profile — mihomo fatals on duplicate
        // YAML mapping keys, so they must be stripped, not just overridden.
        var lines: [String] = []
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            // Match unindented keys only — indented `port:` inside proxy
            // entries is node data and must survive.
            let skip = line.hasPrefix("external-controller")
                || line.hasPrefix("mixed-port:")
                || line.hasPrefix("port:")
                || line.hasPrefix("socks-port:")
                || line.hasPrefix("secret:")
                || line.hasPrefix("allow-lan:")
                || line.hasPrefix("bind-address:")
                || line.hasPrefix("mode:")
                || line.hasPrefix("log-level:")
                || line.hasPrefix("ipv6:")
                || line.hasPrefix("external-ui")
                || line.hasPrefix("unified-delay:")
                || line.hasPrefix("tcp-concurrent:")
                || line.hasPrefix("find-process-mode:")
                || line.hasPrefix("keep-alive-interval:")
                || line.hasPrefix("keep-alive-idle:")
                || line.hasPrefix("authentication:")
                || line.hasPrefix("skip-auth-prefixes:")
            if !skip { lines.append(String(line)) }
        }
        yaml = lines.joined(separator: "\n")

        let bind = prefs.vpnAllowLan ? "*" : "127.0.0.1"
        let header =
            """
            # Generated by ClaudeBar — do not edit; re-generated on every start.
            mixed-port: \(prefs.vpnMixedPort)
            allow-lan: \(prefs.vpnAllowLan)
            bind-address: '\(bind)'
            mode: rule
            log-level: info
            ipv6: false
            unified-delay: false
            tcp-concurrent: true
            find-process-mode: off
            keep-alive-interval: 15
            keep-alive-idle: 600
            external-controller: 127.0.0.1:9097
            secret: "\(prefs.vpnControllerSecret)"
            external-controller-cors:
              allow-private-network: false
              allow-origins: []
            """
        var footer = ""
        if prefs.vpnTunEnabled {
            // Profile dns is kept; appending a second `dns:` fatals mihomo.
            footer +=
                """

                tun:
                  enable: true
                  stack: mixed
                  auto-route: true
                  auto-detect-interface: true
                  dns-hijack:
                    - any:53
                """
        }
        var out = header + "\n" + Self.tuneForStability(yaml) + footer
        if !prefs.vpnTunEnabled {
            // Airports often set dns.listen: :53 which needs root and breaks
            // the resolver when the bind fails.
            for needle in ["listen: ':53'", "listen: \":53\"", "listen: :53", "listen: 0.0.0.0:53"] {
                out = out.replacingOccurrences(of: needle, with: "listen: 127.0.0.1:53553")
            }
        }
        return out
    }

    /// Strip keys the core must not inherit from a subscription (controller
    /// bindings, listeners, tun, duplicates of our header keys) so our header
    /// always wins and no YAML mapping key is defined twice.
    private static func sanitizeProfile(_ text: String, prefs: AppPreferences) -> String {
        var out: [String] = []
        var skippingBlock = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            let top = !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t")
            if top && !t.isEmpty {
                skippingBlock = t.hasPrefix("tun:") || t.hasPrefix("listeners:")
                    || t.hasPrefix("external-controller-cors:")
                    || t.hasPrefix("skip-auth-prefixes:")
                    || t.hasPrefix("authentication:")
            }
            if top && (t.hasPrefix("external-controller") || t.hasPrefix("secret:")
                        || t.hasPrefix("mode:") || t.hasPrefix("log-level:") || t.hasPrefix("ipv6:")
                        || t.hasPrefix("mixed-port:") || t.hasPrefix("allow-lan:")
                        || t.hasPrefix("bind-address:") || t.hasPrefix("unified-delay:")
                        || t.hasPrefix("tcp-concurrent:") || t.hasPrefix("find-process-mode:")
                        || t.hasPrefix("keep-alive-interval:") || t.hasPrefix("keep-alive-idle:")
                        || t.hasPrefix("authentication:")
                        || t.hasPrefix("skip-auth-prefixes:") || t.hasPrefix("external-controller-cors:")) {
                continue
            }
            if !skippingBlock { out.append(String(line)) }
        }
        return out.joined(separator: "\n")
    }

    /// Airport profiles often enable IPv6, 180s full-mesh url-test, and
    /// Google bootstrap DNS. Rewrite those without touching node entries.
    private static func tuneForStability(_ yaml: String) -> String {
        var s = yaml
        for from in [
            "url: 'http://www.gstatic.com/generate_204'",
            "url: \"http://www.gstatic.com/generate_204\"",
            "url: http://www.gstatic.com/generate_204",
            "url: 'https://www.gstatic.com/generate_204'",
            "url: \"https://www.gstatic.com/generate_204\"",
        ] {
            s = s.replacingOccurrences(of: from, with: "url: 'http://cp.cloudflare.com/generate_204'")
        }
        s = s.replacingOccurrences(of: "\n    interval: 180\n", with: "\n    interval: 600\n")
        s = s.replacingOccurrences(of: "\n    interval: 300\n", with: "\n    interval: 900\n")
        s = s.replacingOccurrences(of: "\n  ipv6: true\n", with: "\n  ipv6: false\n")
        s = s.replacingOccurrences(of: "    - '2400:3200::1'\n", with: "")
        s = s.replacingOccurrences(of: "    - \"2400:3200::1\"\n", with: "")
        s = s.replacingOccurrences(of: "    - '2001:4860:4860::8888'\n", with: "")
        s = s.replacingOccurrences(of: "    - \"2001:4860:4860::8888\"\n", with: "")
        s = s.replacingOccurrences(of: "    - 8.8.8.8\n", with: "    - 223.5.5.5\n")
        return s
    }
}

// MARK: - Helpers

/// Tolerant base64 (padding-less variants used by airports).
enum VpnBase64 {
    static func decode(_ s: String) -> String? {
        var t = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        while t.count % 4 != 0 { t += "=" }
        guard let data = Data(base64Encoded: t) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Converts `ss://` / `vmess://` lines (base64 node list) into clash proxy
/// YAML entries. Covers the two schemes airports actually hand out bare;
/// anything else is dropped with a comment.
enum VpnNodeListConverter {
    static func toYAMLProxies(_ body: String) -> String? {
        let lines = body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var out: [String] = []
        for line in lines {
            if let yaml = convert(line) { out.append(yaml) }
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    private static func convert(_ line: String) -> String? {
        if line.hasPrefix("ss://") { return convertSS(String(line.dropFirst(5))) }
        if line.hasPrefix("vmess://") { return convertVmess(String(line.dropFirst(8))) }
        return nil
    }

    /// `ss://base64(method:pass)@host:port#name` (SIP002).
    private static func convertSS(_ rest: String) -> String? {
        guard let hashIdx = rest.firstIndex(of: "#") else { return nil }
        let name = String(rest[rest.index(after: hashIdx)...]).removingPercentEncoding ?? "ss"
        var body = String(rest[..<hashIdx])
        if let at = body.lastIndex(of: "@") {
            let userInfo = String(body[..<at])
            let hostPart = String(body[body.index(after: at)...])
            let decoded = VpnBase64.decode(userInfo) ?? userInfo
            let parts = decoded.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let (host, port) = splitHostPort(hostPart)
            return ssYAML(name: name, method: parts[0], password: parts[1], server: host, port: port)
        } else {
            guard let decoded = VpnBase64.decode(body) else { return nil }
            body = decoded
            guard let colon = body.firstIndex(of: ":"), let at = body.lastIndex(of: "@") else { return nil }
            let method = String(body[..<colon])
            let password = String(body[body.index(after: colon)..<at])
            let (host, port) = splitHostPort(String(body[body.index(after: at)...]))
            return ssYAML(name: name, method: method, password: password, server: host, port: port)
        }
    }

    private static func ssYAML(name: String, method: String, password: String, server: String, port: String) -> String {
        """
          - name: "\(escaped(name))"
            type: ss
            server: \(server)
            port: \(port)
            cipher: \(method)
            password: "\(escaped(password))"
        """
    }

    /// `vmess://base64({v,ps,add,port,id,aid,net,type,tls,...})`
    private static func convertVmess(_ b64: String) -> String? {
        guard let json = VpnBase64.decode(b64),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let ps = obj["ps"] as? String ?? "vmess"
        let add = obj["add"] as? String ?? ""
        let port = "\(obj["port"] ?? 443)"
        let id = obj["id"] as? String ?? ""
        let aid = "\(obj["aid"] ?? 0)"
        let net = obj["net"] as? String ?? "tcp"
        let tls = (obj["tls"] as? String) == "tls"
        let sni = obj["sni"] as? String ?? ""
        var y = """
          - name: "\(escaped(ps))"
            type: vmess
            server: \(add)
            port: \(port)
            uuid: \(id)
            alterId: \(aid)
            cipher: auto
        """
        if net == "ws" {
            y += "\n    network: ws"
            if let path = obj["path"] as? String {
                y += "\n    ws-opts:\n      path: \(path)"
            }
        }
        if tls {
            y += "\n    tls: true"
            if !sni.isEmpty { y += "\n    servername: \(sni)" }
        }
        return y
    }

    private static func splitHostPort(_ s: String) -> (String, String) {
        if s.hasPrefix("["), let idx = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<idx])
            let port = s.contains(":") ? String(s[s.index(after: idx)...].dropFirst()) : "443"
            return (host, port)
        }
        let parts = s.split(separator: ":").map(String.init)
        guard parts.count == 2 else { return (s, "443") }
        return (parts[0], parts[1])
    }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "'")
    }
}
