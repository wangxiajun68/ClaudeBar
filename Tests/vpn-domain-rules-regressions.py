#!/usr/bin/env python3
"""Compile production domain routing and persistence with isolated temporary files."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/Utils/VpnDomainRules.swift').read_text()
writer = (root / 'Sources/ClaudeBar/Utils/PrivateFileWriter.swift').read_text()
subscription = (root / 'Sources/ClaudeBar/Utils/VpnSubscriptionStore.swift').read_text()
preview_builder = subscription[subscription.index('struct VpnProfilePreview:'):subscription.index('/// Seeds `geosite.dat`')]
provider_direct = (root / 'Sources/ClaudeBar/Utils/VpnProviderDirect.swift').read_text()
manager = (root / 'Sources/ClaudeBar/Utils/VpnManager.swift').read_text()
names_start = manager.index('nonisolated static let primaryGroupNames = [')
names = manager[names_start:manager.index(']', names_start) + 1]
swift = source + '\n' + writer + '\n' + provider_direct + '\n' + preview_builder + '\n' + 'enum VpnManager { ' + names + ' }' + r'''
enum FilePaths {
    static var vpnDir: URL { URL(fileURLWithPath: CommandLine.arguments[1]) }
    static var presetsFile: URL { vpnDir.appendingPathComponent("claude.json") }
    static var codexProvidersFile: URL { vpnDir.appendingPathComponent("codex.json") }
}
struct ProvidersFile: Decodable { var providers: [Provider] }
struct Provider: Decodable { var baseURL: String }
struct CodexProvidersFile: Decodable { var providers: [CodexProvider] }
struct CodexProvider: Decodable { var baseURL: String }
struct AppPreferences {
    var vpnAllowLan = false
    var vpnMixedPort = 17890
    var vpnControllerSecret = "fixture"
    var vpnTunEnabled = false
}
enum BuildChannel {
    static let vpnControllerPort = 19097
    static let allowsSystemIntegration = false
}
func check(_ condition: Bool, _ name: String) {
    guard condition else { fatalError(name) }
    print("PASS \(name)")
}
check(VpnDomainRules.normalize(" EXAMPLE.COM. ") == "example.com", "normalization")
for invalid in ["", "https://example.com", "example.com/path", "example.com:443", "*.example.com",
                "a..com", "-a.com", "a-.com", "localhost", "127.0.0.1", "a,b.com", "a\n.com", "中文.com"] {
    check(VpnDomainRules.normalize(invalid) == nil, "reject \(invalid)")
}
let broad = VpnDomainRule(domain: "example.com", includesSubdomains: true, route: .direct)
let exact = VpnDomainRule(domain: "api.example.com", includesSubdomains: false, route: .proxy)
let same = VpnDomainRule(domain: "example.com", includesSubdomains: false, route: .proxy)
check(broad.matches("example.com") && broad.matches("api.example.com"), "suffix includes root and children")
check(!broad.matches("badexample.com") && !exact.matches("sub.api.example.com"), "domain boundaries")
check(VpnDomainRules.ordered([broad, exact, same]) == [exact, same, broad], "specificity precedence")
check(VpnDomainRules.providerBypass(["api.example.com", "other.example.com"], rules: [broad, exact]) == ["other.example.com"], "manual proxy beats automatic bypass")
check(VpnDomainRules.providerBypass(["example.com", "api.example.com"], rules: [same, broad]) == ["api.example.com"], "exact exception beats suffix")
for indent in ["", "  ", "    "] {
    let profile = "proxies: []\nrules:\n# comment\n\(indent)- \"DOMAIN,api.example.com,DIRECT\"\n\(indent)- MATCH,DIRECT\ndns:\n  enable: true\n"
    let result = try VpnDomainRules.inject(into: profile, rules: [broad, exact], proxyTarget: "🚀 节点选择")
    check(result.contains("\(indent)- \"DOMAIN,api.example.com,🚀 节点选择\""), "indentation \(indent.count)")
    check(result.range(of: "DOMAIN,api.example.com,🚀")!.lowerBound < result.range(of: "DOMAIN,api.example.com,DIRECT")!.lowerBound, "user before automatic pin")
    check(result.contains("dns:\n  enable: true"), "preserve sibling block")
    try result.write(to: FilePaths.vpnDir.appendingPathComponent("rules-\(indent.count).yaml"), atomically: true, encoding: .utf8)
}
for profile in ["rules: []", "rules:\ndns:\n  enable: true", "proxies: []", "rules: # comment\n- MATCH,DIRECT",
                "rules: [\"MATCH,DIRECT\"]", "rules: ['MATCH,DIRECT']"] {
    let result = try VpnDomainRules.inject(into: profile, rules: [exact], proxyTarget: "REJECT")
    check(result.contains("DOMAIN,api.example.com,REJECT"), "empty/missing/flow rules")
    if profile.contains("MATCH") { check(result.contains("MATCH,DIRECT"), "retain flow tail") }
}
do {
    _ = try VpnDomainRules.inject(into: "rules: [MATCH,DIRECT]", rules: [exact], proxyTarget: "PROXY")
    fatalError("unsupported rules silently ignored")
} catch { print("PASS unsupported format fails visibly") }
check(try VpnDomainRules.inject(into: "rules: []", rules: [], proxyTarget: "PROXY") == "rules: []", "no changes without rules")
try VpnDomainRules.save([broad, exact])
check(VpnDomainRules.load() == [broad, exact], "persistence roundtrip")
let attributes = try FileManager.default.attributesOfItem(atPath: VpnDomainRules.file.path)
check((attributes[.posixPermissions] as! NSNumber).intValue == 0o600, "private file mode")
let bad = VpnDomainRule(domain: "bad,rule.com", includesSubdomains: true, route: .direct)
try VpnDomainRules.save([bad, exact])
check(VpnDomainRules.load() == [exact], "invalid stored domains filtered")
try VpnDomainRules.save([exact])
let profile = """
proxy-groups:
- name: fallback
  type: url-test
  proxies: [node]
