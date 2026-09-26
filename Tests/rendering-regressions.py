#!/usr/bin/env python3
"""Field subscriptions, native animation lifecycle, and large conversation transforms.
Compiles production code with in-memory fixtures, without starting ClaudeBar.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
observation = (root / 'Sources/ClaudeBar/Models/ScopedStoreObservation.swift').read_text()
motion = (root / 'Sources/ClaudeBar/Views/Shared/DecorativeMotion.swift').read_text()
traffic = (root / 'Sources/ClaudeBar/Views/Pages/TrafficView.swift').read_text()
blocks = traffic[traffic.index('enum ConvBlock:'):traffic.index('private struct TrafficRow:')]
builder = traffic[traffic.index('struct ConversationInput:'):]
scheduler = traffic[traffic.index('    private var conversationInput:'):traffic.index('    /// The list selection')]
fields = sorted(set(re.findall(r'changes\(\$(\w+)\)', observation)))
fixture = 'final class ProviderStore: ObservableObject {\n' + '\n'.join(
    f'    @Published var {field} = 0' for field in fields) + '\n}\n'
swift = r'''
import SwiftUI
import Combine
FIXTURE
private struct SurfaceKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var surfaceIsVisible: Bool {
        get { self[SurfaceKey.self] }
        set { self[SurfaceKey.self] = newValue }
    }
}
OBSERVATION
MOTION
struct CaptureLive: Equatable { var content: String }
enum CaptureTranscript {
    enum ParseMode { case full, conversation }
    struct Turn: Equatable { var role: String; var text: String; var name = "" }
    static func replyTurns(responseJSON: String?, live: CaptureLive?, streaming: Bool, mode: ParseMode) -> [Turn] {
        let text = live?.content ?? responseJSON ?? ""
        return text.isEmpty ? [] : [Turn(role: "assistant", text: text)]
    }
}
BLOCKS
BUILDER
final class ConversationFixture {
    var displayBlocks: [ConvBlock] = []
    var historyCount = 0
SCHEDULER
}
// Simulated visibility isolates lifecycle tests from the user's windows.
final class FixtureWindow: NSWindow {
    var shown = true
    override var occlusionState: NSWindow.OcclusionState { shown ? [.visible] : [] }
}
@main struct Regression {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let store = ProviderStore()
        let usage = StoreInvalidation()
        usage.connect(owner: store, changes: store.viewChanges(.usage))
        var notifications = 0
        let token = usage.objectWillChange.sink { notifications += 1 }
        for i in 0..<1000 { store.sessions = i; store.heartbeats = i; store.providers = i }
        try? await Task.sleep(for: .milliseconds(30))
        precondition(notifications == 0, "Usage must ignore session/configuration updates")
        for i in 1...1000 { store.usageStats = i; store.usageDays = i }
        try? await Task.sleep(for: .milliseconds(30))
        precondition(notifications == 1, "Coalesce a transaction into one invalidation")
        store.usageStats = 1000
        try? await Task.sleep(for: .milliseconds(30))
        precondition(notifications == 1, "Duplicate values must not invalidate")
        usage.visible = false
        store.usageStats = 2000
        try? await Task.sleep(for: .milliseconds(30))
        precondition(notifications == 1, "Hidden surfaces must not invalidate")
        usage.visible = true
        store.usageStats = 2001
        try? await Task.sleep(for: .milliseconds(30))
        precondition(notifications == 2)
        withExtendedLifetime(token) {}

        func animationCount(_ layer: CALayer) -> Int {
            (layer.animationKeys()?.count ?? 0) + (layer.sublayers ?? []).reduce(0) { $0 + animationCount($1) }
        }
        let window = FixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let preview = CGContext(data: nil, width: 1152, height: 144, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        preview.setFillColor(NSColor.black.cgColor)
        preview.fill(CGRect(x: 0, y: 0, width: 1152, height: 144))
        for (index, kind) in [DecorativeMotion.Kind.sparkles, .sweep, .orbit, .pulse, .scan, .conveyor].enumerated() {
            // The belt is a *strip*, not a box: it only means anything at a
            // width several tick pitches across, and a 44pt frame would crop it
            // to two ticks and still pass every lifecycle assertion below.
            let width: CGFloat = kind == .sweep ? 80 : (kind == .scan ? 2 : (kind == .conveyor ? 120 : 44))
            let view = MotionLayerView(frame: NSRect(x: 0, y: 0, width: width, height: 44))
            window.contentView = view
            view.apply(kind: kind, tint: .systemPurple, active: true)
            view.layoutSubtreeIfNeeded()
            let layers = view.layer!.sublayers!.map(ObjectIdentifier.init)
            precondition(animationCount(view.layer!) > 0)
            for _ in 0..<1000 { view.apply(kind: kind, tint: .systemPurple, active: true) }
            precondition(view.layer!.sublayers!.map(ObjectIdentifier.init) == layers,
                         "Unchanged updates must not reconstruct animation layers")
            view.apply(kind: kind, tint: .systemPurple, active: false)
            precondition(animationCount(view.layer!) == 0)
            view.apply(kind: kind, tint: .systemPurple, active: true)
            window.shown = false
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
            precondition(animationCount(view.layer!) == 0)
            window.shown = true
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
            precondition(animationCount(view.layer!) > 0)
            preview.saveGState()
            preview.translateBy(x: CGFloat(index) * 144 + 50, y: 50)
            view.frame = NSRect(x: 0, y: 0, width: width, height: 44)
            view.layoutSubtreeIfNeeded()
            if kind == .conveyor {
                // The belt has one invariant the lifecycle checks above cannot
                // see, and it is the one that was wrong: it must travel exactly
                // one *tick group* per cycle, or the pattern does not meet
                // itself at the loop point and the belt visibly hitches.
                // (The first version drew the pattern across a layer twice as
                // wide as `ticks` pitches while travelling one pitch, i.e. half
                // a group per cycle — every assertion above still passed.)
                let belt = view.layer!.sublayers![0] as! CAGradientLayer
                let travel = belt.animation(forKey: "decoration") as! CABasicAnimation
                let group = Double(belt.frame.width) / Double(belt.locations!.count - 1) * 4
                precondition(abs((travel.toValue as! Double) - group) < 0.001,
                             "The belt must travel one tick group per cycle")
                precondition(belt.frame.minX <= 0 && belt.frame.maxX >= view.bounds.width,
                             "The belt must span the strip across its whole travel")
            }
            view.layer!.render(in: preview)
            preview.restoreGState()
            view.removeFromSuperview()
            precondition(animationCount(view.layer!) == 0, "Detached views must release repeating animations")
        }

        if CommandLine.arguments.count > 1 {
            let image = NSBitmapImageRep(cgImage: preview.makeImage()!)
            try! image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        let history = (0..<10_000).map { CaptureTranscript.Turn(role: $0 % 2 == 0 ? "user" : "assistant", text: "message \($0)") }
        func input(_ id: Int64, query: String = "") -> ConversationInput {
            ConversationInput(id: id, history: history, live: CaptureLive(content: "latest"),
                              response: nil, headers: nil, full: false, streaming: true, query: query)
        }
        let started = CFAbsoluteTimeGetCurrent()
        let all = ConversationBuilder.build(input(1))
        precondition(all.count == 10_001)
        let filtered = ConversationBuilder.build(input(1, query: "message 9999"))
        precondition(filtered.count == 1)
        let fixture = ConversationFixture()
        for i in 1...100 { fixture.requestConversation(input(Int64(i), query: "message 9999")) }
        for _ in 0..<100 where fixture.displayBlocks.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        precondition(fixture.historyCount == 10_000 && fixture.displayBlocks.count == 1)
        fixture.requestConversation(input(101))
        fixture.clearConversation()
        try? await Task.sleep(for: .milliseconds(100))
        precondition(fixture.displayBlocks.isEmpty, "A departed page must reject its pending result")
        print("PASS: scoped/coalesced subscriptions; 7 native effects × 1000 stable updates; hide/detach stops animations; 10000-turn filtering and stale-result rejection (\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - started))s including waits)")
    }
}
'''
for key, value in [('FIXTURE', fixture), ('OBSERVATION', observation), ('MOTION', motion),
                   ('BLOCKS', blocks), ('BUILDER', builder), ('SCHEDULER', scheduler)]:
    swift = swift.replace(key, value)
with tempfile.TemporaryDirectory(prefix='claudebar-rendering-') as folder:
    source = Path(folder) / 'Regression.swift'
    source.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    preview = root / '.build/performance-motion-preview.png'
    preview.parent.mkdir(exist_ok=True)
    subprocess.run([str(binary), str(preview)], check=True)
