import Foundation

/// Pins the hosts a provider actually talks to in front of the profile's rule
/// chain, so a *custom* provider endpoint cannot be swallowed by the trailing
/// `MATCH` and sent out through a node.
///
/// The failure this exists for, measured on this machine: a *self-hosted*
/// provider endpoint — a hostname on a domestic address, served over plain
/// HTTP on a non-standard port. Nothing in the subscription's geosite knows a
/// name that only that one server has, so it never matched `GEOSITE,CN`; the
/// chain fell through to `MATCH,🐟 漏网之鱼`, and every request left through a
/// node abroad before coming straight back home. 26–41 MB of context per turn
/// made that the single largest consumer of node traffic on the machine, and
/// none of the local signals said so: the kernel's own log line said `Direct`
/// (written before geosite finished loading), and the endpoint's IP *is* in
/// China — it was the route, not the destination, that was wrong.
///
/// Two entry points have to be closed, because they are independent:
///
///  - The **system proxy** (ExceptionsList here is CIDR-only, so a hostname is
///    never bypassed) — `VpnSystemProxyController` appends these hosts to the
///    `networksetup -setproxybypassdomains` list, which *does* take hostnames.
///    Traffic then never reaches the kernel at all.
///  - The **rule chain** — needed when the traffic reaches the kernel anyway:
///    TUN mode ignores the system proxy entirely, and any app with its own
///    proxy setting points straight at the mixed port.
///
/// Both read the provider lists rather than being configured by hand, so a
/// provider added in the UI is covered on the next VPN start without the user
/// knowing this file exists.
enum VpnProviderDirect {
    // MARK: - Reading the configured providers

    /// Every host named by a provider's base URL, across both client stacks.
    ///
    /// Both lists, not just the active rows: switching the active provider
    /// rewrites `settings.json` / `config.toml` but does not restart the
    /// kernel, so pinning only today's active host would leave the next one
    /// exposed until the next VPN start. An unused pin costs one rule.
    static func hosts(claudeFile: URL = FilePaths.presetsFile,
                      codexFile: URL = FilePaths.codexProvidersFile) -> [String] {
        var urls: [String] = []
        if let data = try? Data(contentsOf: claudeFile),
           let file = try? JSONDecoder().decode(ProvidersFile.self, from: data) {
            urls += file.providers.map(\.baseURL)
        }
        if let data = try? Data(contentsOf: codexFile),
           let file = try? JSONDecoder().decode(CodexProvidersFile.self, from: data) {
            urls += file.providers.map(\.baseURL)
        }
        return eligibleHosts(from: urls)
    }

    /// Hosts that must not be forced direct. Pure, so the suite can drive it.
    static func eligibleHosts(from urls: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for url in urls {
            guard let host = eligibleHost(from: url), seen.insert(host).inserted else { continue }
            out.append(host)
        }
        return out.sorted()
    }

