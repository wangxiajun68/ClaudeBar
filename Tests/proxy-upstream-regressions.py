#!/usr/bin/env python3
"""Exercise production third-party routing with isolated providers, no app/network."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
models = root / 'Sources/ClaudeBar/Models'

def method(source, name):
    start = source.index('    func ' + name)
    end = source.index('\n    }', start) + len('\n    }')
    return source[start:end]

bridge = (models / 'ProviderBridge.swift').read_text()
# Disk import is irrelevant; use all production conversion helpers unchanged.
start = bridge.index('    // MARK: - Disk')
end = bridge.index('    // MARK: - Provider conversion')
bridge = bridge[:start] + bridge[end:]
state = (models / 'CodexProxyState.swift').read_text()
local_start = state.index('    static func isLoopback')
local_end = state.index('\n    }', local_start) + len('\n    }')
source = '\n'.join([
    (models / name).read_text() for name in
    ['Provider.swift', 'CodexProvider.swift', 'ProviderCatalog.swift']
]) + '\n' + bridge + '\n' + state[state.index('actor CodexProxyState'):]
source += '\nenum LocalProxyAddress {\n' + state[local_start:local_end] + '\n}\n'
store = (models / 'CodexProviderStore.swift').read_text()
source += r'''
final class AppPreferences {
    static let shared = AppPreferences()
    var proxyThirdPartyOpenAIProviderID: UUID?
    var codexRoutingEnabled = true
}
final class ClaudePeer {
    var activeProvider: Provider?
    var providers: [Provider] { activeProvider.map { [$0] } ?? [] }
    var activeProviderID: UUID? { activeProvider?.id }
}
final class StoreFixture {
    var providers: [CodexProvider] = []
    var activeProvider: CodexProvider?
    var claudePeer: ClaudePeer? = ClaudePeer()
    let proxyState = CodexProxyState()
    var proxyRunning = false
    func startProxy() { proxyRunning = true }
    func stopProxy() { proxyRunning = false }
    func resolvedThirdPartyAnthropic() -> Provider? { claudePeer?.activeProvider }
RESOLVER
SYNC
}
@main struct Regression {
    static func main() async {
        let store = StoreFixture()
        precondition(store.resolvedThirdPartyOpenAI() == nil)
        let model = ModelConfig(name: "test-model[1M]")
        let claude = Provider(name: "Claude gateway", authToken: "fixture-key",
            baseURL: "http://gateway.example:2026", models: [model], activeModelID: model.id)
        store.claudePeer?.activeProvider = claude
        let fallback = store.resolvedThirdPartyOpenAI()!
        precondition(fallback.baseURL == "http://gateway.example:2026/v1")
        precondition(fallback.apiKey == "fixture-key" && fallback.wireAPI == "chat")
        precondition(fallback.name == claude.name && fallback.id == claude.id)
        precondition(fallback.activeModel?.name == "test-model")
        precondition(store.providers.isEmpty && store.activeProvider == nil)
        precondition(store.claudePeer?.activeProvider == claude)

        // Execute the actual runtime synchronization; listener stubs avoid
        // binding ports or touching the running app's state.
        store.syncProxyRuntime()
        precondition(store.proxyRunning)
        let state = store.proxyState
        for _ in 0..<200 {
            if await state.thirdPartyOpenAI != nil { break }
            try! await Task.sleep(nanoseconds: 1_000_000)
        }
        let thirdParty = await state.openaiUpstream(thirdParty: true)
        let codex = await state.openaiUpstream(thirdParty: false)
        precondition(thirdParty?.baseURL == fallback.baseURL && codex == nil)
        precondition(thirdParty?.apiKey == fallback.apiKey)

        let active = CodexProvider(name: "Active Codex", apiKey: "codex-fixture",
            baseURL: "https://codex.example/v1")
        let explicit = CodexProvider(name: "Selected vendor", apiKey: "selected-fixture",
            baseURL: "https://selected.example/v1")
        store.providers = [active, explicit]
        store.activeProvider = active
        precondition(store.resolvedThirdPartyOpenAI() == active)
        AppPreferences.shared.proxyThirdPartyOpenAIProviderID = explicit.id
        precondition(store.resolvedThirdPartyOpenAI() == explicit)
        store.activeProvider = nil
        precondition(store.resolvedThirdPartyOpenAI() == explicit)
        AppPreferences.shared.proxyThirdPartyOpenAIProviderID = UUID()
        precondition(store.resolvedThirdPartyOpenAI()?.baseURL == fallback.baseURL)
        store.activeProvider = active
        precondition(store.resolvedThirdPartyOpenAI() == active)
        store.activeProvider = nil
        for invalid in ["", "  ", "http://127.0.0.1:15721", "http://localhost:15721/v1", "http://[::1]:15721"] {
            store.claudePeer?.activeProvider?.baseURL = invalid
            precondition(store.resolvedThirdPartyOpenAI() == nil, "must not route back into proxy")
        }
        store.claudePeer = nil
        precondition(store.resolvedThirdPartyOpenAI() == nil)
        print("PASS: Claude-only OpenAI fallback, credentials, model, route isolation, explicit/active priority, stale selection and loopback rejection")
    }
}
'''.replace('RESOLVER', method(store, 'resolvedThirdPartyOpenAI')).replace(
    'SYNC', method(store, 'syncProxyRuntime'))
with tempfile.TemporaryDirectory(prefix='claudebar-proxy-upstream-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(source)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
