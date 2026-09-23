#!/usr/bin/env python3
"""Compile and run isolated persistence/parser regressions when explicitly requested.
Uses temporary files only; does not launch ClaudeBar or contact any service.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source_root = root / 'Sources/ClaudeBar'


def read(relative):
    return (source_root / relative).read_text()


def method(source, name):
    start = source.index(f'    private static func {name}(')
    end = source.index('\n    }', start) + len('\n    }')
    return source[start:end].replace('private static func', 'static func', 1)


env = read('Models/Preset.swift').split('\n}\n', 1)[0] + '\n}\n'
monitor = read('Utils/ExternalSessionMonitor.swift')
parsers = '\n'.join(method(monitor, name) for name in
                    ['codexSpawnInfo', 'readHead', 'readCodexContext'])
swift = '\n'.join([
    env,
    read('Utils/JSONCoerce.swift'),
    read('Utils/PrivateFileWriter.swift'),
    read('Models/SettingsManager.swift'),
    'enum ParserFixture {\n' + parsers + '\n}',
    r'''
enum FilePaths {
    static let claudeDir = URL(fileURLWithPath: CommandLine.arguments[1])
    static let settingsFile = claudeDir.appendingPathComponent("settings.json")
}

@main struct CoreRegression {
    static func main() throws {
        precondition(JSONCoerce.int64Val(Double.infinity) == 0)
        precondition(JSONCoerce.int64Val(Double.nan) == 0)
        precondition(JSONCoerce.int64Val(Double(Int64.max)) == 0)
        precondition(JSONCoerce.int64Val(Int64.max) == Int64.max)
        precondition(JSONCoerce.int64Val(Double(Int64.min)) == Int64.min)
        precondition(JSONCoerce.intVal("42") == 42)
        precondition(JSONCoerce.intVal(42.9) == 42)

        let original: [String: Any] = [
            "permissions": ["allow": ["Read"]],
            "env": ["CUSTOM_COUNT": 7, "CUSTOM_FLAG": true,
                    "ANTHROPIC_AUTH_TOKEN": "old-key", "ANTHROPIC_API_KEY": "legacy-key",
                    "DISABLE_COMPACT": "1", "GITHUB_PERSONAL_ACCESS_TOKEN": "keep-me"]
        ]
        let originalData = try JSONSerialization.data(withJSONObject: original)
        try originalData.write(to: FilePaths.settingsFile)
        try SettingsManager.writeSettings(env: EnvConfig(
            ANTHROPIC_BASE_URL: "https://example.com/v1", ANTHROPIC_MODEL: "model-a"))
        let savedData = try Data(contentsOf: FilePaths.settingsFile)
        let saved = try JSONSerialization.jsonObject(with: savedData) as! [String: Any]
        let values = saved["env"] as! [String: Any]
        precondition(values["ANTHROPIC_AUTH_TOKEN"] == nil)
        precondition(values["ANTHROPIC_API_KEY"] == nil)
        precondition(values["DISABLE_COMPACT"] == nil)
        precondition(values["CUSTOM_COUNT"] as? Int == 7)
        precondition(values["CUSTOM_FLAG"] as? Bool == true)
        precondition(values["GITHUB_PERSONAL_ACCESS_TOKEN"] as? String == "keep-me")
        precondition(saved["permissions"] != nil)
        precondition(SettingsManager.readSettings()?.ANTHROPIC_MODEL == "model-a")
        let permissions = try FileManager.default.attributesOfItem(atPath: FilePaths.settingsFile.path)
        precondition((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let backup = try Data(contentsOf: FilePaths.settingsFile.appendingPathExtension("bak"))
        precondition(backup == originalData)
        try SettingsManager.restoreOfficial()
        precondition(SettingsManager.readSettings()?.ANTHROPIC_MODEL == "")

        for malformed in ["not-json", "[]", "{\"env\":42}"] {
            let data = Data(malformed.utf8)
            try data.write(to: FilePaths.settingsFile)
            do {
                try SettingsManager.writeSettings(env: EnvConfig(ANTHROPIC_MODEL: "never-written"))
                preconditionFailure("Invalid settings must not be replaced")
            } catch {}
            let retained = try Data(contentsOf: FilePaths.settingsFile)
            precondition(retained == data)
        }

        let path = FilePaths.claudeDir.appendingPathComponent("rollout.jsonl")
        let metadata: [String: Any] = ["type": "session_meta", "payload": [
            "cwd": "/tmp/a\"b", "base_instructions": String(repeating: "x", count: 80_000),
            "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent", "depth": 1]]]
        ]]
        var data = try JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys)
        data.append(0x0A)
        data.append(Data("{\"type\": \"turn_context\", \"payload\": {\"model\": \"latest-model\"}}\n".utf8))
        data.append(Data("{\"type\": \"event_msg\", \"payload\": {\"type\": \"task_complete\"}}\n".utf8))
        try data.write(to: path)
        let head = ParserFixture.readHead(path: path.path, bytes: 32_000)
        let parsed = ParserFixture.codexSpawnInfo(head: head)
        precondition(parsed?.cwd == "/tmp/a\"b")
        precondition(parsed?.parentThreadId == "parent")
        precondition(parsed?.threadSource == "subagent")
        precondition(ParserFixture.codexSpawnInfo(head: "{\"type\":\"session_meta\"") == nil)
        let tail = ParserFixture.readCodexContext(path: path.path)
        precondition(tail.model == "latest-model")
        precondition(tail.hasOpenTask == false)
        print("PASS: numeric bounds, private atomic writes, configuration preservation and Codex metadata")
    }
}
'''])

with tempfile.TemporaryDirectory(prefix='claudebar-core-tests-') as folder:
    temporary = Path(folder)
    source = temporary / 'Regression.swift'
    source.write_text(swift)
    binary = temporary / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary), folder], check=True)
