#!/usr/bin/env python3
"""Real offscreen SwiftUI/AppKit surfaces, synthetic text and no permissions/control APIs."""
from pathlib import Path
import argparse
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline-dir', type=Path)
p.add_argument('--keep-fixture', type=Path)
p.add_argument('--output-json', type=Path)
p.add_argument('--profile', action='store_true')
p.add_argument('--compile-only', action='store_true')
a = p.parse_args()


def read(name, folder):
    path = a.baseline_dir / name if a.baseline_dir and (a.baseline_dir / name).exists() else root / folder / name
    return path.read_text()


table = read('DocumentTable.swift', 'Sources/ClaudeBar/Models')
table = table.replace('func layout(measured: [UUID: Double]) -> Layout {', 'func layout(measured: [UUID: Double]) -> Layout {\n        Bench.layouts += 1')
view = read('DocumentTableView.swift', 'Sources/ClaudeBar/Views/Shared')
has_cache = 'func layout(measured:' in view
view = view.replace('    var body: some View {\n        let layout = ', '    var body: some View {\n        Bench.tableBodies += 1\n        let layout = ', 1)
view = view.replace('        let shown = value.isEmpty', '        Bench.cellParses += 1\n        let shown = value.isEmpty')
panel = read('SkillMarkdownPreview.swift', 'Sources/ClaudeBar/Views/Shared')
panel = panel[panel.index('struct DocumentOutlinePanel:'):]
panel = panel.replace('        let minimumLevel = ', '        Bench.panelBodies += 1\n        let minimumLevel = ', 1)
old = '(try? AttributedString(markdown: heading.title, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(heading.title)'
new = '(try? AttributedString(markdown: title, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(title)'
assert old in panel or new in panel
panel = panel.replace(old, 'Bench.title(heading.title)').replace(new, 'Bench.title(title)')
source = r'''
import AppKit
import SwiftUI
import CryptoKit
enum Theme {
    static let textPrimary = Color.primary, textSecondary = Color.secondary
    static let bgSecondary = Color.gray.opacity(0.1), bgOverlay = Color.gray.opacity(0.08)
    static let hairline = Color.gray.opacity(0.2), cardSurface = Color(nsColor: .controlBackgroundColor)
    static let claude = Color.blue
    static let isDark = false
    enum Ink { static let claude = Color.blue }
    enum Font {
        static let micro = SwiftUI.Font.system(size: 10), microSemibold = SwiftUI.Font.system(size: 10, weight: .semibold)
        static let caption = SwiftUI.Font.system(size: 12)
    }
}
extension Color {
    init(hex: UInt, opacity: Double = 1) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: opacity) }
}
struct HairlineDivider: View { var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) } }
struct ActionIcon: View {
    let symbol: String; let tint: Color; let size: CGFloat; let action: () -> Void
    var body: some View { Button(action: action) { Image(systemName: symbol).foregroundStyle(tint).frame(width: size, height: size) }.buttonStyle(.plain) }
}
enum Bench {
    static var layouts = 0, tableBodies = 0, panelBodies = 0, titleParses = 0, cellParses = 0
    static func title(_ title: String) -> AttributedString {
        titleParses += 1
        return (try? AttributedString(markdown: title, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(title)
    }
}
'''
source += table + '\n' + (root / 'Sources/ClaudeBar/Models/DocumentMarkup.swift').read_text()
source += '\n' + (root / 'Sources/ClaudeBar/Views/Shared/DocumentInlineEditor.swift').read_text() + '\n' + view + '\n' + panel
source += r'''
@MainActor func query(_ controller: DocumentTableController, _ measured: [UUID: Double]) -> DocumentTable.Layout { QUERY }
func same(_ a: DocumentTable.Layout, _ b: DocumentTable.Layout) -> Bool {
    a.rowOffsets == b.rowOffsets && a.columnOffsets == b.columnOffsets &&
    a.clusters.map(\.rows) == b.clusters.map(\.rows) && a.clusters.map(\.cellIndices) == b.clusters.map(\.cellIndices)
}
func ms(_ body: () -> Void) -> Double {
    let start = ContinuousClock.now; body(); let d = start.duration(to: .now)
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
@MainActor func settle() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.006))
}
func require(_ condition: @autoclosure () -> Bool, _ message: String = "", line: UInt = #line) {
    if !condition() { FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8)); exit(1) }
}
@MainActor final class SurfaceState: ObservableObject {
    @Published var editable = false
    @Published var source = ""
    @Published var dark = false
    @Published var headings: [DocumentMarkup.Heading]
    init(_ headings: [DocumentMarkup.Heading] = []) { self.headings = headings }
}
struct TableSurface: View {
    @ObservedObject var state: SurfaceState
    let model: DocumentTable
    var body: some View {
        ScrollView { DocumentTableView(source: state.source, model: model, editable: state.editable, onFocus: { _ in }, onEdit: { _ in }) }
            .preferredColorScheme(state.dark ? .dark : .light)
    }
}
struct OutlineSurface: View {
    @ObservedObject var state: SurfaceState
    var body: some View { DocumentOutlinePanel(headings: state.headings, onClose: {}, onJump: { _ in }).preferredColorScheme(state.dark ? .dark : .light) }
}
@MainActor func digest<V: View>(_ host: NSHostingView<V>) -> String {
    host.layoutSubtreeIfNeeded()
    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return SHA256.hash(data: bitmap.representation(using: .png, properties: [:])!).map { String(format: "%02x", $0) }.joined()
}
@main struct Regression {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        if PROFILE { Thread.sleep(forTimeInterval: 1) }
        var metrics: [String: Any] = [:]
        let big = DocumentTable(rows: (0..<500).map { row in (0..<8).map { col in
            "中文😀 **bold** [link](https://example.test) \(row)-\(col) " + String(repeating: "文字排版 ", count: 12)
        } })
        let controller = DocumentTableController(big)
        Bench.layouts = 0
        let expected = big.layout(measured: [:]); _ = query(controller, [:])
        let before = Bench.layouts
        let repeats = 100
        metrics["cached_layout_\(repeats)_ms"] = ms {
            for _ in 0..<repeats { precondition(same(query(controller, [:]), expected)) }
        }
        metrics["unchanged_layout_computations"] = Bench.layouts - before
        var measured: [UUID: Double] = [big.cells[0].id: 180]
        precondition(same(query(controller, measured), controller.model.layout(measured: measured)))
        measured[big.cells[0].id] = 240
        precondition(same(query(controller, measured), controller.model.layout(measured: measured)))
        measured.removeAll(); precondition(same(query(controller, measured), expected))
        func check() { precondition(same(query(controller, measured), controller.model.layout(measured: measured))) }
        controller.model.columnWidths[0] = 72; check()
        controller.model.cells[0].value += String(repeating: "长文本😀", count: 200); check()
        controller.model.rowHeights[0] = 500; check()
        controller.model.insertRow(at: 1); check()
        controller.model.insertColumn(at: 1); check()
        controller.model.merge(controller.model.cells[0].id, below: true); check()
        controller.model.split(controller.model.cells[0].id); check()
        controller.model.deleteRow(at: 1); controller.model.deleteColumn(at: 1); check()
        let undo = UndoManager(); undo.groupsByEvent = false
        undo.beginUndoGrouping(); controller.change(undoManager: undo) { $0.columnWidths[0] = 333 }; undo.endUndoGrouping(); check()
        undo.undo(); check(); undo.redo(); check()
        controller.model = big; check()
        let nativeModel = DocumentTable(cells: Array(big.cells.prefix(24 * 8)), rowCount: 24, columnCount: 8)
        let tableWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [], backing: .buffered, defer: false)
        let tableState = SurfaceState()
        let tableHost = NSHostingView(rootView: TableSurface(state: tableState, model: nativeModel))
        tableHost.sizingOptions = []
        tableWindow.contentView = tableHost
        tableHost.frame = tableWindow.contentLayoutRect; tableHost.layoutSubtreeIfNeeded(); settle()
        let initialTable = digest(tableHost)
        Bench.layouts = 0; Bench.tableBodies = 0; Bench.cellParses = 0
        let cycles = PROFILE ? 120 : 30
        metrics["native_table_updates_ms"] = ms {
            for i in 0..<cycles {
                tableState.editable = i % 2 == 0
                tableHost.layoutSubtreeIfNeeded(); settle()
            }
        }
        metrics["native_table_body_updates"] = Bench.tableBodies
        metrics["native_table_layout_computations"] = Bench.layouts
        metrics["native_table_text_parses"] = Bench.cellParses
        tableState.editable = false
        settle(); metrics["table_image_sha256"] = digest(tableHost)
        precondition(initialTable == digest(tableHost), "Unchanged geometry must preserve the rendered table")
        let headings = (0..<3000).map { DocumentMarkup.Heading(id: $0, level: $0 % 3 + 1, title: "**中文标题😀** `code` [link](https://example.test) \($0)", number: "\($0 + 1)") }
        let panelWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 230, height: 430), styleMask: [], backing: .buffered, defer: false)
        let panelState = SurfaceState(headings)
        let panelHost = NSHostingView(rootView: OutlineSurface(state: panelState))
        panelHost.sizingOptions = []
        panelWindow.contentView = panelHost; panelHost.frame = panelWindow.contentLayoutRect
        panelHost.layoutSubtreeIfNeeded(); settle(); let initialPanel = digest(panelHost)
        Bench.titleParses = 0; Bench.panelBodies = 0
        metrics["native_outline_updates_ms"] = ms {
            for i in 0..<cycles {
                var changed = headings; changed[2999] = .init(id: 2999, level: 3, title: "Offscreen \(i)", number: "3000")
                panelState.headings = changed
                panelHost.layoutSubtreeIfNeeded(); settle()
            }
        }
        metrics["native_outline_body_updates"] = Bench.panelBodies
        metrics["native_outline_title_parses"] = Bench.titleParses
        panelState.headings = headings
        settle(); metrics["outline_image_sha256"] = digest(panelHost)
        precondition(initialPanel == digest(panelHost), "Offscreen title changes must preserve visible text")
        var visibleChanged = headings
        visibleChanged[0] = .init(id: 0, level: 1, title: "Visible changed title", number: "1")
        panelState.headings = visibleChanged; settle()
        require(initialPanel != digest(panelHost), "Visible title changes must redraw")
        panelState.headings = headings; settle()
        require(initialPanel == digest(panelHost), "Restored title must redraw")
        tableState.dark = true; panelState.dark = true; settle()
        metrics["table_dark_sha256"] = digest(tableHost)
        metrics["outline_dark_sha256"] = digest(panelHost)
        require(initialTable != digest(tableHost), "Table must respond to appearance")
        require(initialPanel != digest(panelHost), "Outline must respond to appearance")
        tableState.dark = false; panelState.dark = false; settle()
        require(initialTable == digest(tableHost) && initialPanel == digest(panelHost), "Restored appearance")
        var changedTable = nativeModel
        changedTable.cells[0].value = "Changed visible content 😀"
        tableState.source = changedTable.html(renderInline: DocumentRichText.html); settle()
        require(initialTable != digest(tableHost), "Changed source must invalidate layout and text")
        metrics["table_content_changed_sha256"] = digest(tableHost)
        var styled = DocumentTable(rows: [["```swift\nlet value = 42\n```", ""], ["Styled **text**", "中文😀"]])
        styled.cells[2].originalHTML = "<strong>Styled</strong> <em>text</em><s>strike</s><span style=\"color: #ff0000; background-color: #ffff00\">color</span>"
        styled.cells[2].originalValue = styled.cells[2].value
        styled.cells[3].attributes = ["vertical-align": "middle", "background-color": "#00ff00"]
        let styledHost = NSHostingView(rootView: TableSurface(state: SurfaceState(), model: styled))
        styledHost.sizingOptions = []; tableWindow.contentView = styledHost
        styledHost.frame = tableWindow.contentLayoutRect; settle()
        metrics["table_styled_sha256"] = digest(styledHost)
        print("DIAGNOSTICS", metrics)
        precondition(Bench.tableBodies >= cycles && Bench.panelBodies >= cycles, "Real SwiftUI updates must occur")
        if CACHED { precondition(metrics["unchanged_layout_computations"] as! Int == 0 && metrics["native_table_layout_computations"] as! Int == 0 && metrics["native_table_text_parses"] as! Int == 0 && metrics["native_outline_title_parses"] as! Int == 0) }
        print("METRICS " + String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), as: UTF8.self))
        print("PASS real native surface updates, geometry/content/height/topology/undo invalidation and pixel stability")
        tableWindow.orderOut(nil); panelWindow.orderOut(nil)
    }
}
'''
source = source.replace('QUERY', 'return controller.layout(measured: measured)' if has_cache else 'return controller.model.layout(measured: measured)').replace('CACHED', 'true' if has_cache else 'false').replace('PROFILE', 'true' if a.profile else 'false')
source = source.replace('precondition(', 'require(')
with tempfile.TemporaryDirectory(prefix='claudebar-frontend-native-') as tmp:
    folder = a.keep_fixture or Path(tmp); folder.mkdir(parents=True, exist_ok=True)
    path = folder / 'probe.swift'; path.write_text(source); binary = folder / 'probe'
    subprocess.run(['swiftc', '-O', '-g', '-parse-as-library', '-module-name', 'ClaudeBar', '-target', 'arm64-apple-macos15.0', str(path), '-o', str(binary)], check=True)
    if a.compile_only:
        raise SystemExit(0)
    result = subprocess.run([str(binary)], text=True, capture_output=True)
    print(result.stdout, end='', flush=True)
    if result.returncode:
        print(result.stderr, end='', flush=True)
        result.check_returncode()
    output = result.stdout
    if a.output_json:
        a.output_json.write_text(json.dumps(next(json.loads(line[8:]) for line in output.splitlines() if line.startswith('METRICS ')), indent=2) + '\n')
