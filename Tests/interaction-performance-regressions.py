#!/usr/bin/env python3
"""Production scroll scheduling, cancelled JSON parsing and native playback.
Synthetic payloads and invisible fixture windows; no app or user stores.
Pass --compare to measure SSE parsing against the committed implementation.
"""
from pathlib import Path
import subprocess
import re
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
shared = root / 'Sources/ClaudeBar/Views/Shared'
interaction = (shared / 'Interaction.swift').read_text()
gate = interaction[interaction.index('enum ScrollHoverGate {'):interaction.index('/// Tracks pointer-in')]
# The phase-preserving retime both native layers below call lives in
# `Interaction.swift` now (`CALayer.retime(to:)`); the `GATE` slice would drop
# it, so it is spliced in with the sections that need it.
retime = interaction[interaction.index('// MARK: - Phase-preserving retiming'):interaction.index('// MARK: - Rolling figures')]
json_source = (shared / 'JSONTreeView.swift').read_text()
json_parser = json_source[json_source.index('enum JSONDocument {'):json_source.index('// MARK: - View')]
sse = (root / 'Sources/ClaudeBar/Utils/StreamAssembler.swift').read_text().split('/// Token usage')[0]
power = (shared / 'PowerFlowCard.swift').read_text()
power_layer = power[power.index('private struct SankeyWave:'):]
marks = (root / 'Tests/fixtures/machine-mark-probe.swift').read_text().split('@main struct Probe')[0]
marks = marks.replace('<<<LUCIDE_GEOMETRY>>>', (shared / 'LucideHardwareGeometry.swift').read_text())
marks = marks.replace('<<<LUCIDE_PATHS>>>', (shared / 'LucideHardwarePaths.swift').read_text())
marks = marks.replace('<<<INSTRUMENT_GLYPH>>>', (shared / 'InstrumentGlyph.swift').read_text())
marks = marks.replace('<<<HARDWARE_ILLUSTRATION>>>', (shared / 'HardwareIllustration.swift').read_text())
marks = marks.replace('<<<RETIME>>>', retime)

