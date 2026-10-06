#!/usr/bin/env python3
"""Exercise the production monitor with an isolated index and rollout fixtures."""
from pathlib import Path
import subprocess, tempfile, sqlite3, json, os, time
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='claudebar-codex-') as folder:
    work = Path(folder)
    db = sqlite3.connect(work / 'state_5.sqlite')
    db.execute('CREATE TABLE threads (id TEXT, rollout_path TEXT, cwd TEXT, created_at INTEGER, updated_at INTEGER, source TEXT, archived INTEGER, title TEXT, model TEXT)')
    now = int(time.time())
    def thread(name, *, age=0, archived=0, child=False, missing=False, open_turn=False, malformed=False, source='vscode', model=''):
        path = work / 'sessions' / (name + '.jsonl')
        path.parent.mkdir(exist_ok=True)
        if child:
            source = {'subagent': {'thread_spawn': {'parent_thread_id': 'idle', 'depth': 1}}}
        if not missing:
            meta = {'type': 'session_meta', 'payload': {'cwd': '/tmp/project', 'source': source}}
            event = {'type': 'event_msg', 'payload': {'type': 'task_started' if open_turn else 'task_complete'}}
            path.write_text(('invalid\n' if malformed else json.dumps(meta)+'\n')+json.dumps(event)+'\n')
            os.utime(path, (now-age, now-age))
        db.execute('INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?)', (name,str(path),'/tmp/project',now-age,now-age,json.dumps(source) if child else source,archived,'Title '+name,model))
    thread('idle', age=86400*30)
    thread('running', open_turn=True)
    thread('stale-open', age=86400, open_turn=True)
    # The shape a real stuck thread takes (`cxwait2`): indexed, unarchived, one
    # `task_started` and no `task_complete`, and stopped being written. It must
    # stay *listed* — it is a real session the user can resume — but it must not
    # count as running. The holder is what used to make it run forever.
    thread('stalled', age=3600, open_turn=True)
    thread('missing', age=86400, missing=True)
    thread('malformed', age=86400, malformed=True)
    thread('archived', archived=1)
    thread('child', child=True, open_turn=True)
    thread('child-stale', child=True, age=600, open_turn=True)
    thread('exec-once', source='exec', open_turn=True)
    thread('mcp-once', source='mcp')
    # A tool body larger than the 512KB tail hides task_started from the window.
    # 120s is past the 90s recency fallback and inside the 5-minute open-turn
    # window, so only a lookback that actually finds task_started stays running.
    pad = 'x' * 600_000
    def buried(name, events, age, extra=None):
        path = work / 'sessions' / (name + '.jsonl')
        lines = [json.dumps({'type': 'session_meta', 'payload': {'cwd': '/tmp/project', 'source': 'vscode'}})]
        lines.extend(json.dumps(event) for event in events)
        if extra:
            lines.extend(json.dumps(event) for event in extra)
        lines.append(json.dumps({'type': 'response_item', 'payload': {'type': 'custom_tool_call_output', 'output': pad}}))
        path.write_text('\n'.join(lines) + '\n')
        os.utime(path, (now - age, now - age))
        db.execute('INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?)',
                   (name, str(path), '/tmp/project', now - age, now - age, 'vscode', 0, 'Title ' + name, ''))
    call = {'type': 'response_item', 'payload': {'type': 'custom_tool_call', 'name': 'exec'}}
    buried('buried-open', [
        {'type': 'event_msg', 'payload': {'type': 'task_started'}},
        call,
    ], 120)
    buried('buried-done', [
        {'type': 'event_msg', 'payload': {'type': 'task_started'}},
        {'type': 'event_msg', 'payload': {'type': 'task_complete'}},
        call,
    ], 30)
    # The shape finding 46 measured on this machine: the head's 32 KB read
    # (session_meta ~23 KB, then a partial record) ends before the first
    # turn_context, and a body below buries the newest one past the 512 KB
    # tail window — so *both* file routes for `model` return "". The index
    # row's `model` column is the surviving source, and `deep-head`'s is the
    # deeper bounded head read (the only route when there is no index row).
    def long_lived(name, turn_model, index_model, age=30):
        path = work / 'sessions' / (name + '.jsonl')
        lines = [json.dumps({'type': 'session_meta',
                             'payload': {'cwd': '/tmp/project', 'source': 'vscode', 'pad': 'x' * 23_000}})]
        for _ in range(4):
            lines.append(json.dumps({'type': 'response_item',
                                     'payload': {'type': 'custom_tool_call_output', 'output': 'y' * 20_000}}))
        lines.append(json.dumps({'type': 'turn_context', 'payload': {'model': turn_model}}))
        lines.append(json.dumps({'type': 'event_msg', 'payload': {'type': 'task_complete'}}))
        # One record larger than the tail window, so the window holds no
        # turn_context at all.
        lines.append(json.dumps({'type': 'response_item',
                                 'payload': {'type': 'custom_tool_call_output', 'output': 'z' * 700_000}}))
        path.write_text('\n'.join(lines) + '\n')
        os.utime(path, (now - age, now - age))
        db.execute('INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?)',
                   (name, str(path), '/tmp/project', now - age, now - age, 'vscode', 0, 'Title ' + name, index_model))
    long_lived('long-lived', turn_model='gpt-hidden', index_model='gpt-6.1-sol', age=30)
    long_lived('deep-head', turn_model='gpt-deep', index_model='', age=20)
    # …and the other direction: when the tail window *can* see the newest
    # turn_context, it outranks the index row — a thread that switched models
    # mid-life must show the model it is on now.
    switched = work / 'sessions' / 'switched.jsonl'
    switched.write_text('\n'.join([
        json.dumps({'type': 'session_meta', 'payload': {'cwd': '/tmp/project', 'source': 'vscode'}}),
        json.dumps({'type': 'turn_context', 'payload': {'model': 'gpt-old'}}),
        json.dumps({'type': 'event_msg', 'payload': {'type': 'task_complete'}}),
        json.dumps({'type': 'turn_context', 'payload': {'model': 'gpt-new'}}),
    ]) + '\n')
    os.utime(switched, (now - 10, now - 10))
    db.execute('INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?)',
               ('switched', str(switched), '/tmp/project', now - 10, now - 10, 'vscode', 0, 'Title switched', 'gpt-old'))
    db.commit()
    harness = work / 'Main.swift'
    harness.write_text('''import Foundation
    enum UsageStats { static func formatContext(_ n: Int) -> String { String(n) } }
    // `ExternalAgentKind.rootDir` gates on the build channel. Every fixture in
    // this file drives the *release* shape — it points `CODEX_HOME` at its own
    // tree and expects `rootDir` to honour it — so the channel is stated as
    // release rather than sliced. `FilePaths` is named by the other branch and
    // must resolve for the file to compile.
    enum BuildChannel { static let allowsSystemIntegration = true }
    enum FilePaths { static let codexDir = URL(fileURLWithPath: "/nonexistent") }
    @main struct Regression {
        static func main() {
            let sessions = ExternalSessionMonitor.fetchActive()
            let ids = Set(sessions.map(\\.sessionId))
            precondition(ids == Set(["idle", "running", "stale-open", "stalled", "missing", "malformed", "buried-open", "buried-done", "long-lived", "deep-head", "switched"]), "Unarchived main threads must remain visible: \\(ids)")
            precondition(sessions.filter(\\.isActive).map(\\.sessionId) == ["running", "buried-open"],
                         "an open turn behind a huge tool body stays running: \\(sessions.filter(\\.isActive).map(\\.sessionId))")
            precondition(sessions.first { $0.sessionId == "buried-open" }?.currentActivity == "exec",
                         "the tool call behind that body is the activity line")
            precondition(sessions.first { $0.sessionId == "buried-done" }?.isActive == false,
                         "a completion behind a huge tool body is still a completion")
            // Every open turn that stopped advancing is offered for cleanup —
            // both the hours-old one and the day-old one. `idle`, `missing` and
            // `malformed` have no open turn at all, so they are never cleanup
            // candidates however old they are.
            precondition(sessions.filter(\\.hasStalledTurn).map(\\.sessionId).sorted() == ["stale-open", "stalled"],
                         "a stopped open turn is what cleanup acts on: \\(sessions.filter(\\.hasStalledTurn).map(\\.sessionId))")
            precondition(sessions.allSatisfy { $0.displayName == "Title " + $0.sessionId })
            precondition(sessions.allSatisfy { !$0.isSubagent })

            // The model is what every surface prints as the session's identity
            // (`ExternalSessionCardView` falls back to the cwd, the island drops
            // its "model · 运行中" line, the sessions page prints a placeholder).
            // Precedence: newest `turn_context` in the tail window, then the
            // index row's `model` column, then the deeper head read.
            func model(_ id: String) -> String { sessions.first { $0.sessionId == id }?.model ?? "<missing>" }
            precondition(model("switched") == "gpt-new",
                         "the newest turn_context outranks the index row: \\(model("switched"))")
            precondition(model("long-lived") == "gpt-6.1-sol",
                         "a long-lived rollout takes its model from the index row: \\(model("long-lived"))")
            precondition(model("deep-head") == "gpt-deep",
                         "with no index column, the deeper head read finds the first turn_context: \\(model("deep-head"))")
            for named in ["running", "buried-open"] {
                precondition(model(named) == "",
                             "\\(named)'s rollout carries no turn_context, so no route invents a model: \\(model(named))")
            }

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

            // Codex journals no park: a thread held on an approval is
            // indistinguishable on disk from one whose writer went quiet, so
            // `isWaiting` is deliberately the empty case (see its doc comment,
            // measured against codex-cli 0.159.0). Pin it here so a rollout
            // format that *does* start journaling a park, or a future code
            // path that fabricates one from staleness, fails loudly rather than
            // silently mislabelling every idle thread as parked.
            precondition((scan.main + scan.subagents).allSatisfy { !$0.isWaiting },
                         "no Codex thread may report a park: the rollout carries no such state")

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

            // The file cache re-reads a rollout only when mtime or size moved,
            // and every scan so far saw identical bytes — so a cache that never
            // invalidated would look perfect. Append the turn's terminal event
            // and re-scan: the cached head/tail fields must be dropped, and the
            // thread must now read idle.
            let runningPath = ProcessInfo.processInfo.environment["CODEX_HOME"]! + "/sessions/running.jsonl"
            if let handle = FileHandle(forWritingAtPath: runningPath) {
                handle.seekToEndOfFile()
                handle.write(Data("{\\"type\\":\\"event_msg\\",\\"payload\\":{\\"type\\":\\"task_complete\\"}}\\n".utf8))
                handle.closeFile()
            } else {
                preconditionFailure("the running fixture must be writable")
            }
            let advanced = ExternalSessionMonitor.scan()
            precondition(advanced.main.first { $0.sessionId == "running" }?.isActive == false,
                         "a terminal event appended after a scan must invalidate the file cache")

            print("PASS: idle, stale-open, missing and malformed rollouts retained; archived, exec and mcp threads excluded; running state means a *recently written* open turn, so a stalled one is listed but idle and offered for cleanup; titles; recent sub-agent returned and stale sub-agent dropped; no thread reports a park; 16 overlapping scans agree under the caches' locks; an appended terminal event is seen through the file cache")
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

# The legacy no-index walk is a *separate module of the monitor* and, crucially,
# a separate process: `indexReadAt` memoizes the index for ten seconds, so a
# second scan in the harness above would keep serving the first home's index and
# never reach the fallback (measured: home B with no sqlite still returned home
# A's rows). One rollout tree and no `state_*.sqlite` is all it takes to make
# `readThreadIndex()` return nil.
with tempfile.TemporaryDirectory(prefix='claudebar-codex-legacy-') as legacy_folder:
    legacy = Path(legacy_folder)
    day = legacy / 'sessions' / '2026' / '10' / '02'
    day.mkdir(parents=True)
    (day / 'open-fresh.jsonl').write_text(
        json.dumps({'type': 'session_meta', 'payload': {'cwd': '/tmp/project', 'source': 'vscode'}}) + '\n'
        + json.dumps({'type': 'event_msg', 'payload': {'type': 'task_started'}}) + '\n')
    sub = day / 'sub-fresh.jsonl'
    sub.write_text(
        json.dumps({'type': 'session_meta', 'payload': {'cwd': '/tmp/project',
                     'source': {'subagent': {'thread_spawn': {'parent_thread_id': 'open-fresh', 'depth': 1}}}}}) + '\n'
        + json.dumps({'type': 'event_msg', 'payload': {'type': 'task_started'}}) + '\n')
    harness = legacy / 'Main.swift'
    harness.write_text('''import Foundation
    enum UsageStats { static func formatContext(_ n: Int) -> String { String(n) } }
    // `ExternalAgentKind.rootDir` gates on the build channel. Every fixture in
    // this file drives the *release* shape — it points `CODEX_HOME` at its own
    // tree and expects `rootDir` to honour it — so the channel is stated as
    // release rather than sliced. `FilePaths` is named by the other branch and
    // must resolve for the file to compile.
    enum BuildChannel { static let allowsSystemIntegration = true }
    enum FilePaths { static let codexDir = URL(fileURLWithPath: "/nonexistent") }
    @main struct Regression {
        static func main() {
            let scan = ExternalSessionMonitor.scan()
            precondition(scan.main.map(\\.sessionId) == ["open-fresh"],
                         "the legacy walk must surface a rollout with no thread index: \\(scan.main.map(\\.sessionId))")
            precondition(scan.main.allSatisfy { $0.isActive }, "an open legacy turn reads as running")
            precondition(scan.subagents.map(\\.sessionId) == ["sub-fresh"],
                         "the legacy walk must return sub-agents too: \\(scan.subagents.map(\\.sessionId))")
            precondition(scan.subagents.first?.parentThreadId == "open-fresh",
                         "the legacy child carries its parent id")
            print("PASS: with no thread index, the rollout walk still lists open main threads and sub-agents")
        }
    }''')
    binary = legacy / 'regression'
    subprocess.run(['swiftc','-parse-as-library',
                    str(root/'Sources/ClaudeBar/Utils/ExternalSessionMonitor.swift'),
                    str(root/'Sources/ClaudeBar/Utils/JSONCoerce.swift'),
                    str(root/'Sources/ClaudeBar/Utils/SessionTitle.swift'),
                    str(harness),'-o',str(binary)], check=True)
    subprocess.run([str(binary)], env={**os.environ, 'CODEX_HOME':legacy_folder}, check=True)

    # A second, tiny harness for the holder rule itself.
    #
    # No test here can *be* a holder: `CodexProcessScan.openRollouts()` reads the
# live process table of whatever process runs the fixture, and CI has no
# `codex` executable holding a rollout open, so the holder branch is
# unreachable end to end. That is exactly the branch a stuck thread hangs off,
# so it is exercised by calling the shipped rule with both answers instead of
# faking a holder: a stalled rollout must read idle *either way*, which is the
# property the fix is about, and a freshly written one must read running even
# with no holder at all (the CLI case the rule used to get wrong by ignoring
# non-holders' recency).
with tempfile.TemporaryDirectory(prefix='claudebar-codex-rule-') as folder2:
    work2 = Path(folder2)
    harness = work2 / 'Main.swift'
    harness.write_text('''import Foundation
    enum UsageStats { static func formatContext(_ n: Int) -> String { String(n) } }
    // `ExternalAgentKind.rootDir` gates on the build channel. Every fixture in
    // this file drives the *release* shape — it points `CODEX_HOME` at its own
    // tree and expects `rootDir` to honour it — so the channel is stated as
    // release rather than sliced. `FilePaths` is named by the other branch and
    // must resolve for the file to compile.
    enum BuildChannel { static let allowsSystemIntegration = true }
    enum FilePaths { static let codexDir = URL(fileURLWithPath: "/nonexistent") }
    @main struct Regression {
        static func main() {
            let now = Date().timeIntervalSince1970
            func running(openTurn: Bool?, age: TimeInterval) -> Bool {
                ExternalSessionMonitor.isRunning(openTask: openTurn, updated: now - age, now: now)
            }
            precondition(running(openTurn: true, age: 5) == true, "an open turn still being written is running")
            precondition(running(openTurn: false, age: 5) == false, "a closed turn is never running")
            precondition(running(openTurn: nil, age: 5) == true, "legacy rollout keeps the writer-recency fallback")
            precondition(running(openTurn: nil, age: 3600) == false, "a quiet legacy rollout is not running")
            precondition(running(openTurn: true, age: 3600) == false,
                         "an open turn nobody is writing is NOT running — this is the cxwait2 shape")
            print("PASS: running means a *recently written* open turn, independent of any holder")
        }
    }''')
    binary = work2 / 'regression'
    subprocess.run(['swiftc','-parse-as-library',
                    str(root/'Sources/ClaudeBar/Utils/ExternalSessionMonitor.swift'),
                    str(root/'Sources/ClaudeBar/Utils/JSONCoerce.swift'),
                    str(root/'Sources/ClaudeBar/Utils/SessionTitle.swift'),
                    str(harness),'-o',str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
