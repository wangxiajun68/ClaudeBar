#!/usr/bin/env python3
"""A custom provider endpoint must not be swallowed by the rule chain's MATCH.

The bug this pins, measured on this machine: the active Claude Code provider was
a *self-hosted* endpoint (`llm.example.net:2026` here) — a hostname on a domestic
IP, served over plain HTTP on a non-standard port. No geosite knows a name only
that one server has, so it matched neither `GEOIP,CN` nor `GEOSITE,CN`; the chain
fell through to `MATCH,🐟 漏网之鱼` and every request left through a node abroad
before coming straight back home. With 26–41 MB of context per turn it became the
largest consumer of node traffic on the machine while every local signal looked
fine: the destination really is in China, and the kernel's own log line said
`Direct` (because it was written before geosite finished loading). Only the route
was wrong.

Three things have to hold, and each has a way of being silently wrong:

  1. The generated config.yaml carries `DOMAIN,<host>,DIRECT` **first** under
     `rules:`. Placed anywhere after `GEOIP,CN` it is dead text — the host is
     already in China, and the rule that swallowed it is the LAST one in the
     chain, not the first.
  2. Hosts that must keep routing abroad are NOT pinned. `openrouter.ai` is in
     this user's provider list today; pinning it DIRECT would break it. This is
     the one way the feature can do harm, so it is fixtured explicitly.
  3. A profile with no `rules:` key is left byte-identical. Inventing a rules
     block for a profile that never declared one would change which chain the
     core applies.

The app-level suite compiles the *production* slice — the same file the app
builds, header comment and all — rather than a re-typed copy, so the "first
entry under rules:" invariant can't drift from the shipping code.

No app launch, no network, no file writes outside a temp dir.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/Utils/VpnProviderDirect.swift').read_text()

# --- slice the production source ---------------------------------------------
# Models (ProvidersFile/CodexProvidersFile) are later in the same module; the
# slice below reaches VpnSubscriptionStore's trailing brace, which closes the
# file, so a stub is prepended instead of the real decodables.
#
# The whole enum, minus nothing: `hosts()` reads from disk, and the suite drives
# `eligibleHosts(from:)` / `inject(into:)`, so the file's own defaults are never
# exercised here.
start = source.index('enum VpnProviderDirect {')
enum_src = source[start:].rstrip() + '\n'

stubs = r'''
import Foundation

// --- test stubs for the real model/file types -------------------------------
struct ProvidersFile: Decodable { var providers: [Provider]; var activeProviderID: UUID? }
struct Provider: Decodable { var baseURL: String }
struct CodexProvidersFile: Decodable { var providers: [CodexProvider]; var activeProviderID: UUID? }
struct CodexProvider: Decodable { var baseURL: String }
enum FilePaths {
    static var presetsFile: URL { URL(fileURLWithPath: "/nonexistent/claude.json") }
    static var codexProvidersFile: URL { URL(fileURLWithPath: "/nonexistent/codex.json") }
}
'''

swift = stubs + '\n' + enum_src + r'''

// --- assertions --------------------------------------------------------------

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if ok { print("  ok   \(what)") }
    else { print("  FAIL \(what)"); failures += 1 }
}

// 1. The measured host is pinned, and is first under `rules:`.
let bug = VpnProviderDirect.eligibleHost(from: "http://llm.example.net:2026")
check(bug == "llm.example.net", "the self-hosted provider host survives host extraction")

// The real subscription's layout: `rules:` then COLUMN-ZERO items. Assuming
// two-space items here is what killed the core at startup with
// "Parse config error: yaml: line 1: did not find expected key".
let profile = """
proxies:
- name: node
  type: vless
  server: 51.222.9.117
