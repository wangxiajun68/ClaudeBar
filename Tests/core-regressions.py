#!/usr/bin/env python3
"""Compile and run isolated persistence/parser regressions when explicitly requested.
Uses temporary files only; does not launch ClaudeBar or contact any service.
"""
from pathlib import Path
import os
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
                    ['codexSpawnInfo', 'readHead', 'readCodexContext', 'recoverBeforeTail'])
# The tail reader sizes its own window from constants and, when the window
# carries no lifecycle line, falls back to a bounded lookback behind it; the
# slice has to carry both or the extraction does not type-check (which is how
# this fixture found out the method had grown a dependency).
constants = '\n'.join(
    line for line in monitor.split('\n') if 'static let codexTail' in line
    or 'static let codexLifecycle' in line)
if 'CLAUDEBAR_CORE_OLD_TAIL' in os.environ:
    # A/B knob for the fixture above: recompile the reader as the 48 KB
    # `size - min(48_000, size)` read it replaced, to prove the fixture still
    # fails on the shape it was written for.
    constants = ''
    anchor = 'static func readCodexContext'
    parsers = parsers[:parsers.index(anchor)] + parsers[parsers.index(anchor):].replace(
        'var start = size > UInt64(Self.codexTailWindow) ? size - UInt64(Self.codexTailWindow) : 0',
        'var start = size - min(48_000, size)', 1).replace(
        'let probeStart = start > UInt64(Self.codexTailLineSlack) ? start - UInt64(Self.codexTailLineSlack) : 0',
        'let probeStart = start', 1)
    # The trimmed read below still names the two constants.
    parsers = parsers.replace('Self.codexTailLineSlack)', '48_000)').replace(
        'Self.codexTailWindow + Int(size - start)', 'Int(size - start)')
