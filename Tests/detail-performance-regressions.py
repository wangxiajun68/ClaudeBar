#!/usr/bin/env python3
"""Production quota formatting and native document preparation; synthetic data only."""
from pathlib import Path
import argparse
import json
import statistics
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--baseline-ref', default='c985f1f')
p.add_argument('--compare', action='store_true')
p.add_argument('--probe', action='store_true')
p.add_argument('--output-json', type=Path)
p.add_argument('--keep-fixture', type=Path)
a = p.parse_args()

editor_path = 'Sources/ClaudeBar/Views/Shared/DocumentInlineEditor.swift'
quota_path = 'Sources/ClaudeBar/Utils/CodexQuotaFetcher.swift'


def baseline(path):
    return subprocess.check_output(['git', 'show', f'{a.baseline_ref}:{path}'], cwd=root, text=True)


if a.compare:
    original_editor = baseline(editor_path)
    original_quota = baseline(quota_path).split('enum CodexQuotaFetcher {')[0]
    oracle_rich = original_editor[original_editor.index('enum DocumentRichText {'):].replace('DocumentRichText', 'OriginalRichText')
    oracle_quota = original_quota.replace('CodexQuotaWindow', 'OriginalQuotaWindow')
else:
    # Frozen production oracle works in a shallow checkout without old commits.
    reference = (root / 'Tests/fixtures/native-detail-baseline.swift').read_text()
    offset = reference.index('enum OriginalRichText {')
    oracle_quota, oracle_rich = reference[:offset], reference[offset:]