- name: Custom Selector
  type: select
  proxies: [node]
- name: 主代理
  type: select
  proxies: [node]
proxies:
- name: node
  type: ss
  server: example.net
rules:
- MATCH,DIRECT
"""
let preferences = AppPreferences()
check(try VpnConfigBuilder.build(profileText: profile, prefs: preferences).contains("DOMAIN,api.example.com,主代理"), "builder uses primary group")
let escaped = profile.replacingOccurrences(of: "Custom Selector", with: #""\U0001F680 \u8282\u70b9\u9009\u62e9""#)
    .replacingOccurrences(of: "- name: 主代理\n  type: select\n  proxies: [node]\n", with: "")
check(try VpnConfigBuilder.build(profileText: escaped, prefs: preferences).contains("DOMAIN,api.example.com,🚀 节点选择"), "builder decodes YAML Unicode group names")
let custom = profile.replacingOccurrences(of: "- name: 主代理\n  type: select\n  proxies: [node]\n", with: "")
check(try VpnConfigBuilder.build(profileText: custom, prefs: preferences).contains("DOMAIN,api.example.com,Custom Selector"), "builder falls back to selector")
let leaf = "proxies:\n- name: node\n  type: ss\n  server: example.net\nrules: []"
check(try VpnConfigBuilder.build(profileText: leaf, prefs: preferences).contains("DOMAIN,api.example.com,node"), "builder falls back to leaf")
check(try VpnConfigBuilder.build(profileText: nil, prefs: preferences).contains("DOMAIN,api.example.com,REJECT"), "builder fails closed without proxy")
'''
# Check app wiring without compiling or running any system integration.
builder = (root / 'Sources/ClaudeBar/Utils/VpnSubscriptionStore.swift').read_text()
assert 'try VpnDomainRules.inject(into: automaticPins' in builder
controller = (root / 'Sources/ClaudeBar/Utils/VpnSystemProxyController.swift').read_text()
assert 'VpnDomainRules.providerBypass(VpnProviderDirect.hosts(), rules: VpnDomainRules.load())' in controller
with tempfile.TemporaryDirectory(prefix='vpn-domain-rules-') as temp:
    directory = Path(temp)
    main = directory / 'main.swift'
    main.write_text(swift)
    binary = directory / 'rules-test'
    subprocess.run(['swiftc', str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary), temp], check=True)
    import json
    for output in directory.glob('rules-*.yaml'):
        lines = output.read_text().splitlines()
        start = lines.index('rules:') + 1
        pins = [json.loads(line.strip()[2:]) for line in lines[start:start + 2]]
        assert pins == ['DOMAIN,api.example.com,🚀 节点选择', 'DOMAIN-SUFFIX,example.com,DIRECT']
print('PASS domain rules and YAML structure')
