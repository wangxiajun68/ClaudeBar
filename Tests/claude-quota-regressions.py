#!/usr/bin/env python3
"""Exercise production CC quota parsing, transport, state and dev gates using synthetic credentials."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]

def declaration(text, marker):
    start = text.index(marker)
    pos = text.index('{', start) + 1
    level = 1
    while level:
        level += (text[pos] == '{') - (text[pos] == '}')
        pos += 1
    return text[start:pos]

fetch = (root / 'Sources/ClaudeBar/Utils/ClaudeQuotaFetcher.swift').read_text()
read = declaration(fetch, '    private static func readCredential()')
assert 'guard BuildChannel.allowsSystemIntegration' in read
assert 'context.interactionNotAllowed = true' in read
assert 'kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail' in read
assert 'SecKeychainSetUserInteractionAllowed(false) == errSecSuccess' in read
assert 'defer { _ = SecKeychainSetUserInteractionAllowed(interactionAllowed.boolValue) }' in read
assert read.index('guard BuildChannel.allowsSystemIntegration') < read.index('SecKeychainGetUserInteractionAllowed')
card = (root / 'Sources/ClaudeBar/Views/Shared/ClaudeQuotaCard.swift').read_text()
assert '.task' not in card and 'Task { await quota.refresh() }' in card
header = (root / 'Sources/ClaudeBar/Views/Popup/PanelHeader.swift').read_text()
assert 'quotaWindows: claudeQuota.windows' in header
greeting = (root / 'Sources/ClaudeBar/Views/Shared/GreetingCard.swift').read_text()
assert 'ccWindows: claudeQuota.windows' in greeting
assert 'SillChip(action: refreshCCQuota' in greeting
assert 'ClaudeQuotaCard()' not in (root / 'Sources/ClaudeBar/Views/Pages/UsageView.swift').read_text()
assert 'SecItemAdd' not in fetch and 'SecItemUpdate' not in fetch
fetch = fetch.replace(read, '''    private static func readCredential() -> Credential? {
        Probe.reads += 1
        return Probe.login
    }''')
window = declaration((root / 'Sources/ClaudeBar/Utils/CodexQuotaFetcher.swift').read_text(), 'struct CodexQuotaWindow:')
store = (root / 'Sources/ClaudeBar/Models/ClaudeQuotaStore.swift').read_text()
source = '''
import Foundation
import Combine
struct BuildChannel { static var allowsSystemIntegration = false }
enum Probe {
    static var reads = 0
    static var login: ClaudeQuotaFetcher.Credential? = .init(token: "synthetic-quota-token", expiresAt: nil)
}
''' + window + '\n' + fetch + '\n' + store + r'''
final class MockProtocol: URLProtocol {
    static var requests = 0
    static var status = 200
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        precondition(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-quota-token")
        precondition(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
            httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "120"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
func data(_ text: String) -> Data { Data(text.utf8) }
@main struct Regression {
    @MainActor static func main() async {
        let valid = data(#"{"five_hour":{"utilization":0,"resets_at":"2026-10-12T10:00:00Z"},"seven_day":{"utilization":42.5,"resets_at":"2026-10-18T10:00:00.123Z"},"seven_day_sonnet":null}"#)
        let parsed = ClaudeQuotaFetcher.parse(valid)
        precondition(!parsed.failed && parsed.windows.count == 2)
        precondition(parsed.windows.map(\.usedPercent) == [0,42.5])
        precondition(parsed.windows.map(\.id) == ["five_hour","seven_day"])
        precondition(parsed.windows.allSatisfy { $0.resetsAt != nil })
        precondition(parsed.windows.map(\.durationMinutes) == [300,10080])
        precondition(ClaudeQuotaFetcher.parse(data(#"{"five_hour":{"utilization":true}}"#)).windows.isEmpty)
        precondition(ClaudeQuotaFetcher.parse(data(#"{"five_hour":{"utilization":-2}}"#)).windows.isEmpty)
        precondition(ClaudeQuotaFetcher.parse(data(#"{"five_hour":{"utilization":120}}"#)).windows[0].usedPercent == 100)
        precondition(ClaudeQuotaFetcher.parse(data("not-json")).failed)
        precondition(ClaudeQuotaFetcher.parse(data(#"{"error":{"message":"synthetic"}}"#)).failed)
        precondition(ClaudeQuotaFetcher.parse(data("{}")).windows.isEmpty)
        let cred = ClaudeQuotaFetcher.credential(from: data(#"{"claudeAiOauth":{"accessToken":"synthetic-quota-token","expiresAt":1791806400000}}"#))
        precondition(cred?.token == "synthetic-quota-token" && cred?.expiresAt != nil)
        precondition(ClaudeQuotaFetcher.credential(from: data(#"{"apiKey":"synthetic-api-key"}"#)) == nil)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let blocked = await ClaudeQuotaFetcher.fetch(using: session)
        precondition(blocked.clearWindows && Probe.reads == 0 && MockProtocol.requests == 0)
        BuildChannel.allowsSystemIntegration = true
        MockProtocol.body = valid
        let good = await ClaudeQuotaFetcher.fetch(using: session)
        precondition(good.windows.count == 2 && good.accountKey != nil && MockProtocol.requests == 1)
        let state = ClaudeQuotaStore()
        state.apply(good)
        MockProtocol.status = 503
        state.apply(await ClaudeQuotaFetcher.fetch(using: session))
        precondition(state.windows.count == 2 && state.note != nil)
        MockProtocol.status = 429
        let limited = await ClaudeQuotaFetcher.fetch(using: session)
        precondition(limited.failed && limited.retryAt!.timeIntervalSinceNow > 100)
        state.apply(limited)
        precondition(state.windows.count == 2)
        state.apply(.init(note: "synthetic switched account", failed: true, accountKey: "different"))
        precondition(state.windows.isEmpty && state.updatedAt == nil)
        state.apply(good)
        MockProtocol.status = 401
        state.apply(await ClaudeQuotaFetcher.fetch(using: session))
        precondition(state.windows.isEmpty)
        state.apply(good)
        MockProtocol.status = 200; MockProtocol.body = data("{}")
        state.apply(await ClaudeQuotaFetcher.fetch(using: session))
        precondition(state.windows.isEmpty && state.note != nil)
        Probe.login = nil
        let before = MockProtocol.requests
        let missing = await ClaudeQuotaFetcher.fetch(using: session)
        precondition(missing.clearWindows && MockProtocol.requests == before)
        Probe.login = .init(token: "synthetic-quota-token", expiresAt: .distantPast)
        let expired = await ClaudeQuotaFetcher.fetch(using: session)
        precondition(expired.clearWindows && MockProtocol.requests == before)
        print("PASS: CC windows, missing vs zero, token/expiry parsing, mocked HTTP, 429 cooldown, transient failure retention, account changes, logout and dev credential/network gates")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='claudebar-cc-quota-') as tmp:
    file = Path(tmp) / 'Regression.swift'
    file.write_text(source)
    binary = Path(tmp) / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(file), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