main = r'''
enum Theme {
    static let textPrimary = Color.primary
    static let bgSecondary = Color.gray.opacity(0.1)
    enum Ink { static let claude = Color.blue }
}
enum Counter { static var applies = 0 }
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        if PROBE { print("BASELINE VIOLATION:", message) } else { fatalError(message) }
    }
}
func measure(_ work: () -> Int) -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    let count = work()
    precondition(count > 0)
    return (CFAbsoluteTimeGetCurrent() - start) * 1000
}
@main struct Regression {
    @MainActor static func main() {
        _ = NSApplication.shared
        if CommandLine.arguments.contains("--profile") {
            let text = NSMutableAttributedString(string: String(repeating: "中文😀 e\u{301} \\*_[a]<>~ ", count: 800))
            for start in stride(from: 0, to: text.length, by: 60) {
                text.addAttribute(.foregroundColor, value: start % 120 == 0 ? NSColor.red : NSColor.blue,
                                  range: NSRange(location: start, length: min(60, text.length - start)))
            }
            let quota = CodexQuotaWindow(label: "fixture", usedPercent: 10, resetsAt: Date().addingTimeInterval(3600), durationMinutes: 300)
            var count = 0
            for _ in 0..<60 {
                autoreleasepool {
                    for _ in 0..<20 { count += DocumentRichText.markdown(text).utf16.count }
                    for _ in 0..<500 { count += quota.resetClock.count + quota.resetCompact.count }
                    for _ in 0..<100 {
                        let editor = DocumentInlineEditor(markdown: "**中文** *e\u{301}* `code` https://example.test", fontSize: 15, editable: true, onChange: { _ in })
                        let context = DocumentInlineEditor.Context(coordinator: editor.makeCoordinator())
                        count += editor.makeNSView(context: context).string.count
                    }
                }
            }
            print("PROFILE synthetic checksum", count)
            return
        }
        let now = Date()
        let dates = [-800_000.0, -3600, 0, 3600, 90_000, 800_000].map { now.addingTimeInterval($0) }
        let defaultZone = NSTimeZone.default
        defer { NSTimeZone.default = defaultZone }
        for zone in ["Asia/Shanghai", "America/Los_Angeles", "UTC", "Asia/Kathmandu"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            for date in dates {
                for duration in [0, 300, 1440, 10_080] {
                    let current = CodexQuotaWindow(label: "fixture", usedPercent: 10, resetsAt: date, durationMinutes: duration)
                    let original = OriginalQuotaWindow(label: "fixture", usedPercent: 10, resetsAt: date, durationMinutes: duration)
                    precondition(current.resetClock == original.resetClock, "clock changed in " + zone)
                    precondition(current.resetCompact == original.resetCompact, "compact changed in " + zone)
                    precondition(current.resetWait == original.resetWait)
                }
            }
        }
        let empty = CodexQuotaWindow(label: "fixture", usedPercent: 0)
        precondition(empty.resetClock == "重置时间未知" && empty.resetCompact.isEmpty)
        let samples = ["", "  普通正文 👩🏽‍💻 e\u{301}  ", "**粗体** 与 *斜体*、~~删除~~、`a*b`", "[链接](https://example.test/a?q=1&b=2)", "https://example.test/plain", "`https://example.test/code`", "[非法](javascript:alert)", "a & <b>\n下一行", "```swift\nlet a = 1\n```", "破损 **标记", "  ", "\t\n", "mailto:test@example.test"]
        for text in samples {
            let current = DocumentRichText.attributed(text, size: 15)
            precondition(current.isEqual(to: OriginalRichText.attributed(text, size: 15)), "attributes differ")
            precondition(DocumentRichText.html(text) == OriginalRichText.html(text), "HTML differs")
            precondition(DocumentRichText.markdown(current) == OriginalRichText.markdown(current), "Markdown differs")
        }
        let plain = NSMutableAttributedString(string: String(repeating: "  中文😀 e\u{301} \\*_[a]<>~\t\n", count: 800))
        for start in stride(from: 0, to: plain.length, by: 60) {
            let range = NSRange(location: start, length: min(60, plain.length - start))
            plain.addAttribute(.foregroundColor, value: start % 120 == 0 ? NSColor.red : NSColor.blue, range: range)
        }
        precondition(DocumentRichText.markdown(plain) == OriginalRichText.markdown(plain))
        let styled = NSMutableAttributedString(string: " code` x **链接** whitespace ")
        styled.addAttribute(.documentCode, value: true, range: NSRange(location: 0, length: 5))
        styled.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), range: NSRange(location: 5, length: 4))
        styled.addAttributes([.documentStrong: true, .documentEmphasis: true, .strikethroughStyle: 1, .link: URL(string: "https://example.test/a(b)")!], range: NSRange(location: 10, length: 6))
        precondition(DocumentRichText.markdown(styled) == OriginalRichText.markdown(styled))
        var publications: [String] = []
        var editor = DocumentInlineEditor(markdown: "**初始** 内容 https://example.test", fontSize: 15, editable: true, onChange: { publications.append($0) })
        let coordinator = editor.makeCoordinator()
        let context = DocumentInlineEditor.Context(coordinator: coordinator)
        Counter.applies = 0
        let view = editor.makeNSView(context: context)
        let initialApplies = Counter.applies
        require(initialApplies == 1, "initial editor formats and assigns text twice")
        let before = Counter.applies
        view.setSelectedRange(NSRange(location: 1, length: 2))
        editor.updateNSView(view, context: context)
        require(Counter.applies == before && view.selectedRange() == NSRange(location: 1, length: 2), "equal update rewrites native selection")
        editor = DocumentInlineEditor(markdown: "外部新正文", fontSize: 15, editable: false, onChange: { publications.append($0) })
        editor.updateNSView(view, context: context)
        precondition(Counter.applies == before + 1 && !view.isEditable && view.string == "外部新正文")
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        precondition(publications.isEmpty, "unchanged content republished")
        view.textStorage?.setAttributedString(NSAttributedString(string: "输入😀"))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        precondition(publications == ["输入😀"], "native edit publication lost or duplicated")
        let literal = DocumentInlineEditor(markdown: "**源码**", fontSize: 13, editable: true, literal: true, onChange: { _ in })
        let literalContext = DocumentInlineEditor.Context(coordinator: literal.makeCoordinator())
        Counter.applies = 0
        let literalView = literal.makeNSView(context: literalContext)
        require(Counter.applies == 1 && literalView.string == "**源码**", "literal startup should assign once")
        let short = CodexQuotaWindow(label: "fixture", usedPercent: 10, resetsAt: dates[3], durationMinutes: 300)
        let long = CodexQuotaWindow(label: "fixture", usedPercent: 10, resetsAt: dates[5], durationMinutes: 10_080)
        let quotaTime = measure { var count = 0; for _ in 0..<1000 { count += short.resetClock.count + short.resetCompact.count + long.resetClock.count + long.resetCompact.count }; return count }
        let serializeTime = measure { var count = 0; for _ in 0..<20 { count += DocumentRichText.markdown(plain).utf16.count }; return count }
        let htmlTime = measure { var count = 0; for _ in 0..<100 { count += DocumentRichText.html(samples[2] + " " + samples[4]).count }; return count }
        let startupTime = measure {
            var count = 0
            for _ in 0..<150 {
                let editor = DocumentInlineEditor(markdown: samples[2] + samples[4], fontSize: 15, editable: true, onChange: { _ in })
                let context = DocumentInlineEditor.Context(coordinator: editor.makeCoordinator())
                let view = editor.makeNSView(context: context)
                count += view.string.count
            }
            return count
        }
        let metrics: [String: Double] = ["quota_1000_updates_ms": quotaTime, "document_20_serializations_ms": serializeTime, "document_100_html_ms": htmlTime, "editor_150_mounts_ms": startupTime, "editor_initial_assignments": Double(initialApplies)]
        print("METRICS " + String(data: try! JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), encoding: .utf8)!)
        print(PROBE ? "Baseline probe completed" : "PASS: production formatting, four time zones, Unicode/markup/links, mutable text storage, initial editor assignments and native edit publications")
    }
}
'''


