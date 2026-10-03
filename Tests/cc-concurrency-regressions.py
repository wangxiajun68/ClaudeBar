#!/usr/bin/env python3
"""CC model concurrency defaults, editor validation, provider readiness and
production env persistence."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = root / 'Sources/ClaudeBar'
def read(path):
    return (sources / path).read_text()
store = read('Models/ProviderStore.swift')
start = store.index('    private func buildEnv(')
end = store.index('\n    }', start) + len('\n    }')
build_env = store[start:end].replace('private func', 'func', 1)
editor = read('Views/Shared/ProviderConnectionEditor.swift')
editor = editor[editor.index('struct ProviderConnectionRoute'):editor.index('struct ProviderConnectionEditor: View')]
# `ProviderCardState.isReady` gates the activation control and the model
# picker. It is pure (no Theme, no Bundle), so it is compiled here against the
# same catalog that decides whether an empty key is legal.
controls = read('Views/Shared/ProviderControls.swift')
start = controls.index('    static func isReady(')
end = controls.index('\n    }\n', start) + len('\n    }\n')
is_ready = 'enum ProviderCardState {\n' + controls[start:end].replace('static func isReady', 'static func isReady', 1) + '\n}\n'
swift = '\n'.join(read(path) for path in [
    'Models/Preset.swift', 'Models/Provider.swift', 'Models/CodexProvider.swift',
    'Models/ProviderCatalog.swift', 'Models/SettingsManager.swift', 'Utils/PrivateFileWriter.swift',
]) + '\n' + editor + '\n' + is_ready + '\nstruct EnvFixture {\n' + build_env + '\n}\n'
swift += r'''
enum FilePaths {
    static let claudeDir = URL(fileURLWithPath: CommandLine.arguments[1])
    static let settingsFile = claudeDir.appendingPathComponent("settings.json")
}
enum LocalProxyAddress { static let claudeBase = "http://localhost:9999" }
enum CodexProxyServer { static let configuredToken = "fixture-proxy-token" }
@main struct Regression {
    static func main() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(ModelConfig.self, from: Data(#"{"name":"old-model"}"#.utf8))
        precondition(legacy.maxConcurrentSubagents == "20" && legacy.workflowMaxConcurrentAgents == "30")
        let oldProvider = try decoder.decode(Provider.self, from: Data(#"{"name":"legacy","models":["old-model"]}"#.utf8))
        precondition(oldProvider.models[0].workflowMaxConcurrentAgents == "30")
        var model = ModelConfig(name: "test-model", maxConcurrentSubagents: "3", workflowMaxConcurrentAgents: "32")
        let decoded = try decoder.decode(ModelConfig.self, from: JSONEncoder().encode(model))
        precondition(decoded == model)
        var draft = ProviderConnectionDraft.custom(client: .claude, id: UUID())
        draft.name = "fixture"
        draft.baseURL = "http://localhost:9998"
        draft.models = [ProviderConnectionModel(id: UUID(), name: "test-model")]
        precondition(draft.models[0].maxConcurrentSubagents == "20" && draft.models[0].workflowMaxConcurrentAgents == "30")
        precondition(draft.validationError == nil)
        for value in ["", "0", "-1", "1.5", "+2", "abc", "999999999999999999999999"] {
            draft.models[0].maxConcurrentSubagents = value
            precondition(draft.validationError != nil, "invalid subagent value accepted: \(value)")
        }
        draft.models[0].maxConcurrentSubagents = " 3 "
        for value in ["", "0", "-1", "257", "1.5", "abc"] {
            draft.models[0].workflowMaxConcurrentAgents = value
            precondition(draft.validationError != nil)
        }
        for value in ["1", "30", "256"] {
            draft.models[0].workflowMaxConcurrentAgents = value
            precondition(draft.validationError == nil)
        }
        // Readiness is the editors' rule, not a stricter second one. A loopback
        // endpoint serves unauthenticated, so an empty key is a valid record —
        // it must be ready (activation never reads the key); a public endpoint
        // with no key is not.
        let readyModel = ModelConfig(name: "local-model")
        let local = Provider(name: "Ollama", authToken: "", baseURL: "http://localhost:11434", models: [readyModel])
        precondition(ProviderCardState.isReady(local), "a keyless loopback provider must be ready")
        precondition(ProviderCardState.isReady(Provider(name: "Ollama", authToken: "", baseURL: "http://127.0.0.1:11434", models: [readyModel])),
                     "every loopback spelling is ready without a key")
        precondition(ProviderCardState.isReady(Provider(name: "Ollama", authToken: "", baseURL: "http://192.168.1.9:11434", models: [readyModel])),
                     "a private-network endpoint is ready without a key")
        precondition(!ProviderCardState.isReady(Provider(name: "Gateway", authToken: "", baseURL: "https://gateway.example", models: [readyModel])),
                     "a public endpoint with no key is still incomplete")
        precondition(ProviderCardState.isReady(Provider(name: "Gateway", authToken: "k", baseURL: "https://gateway.example", models: [readyModel])))
        precondition(!ProviderCardState.isReady(Provider(name: "Ollama", authToken: "", baseURL: "http://localhost:11434")),
                     "a keyless loopback provider with no model is incomplete")
        precondition(!ProviderCardState.isReady(Provider(name: "Ollama", authToken: "", baseURL: "  ", models: [readyModel])))
        let provider = Provider(name: "fixture", authToken: "fixture-key", baseURL: "https://gateway.example")
        let fixture = EnvFixture()
        let defaults = fixture.buildEnv(from: provider, model: legacy)
        precondition(defaults.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS == "20")
        precondition(defaults.CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS == "30")
        let original: [String: Any] = ["permissions": ["allow": ["Read"]], "env": ["CUSTOM_VALUE": 7]]
        try JSONSerialization.data(withJSONObject: original).write(to: FilePaths.settingsFile)
        try SettingsManager.writeSettings(env: fixture.buildEnv(from: provider, model: model))
        precondition(SettingsManager.readSettings()?.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS == "3")
        precondition(SettingsManager.readSettings()?.CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS == "32")
        model.maxConcurrentSubagents = " 5 "
        model.workflowMaxConcurrentAgents = "8"
        try SettingsManager.writeSettings(env: fixture.buildEnv(from: provider, model: model))
        precondition(SettingsManager.readSettings()?.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS == "5")
        precondition(SettingsManager.readSettings()?.CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS == "8")
        try SettingsManager.restoreOfficial()
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: FilePaths.settingsFile)) as! [String: Any]
        let env = saved["env"] as! [String: Any]
        precondition(env["CUSTOM_VALUE"] as? Int == 7 && saved["permissions"] != nil)
        precondition(env["CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"] == nil)
        precondition(env["CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS"] == nil)
        print("PASS: CC concurrency defaults, legacy decoding, round trip, editor bounds, keyless-loopback readiness, production env mapping, switching and official restore")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='claudebar-cc-concurrency-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary), folder], check=True)
