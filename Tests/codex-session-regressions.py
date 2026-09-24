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
            print("PASS: idle, stale-open, missing and malformed rollouts retained; archived, child, exec and mcp threads excluded; running state and titles")
        }
    }''')
    binary = work / 'regression'
    subprocess.run(['swiftc','-parse-as-library',str(root/'Sources/ClaudeBar/Utils/ExternalSessionMonitor.swift'),str(root/'Sources/ClaudeBar/Utils/JSONCoerce.swift'),str(harness),'-o',str(binary)], check=True)
    subprocess.run([str(binary)], env={**os.environ, 'CODEX_HOME':folder}, check=True)
