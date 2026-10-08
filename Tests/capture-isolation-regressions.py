#!/usr/bin/env python3
"""抓包开关必须按客户端隔离。

开启 Codex 抓包（`CodexProviderStore.setCaptureEnabled`）会经
`ProviderProfileSync.pushCodex` 推送 twin 给 Claude Code 一侧；若把
`captureEnabled` 也一起推过去，CC 的卡片会被点亮，而且当那一行正好是当前使用中
的配置时，`rewriteClaude` 会重写 `~/.claude/settings.json` —— 把
`ANTHROPIC_BASE_URL` 改成 loopback、把真实 key 换成代理 token。用户看到的就是
"开了 Codex 抓包，CC 的配置文件也跟着改成抓包了"。

本回归锁定两件事：
  * twin 同步 / 导入转换不再搬运 `captureEnabled`（源码切片断言 + 切片出的真实
    `fillClaude` / `fillCodex` 生产代码的行为断言）；
  * `ProviderStore` 的幂等自愈会把旧版本残留的 CC 状态拉回一致（切片出的真实
    `healCrossClientCapture` + 真实 `SettingsManager`，读回磁盘上的
    `settings.json`）。
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = root / 'Sources/ClaudeBar'


def slice_decl(text, marker):
    """The declaration starting at `marker` up to its closing brace."""
    start = text.index(marker)
    end = text.index('\n    }\n', start) + len('\n    }\n')
    return text[start:end]


# --- 1. 源码断言：两条同步路径都不再搬运 captureEnabled -----------------------
sync = (sources / 'Models/ProviderProfileSync.swift').read_text()
for name in ('fillClaude', 'fillCodex'):
    body = slice_decl(sync, f'private static func {name}(')
    assert 'captureEnabled' not in body, \
        f'{name} still carries the 抓包 switch across clients — that is what rewrote CC config'
bridge = (sources / 'Models/ProviderBridge.swift').read_text()
for name in ('toCodex', 'toClaude'):
    body = slice_decl(bridge, f'static func {name}(')
    assert 'captureEnabled' not in body, \
        f'ProviderBridge.{name} still imports the 抓包 switch from the other client'

# The switch still has to be writable by the client that owns it.
capture = slice_decl((sources / 'Models/ProviderStore.swift').read_text(), 'func setCaptureEnabled(')
assert 'providers[idx].captureEnabled = enabled' in capture, \
    'Claude-side capture toggle must still write its own store'

# --- 2. 行为断言：切片出的生产 fillClaude / fillCodex 不跨客户端搬开关 --------
# The two fill bodies are private enum members; slice them out and host them
# verbatim as `struct Fills` members (same 4-space convention), the way
# provider-delete-regressions.py slices deleteProvider.
import re

fills = '\n'.join(
    re.sub(r'private static func (fillClaude|fillCodex)\(', r'static func \1(',
           slice_decl(sync, f'private static func {name}('))
    for name in ('fillClaude', 'fillCodex'))
assert fills.count('static func fill') == 2

swift = '\n'.join((sources / name).read_text() for name in [
    'Models/Preset.swift',
    'Models/Provider.swift',
    'Models/CodexProvider.swift',
]) + r'''
struct ProviderCatalogEntry {
    struct Endpoint {
        let baseURL: String
        let wireAPI: String
        func url(for wireAPI: String) -> String { baseURL }
    }
    let id: String
    let codex: Endpoint?
    let claude: Endpoint?
    static func entry(id: String?) -> ProviderCatalogEntry? { nil }
    static func matching(baseURL: String) -> ProviderCatalogEntry? { nil }
}
enum ProviderBridge {
    static func stripClaudeModelSuffix(_ name: String) -> String { name }
    static func codexModel(from model: ModelConfig, preserving old: CodexModelConfig? = nil) -> CodexModelConfig {
        old ?? CodexModelConfig(name: model.name)
    }
    static func claudeModel(from model: CodexModelConfig, preserving old: ModelConfig? = nil) -> ModelConfig {
        old ?? ModelConfig(name: model.name)
    }
}
/// The production fill bodies, spliced (see the note above).
struct Fills {
FILLS
}
@main struct Regression {
    static func main() throws {
        let profile = UUID()
        let claude = Provider(name: "twin", authToken: "k", baseURL: "https://vendor.example",
                              models: [ModelConfig(name: "m")], captureEnabled: true, profileID: profile)
        let codex = CodexProvider(name: "twin", apiKey: "k", baseURL: "https://vendor.example/v1",
                                  models: [CodexModelConfig(name: "m")], captureEnabled: false, profileID: profile)

        // Codex 推给 CC：CC 的开关不能被清掉，其余仍同步。
        var claudeRow = claude
        Fills.fillClaude(&claudeRow, from: codex, entry: nil, creating: false)
        precondition(claudeRow.captureEnabled == true,
                     "pushing a Codex row must not clear the Claude 抓包 switch")
        precondition(claudeRow.name == "twin" && claudeRow.authToken == "k", "name/key still sync")
        precondition(!claudeRow.models.isEmpty, "model list still syncs")

        // CC 推给 Codex：Codex 的开关不能被点亮，其余仍同步。
        var codexRow = codex
        Fills.fillCodex(&codexRow, from: claude, entry: nil, creating: false)
        precondition(codexRow.captureEnabled == false,
                     "pushing a Claude row must not light up the Codex 抓包 switch")
        precondition(codexRow.name == "twin" && codexRow.apiKey == "k", "name/key still sync")
        precondition(!codexRow.models.isEmpty, "model list still syncs")

        print("PASS: 抓包 stays on the client that owns it while name/key/models keep syncing")
    }
}
'''
swift = swift.replace('FILLS', fills)

# --- 3. 自愈断言：切片出的生产 healCrossClientCapture -------------------------
store_swift = '\n'.join((sources / name).read_text() for name in [
    'Models/Preset.swift',
    'Models/Provider.swift',
    'Models/SettingsManager.swift',
    'Utils/PrivateFileWriter.swift',
]) + r'''
enum FilePaths {
    static let claudeDir = URL(fileURLWithPath: CommandLine.arguments[1])
    static let settingsFile = claudeDir.appendingPathComponent("settings.json")
}
/// The proxy addresses the heal decision reads. Stubbed: pulling in the real
/// `CodexProxyState.swift` would drag `AppPreferences` and the whole app graph
/// for two string constants.
enum LocalProxyAddress {
    static let claudeBase = "http://127.0.0.1:15721"
    static func isLoopback(_ url: String) -> Bool { url.hasPrefix("http://127.0.0.1:") }
}
/// A store around the **production** heal body. `activateModel` mirrors
/// `ProviderStore.buildEnv`'s documented contract: a capture-on vendor routes
/// through the proxy, a capture-off one writes its real URL and key back.
struct StoreFixture {
    var providers: [Provider] = []
    var currentEnv: EnvConfig?
    var saved = 0
    var activeProviderID: UUID? = nil
    @discardableResult mutating func saveProviders() -> Bool { saved += 1; return true }
    var activeProvider: Provider? { providers.first { $0.id == activeProviderID } }
    mutating func activateModel(providerID: UUID, modelID: UUID) {
        guard let provider = providers.first(where: { $0.id == providerID }),
              let model = provider.models.first(where: { $0.id == modelID }) else { return }
        try? SettingsManager.writeSettings(env: EnvConfig(
            ANTHROPIC_AUTH_TOKEN: provider.captureEnabled ? "proxy-token" : provider.authToken,
            ANTHROPIC_BASE_URL: provider.captureEnabled ? LocalProxyAddress.claudeBase : provider.baseURL,
            ANTHROPIC_MODEL: model.name))
        activeProviderID = providerID
    }
HEAL
}
@main struct Regression {
    static func main() throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        precondition(FileManager.default.fileExists(atPath: dir.path), "fixture dir exists")

        func env() throws -> [String: Any] {
            let data = try Data(contentsOf: FilePaths.settingsFile)
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return json["env"] as? [String: Any] ?? [:]
        }
        func vendor() -> (Provider, ModelConfig) {
            let model = ModelConfig(name: "m")
            return (Provider(name: "vendor", authToken: "real-key",
                             baseURL: "https://vendor.example", models: [model]), model)
        }

        // (a) 开关没开却留着 loopback 地址 —— Codex 抓包带过来的残留。
        let (stale, model) = vendor()
        var store = StoreFixture(providers: [stale], activeProviderID: stale.id)
        try SettingsManager.writeSettings(env: EnvConfig(
            ANTHROPIC_AUTH_TOKEN: "proxy-token", ANTHROPIC_BASE_URL: LocalProxyAddress.claudeBase,
            ANTHROPIC_MODEL: model.name))
        store.currentEnv = SettingsManager.readSettings()
        store.healCrossClientCapture()
        let healed = try env()
        precondition(healed["ANTHROPIC_BASE_URL"] as? String == "https://vendor.example",
                     "a capture-off vendor must be rewritten back off loopback")
        precondition(healed["ANTHROPIC_AUTH_TOKEN"] as? String == "real-key",
                     "the real key must come back")

        // (b) 开关被抄过来但并未生效。
        var (flagged, model2) = vendor()
        flagged.captureEnabled = true
        var flaggedStore = StoreFixture(providers: [flagged], activeProviderID: flagged.id)
        try SettingsManager.writeSettings(env: EnvConfig(
            ANTHROPIC_AUTH_TOKEN: flagged.authToken, ANTHROPIC_BASE_URL: flagged.baseURL,
            ANTHROPIC_MODEL: model2.name))
        flaggedStore.currentEnv = SettingsManager.readSettings()
        flaggedStore.healCrossClientCapture()
        precondition(flaggedStore.providers[0].captureEnabled == false,
                     "a switch that never took effect must be cleared")
        precondition(flaggedStore.saved == 1, "clearing the switch persists the list")
        let untouched = try env()
        precondition(untouched["ANTHROPIC_BASE_URL"] as? String == "https://vendor.example",
                     "the live config is left alone")

        // (c) 正常状态：开关开、配置就是 loopback —— 不动。
        var (live, model3) = vendor()
        live.captureEnabled = true
        var liveStore = StoreFixture(providers: [live], activeProviderID: live.id)
        try SettingsManager.writeSettings(env: EnvConfig(
            ANTHROPIC_AUTH_TOKEN: "proxy-token", ANTHROPIC_BASE_URL: LocalProxyAddress.claudeBase,
            ANTHROPIC_MODEL: model3.name))
        liveStore.currentEnv = SettingsManager.readSettings()
        liveStore.healCrossClientCapture()
        precondition(liveStore.providers[0].captureEnabled == true && liveStore.saved == 0,
                     "a self-consistent capture-on state is left alone")

        print("PASS: Claude 抓包 self-heals the cross-client residue and leaves consistent state alone")
    }
}
'''
heal = slice_decl((sources / 'Models/ProviderStore.swift').read_text(),
                  '    /// 抓包开关被旧版本跨客户端同步过')
heal = re.sub(r'private func healCrossClientCapture', 'mutating func healCrossClientCapture', heal)
heal = '\n'.join(('    ' + line if line.strip() else line) for line in heal.split('\n'))
assert 'LocalProxyAddress.isLoopback' in heal and 'activateModel(' in heal \
    and 'captureEnabled = false' in heal, 'the heal slice changed shape; re-point this extraction'
store_swift = store_swift.replace('HEAL', heal)

with tempfile.TemporaryDirectory(prefix='claudebar-capture-isolation-') as folder:
    for name, body, args in (('Fills', swift, []), ('Heal', store_swift, [folder])):
        path = Path(folder) / f'{name}.swift'
        path.write_text(body)
        binary = Path(folder) / name.lower()
        subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
        subprocess.run([str(binary), *args], check=True)