def method(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    level, end = 1, opening + 1
    while level:
        level += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func')

sampler = (root / 'Sources/ClaudeBar/Utils/ProcessSampler.swift').read_text()
fan = (root / 'Sources/ClaudeBar/Utils/FanMonitor.swift').read_text()
low_load = r'''
import Combine
// Visible state and installer probe only; no hardware or process scan.
enum UIWakePolicy {
    static var hasVisibleWindow = true
    static let subject = PassthroughSubject<Void, Never>()
    static func observe(_ body: @escaping () -> Void) -> AnyCancellable { subject.sink { body() } }
    static func set(_ visible: Bool) { hasVisibleWindow = visible; subject.send() }
}
enum FanHelperInstaller { static func isInstalled() -> Bool { false } }
@MainActor final class FanFixture {
    var subscribers = 0
    var helperInstalled = false
    var timer: Timer?
    var wakeObservation: AnyCancellable?
    var reads = 0
    func refresh() { reads += 1 }
FAN_START
FAN_SYNC
FAN_STOP
}
final class FixtureTimer {
    var schedules = 0
    func schedule(deadline: DispatchTime, repeating: TimeInterval, leeway: DispatchTimeInterval) { schedules += 1 }
}
final class SamplerFixture {
    var timer: FixtureTimer? = FixtureTimer()
    var timerSuspended = false
    var wantsAttribution = true
    var foreground = true
    var live = false
    var period: TimeInterval = 2.5
    var transitions: [Bool] = []
    func setTimerSuspended(_ value: Bool) { transitions.append(value) }
SAMPLER_PERIOD
}
'''
for token, body in [('FAN_START', method(fan, '    func start()')),
                    ('FAN_SYNC', method(fan, '    private func syncPolling()')),
                    ('FAN_STOP', method(fan, '    func stop()')),
                    ('SAMPLER_PERIOD', method(sampler, '    private func applyPeriod()'))]:
    low_load = low_load.replace(token, body)

markdown = (shared / 'SkillMarkdownPreview.swift').read_text()
markdown_slice = (root / 'Sources/ClaudeBar/Models/DocumentMarkup.swift').read_text()
markdown_slice += 'enum MarkdownFixture {\n' + method(markdown, '    nonisolated private static func parse(').replace('private static func', 'static func') + '\n}\n'

benchmark = r'''
func benchmarkSSE() throws {
    let payload = String(repeating: "x", count: 512)
    let raw = (0..<30_000).map { "event: delta\ndata: {\"index\":\($0),\"text\":\"\(payload)\"}\n\n" }.joined()
    let started = CFAbsoluteTimeGetCurrent()
    let doc = try JSONTree.parse(raw)
    guard case .sse(let events, let truncated) = doc else { fatalError("Expected SSE") }
    precondition(events.count == 400 && truncated == 29_600)
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print(String(format: "SSE 30000 × 512 bytes: %.3f s, process peak RSS %.1f MiB",
                 CFAbsoluteTimeGetCurrent() - started, Double(usage.ru_maxrss) / 1_048_576))
}
'''
probe = r'''
import Darwin
POWER_STUB
LOW_LOAD
MARKDOWN
GATE
JSON
SSE
BENCHMARK
actor ParseLatch {
    private var ready = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if ready { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { ready = true; waiter?.resume(); waiter = nil }
}
final class FixtureWindow: NSWindow {
    var shown = true
    override var occlusionState: NSWindow.OcclusionState { shown ? [.visible] : [] }
}
@main struct Regression {
    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(6)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(condition(), "Scheduling effect did not arrive")
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let sampler = SamplerFixture()
        UIWakePolicy.set(false)
        sampler.applyPeriod()
        precondition(sampler.timerSuspended && sampler.transitions == [true],
                     "A mounted scope must not keep hidden telemetry running")
        sampler.applyPeriod()
        precondition(sampler.transitions == [true], "Suspend must be balanced")
        UIWakePolicy.set(true)
        sampler.applyPeriod()
        precondition(!sampler.timerSuspended && sampler.transitions == [true, false])
        precondition(sampler.period == 2 && sampler.timer?.schedules == 1)
        sampler.live = true
        sampler.applyPeriod()
        precondition(sampler.period == 1)
        let fan = FanFixture()
        UIWakePolicy.set(false)
        fan.start(); fan.start()
        precondition(fan.subscribers == 2 && fan.timer == nil && fan.reads == 0)
        UIWakePolicy.set(true)
        precondition(fan.timer != nil && fan.reads == 1)
        let timer = fan.timer
        fan.stop()
        precondition(fan.timer === timer && timer!.isValid)
        UIWakePolicy.set(false)
        precondition(fan.timer == nil && !timer!.isValid)
        UIWakePolicy.set(true)
        precondition(fan.reads == 2 && fan.timer != nil)
        fan.stop()
        precondition(fan.timer == nil && fan.wakeObservation == nil)
        UIWakePolicy.set(false); UIWakePolicy.set(true)
        precondition(fan.reads == 2, "No subscriber may restart polling")

        let a = UUID(), b = UUID()
        var applied: [Int] = []
        ScrollHoverGate.set(true, owner: a)
        for i in 0..<1000 { ScrollHoverGate.afterScroll("reading") { applied.append(i) } }
        ScrollHoverGate.set(true, owner: b)
        ScrollHoverGate.set(false, owner: a)
        // Let the first owner's idle callback land while the second still moves.
        try await Task.sleep(for: .milliseconds(30))
        precondition(applied.isEmpty && ScrollHoverGate.isDeferring)
        ScrollHoverGate.set(false, owner: b)
        await waitUntil { applied == [999] }
        precondition(!ScrollHoverGate.scrolling)

        // A queued idle callback from one gesture must not flush the next.
        ScrollHoverGate.set(true, owner: a)
        ScrollHoverGate.afterScroll("reading") { applied.append(1) }
        ScrollHoverGate.set(false, owner: a)
        ScrollHoverGate.set(true, owner: b)
        ScrollHoverGate.afterScroll("reading") { applied.append(2) }
        try await Task.sleep(for: .milliseconds(30))
        precondition(applied == [999])
        ScrollHoverGate.set(false, owner: b)
        await waitUntil { applied == [999, 2] }

        // Disappearance has the same owner release path as idle; an unrelated
        // view disappearing cannot clear another owner's gesture.
        ScrollHoverGate.set(true, owner: a)
        ScrollHoverGate.set(false, owner: b)
        ScrollHoverGate.afterScroll("deadline") { applied.append(3) }
        await waitUntil { applied.last == 3 }
        precondition(!ScrollHoverGate.isDeferring, "Lost idle must release hover too")
        ScrollHoverGate.set(false, owner: a)

        for count in [0, 1, 399, 400, 401, 1001] {
            let raw = (0..<count).map { "event: delta\r\ndata: {\"index\":\($0)}\r\n\r\n" }.joined()
            let doc = try JSONTree.parse(raw)
            if count == 0 { guard case .empty = doc else { fatalError("Empty stream") }; continue }
            guard case .sse(let events, let truncated) = doc else { fatalError("SSE document") }
            precondition(events.count == min(count, 400) && truncated == max(0, count - 400))
            for (i, event) in events.enumerated() {
                precondition(event.id == i && event.name == "delta")
                precondition(event.raw == "{\"index\":\(truncated + i)}", "Tail order after ring wrap")
            }
        }
        var assembler = LineSSEParser()
        _ = assembler.push(line: "data: {\"value\":42}")
        precondition(assembler.finish()?.json?["value"] as? Int == 42,
                     "Streaming assemblers must keep decoding by default")
        let multiline = try JSONTree.parse("event: delta\ndata: {\"x\":\ndata: 42}\n\ndata: [DONE]")
        guard case .sse(let events, _) = multiline else { fatalError("SSE multiline") }
        precondition(events.count == 2 && events[0].raw == "{\"x\":42}" && events[1].raw == "[DONE]")
        precondition(events[0].node?.children.first?.key == "x", "Retained tail still decodes JSON")
        let unicodePayload = "{\"text\":\"中文 👩🏽‍💻\u{2028}line\u{2029}paragraph\"}"
        let unicodeStream = try JSONTree.parse("data: " + unicodePayload + "\n\ndata: [DONE]")
        guard case .sse(let unicodeEvents, _) = unicodeStream else { fatalError("Unicode SSE") }
        precondition(unicodeEvents.count == 2 && unicodeEvents[0].raw == unicodePayload,
                     "Only LF/CRLF may split lines; Unicode text must survive")
        precondition(unicodeEvents[0].node != nil)
        let array = try JSONTree.parse("{\"items\":[" + (0..<100).map(String.init).joined(separator: ",") + "]}")
        guard case .tree(let node) = array else { fatalError("JSON outline") }
        precondition(node.children[0].count == 100 && node.children[0].children.count == 80)
        guard case .text = try JSONTree.parse("ordinary text") else { fatalError("Text fallback") }

        // Deterministically cancel before computation begins, then cancel an
        // in-flight large stream. Both must throw, rather than return a tree.
        let latch = ParseLatch()
        let cancelled = Task.detached { await latch.wait(); return try JSONTree.parse("{\"x\":1}") }
        cancelled.cancel()
        await latch.release()
        do { _ = try await cancelled.value; fatalError("Cancelled parse returned") }
        catch is CancellationError {}
        let large = String(repeating: "data: {\"text\":\"" + String(repeating: "x", count: 512) + "\"}\n\n", count: 100_000)
        let started = ParseLatch()
        let inflight = Task.detached { await started.release(); return try JSONTree.parse(large) }
        await started.wait()
        try await Task.sleep(for: .milliseconds(10))
        inflight.cancel()
        do { _ = try await inflight.value; fatalError("In-flight cancelled parse returned") }
        catch is CancellationError {}

        let markdown = try MarkdownFixture.parse("---\ntitle: Demo\n---\n# Title\n\nParagraph\n\n```swift\nlet x = 1\n```")
        precondition(markdown.count == 3)
        guard case .heading(1, "Title") = markdown[0], case .code("swift", "let x = 1") = markdown[2]
        else { fatalError("Markdown formatting changed") }
        let markdownLatch = ParseLatch()
        let cancelledMarkdown = Task.detached {
            await markdownLatch.wait()
            return try MarkdownFixture.parse("# Title")
        }
        cancelledMarkdown.cancel()
        await markdownLatch.release()
        do { _ = try await cancelledMarkdown.value; fatalError("Cancelled Markdown parse returned") }
        catch is CancellationError {}

        let window = FixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let waves = SankeyWaveView()
        waves.frame = NSRect(x: 0, y: 0, width: 240, height: 100)
        window.contentView = waves
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: 240, height: 100), transform: nil)
        let input = [SankeyWave(id: "battery", path: path, destination: .batteryIn)]
        waves.apply(waves: input, animating: true, travel: (0, 240), pace: 2, dark: true)
        let clock = waves.layer!.sublayers!.first!
        precondition(clock.speed > 0)
        let layers = clock.sublayers!.map(ObjectIdentifier.init)
        for _ in 0..<1000 { waves.apply(waves: input, animating: true, travel: (0, 240), pace: 2, dark: true) }
        precondition(clock.sublayers!.map(ObjectIdentifier.init) == layers)
        window.shown = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        precondition(clock.speed == 0)
        let frozen = clock.convertTime(CACurrentMediaTime(), from: nil)
        window.shown = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        precondition(clock.speed > 0 && abs(clock.convertTime(CACurrentMediaTime(), from: nil) - frozen) < 0.02)
        waves.removeFromSuperview()
        precondition(clock.speed == 0)
        waves.stop()
        precondition(clock.sublayers!.allSatisfy { $0.sublayers!.first!.animationKeys()?.isEmpty != false })

        let reading = ReadingSweepView(frame: NSRect(x: 0, y: 0, width: 128, height: 104))
        window.contentView = reading
        reading.active = true
        reading.level = 0.8
        reading.sync()
        let sheen = reading.layer!.sublayers!.first!.sublayers!.first!
        precondition(sheen.speed > 0)
        reading.removeFromSuperview()
        precondition(sheen.speed == 0 && sheen.opacity == 0, "Detached reading must stop")
        window.contentView = reading
        reading.sync()
        precondition(sheen.speed > 0)
        reading.stop()
        precondition(sheen.speed == 0)
        print("PASS: hidden sampler suspension and fan timer lifecycle; independent scroll owners, burst coalescing, stale idle and deadline; bounded SSE order, JSON fallback and cancellation; native hide/detach/phase/stable layers")
    }
}
'''
power_stub = '''enum PowerFlow {
    enum Node { case batteryIn }
    static func color(_ node: Node) -> Color { .green }
}
'''
for key, value in [('POWER_STUB', power_stub + power_layer), ('LOW_LOAD', low_load), ('MARKDOWN', markdown_slice), ('GATE', gate),
                   ('JSON', json_parser), ('SSE', sse), ('BENCHMARK', benchmark)]:
    probe = re.sub(r'^' + key + r'$', lambda _: value, probe, flags=re.MULTILINE)

with tempfile.TemporaryDirectory(prefix='claudebar-interaction-perf-') as folder:
    folder = Path(folder)
    source = folder / 'Regression.swift'
    binary = folder / 'regression'
    source.write_text(marks + probe)
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    if '--compare' in sys.argv:
        original = subprocess.check_output(['git', 'show', 'HEAD:Sources/ClaudeBar/Views/Shared/JSONTreeView.swift'], cwd=root, text=True)
        original = original[original.index('enum JSONDocument {'):original.index('// MARK: - View')]
        for name, parser in [('committed', original), ('optimized', json_parser)]:
            source.write_text('import Foundation\nimport Darwin\n' + sse + parser + benchmark + '\ntry benchmarkSSE()\n')
            subprocess.run(['swiftc', '-O', str(source), '-o', str(binary)], check=True)
            print(name + ':', flush=True)
            for _ in range(3):
                subprocess.run([str(binary)], check=True)
