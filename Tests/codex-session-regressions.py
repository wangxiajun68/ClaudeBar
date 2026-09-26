#!/usr/bin/env python3
"""Exercise the production monitor with an isolated index and rollout fixtures."""
from pathlib import Path
import subprocess, tempfile, sqlite3, json, os, time
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='claudebar-codex-') as folder:
    work = Path(folder)
    db = sqlite3.connect(work / 'state_5.sqlite')
    db.execute('CREATE TABLE threads (id TEXT, rollout_path TEXT, cwd TEXT, created_at INTEGER, updated_at INTEGER, source TEXT, archived INTEGER, title TEXT)')
    now = int(time.time())
    def thread(name, *, age=0, archived=0, child=False, missing=False, open_turn=False, malformed=False, source='vscode'):
        path = work / 'sessions' / (name + '.jsonl')
        path.parent.mkdir(exist_ok=True)
        if child:
            source = {'subagent': {'thread_spawn': {'parent_thread_id': 'idle', 'depth': 1}}}
        if not missing:
            meta = {'type': 'session_meta', 'payload': {'cwd': '/tmp/project', 'source': source}}
            event = {'type': 'event_msg', 'payload': {'type': 'task_started' if open_turn else 'task_complete'}}
            path.write_text(('invalid\n' if malformed else json.dumps(meta)+'\n')+json.dumps(event)+'\n')
            os.utime(path, (now-age, now-age))
        db.execute('INSERT INTO threads VALUES (?,?,?,?,?,?,?,?)', (name,str(path),'/tmp/project',now-age,now-age,json.dumps(source) if child else source,archived,'Title '+name))
    thread('idle', age=86400*30)
    thread('running', open_turn=True)
    thread('stale-open', age=86400, open_turn=True)
    thread('missing', age=86400, missing=True)
    thread('malformed', age=86400, malformed=True)
    thread('archived', archived=1)
    thread('child', child=True, open_turn=True)
    thread('child-stale', child=True, age=600, open_turn=True)
    thread('exec-once', source='exec', open_turn=True)
    thread('mcp-once', source='mcp')
    db.commit()
    harness = work / 'Main.swift'
    harness.write_text('''import Foundation
    enum UsageStats { static func formatContext(_ n: Int) -> String { String(n) } }
    @main struct Regression {
        static func main() {
            let sessions = ExternalSessionMonitor.fetchActive()
            let ids = Set(sessions.map(\\.sessionId))
            precondition(ids == Set(["idle", "running", "stale-open", "missing", "malformed"]), "Unarchived main threads must remain visible: \\(ids)")
            precondition(sessions.filter(\\.isActive).map(\\.sessionId) == ["running"])
            precondition(sessions.allSatisfy { $0.displayName == "Title " + $0.sessionId })
            precondition(sessions.allSatisfy { !$0.isSubagent })

            // The swarm tree joins children to parents by `parentThreadId`, so
            // the monitor has to hand back the helpers too — for years it did
            // not, and the tree was structurally empty.
            let scan = ExternalSessionMonitor.scan()
            precondition(scan.main.map(\\.sessionId).sorted() == ids.sorted(),
                         "main must be exactly the fetchActive set")
            precondition(scan.subagents.map(\\.sessionId) == ["child"],
                         "a recent sub-agent is returned: \\(scan.subagents.map(\\.sessionId))")
            let child = scan.subagents[0]
            precondition(child.isSubagent && child.parentThreadId == "idle",
                         "the helper carries the id its parent is keyed by")
            precondition(ids.contains(child.parentThreadId!),
                         "the parent is itself a returned main thread, or the tree drops the child")
            precondition(child.isActive, "an open sub-agent turn reads as running")

            // `scan()` runs off-main and polls can overlap (the app kicks it
            // from detached tasks), which is the whole reason `indexRows`,
            // `codexFileCache` and `indexReadAt` sit behind `NSLock`s. Run
            // several scans at once: they must agree with each other and with
            // the sequential result above. A dropped lock shows up as a torn
            // dictionary or a crash here instead of in the field.
            let expected = (scan.main + scan.subagents).map(\\.id).sorted()
            let queue = DispatchQueue(label: "scan", attributes: .concurrent)
            let group = DispatchGroup()
            let gate = NSLock()
            var outcomes = Set<String>()
            for _ in 0..<16 {
                group.enter()
                queue.async {
                    let s = ExternalSessionMonitor.scan()
                    let key = (s.main + s.subagents).map(\\.id).sorted().joined(separator: ",")
                    gate.lock(); outcomes.insert(key); gate.unlock()
                    group.leave()
                }
            }
            group.wait()
            precondition(outcomes == [expected.joined(separator: ",")],
                         "concurrent scans disagreed: \\(outcomes)")

            print("PASS: idle, stale-open, missing and malformed rollouts retained; archived, exec and mcp threads excluded; running state and titles; recent sub-agent returned and stale sub-agent dropped; 16 overlapping scans agree under the caches' locks")
        }
    }''')
    binary = work / 'regression'
    # SessionTitle is a dependency of the monitor, not of the fixture: without
    # it the slice does not compile at all, which is how this test came to be
    # parked outside CI (`Makefile` / `ci.yml` never ran it). Fonts are
    # CoreGraphics and Foundation only, so the slice stays app-free.
    subprocess.run(['swiftc','-parse-as-library',
                    str(root/'Sources/ClaudeBar/Utils/ExternalSessionMonitor.swift'),
                    str(root/'Sources/ClaudeBar/Utils/JSONCoerce.swift'),
                    str(root/'Sources/ClaudeBar/Utils/SessionTitle.swift'),
                    str(harness),'-o',str(binary)], check=True)
    subprocess.run([str(binary)], env={**os.environ, 'CODEX_HOME':folder}, check=True)