    /// Nil for anything whose correct route we cannot claim to know.
    ///
    /// Deliberately a **denylist**: an unrecognised host is pinned direct. That
    /// is the direction that fixes this class of bug — the hosts that break are
    /// the self-hosted and vanity-domain endpoints that no geosite has heard of,
    /// and those look exactly like a hypothetical unknown overseas relay. A user
    /// pointing a custom provider at an overseas endpoint the list below does not
    /// know would get a DIRECT pin and have to add it; the reverse default is
    /// what shipped the bug.
    static func eligibleHost(from baseURL: String) -> String? {
        guard let host = host(of: baseURL) else { return nil }
        // A literal address is already covered by the profile's IP rules, and
        // `setproxybypassdomains` does not want one. LAN/host-internal
        // addresses land here too (192.168.x.x, 10.x, ::1).
        if isIPLiteral(host) { return nil }
        // Names macOS resolves locally, never through DNS the kernel controls.
        if host == "localhost" || host.hasSuffix(".local")
            || host.hasSuffix(".lan") || host.hasSuffix(".internal") { return nil }
        if overseasSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return nil }
        return host
    }

    private static func host(of baseURL: String) -> String? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // Codex provider rows are stored with a scheme, but a hand-typed one
        // may not be — `URLComponents` needs it to populate `host`.
        if !s.contains("://") { s = "https://" + s }
        guard let host = URLComponents(string: s)?.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true } // IPv6 (v4 already stripped the port)
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let n = Int(part), n >= 0, n <= 255 else { return false }
            return String(n) == part || part.count > 1 && part.hasPrefix("0")
        }
    }

    /// Endpoints that are only reachable through a node from a mainland
    /// network. Pinning these direct would break them, which is the one way
    /// this feature can do harm.
    static let overseasSuffixes = [
        "anthropic.com",            // api.anthropic.com — the official Claude API
        "openai.com",               // api.openai.com
        "x.ai",                     // api.x.ai
        "openrouter.ai",            // catalog: 聚合模型
        "googleapis.com",           // generativelanguage.googleapis.com (Gemini)
        "nvidia.com",               // integrate.api.nvidia.com
        "lmstudio.ai",
    ]

    // MARK: - Rule injection

    static func ruleLines(for hosts: [String], indent: String = "  ") -> [String] {
        hosts.map { "\(indent)- \"DOMAIN,\($0),DIRECT\"" }
    }

    /// Insert the pins as the first entries under the profile's `rules:` key.
    ///
    /// `DOMAIN` (exact host), not `DOMAIN-SUFFIX`: the provider row names the
    /// one host it calls, and a suffix rule on a vanity domain would drag every
    /// sibling subdomain to DIRECT with it.
    ///
    /// Prepending is the whole point — a pin placed after `GEOIP,CN` would be
    /// dead text, because the host is already in China and the rule that
    /// swallowed it (`MATCH`) is the last one in the chain, not the first.
    ///
    /// The injected items take the **exact indentation of the profile's own
    /// first rule item**, which is not cosmetic: YAML requires every item of a
    /// block sequence to share one column, and the two populations differ in
    /// the wild — airport profiles write `rules:` followed by column-zero
    /// `- "DOMAIN,…"`, while hand-written ones indent by two. Assuming either
    /// makes the core die at startup with `Parse config error: yaml: line 1:
    /// did not find expected key`, which is what shipped before this was read
    /// off the profile (measured against this machine's 1195-rule subscription).
    ///
    /// `hosts` is injectable so the suite can drive placement without a
    /// provider file on disk; the app build calls it with the default.
    static func inject(into yaml: String, hosts: [String] = VpnProviderDirect.hosts()) -> String {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let keyAt = lines.firstIndex(of: "rules:") else {
            // No rules block means no rule chain to pin in front of; leaving
            // the text untouched beats inventing a `rules:` a profile did not
            // declare.
            return yaml
        }
        guard let indent = firstRuleIndent(after: keyAt, in: lines) else { return yaml }
        let pins = ruleLines(for: hosts, indent: indent)
        guard !pins.isEmpty else { return yaml }
        var out = lines
        out.insert(contentsOf: pins, at: keyAt + 1)
        return out.joined(separator: "\n")
    }

    /// Leading whitespace of the first `- item` under `rules:`, or nil when the
    /// block is empty (`rules:` followed by a dedent) — an empty chain has no
    /// layout to copy, so there is nothing safe to add to.
    private static func firstRuleIndent(after keyAt: Int, in lines: [String]) -> String? {
        for line in lines[(keyAt + 1)...] {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard !trimmed.isEmpty else { continue }
            // A comment line under `rules:` is not a sequence item; reading
            // `# …` as a dedent to the next key used to drop the pins silently.
            guard !trimmed.hasPrefix("#") else { continue }
            guard trimmed.hasPrefix("-") else { return nil } // dedented to the next key
            return String(line.prefix { $0 == " " || $0 == "\t" })
        }
        return nil
    }
}
