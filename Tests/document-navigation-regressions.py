#!/usr/bin/env python3
"""Real document locations and editor callback with synthetic Unicode documents."""
from pathlib import Path
import argparse, json, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--baseline-ref'); p.add_argument('--probe', action='store_true')
p.add_argument('--keep-fixture', type=Path); p.add_argument('--output-json', type=Path)
a = p.parse_args()
def read(path):
    return subprocess.check_output(['git', 'show', f'{a.baseline_ref}:{path}'], cwd=root, text=True) if a.baseline_ref else (root / path).read_text()
def decl(source, marker):
    start = source.index(marker); end = source.index('{', start) + 1; depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end]
markup = read('Sources/ClaudeBar/Models/DocumentMarkup.swift')
view = read('Sources/ClaudeBar/Views/Pages/FeishuDocumentsView.swift')
callback = decl(view, '{ heading in')
callback = callback[callback.index('{ heading in') + len('{ heading in'):callback.rindex('}')]
prepared = 'in blocks: [LocatedBlock]' in markup
swift = (root / 'Sources/ClaudeBar/Models/DocumentTable.swift').read_text() + '\n' + markup + '\n' + (root / 'Tests/fixtures/document-navigation-baseline.swift').read_text() + r'''
import QuartzCore
struct Draft { let id: UUID; let text: String }
final class Store { var activeDraft: Draft? }
struct FeishuEditorJump { let location: Int }
final class NavigationFixture {
    let store = Store()
    var draftHeadings: [DocumentMarkup.Heading] = []
    var draftLocated: [DocumentMarkup.LocatedBlock] = []
    var draftOutlineText: String?
    var editorJump: FeishuEditorJump?
    func select(_ heading: DocumentMarkup.Heading, draft: Draft) { CALLBACK }
}
func require(_ ok: @autoclosure () -> Bool, _ message: String) {
    if !ok() { if PROBE { print("BASELINE VIOLATION:", message) } else { fatalError(message) } }
}
@inline(never) func locate(_ heading: DocumentMarkup.Heading, text: String, located: [DocumentMarkup.LocatedBlock], headings: [DocumentMarkup.Heading]) -> Int? {
    LOOKUP
}
@main struct Regression {
    @MainActor static func main() throws {
        let cases = [
            "# 标题\n## 重复\n## 重复",
            "😀开始\r\n\r\n   ## 中文标题 ###\r\n\r\n第二个标题\r\n====\r\n",
            "# 标题\n````\n## 重复\n```\n````\n## 重复\n## 重复\n<h3><strong>子标题</strong></h3>",
            "# 标题\n~~~\n## 重复\n~~~\n<pre>\n## 重复\n</pre>\n## 重复",
            "<div><h1>😀嵌套 &amp; 标题</h1><p>中文</p><h2>重复</h2><h2>重复</h2></div>",
            "# 标题\n| 列 |\n| --- |\n| ## 重复 |\n\n## 重复"
        ]
        var checked = 0
        for text in cases {
            let located = try DocumentMarkup.locatedBlocks(text), headings = DocumentMarkup.outline(located.map(\.block))
            for h in headings {
                let actual = locate(h, text: text, located: located, headings: headings)
                let original = OriginalNavigation.sourceLocation(h, in: text, headings: headings)
                if let original { precondition(actual == original, "Supported heading positions changed") }
                else if PREPARED {
                    precondition(h.title == "第二个标题" && actual == (text as NSString).range(of: "第二个标题").location,
                                 "CRLF Setext heading must use its original source position")
                }
                if let actual { precondition(Range(NSRange(location: actual, length: 0), in: text) != nil) }
                checked += 1
            }
        }
        if PREPARED {
            let extra = "---\n# 重复\n---\n\n# 重复\n<h7>深层😀</h7>\n<h9>更深</h9>"
            let located = try DocumentMarkup.locatedBlocks(extra), headings = DocumentMarkup.outline(located.map(\.block))
            let expected = [(extra as NSString).range(of: "# 重复", options: .backwards).location,
                            (extra as NSString).range(of: "<h7>").location,
                            (extra as NSString).range(of: "<h9>").location]
            precondition(headings.count == expected.count)
            for (heading, location) in zip(headings, expected) {
                precondition(locate(heading, text: extra, located: located, headings: headings) == location)
            }
            let wrongTitle = DocumentMarkup.Heading(id: headings[0].id, level: headings[0].level, title: "obsolete", number: "")
            precondition(locate(wrongTitle, text: extra, located: located, headings: headings) == nil)
            precondition(locate(.init(id: -1, level: 1, title: "wrong", number: ""), text: extra, located: located, headings: headings) == nil)
        }
        let f = NavigationFixture(), text = cases[0]
        let draft = Draft(id: UUID(), text: text)
        f.store.activeDraft = draft; f.draftOutlineText = text
        f.draftLocated = try DocumentMarkup.locatedBlocks(text)
        f.draftHeadings = DocumentMarkup.outline(f.draftLocated.map(\.block))
        f.select(f.draftHeadings.last!, draft: draft)
        precondition(f.editorJump?.location == (text as NSString).range(of: "## 重复", options: .backwards).location)
        f.editorJump = nil
        f.store.activeDraft = Draft(id: draft.id, text: "modified " + text)
        f.select(f.draftHeadings.last!, draft: draft)
        require(f.editorJump == nil, "Delayed callback must reject changed draft text")
        f.editorJump = nil; f.store.activeDraft = Draft(id: UUID(), text: text)
        f.select(f.draftHeadings.last!, draft: draft)
        require(f.editorJump == nil, "Delayed callback must reject a different draft")
        f.editorJump = nil; f.store.activeDraft = draft; f.draftOutlineText = "previous text"
        f.select(f.draftHeadings.last!, draft: draft)
        require(f.editorJump == nil, "Cached ranges must belong to the current text")
        var result: [[String: Any]] = []
        for count in [100, 1000, 3000] {
            let text = (0..<count).map { i in "## 标题 \(i)\n\n" + String(repeating: "中文正文😀内容 ", count: 6) + "\n\n" }.joined()
            precondition(text.utf8.count <= 512_000)
            let located = try DocumentMarkup.locatedBlocks(text), headings = DocumentMarkup.outline(located.map(\.block))
            var times: [Double] = []
            var checksum = 0
            for sample in 0..<20 {
                let heading = headings[(sample * 97) % headings.count]
                let start = CACurrentMediaTime()
                let location = locate(heading, text: text, located: located, headings: headings)
                times.append((CACurrentMediaTime() - start) * 1000)
                precondition(location == located[heading.id].range.location)
                checksum += location!
            }
            precondition(checksum > 0)
            result.append(["headings": count, "bytes": text.utf8.count, "median_lookup_ms": times.sorted()[10]])
        }
        print("METRICS " + String(data: try JSONSerialization.data(withJSONObject: ["document_navigation": result, "parity_headings": checked], options: [.sortedKeys]), encoding: .utf8)!)
        if !PROBE { print("PASS parser ranges, duplicate/protected Unicode headings and stale editor callback") }
    }
}
'''
lookup = 'return DocumentMarkup.sourceLocation(heading, in: located)' if prepared else 'return DocumentMarkup.sourceLocation(heading, in: text, headings: headings)'
for key, value in {'CALLBACK': callback, 'LOOKUP': lookup, 'PREPARED': 'true' if prepared else 'false', 'PROBE': 'true' if a.probe else 'false'}.items(): swift = swift.replace(key, value)
with tempfile.TemporaryDirectory(prefix='claudebar-document-navigation-') as tmp:
    out = a.keep_fixture or Path(tmp); out.mkdir(parents=True, exist_ok=True)
    path = out / 'probe.swift'; path.write_text(swift); binary = out / 'probe'
    subprocess.run(['swiftc','-O','-g','-parse-as-library','-target','arm64-apple-macos15.0',str(path),'-o',str(binary)],check=True)
    result = subprocess.check_output([str(binary)],text=True); print(result,end='',flush=True)
    if a.output_json:
        metrics=next(json.loads(line[8:]) for line in result.splitlines() if line.startswith('METRICS '))
        a.output_json.write_text(json.dumps(metrics,indent=2)+'\n')