def fixture(editor, quota, probe):
    editor = editor.replace('struct DocumentInlineEditor: NSViewRepresentable {', 'struct DocumentInlineEditor {\n    struct Context { let coordinator: Coordinator }')
    editor = editor.replace('    private func applyText(_ view: NSTextView) {', '    private func applyText(_ view: NSTextView) {\n        Counter.applies += 1')
    return editor + quota.split('enum CodexQuotaFetcher {')[0] + oracle_rich + oracle_quota + main.replace('PROBE', str(probe).lower())


with tempfile.TemporaryDirectory(prefix='claudebar-detail-') as folder:
    folder = Path(folder)
    arms = {'current': fixture((root / editor_path).read_text(), (root / quota_path).read_text(), a.probe)}
    if a.compare:
        arms['baseline'] = fixture(original_editor, baseline(quota_path), True)
    binaries = {}
    for name, content in arms.items():
        source = folder / f'{name}.swift'
        source.write_text(content)
        binary = folder / name
        subprocess.run(['swiftc', '-O', '-g', '-parse-as-library', str(source), '-o', str(binary)], check=True)
        binaries[name] = binary
        if a.keep_fixture and name == 'current':
            a.keep_fixture.mkdir(parents=True, exist_ok=True)
            import shutil
            shutil.copy2(source, a.keep_fixture / 'detail-worker.swift')
            shutil.copy2(binary, a.keep_fixture / 'detail-worker')
            if binary.with_suffix('.dSYM').exists():
                shutil.copytree(binary.with_suffix('.dSYM'), a.keep_fixture / 'detail-worker.dSYM', dirs_exist_ok=True)
    samples = {name: [] for name in arms}
    order = ['baseline', 'current', 'current', 'baseline', 'baseline', 'current'] if a.compare else ['current']
    for name in order:
        output = subprocess.check_output([str(binaries[name])], text=True)
        print(name + ': ' + output.strip())
        samples[name].append(json.loads(next(line.removeprefix('METRICS ') for line in output.splitlines() if line.startswith('METRICS '))))
    result = {'baseline_ref': a.baseline_ref, 'synthetic': True, 'samples': samples,
              'medians': {name: {key: statistics.median(row[key] for row in rows) for key in rows[0]} for name, rows in samples.items()}}
    if a.output_json:
        a.output_json.write_text(json.dumps(result, indent=2) + '\n')
