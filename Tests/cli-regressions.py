#!/usr/bin/env python3
"""Exercise the native CLI with private temporary snapshots; never launch the app."""
import datetime
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[1]
shared = [root / 'Sources/Shared/BuildChannel.swift', root / 'Sources/Shared/CLISnapshot.swift', root / 'Sources/Shared/CLIControl.swift', root / 'Sources/Shared/AppPresentation.swift']
cli = sorted((root / 'Sources/CLI').glob('*.swift'))
now = datetime.datetime.now(datetime.timezone.utc)
snapshot = {
    'schemaVersion': 1, 'channel': 'dev', 'appVersion': '1.0.0', 'pid': 123456,
    'updatedAt': now.isoformat().replace('+00:00', 'Z'),
    'sessions': [dict(id=f'c-{i}', agent='claude', pid=i + 100, status='busy' if i % 2 else 'idle',
                      model='opus', project='测试项目', activity='Read', contextTokens=50, contextLimit=100,
                      contextPercent=50, isSubagent=False) for i in range(12)]
        + [dict(id='codex-main', agent='codex', status='waiting', model='gpt', project='matrix',
                activity='Confirm', contextPercent=25, isSubagent=False),
           dict(id='codex-helper', agent='codex', status='busy', model='gpt', project='matrix',
                activity='Read', isSubagent=True, parentID='codex-main'),
           dict(id='cursor-main', agent='cursor', status='idle', model='', project='ide', activity='', isSubagent=False)],
    'usage': {'period': '本月', 'tokens': 9999, 'todayTokens': 123, 'todayCalls': 4,
              'loading': False, 'models': [{'model': 'opus', 'tokens': 9999}]},
    'providers': [{'agent': 'claude', 'name': 'Test provider', 'active': True, 'model': 'opus'}],
    'quota': [{'label': '5h', 'usedPercent': 20}], 'quotaLoading': False,
    'vpn': {'state': 'idle', 'enabled': False, 'systemProxy': False, 'tun': False, 'mixedPort': 17890},
    'proxy': {'running': False, 'port': 15722},
    'connectors': [{'name': 'test', 'kind': 'skill', 'platforms': ['claude'], 'enabled': True}],
    'connectorsScanned': True, 'connectorsLoading': False,
    'charge': {'mode': 'system', 'limit': 80, 'status': 'system'}
}