rules:
- "DOMAIN-KEYWORD,Thunder,\\U0001F3AF Direct"
- "GEOIP,CN,\\U0001F3AF Direct"
- "GEOSITE,CN,\\U0001F3AF Direct"
- "MATCH,\\U0001F41F 漏网之鱼"
"""
let nameOf = VpnProviderDirect.eligibleHost(from: "llm.example.net:2026")
let injected = VpnProviderDirect.inject(into: profile, hosts: [nameOf ?? "llm.example.net"])
let body = injected.split(separator: "\n").map(String.init)
let rulesAt = body.firstIndex(of: "rules:")!
check(body[rulesAt + 1] == "- \"DOMAIN,llm.example.net,DIRECT\"",
      "the pin copies the profile's own item indentation (column zero)")
check(body.firstIndex(of: "- \"DOMAIN,llm.example.net,DIRECT\"")! < body.firstIndex(of: "- \"GEOIP,CN,\\U0001F3AF Direct\"")!,
      "the pin precedes GEOIP,CN — after it the pin would be dead text")
check(injected.contains("- \"MATCH,\\U0001F41F 漏网之鱼\""), "the profile tail is preserved")
check(injected.components(separatedBy: "llm.example.net").count - 1 == 1,
      "injected exactly once")

// The other population: a hand-written profile indents its items by two.
let indented = "proxies: []\nrules:\n  - \"MATCH,DIRECT\"\n"
let indentedOut = VpnProviderDirect.inject(into: indented, hosts: ["llm.example.net"])
check(indentedOut.contains("\n  - \"DOMAIN,llm.example.net,DIRECT\"\n  - \"MATCH,DIRECT\""),
      "a two-space profile keeps two-space items: \(indentedOut.debugDescription)")

// An empty chain has no layout to copy.
let emptyRules = "proxies: []\nrules:\n"
check(VpnProviderDirect.inject(into: emptyRules, hosts: ["llm.example.net"]) == emptyRules,
      "an empty rules: block is left untouched")

// 2. Hosts whose correct route is abroad are NOT pinned.
for overseas in ["https://api.openrouter.ai/api/v1", "https://api.anthropic.com",
                 "https://api.openai.com/v1", "https://api.x.ai/v1",
                 "https://generativelanguage.googleapis.com/v1beta/openai",
                 "https://integrate.api.nvidia.com/v1"] {
    check(VpnProviderDirect.eligibleHost(from: overseas) == nil,
          "not pinned: \(overseas)")
}

// 3. Names that never reach the kernel, and literals the IP rules already cover.
for none in ["http://127.0.0.1:15721", "http://localhost:11434",
             "https://192.168.241.10:3000", "http://10.0.0.5",
             "http://foo.local", "http://[::1]:11434", ""] {
    check(VpnProviderDirect.eligibleHost(from: none) == nil, "not pinned: \(none)")
}

// 4. Domestic provider hosts ARE pinned — the whole point.
for domestic in ["https://open.bigmodel.cn/api/anthropic",
                 "https://dashscope.aliyuncs.com/apps/anthropic",
                 "https://api.moonshot.cn/anthropic",
                 "https://ark.cn-beijing.volces.com/api/compatible",
                 "https://api.stepfun.com",
                 "https://api.siliconflow.cn"] {
    let h = VpnProviderDirect.eligibleHost(from: domestic)
    check(h != nil, "pinned: \(domestic) -> \(h ?? "nil")")
}

// 5. A scheme-less hand-typed row still yields a host.
check(VpnProviderDirect.eligibleHost(from: "llm.example.net:2026") == "llm.example.net",
      "a row without a scheme still resolves its host")

// 6. Deduped and sorted, so the same host on both client stacks is one rule.
let both = VpnProviderDirect.eligibleHosts(from: [
    "http://llm.example.net:2026", "http://llm.example.net:2026/v1",
    "https://open.bigmodel.cn/api/anthropic", "https://open.bigmodel.cn/api/v1",
])
check(both == ["llm.example.net", "open.bigmodel.cn"], "deduped + sorted: \(both)")

// 7. A profile with no rules block is untouched, byte for byte.
let noRules = "proxies:\n- name: node\n  type: vless\n"
check(VpnProviderDirect.inject(into: noRules) == noRules,
      "a profile without rules: is left byte-identical")

// 8. An indented `rules:` belonging to another schema is not a target — and
//    with no column-zero `rules:` the text comes back untouched.
let nested = "rule-providers:\n  rules:\n    x: 1\nproxies: []\n"
check(VpnProviderDirect.inject(into: nested) == nested,
      "an indented rules: is not injected into")

exit(failures == 0 ? 0 : 1)
'''

with tempfile.TemporaryDirectory() as tmp:
    temporary = Path(tmp)
    source_file = temporary / 'Regression.swift'
    source_file.write_text(swift)
    binary = temporary / 'regression'
    r = subprocess.run(['swiftc', str(source_file), '-o', str(binary)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr)
        raise SystemExit('compile failed')
    run = subprocess.run([str(binary)], capture_output=True, text=True)
    print(run.stdout, end='')
    if run.stderr:
        print(run.stderr, end='')
    raise SystemExit(run.returncode)