swift = '\n'.join([
    env,
    read('Utils/JSONCoerce.swift'),
    read('Utils/PrivateFileWriter.swift'),
    read('Utils/XZArchive.swift'),
    read('Models/SettingsManager.swift'),
    'enum ParserFixture {\n' + constants + '\n' + parsers + '\n}',
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

        // A destination some earlier build left world-readable is healed by the
        // next write: the staged file is created 0600 and `rename` carries the
        // staged inode's mode, so the fix-up needs no separate pass.
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: FilePaths.settingsFile.path)
        try SettingsManager.writeSettings(env: EnvConfig(ANTHROPIC_MODEL: "model-b"))
        let healed = try FileManager.default.attributesOfItem(atPath: FilePaths.settingsFile.path)
        precondition((healed[.posixPermissions] as? NSNumber)?.intValue == 0o600)
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

        // A turn whose own records are larger than the window it is read with.
        // One local rollout carries a single 11 MB `function_call_output`, and
        // a window that lands inside it sees no lifecycle event at all — which
        // reads as `hasOpenTask == nil`, i.e. "this thread was never started",
        // and silently loses the completion. The window must clear a record
        // larger than itself and still reach the completion behind it.
        //
        // The 60 KB record trailing the completion is what makes this fixture
        // discriminate: it keeps the whole turn more than one old 48 KB read
        // away from EOF, so a reader that only looks at the last window reads
        // that record's tail and nothing else — which is exactly the failure
        // mode. Without it the message and the completion sit inside the tail
        // of the huge record and even the old reader passes.
        let big = FilePaths.claudeDir.appendingPathComponent("big-rollout.jsonl")
        var bigData = Data()
        bigData.append(Data("{\"type\": \"turn_context\", \"payload\": {\"model\": \"m\"}}\n".utf8))
        bigData.append(Data("{\"type\": \"event_msg\", \"payload\": {\"type\": \"task_started\"}}\n".utf8))
        let filler = String(repeating: "x", count: 900_000)
        bigData.append(Data("{\"type\": \"response_item\", \"payload\": {\"type\": \"function_call_output\", \"output\": \"\(filler)\"}}\n".utf8))
        bigData.append(Data("{\"type\": \"response_item\", \"payload\": {\"type\": \"message\", \"role\": \"assistant\", \"content\": [{\"type\": \"output_text\", \"text\": \"done\"}]}}\n".utf8))
        // No `last_agent_message`, so confirming the turn depends on the walk
        // actually having seen the assistant message, not on Codex's summary
        // field — the field would confirm the turn from any window that
        // reached the completion alone.
        bigData.append(Data("{\"type\": \"event_msg\", \"payload\": {\"type\": \"task_complete\", \"turn_id\": \"t1\"}}\n".utf8))
        let trailer = String(repeating: "y", count: 60_000)
        bigData.append(Data("{\"type\": \"response_item\", \"payload\": {\"type\": \"function_call_output\", \"output\": \"\(trailer)\"}}\n".utf8))
        try bigData.write(to: big)
        let bigTail = ParserFixture.readCodexContext(path: big.path)
        precondition(bigTail.hasOpenTask == false, "a turn behind a huge record must still be read")
        precondition(bigTail.completionID == "t1", "…and its delivered answer must be visible")

        // A compaction turn ends with `last_agent_message: null` and no
        // assistant reply of its own: it must not read as a delivered answer.
        let compact = FilePaths.claudeDir.appendingPathComponent("compact-rollout.jsonl")
        var compactData = Data()
        compactData.append(Data("{\"type\": \"event_msg\", \"payload\": {\"type\": \"task_complete\", \"turn_id\": \"c1\"}}\n".utf8))
        compactData.append(Data("{\"type\": \"event_msg\", \"payload\": {\"type\": \"task_complete\", \"turn_id\": \"c2\", \"last_agent_message\": null}}\n".utf8))
        compactData.append(Data("{\"type\": \"event_msg\", \"payload\": {\"type\": \"task_complete\", \"turn_id\": \"c3\", \"last_agent_message\": \"  \"}}\n".utf8))
        try compactData.write(to: compact)
        let nullTail = ParserFixture.readCodexContext(path: compact.path)
        precondition(nullTail.completionID == nil, "a turn that delivered nothing must not confirm")

        // The VPN core ships as `.xz` and is unpacked in-app (see
        // `XZArchive`). The archive is committed, so this decodes the real
        // bytes rather than a fixture: it pins the packer and the reader to each
        // other, which is the only place that can catch "the build packed a
        // different file" or "the decoder stopped matching the packer" before
        // a user meets it as 未找到 mihomo 内核.
        //
        // The repo root arrives as argv[2]: this file is copied into a temp
        // directory before it is compiled, so `#filePath` pointed at the temp
        // copy and the whole block silently skipped itself for every run. The
        // size is the *recorded* one, not a guessed ratio — LZMA on a 56 MB
        // binary is about 4×, and the old `20 × packed` bound could never hold.
        let archive = URL(fileURLWithPath: CommandLine.arguments[2])
            .appendingPathComponent("Sources/ClaudeBar/Resources/mihomo-core.xz")
        precondition(FileManager.default.fileExists(atPath: archive.path),
                     "the committed core archive must exist — it is what ships in the bundle")
        let restored = FileManager.default.temporaryDirectory
            .appendingPathComponent("mihomo-core-restored")
        try? FileManager.default.removeItem(at: restored)
        try XZArchive.extract(archive, to: restored)
        let packed = (try FileManager.default
            .attributesOfItem(atPath: archive.path))[.size] as? UInt64 ?? 0
        let unpacked = (try FileManager.default
            .attributesOfItem(atPath: restored.path))[.size] as? UInt64 ?? 0
        precondition(packed == 13_980_460, "the shipped core archive changed size — record it here if that was deliberate")
        precondition(unpacked == 56_588_610,
                     "the core must decode to the recorded binary — packed \(packed), unpacked \(unpacked)")
        try? FileManager.default.removeItem(at: restored)

        // Swift has no adjacent-literal concatenation, so this stays one line.
        print("PASS: numeric bounds, private atomic writes, configuration preservation, Codex metadata, the shipped xz core, and completion behind a huge record")
    }
}
'''])

with tempfile.TemporaryDirectory(prefix='claudebar-core-tests-') as folder:
    temporary = Path(folder)
    source = temporary / 'Regression.swift'
    source.write_text(swift)
    binary = temporary / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary), folder, str(root)], check=True)
