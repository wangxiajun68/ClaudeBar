#!/usr/bin/env python3
"""Bulk enable / disable / remove over the connector inventory.

The rules that are one edit away from silently regressing, none of which a
compiler catches:

1. **The batch may only do what a single card does.** `batchCapability` decides
   which actions reach a record, and it is derived from the same cases the
   card's own buttons branch on. A record the card refuses to touch — a Cursor
   plugin, a Codex cache entry, a Claude plugin MCP — must be *skipped*, not
   quietly written. This is the difference between "停用 the selected 40 skills"
   and "停用 the selected 40 things, three of which turned out to be the client's
   own files".

2. **停用 and 启用 are not each other's complement.** A record already in the
   target state is skipped, because nine of ten selected skills are already off
   and re-running the move on each is that many needless disk operations. A
   Cursor MCP is the exception and takes *both* commands — its state cannot be
   read, so the app must act on what the user asked for rather than on a guess.

3. **The count shown is the count executed.** The confirmation's number comes
   from the same `ConnectorBatch.records` the run then walks, so a promise of
   "12 项" cannot turn into 19 writes.

Runs against the production source with temporary storage; no app launch, no
client CLI, no real configuration touched.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
manager = (root / 'Sources/ClaudeBar/Models/ConnectorManager.swift').read_text()

# Everything above the manager class is the model: the record type, its
# capability derivation, the batch policy, and the outcome summary. The scan and
# the mutations below it reach for FilePaths / BuildChannel / the real home
# directory and are not what this test is about.
model = manager[:manager.index('@MainActor final class ConnectorManager')]

# The avatar's hue and the card's brand mark are *declared* in this region but
# belong to the UI. `djb2` is lifted verbatim rather than re-derived — a fixture
# that reimplements production would pass while the real one drifts.
theme = (root / 'Sources/ClaudeBar/Theme/Theme.swift').read_text()
start = theme.index('    static func djb2(')
end = theme.index('\n    }', start) + len('\n    }')
djb2 = theme[start:end]

swift = r'''
import Foundation

enum ProductBrandMark {
    enum Brand { case claude, codex, cursor }
}
enum Theme {
DJ2
}

MODEL

@main struct Regression {
    static func main() {
        // --- fixtures -------------------------------------------------------
        func skill(_ name: String, enabled: Bool) -> ConnectorRecord {
            ConnectorRecord(id: "skill:" + name, name: name, summary: "/tmp/" + name,
                            kind: .skill, platforms: [.claude], scope: "个人",
                            source: URL(fileURLWithPath: "/tmp/" + name),
                            enabled: enabled, method: .skillMove(original: URL(fileURLWithPath: "/tmp/" + name)))
        }
        func codexMCP(_ name: String, enabled: Bool) -> ConnectorRecord {
            ConnectorRecord(id: "codex:mcp:" + name, name: name, summary: "/tmp/config.toml",
                            kind: .mcp, platforms: [.codex], scope: "个人",
                            source: URL(fileURLWithPath: "/tmp/config.toml"), enabled: enabled,
                            method: .codexSetting(section: "mcp_servers." + name))
        }
        func cursorMCP(_ name: String) -> ConnectorRecord {
            ConnectorRecord(id: "cursor:mcp:" + name, name: name, summary: "/tmp/mcp.json",
                            kind: .mcp, platforms: [.cursor], scope: "个人",
                            source: URL(fileURLWithPath: "/tmp/mcp.json"), enabled: nil,
                            method: .cursorMCP(identifier: name, directory: URL(fileURLWithPath: "/tmp")))
        }
        func nativePlugin(_ name: String) -> ConnectorRecord {
            ConnectorRecord(id: "cursor:plugin:" + name, name: name, summary: "Cursor 本地插件",
                            kind: .plugin, platforms: [.cursor], scope: "个人 · 本地",
                            source: URL(fileURLWithPath: "/tmp/" + name), enabled: nil, method: .native)
        }
        func nativeMCP(_ name: String) -> ConnectorRecord {
            ConnectorRecord(id: "claude:user:" + name, name: name, summary: "Claude Code · 用户配置",
                            kind: .mcp, platforms: [.claude], scope: "个人",
                            source: URL(fileURLWithPath: "/tmp/.mcp.json"), enabled: nil, method: .native)
        }

        // --- 1. capability is derived from the record, not assumed ----------
        precondition(skill("a", enabled: true).batchCapability == .state(true))
        precondition(skill("a", enabled: false).batchCapability == .state(false))
        precondition(codexMCP("a", enabled: false).batchCapability == .state(false))
        precondition(cursorMCP("a").batchCapability == .command)
        // A native client's own file: no state *and* no removal for a plugin.
        precondition(nativePlugin("a").batchCapability == .none)
        precondition(!nativePlugin("a").canRemove)
        // A native MCP config is removable even though it has no enabled flag —
        // the two facts are separate, and conflating them is what put a fake
        // 停用 button on cards whose write the gate would then reject.
        precondition(nativeMCP("a").batchCapability == .none)
        precondition(nativeMCP("a").canRemove)

        // --- 2. disable reaches only what is actually on ---------------------
        let mixed = [skill("on-1", enabled: true), skill("on-2", enabled: true),
                     skill("off", enabled: false), codexMCP("live", enabled: true),
                     codexMCP("dead", enabled: false), cursorMCP("cursor"),
                     nativePlugin("native"), nativeMCP("native-mcp")]
        let disabled = ConnectorBatch.records(mixed, for: .disable).map(\.name)
        precondition(disabled == ["on-1", "on-2", "live", "cursor"],
                     "disable must skip the already-off and the client-managed; got \(disabled)")
        // The already-off are *skipped*, not failed: the run reports them so the
        // user is not told 40 项 while 37 moved.
        precondition(ConnectorBatch.inert(mixed) == 1,
                     "only the Cursor plugin is unreachable by every action")

        // --- 3. enable is the mirror, and Cursor takes both ------------------
        let enabled = ConnectorBatch.records(mixed, for: .enable).map(\.name)
        precondition(enabled == ["off", "dead", "cursor"],
                     "enable must skip the already-on; got \(enabled)")
        // The two sets overlap in exactly one place: the record whose state is
        // unknown. That overlap is deliberate and this pins it.
        precondition(Set(disabled).intersection(enabled) == ["cursor"])

        // --- 4. remove is its own gate --------------------------------------
        let removed = ConnectorBatch.records(mixed, for: .remove).map(\.name)
        precondition(removed == ["on-1", "on-2", "off", "live", "dead", "cursor", "native-mcp"],
                     "remove follows canRemove, and a native MCP config is removable; got \(removed)")
        precondition(!removed.contains("native"), "a native plugin has no config to delete")

        // --- 5. a selection of only client-managed rows does nothing --------
        let clients = [nativePlugin("a"), nativePlugin("b")]
        for action in [ConnectorBatchAction.disable, .enable, .remove] {
            precondition(ConnectorBatch.records(clients, for: action).isEmpty,
                         "client-managed rows must be reachable by nothing")
        }
        precondition(ConnectorBatch.inert(clients) == 2)

        // --- 6. the outcome line matches the action -------------------------
        var outcome = ConnectorBatchOutcome()
        outcome.disabled = 12; outcome.movedSkills = 8
        precondition(outcome.notice(.disable) == "已停用 12 项，8 个 Skill 目录已移入停用区。")
        var restored = ConnectorBatchOutcome()
        restored.enabled = 3; restored.movedSkills = 3
        precondition(restored.notice(.enable) == "已启用 3 项，3 个 Skill 目录已还原。")
        var gone = ConnectorBatchOutcome()
        gone.removed = 2; gone.movedSkills = 1
        precondition(gone.notice(.remove) == "已移除 2 项，1 个 Skill 目录已进废纸篓。")
        // A run that did nothing must not claim a number, and the Cursor caveat
        // is appended without inventing a success count for it.
        var commandsOnly = ConnectorBatchOutcome()
        commandsOnly.cursorCommands = 2
        precondition(commandsOnly.notice(.disable)
                        == "Cursor 的实际状态请在 Customize 中核对。",
                     "a command-only run must not report a state change")
        precondition(ConnectorBatchOutcome().notice(.disable) == nil, "an empty run says nothing")
        var partial = ConnectorBatchOutcome()
        partial.disabled = 5; partial.skipped = 3; partial.failures = ["x：锁住"]
        // Failures go to the error banner, not into the count line — one run
        // must not say the same thing twice in two banners.
        precondition(partial.notice(.disable) == "已停用 5 项，跳过 3 项。")
        precondition(!partial.notice(.disable)!.contains("锁住"))

        // --- 7. hasWork drives the single rescan ----------------------------
        precondition(!ConnectorBatchOutcome().hasWork)
        var skippedOnly = ConnectorBatchOutcome()
        skippedOnly.skipped = 40
        precondition(!skippedOnly.hasWork, "a run that changed nothing must not rescan the disk")
        var worked = ConnectorBatchOutcome()
        worked.disabled = 1
        precondition(worked.hasWork)

        print("PASS: batch capability derived from the card's own rules; disable skips "
              + "already-off; Cursor takes both commands (state unreadable); remove follows "
              + "canRemove; client-managed rows are skipped by every action; outcome line "
              + "matches the action and failures stay out of it")
    }
}
'''.replace('MODEL', model).replace('DJ2', djb2)

with tempfile.TemporaryDirectory(prefix='claudebar-connector-batch-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