with tempfile.TemporaryDirectory(prefix='claudebar-cli-') as temporary:
    temp = Path(temporary)
    version = temp / 'CLIVersion.swift'
    version.write_text('enum CLIVersion { static let value = "1.0.0" }')
    fixture = temp / 'snapshot.json'
    fixture.write_text(json.dumps(snapshot))
    binary = temp / 'claudebar-dev'
    subprocess.run(['swiftc', '-O', '-parse-as-library', '-D', 'CLAUDEBAR_DEV',
                    *map(str, shared + cli), str(version), '-framework', 'AppKit', '-framework', 'IOKit',
                    '-o', str(binary)], check=True)

    def run(*args, code=0):
        result = subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=20,
                                env=dict(os.environ, NO_COLOR='1'))
        assert result.returncode == code, (args, result.returncode, result.stderr)
        return result

    def query(*args):
        return run(*args, '--snapshot', str(fixture))

    assert query('count').stdout.strip() == '14'
    assert query('sessions', 'count', '--agent', 'claude').stdout.strip() == '12'
    assert query('count', '--include-subagents').stdout.strip() == '15'
    assert query('count', '--status', 'busy').stdout.strip() == '6'
    assert query('count', '--status', 'waiting').stdout.strip() == '1'
    assert query('sessions', '--count', '--agent', 'codex').stdout.strip() == '1'
    report = json.loads(query('sessions', '--json', '--limit', '2').stdout)
    assert report['counts']['total'] == 14 and len(report['sessions']) == 2
    assert report['counts']['byAgent'] == {'claude': 12, 'codex': 1, 'cursor': 1}
    assert report['freshness'] == 'archived'
    text = query('sessions', '--plain').stdout
    assert 'TOTAL 14' in text and '\x1b' not in text and 'CLAUDE/111' in text
    for command, key in [('usage', 'usage'), ('vpn', 'vpn'), ('proxy', 'proxy'), ('providers', 'providers'),
                         ('quota', 'quota'), ('connectors', 'connectors'), ('config', 'charge')]:
        assert key in json.loads(query(command, '--json').stdout)
    assert json.loads(query('usage', '--json').stdout)['usage']['todayTokens'] == 123
    # New local commands remain useful without an application snapshot.
    for command in ['date', 'calendar', 'greet', 'commands']:
        report = json.loads(run(command, '--snapshot', str(temp / 'missing'), '--json').stdout)
        assert report['freshness'] == 'unavailable'
        if command == 'commands':
            assert {'weather', 'agents', 'alerts', 'cpu', 'calendar'} <= set(report['commands'])
        else:
            assert report['date']['timezone'] and report['greeting']
    for command in ['cpu', 'gpu', 'memory', 'disk', 'battery', 'network', 'uptime']:
        assert command in run('commands', '--json').stdout
    agents = json.loads(query('agents', '--json').stdout)['agents']
    codex = next(row for row in agents if row['agent'] == 'codex')
    assert codex == dict(agent='codex', main=1, subagents=1, busy=0, waiting=1, idle=0)
    assert json.loads(query('models', '--json').stdout)['models'][0]['model'] == 'opus'
    alerts = json.loads(query('alerts', '--json').stdout)['alerts']
    assert any('awaiting confirmation' in row['message'] for row in alerts)
    assert json.loads(query('weather', '--json').stdout)['weatherAvailable'] is False
    assert 'N/A' in query('weather').stdout
    weather = dict(place='上海', temperatureC=22, feelsLikeC=21, condition='晴', highC=25, lowC=18,
                   humidity=55, windKph=8, windDirection='NE', sunrise='06:00', sunset='17:30', rainChance=10,
                   observedAt=now.isoformat(), fetchedAt=now.isoformat(), timezone='Asia/Shanghai', source='fixture',
                   forecast=[dict(date=now.isoformat(), highC=25, lowC=18, rainChance=10)])
    snapshot['weather'] = weather
    snapshot['greeting'] = '欢迎回到矩阵'
    fixture.write_text(json.dumps(snapshot))
    report = json.loads(query('weather', '--json').stdout)
    assert report['weatherAvailable'] is True and report['weatherStale'] is False
    assert '上海' in query('weather').stdout and '06:00' in query('weather').stdout
    assert report['weather']['forecast'][0]['rainChance'] == 10
    assert 'latitude' not in report['weather'] and 'longitude' not in report['weather']
    weather['fetchedAt'] = (now - datetime.timedelta(hours=1)).isoformat()
    fixture.write_text(json.dumps(snapshot))
    assert json.loads(query('weather', '--json').stdout)['weatherStale'] is True
    assert 'STALE' in query('weather').stdout
    weather['fetchedAt'] = now.isoformat()
    fixture.write_text(json.dumps(snapshot))
    assert '欢迎回到矩阵' in query('status', '--compact').stdout
    assert 'MTX' in run('help').stdout and '--compact' in run('help').stdout
    run('weather', 'invalid', code=2)
    run('weather', 'refresh', '--watch', code=2)
    run('commands', '--watch', code=2)
    watched = query('sessions', '--json', '--watch', '--samples', '2', '--interval', '0.5').stdout.splitlines()
    assert len(watched) == 2 and all(json.loads(row)['counts']['total'] == 14 for row in watched)
    shorthand = query('s', '-w', '1', '-j', '-n', '2').stdout.splitlines()
    assert len(shorthand) == 2 and all(json.loads(row)['counts']['total'] == 14 for row in shorthand)
    timestamps = [datetime.datetime.fromisoformat(json.loads(row)['capturedAt'].replace('Z', '+00:00')) for row in shorthand]
    assert (timestamps[1] - timestamps[0]).total_seconds() >= 0.8
    assert query('s', 'c', '-a', 'codex').stdout.strip() == '1'
    assert json.loads(run('cmd', '-j').stdout)['aliases']['cn'] == 'connectors'
    # The exact requested form watches the whole panel and emits one JSON line per frame.
    assert len(query('-w', '1', '-j', '-n', '2').stdout.splitlines()) == 2
    # A downstream consumer (head/jq) closing stdout must not raise an ObjC exception.
    pipe = subprocess.Popen([str(binary), 'sessions', '--snapshot', str(fixture), '--json', '--watch',
                             '--samples', '3', '--interval', '0.5'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert json.loads(pipe.stdout.readline())['counts']['total'] == 14
    pipe.stdout.close()
    assert pipe.wait(timeout=10) == -signal.SIGPIPE
    assert not pipe.stderr.read()
    for args in [('start', '--watch'), ('stop', '--watch'), ('open', 'invalid'), ('--interval', 'nan'),
                 ('--interval', '0'), ('sessions', '--agent', 'other'), ('--samples', '0'),
                 ('sessions', '--status', 'unknown'), ('usage', '--count'), ('unknown',), ('sessions', '--limit', '0')]:
        run(*args, code=2)
    failure = run('sessions', '--json', '--snapshot', str(temp / 'missing'), code=3)
    assert not failure.stdout and json.loads(failure.stderr)['exitCode'] == 3
    bad = dict(snapshot, channel='release')
    fixture.write_text(json.dumps(bad))
    run('count', '--snapshot', str(fixture), code=3)
    bad = dict(snapshot, schemaVersion=999)
    fixture.write_text(json.dumps(bad))
    assert 'schema' in run('count', '--snapshot', str(fixture), code=3).stderr
    fixture.write_text('{')
    assert 'malformed' in run('count', '--snapshot', str(fixture), code=3).stderr
    fixture.write_text(json.dumps(snapshot))
    for shell in ['bash', 'zsh', 'fish']:
        completion = run('completion', shell).stdout
        assert 'mtx-dev' in completion and 'claudebar-dev' in completion and 'sessions' in completion and 'weather' in completion
        assert 'sess' in completion and 'cn' in completion
        assert ('-s w' if shell == 'fish' else '-w') in completion
        if shell in ['bash', 'zsh']:
            script = temp / f'completion.{shell}'
            script.write_text(completion)
            subprocess.run([shell, '-n', str(script)], check=True)
    # The lifecycle gate rejects a different channel before any launch.
    wrong_app = temp / 'ClaudeBar.app'
    (wrong_app / 'Contents/MacOS').mkdir(parents=True)
    executable = wrong_app / 'Contents/MacOS/ClaudeBar'
    executable.write_text('#!/bin/sh\nexit 99\n'); executable.chmod(0o755)
    (wrong_app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'com.claudebar.app', 'ClaudeBarBuildChannel': 'release',
        'CFBundleExecutable': 'ClaudeBar', 'CFBundlePackageType': 'APPL'}))
    run('start', '--app', str(wrong_app), code=4)
    # Interactive cleanup must run on Ctrl-C, without leaving the cursor hidden.
    import pty
    master, slave = pty.openpty()
    process = subprocess.Popen([str(binary), 'sessions', '--snapshot', str(fixture), '--watch', '--interval', '0.5'],
                               stdin=slave, stdout=slave, stderr=slave, env=dict(os.environ, TERM='xterm-256color'))
    os.close(slave)
    import threading
    chunks = []
    ready = threading.Event()
    def drain():
        try:
            while True:
                chunk = os.read(master, 65536)
                if not chunk: break
                chunks.append(chunk)
                if b'AGENT SESSIONS' in b''.join(chunks): ready.set()
        except OSError:
            pass
    reader = threading.Thread(target=drain, daemon=True)
    reader.start()
    try:
        assert ready.wait(10), 'watch never rendered'
        process.send_signal(signal.SIGINT)
        assert process.wait(timeout=10) == 130
        reader.join(timeout=2)
    finally:
        if process.poll() is None:
            process.kill()  # Only this fixture process; never an app or VPN.
            process.wait()
        os.close(master)
    output = b''.join(chunks)
    assert b'\x1b[?25h' in output and b'\x1b[?1049l' in output, output


    # Exercise the real event loop in a small PTY; fixtures only, no running app/control socket.
    import fcntl
    import select
    import struct
    import termios
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 18, 100, 0, 0))
    original_settings = termios.tcgetattr(slave)
    process = subprocess.Popen([str(binary), 's', '--snapshot', str(fixture), '-w', '0.5'],
                               stdin=slave, stdout=slave, stderr=slave,
                               env=dict(os.environ, TERM='xterm-256color'))
    captured = bytearray()
    def wait_for(needle, start=0, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if needle in captured[start:]: return
            readable, _, _ = select.select([master], [], [], .1)
            if readable:
                try: captured.extend(os.read(master, 65536))
                except OSError: break
        assert needle in captured[start:], (needle, bytes(captured[start:]))
    def send(text, needle):
        start = len(captured)
        os.write(master, text)
        wait_for(needle, start)
    try:
        wait_for(b'CLAUDE/100')
        assert b'CURSOR/cursor-m' not in captured  # Below the initial viewport.
        assert termios.tcgetattr(slave)[3] & termios.ICANON == 0
        send(b'G', b'CURSOR/cursor-m')
        send(b'\r', b'SESSION cursor-main')
        send(b'\x1b', b'CURSOR/cursor-m')
        send(b'/matrix\r', b'1 rows')
        send(b'\r', b'SESSION codex-main')
        send(b'\x1b', b'CODEX/codex-ma')
        send(b' ', b'PAUSED')
        snapshot['sessions'][12]['project'] = 'fresh-after-pause'
        fixture.write_text(json.dumps(snapshot))
        # Refresh remains active while the visible frame is frozen.
        time.sleep(.8)
        send(b'm', b'\x1b[?1006l')
        assert b'fresh-after-pause' not in captured
        send(b' ', b'0 rows')  # Search matrix no longer matches in the newly loaded frame.
        send(b'\x1b', b'14 rows')  # Clear this page's search.
        send(b'm', b'\x1b[?1006h')
        send(b'\x1b[<65;2;8M', b'4-14/14')
        send(b':vpn pv\r', b'Archived snapshot views cannot control')
        send(b'?', b'MTX INTERACTIVE TERMINAL')
        mark = len(captured)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 10, 45, 0, 0))
        process.send_signal(signal.SIGWINCH)
        wait_for(b'\x1b[2J', mark)
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=10) == 130
        while select.select([master], [], [], .1)[0]:
            try:
                chunk = os.read(master, 65536)
                if not chunk: break
                captured.extend(chunk)
            except OSError: break
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            process.wait(timeout=10)
        restored = termios.tcgetattr(slave)
        restored[3] &= ~termios.PENDIN  # Darwin marks queued canonical input for reprocessing.
        original_settings[3] &= ~termios.PENDIN
        assert restored == original_settings
        os.close(slave); os.close(master)
    assert process.returncode == 130
    assert all(sequence in captured for sequence in [b'\x1b[?1006l', b'\x1b[?2004l', b'\x1b[?25h', b'\x1b[?1049l'])

    for finite in [False, True]:
        master, slave = pty.openpty()
        original_settings = termios.tcgetattr(slave)
        process = subprocess.Popen([str(binary), 's', '--snapshot', str(fixture), '-w', '.5'] + (['-n', '2'] if finite else []),
                                   stdin=slave, stdout=slave, stderr=slave, env=dict(os.environ, TERM='xterm-256color'))
        output = bytearray(); deadline = time.monotonic() + 10; sent = False
        try:
            while time.monotonic() < deadline:
                if select.select([master], [], [], .1)[0]:
                    output.extend(os.read(master, 65536))
                if not finite and b'CLAUDE/100' in output and not sent:
                    os.write(master, b'q'); sent = True
                if process.poll() is not None: break
            assert process.wait(timeout=2) == 0
            while select.select([master], [], [], .1)[0]:
                chunk = os.read(master, 65536)
                if not chunk: break
                output.extend(chunk)
            restored = termios.tcgetattr(slave)
            restored[3] &= ~termios.PENDIN; original_settings[3] &= ~termios.PENDIN
            assert restored == original_settings
            assert b'\x1b[?2004l' in output and b'\x1b[?1049l' in output
        finally:
            if process.poll() is None:
                process.kill(); process.wait()  # Only this isolated CLI fixture.
            os.close(slave); os.close(master)

    # Direct production renderer tests with synthetic host telemetry (no hardware reads).
    harness = temp / 'Renderer.swift'
    harness.write_text(r'''
import Foundation
import Darwin
@main struct Probe {
    static func main() throws {
        _ = setlocale(LC_CTYPE, "en_US.UTF-8")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var snapshot = try decoder.decode(CLISnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        snapshot.sessions[0].project = "\u{1B}]2;attack\u{7}\nspoof"
        snapshot.vpn.state = "\u{1B}[2Jspoof"
        let host = CLISystem(sampledAt: Date(), hostname: "test", os: "macOS", chip: "Apple", cores: 8,
            uptimeSeconds: 500, cpuPercent: 50, gpuPercent: nil, memoryUsedBytes: 8 * 1024 * 1024 * 1024,
            memoryTotalBytes: 16 * 1024 * 1024 * 1024, diskAvailableBytes: 100 * 1024 * 1024 * 1024,
            diskTotalBytes: 200 * 1024 * 1024 * 1024, loadAverage: [1, 2, 3])
        var frame = CLIFrame(snapshot: snapshot, running: false, archived: false, system: host)
        precondition(frame.freshness == "stale")
        frame.running = true; snapshot.updatedAt = Date(); frame.snapshot = snapshot
        precondition(frame.freshness == "fresh")
        frame.snapshotProcessMatches = false
        precondition(frame.freshness == "stale")
        frame.snapshotProcessMatches = true
        snapshot.updatedAt = Date().addingTimeInterval(120); frame.snapshot = snapshot
        precondition(frame.freshness == "invalid-clock")
        snapshot.updatedAt = Date().addingTimeInterval(-120); frame.snapshot = snapshot
        precondition(frame.freshness == "stale")
        precondition(CLITerminal.cells("中文") == 4)
        precondition(CLITerminal.cells("👨‍👩‍👧‍👦") == 2)
        precondition(CLITerminal.bytes(Double(8 * 1024 * 1024 * 1024)) == "8.0 GiB")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let leapDay = ISO8601DateFormatter().date(from: "2024-02-29T12:00:00Z")!
        let day = CLILifestyle(date: leapDay, calendar: calendar)
        precondition(day.daysInYear == 366 && day.dayOfYear == 60 && day.word == "AFTERNOON")
        let month = day.month(CLITerminal(width: 100, height: 40, color: false, ascii: true, plain: false)).joined(separator: "\n")
        precondition(month.contains("[29]") && !month.contains(" 30 "))
        for width in [32, 64, 100] {
            let terminal = CLITerminal(width: width, height: 40, color: false, ascii: true, plain: false)
            let text = CLIRenderer(terminal: terminal, options: .init()).render(frame)
            precondition(!text.contains("\u{1B}"))
            precondition(text.components(separatedBy: "\n").allSatisfy { CLITerminal.cells($0) <= width })
            if width == 100 { precondition(text.contains("8.0 GiB / 16.0 GiB")) }
            for command in ["date", "calendar", "greet", "weather", "agents", "models", "alerts", "commands", "cpu", "gpu", "memory", "disk", "battery", "network", "uptime"] {
                let options = try CLIOptions.parse([command])
                let output = CLIRenderer(terminal: terminal, options: options).render(frame)
                precondition(output.components(separatedBy: "\n").allSatisfy { CLITerminal.cells($0) <= width })
                precondition(!output.contains("\u{1B}"))
            }
            for hour in [0, 6, 13, 19] {
                frame.capturedAt = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: leapDay)!
                for color in [false, true] {
                    var styled = terminal; styled.color = color
                    let screen = CLIRenderer(terminal: styled, options: .init()).render(frame)
                    let visible = screen.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
                    precondition(visible.components(separatedBy: "\n").allSatisfy { CLITerminal.cells($0) <= width })
                    if color && width == 100 {
                        precondition(screen.contains("38;5;183") && screen.contains("38;5;75") && screen.contains("38;5;221"))
                    }
                }
            }
            let vpnOptions = try CLIOptions.parse(["vpn"])
            let vpn = CLIRenderer(terminal: terminal, options: vpnOptions).render(frame)
            precondition(!vpn.contains("\u{1B}"))
        }

        var catalog = CLITUIState(command: "models")
        catalog.receive(frame)
        let providerReply = CLIControl.response(.init(command: "providers", arguments: ["catalog"]), message: "Catalog", result: ["providers": [
            ["id": "p-1", "name": "Provider One", "agent": "claude", "active": true,
             "models": [["id": "m-1", "name": "Model One", "active": true]]]]])
        precondition(catalog.receiveCatalog(providerReply) && catalog.page == "models")
        let catalogRows = catalog.rows(options: .init(), terminal: .init(width: 100, height: 30, color: false, ascii: false, plain: false))
        precondition(catalogRows.count == 3 && catalogRows.last!.detail.contains("ID: m-1"))
        let nodeReply = CLIControl.response(.init(command: "vpn", arguments: ["preview"]), message: "Preview", result: ["source": "subscription",
            "nodes": [["name": "Hong Kong 01"]], "groups": [["name": "Main", "nodes": ["Hong Kong 01"]]]])
        precondition(catalog.receiveCatalog(nodeReply) && catalog.page == "vpn")
        catalog.viewports["vpn"] = .init(query: "Hong Kong")
        precondition(catalog.rows(options: .init(), terminal: .init(width: 100, height: 30, color: false, ascii: false, plain: false)).count == 1)

        // Decode split UTF-8 and split escape reports; pasted CR must never submit a command.
        var input = CLITUIInput()
        precondition(input.feed([27, 91]).isEmpty)
        precondition(input.feed([65]) == [.up])
        precondition(input.feed(Array("\u{1B}[<65;9;5M".utf8)) == [.mouse(65, 9, 5, false)])
        precondition(input.feed([27, 91, 77, 96, 113]).isEmpty)
        precondition(input.feed([37]) == [.mouse(64, 81, 5, false)])
        precondition(input.feed([27]).isEmpty)
        precondition(input.feed([], flushEscape: true) == [.escape])
        let chinese = Array("中".utf8)
        precondition(input.feed(Array(chinese.prefix(1))).isEmpty)
        precondition(input.feed(Array(chinese.dropFirst())) == [.text("中")])
        let paste = input.feed(Array("\u{1B}[200~vpn off\r\u{1B}[201~".utf8))
        precondition(!paste.contains(.enter))
        precondition(paste.allSatisfy { if case .paste = $0 { return true }; return false })
        precondition(input.feed([255, 113]) == [.text("q")])
        let argv = try CLITUIState.arguments("vpn s 'Hong Kong 01' --group \"Main group\"")
        precondition(argv == ["vpn", "s", "Hong Kong 01", "--group", "Main group"])
        let literalArgv = try CLITUIState.arguments("cn s '$(touch secret)' " )
        precondition(literalArgv == ["cn", "s", "$(touch secret)"])
        do { _ = try CLITUIState.arguments("vpn s 'broken"); preconditionFailure() } catch {}
        var viewport = CLITUIViewport()
        let records = (0..<30).map { CLITUIRow(id: "id-\($0)", text: "record \($0)") }
        viewport.reconcile(records, height: 5); viewport.move(12, rows: records, height: 5)
        precondition(viewport.selected == "id-12" && viewport.offset == 8)
        var inserted = [CLITUIRow(id: "new", text: "new")] + records
        viewport.reconcile(inserted, height: 5)
        precondition(viewport.selected == "id-12" && viewport.offset == 9 && viewport.top == "id-8")
        inserted.removeAll { $0.id == "id-12" }
        viewport.reconcile(inserted, height: 5)
        precondition(viewport.selected == "id-8")
        viewport.scroll(100, rows: inserted, height: 5)
        precondition(viewport.offset == inserted.count - 5)
        viewport.reconcile([], height: 5); precondition(viewport.offset == 0 && viewport.selected == nil)
        var tui = CLITUIState(command: "sessions")
        tui.receive(frame); let beforePause = tui.frame!.capturedAt
        tui.togglePause(latest: frame)
        var next = frame; next.capturedAt = frame.capturedAt.addingTimeInterval(20)
        next.system!.cpuPercent = 99; tui.receive(next)
        precondition(tui.frame!.capturedAt == beforePause)
        tui.togglePause(latest: next); precondition(tui.frame!.capturedAt == next.capturedAt)
        for _ in 0..<100 { tui.receive(next) }; precondition(tui.history.count == 60)
        tui.viewports["sessions"] = .init(query: "matrix")
        precondition(tui.rows(options: .init(), terminal: .init(width: 100, height: 20, color: false, ascii: false, plain: false)).isEmpty)
        tui.viewports["sessions"] = .init()
        tui.modal = ["A long detail / 中文 / 👨‍👩‍👧‍👦 " + String(repeating: "Long path ", count: 30)]
        for width in [1, 12, 45, 100] {
            for height in [1, 7, 18, 40] {
                let screen = tui.screen(options: .init(), terminal: .init(width: width, height: height, color: true, ascii: false, plain: false))
                precondition(screen.count == height)
                precondition(screen.allSatisfy { CLITerminal.cells(CLITUIState.plain($0)) <= max(1, width - 1) })
            }
        }
        tui.modal = nil
        for page in CLITUIState.pages {
            tui.page = page
            for width in [12, 45, 64, 65, 66, 100] {
                let terminal = CLITerminal(width: width, height: 18, color: true, ascii: false, plain: false)
                let screen = tui.screen(options: .init(), terminal: terminal)
                precondition(screen.count == 18 && screen.allSatisfy { CLITerminal.cells(CLITUIState.plain($0)) <= width - 1 })
                let rows = tui.rows(options: .init(), terminal: CLITUIState.bodyTerminal(terminal))
                precondition(rows.contains { $0.id == tui.viewports[page]?.top })
            }
        }
        var diff = CLITUIDiff()
        precondition(diff.draw(["a", "b"], width: 30).contains("\u{1B}[2J"))
        precondition(diff.draw(["a", "b"], width: 30).isEmpty)
        let changed = diff.draw(["a", "c"], width: 30)
        precondition(changed.contains("\u{1B}[2;1H") && !changed.contains("\u{1B}[1;1H") && !changed.contains("\u{1B}[2J"))
        precondition(diff.draw(["a", "c"], width: 20).contains("\u{1B}[2J"))
        print("PASS: TUI input, stable viewport, pause, command quoting, Unicode clipping and incremental rendering")
        print("PASS: renderer width, CJK, telemetry, injection defense and freshness")
    }
}
''')
    renderer = temp / 'renderer'
    renderer_sources = shared + [path for path in cli if path.name not in ['ClaudeBarCLI.swift', 'CLIControlClient.swift', 'CLITUIRuntime.swift']]
    subprocess.run(['swiftc', '-O', '-parse-as-library', *map(str, renderer_sources), str(harness),
                    '-framework', 'AppKit', '-framework', 'IOKit', '-o', str(renderer)], check=True)
    subprocess.run([str(renderer), str(fixture)], check=True)

    # The real publisher coalesces ticks into a private atomic file off-main.
    writer = temp / 'Writer.swift'
    publisher = (root / 'Sources/ClaudeBar/Models/CLISnapshotPublisher.swift').read_text().split('extension ProviderStore')[0]
    writer.write_text(publisher + r'''
@main struct WriterProbe {
    static func main() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var value = try decoder.decode(CLISnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let destination = URL(fileURLWithPath: CommandLine.arguments[2])
        for index in 0..<100 {
            value.pid = index
            CLISnapshotPublisher.submit(value, to: destination)
        }
        let deadline = Date().addingTimeInterval(5)
        var latest = false
        while Date() < deadline {
            if let data = try? Data(contentsOf: destination),
               let snapshot = try? decoder.decode(CLISnapshot.self, from: data), snapshot.pid == 99 {
                latest = true; break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        precondition(latest, "latest snapshot was dropped")
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        precondition(!FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).contains { $0.hasSuffix(".tmp") })
        print("PASS: bounded publisher retains latest tick, atomic JSON and owner-only mode")
    }
}
'''.replace('precondition(!FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).contains',
                'let remaining = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)\n        precondition(!remaining.contains'))
    writer_binary = temp / 'writer'
    subprocess.run(['swiftc', '-O', '-parse-as-library', *map(str, shared),
                    str(root / 'Sources/ClaudeBar/Utils/PrivateFileWriter.swift'), str(writer), '-o', str(writer_binary)], check=True)
    subprocess.run([str(writer_binary), str(fixture), str(temp / 'cli-status.json')], check=True)

    install_root = temp / 'install-project'
    (install_root / 'Tools').mkdir(parents=True)
    (install_root / 'Sources').mkdir()
    import shutil
    shutil.copy(root / 'Tools/install-cli.sh', install_root / 'Tools/install-cli.sh')
    shutil.copy(root / 'Sources/build-config.sh', install_root / 'Sources/build-config.sh')
    home = temp / 'home'
    destination = home / '.local/bin'
    destination.mkdir(parents=True)
    for channel, name, canonical in [('dev', 'mtx-dev', 'claudebar-dev'), ('release', 'mtx', 'claudebar')]:
        app_name = 'ClaudeBar Dev' if channel == 'dev' else 'ClaudeBar'
        source = install_root / '.build' / channel / (app_name + '.app') / 'Contents/Helpers' / canonical
        source.parent.mkdir(parents=True)
        source.write_text('#!/bin/sh\nexit 0\n'); source.chmod(0o755)
        alias = destination / name
        alias.write_text('other command')
        result = subprocess.run(['bash', str(install_root / 'Tools/install-cli.sh'), channel],
                                env=dict(os.environ, HOME=str(home)), capture_output=True)
        assert result.returncode != 0 and alias.read_text() == 'other command'
        assert not (destination / canonical).exists(), 'collision created a partial install'
        alias.unlink()
        for attempt in range(2):
            subprocess.run(['bash', str(install_root / 'Tools/install-cli.sh'), channel],
                           env=dict(os.environ, HOME=str(home)), check=True, capture_output=True)
        assert alias.is_symlink() and alias.resolve() == source.resolve()
        assert (destination / canonical).resolve() == source.resolve()
    publisher_source = (root / 'Sources/ClaudeBar/Models/CLISnapshotPublisher.swift').read_text()
    assert 'String(describing: vpn.state)' not in publisher_source and 'case .failed: vpnState = "failed"' in publisher_source
    route = (root / 'Sources/ClaudeBar/ClaudeBarApp.swift').read_text().split('case "/weather-refresh":')[1].split('case "/refresh":')[0]
    assert 'refreshCityForCLI' in route and 'requestFix' not in route
    city_fetch = (root / 'Sources/ClaudeBar/Utils/WeatherFetcher.swift').read_text().split('func refreshCityForCLI() {')[1].split('    /// Location failed')[0]
    assert 'guard inflight == nil' in city_fetch and 'fetch(query: city' in city_fetch
    assert 'refresh()' not in city_fetch and 'rerun' not in city_fetch and 'requestFix' not in city_fetch
    # A release CLI has a separate identity and cannot read a dev snapshot.
    release = temp / 'claudebar'
    subprocess.run(['swiftc', '-O', '-parse-as-library', '-D', 'CLAUDEBAR_RELEASE', *map(str, shared + cli),
                    str(version), '-framework', 'AppKit', '-framework', 'IOKit', '-o', str(release)], check=True)
    version_json = subprocess.check_output([str(release), 'version', '--json'], text=True)
    assert json.loads(version_json)['channel'] == 'release'
    result = subprocess.run([str(release), 'count', '--snapshot', str(fixture)], capture_output=True)
    assert result.returncode == 3

print('PASS: CLI counts, filters, full inventory, JSON/NDJSON, terminal cleanup, channel and lifecycle gates')
