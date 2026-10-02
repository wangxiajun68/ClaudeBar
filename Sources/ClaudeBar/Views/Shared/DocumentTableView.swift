import AppKit
import SwiftUI

@MainActor final class DocumentTableController: ObservableObject {
    @Published var model: DocumentTable
    var onChange: (String) -> Void = { _ in }
    var lastSource = ""
    init(_ model: DocumentTable) { self.model = model }
    func publish() { lastSource = model.html(renderInline: DocumentRichText.html); onChange(lastSource) }
    func change(undoManager: UndoManager?, _ update: (inout DocumentTable) -> Void) {
        let before = model
        update(&model)
        undoManager?.registerUndo(withTarget: self) { $0.restore(before, undoManager: undoManager) }
        undoManager?.setActionName("编辑表格")
        publish()
    }
    private func restore(_ model: DocumentTable, undoManager: UndoManager?) {
        let current = self.model
        undoManager?.registerUndo(withTarget: self) { $0.restore(current, undoManager: undoManager) }
        self.model = model; publish()
    }
}

/// Cells stay editable; merged topology, column edges and row edges are real
/// document data, not a separate source editor or temporary presentation state.
struct DocumentTableView: View {
    let source: String
    let editable: Bool
    var onFocus: (Bool) -> Void
    var onEdit: (String) -> Void
    @StateObject private var controller: DocumentTableController
    @StateObject private var navigator = DocumentFocusNavigator()
    @State private var activeCell: UUID?
    @State private var dragStart: Double?
    @State private var dragBefore: DocumentTable?
    @State private var measured: [UUID: CGFloat] = [:]
    init(source: String, model: DocumentTable, editable: Bool, onFocus: @escaping (Bool) -> Void, onEdit: @escaping (String) -> Void) {
        self.source = source; self.editable = editable; self.onFocus = onFocus; self.onEdit = onEdit
        _controller = StateObject(wrappedValue: DocumentTableController(model))
    }
    private var model: DocumentTable { controller.model }
    private var heights: [Double] {
        var values = model.rowHeights
        for cell in model.cells {
            let width = model.columnWidths[cell.column..<(cell.column + cell.columnSpan)].reduce(0, +) - 24
            let estimate = cell.value.components(separatedBy: "\n").reduce(0) { $0 + max(1, Int(ceil(Double($1.count) * 8 / max(40, width)))) }
            let content = Double(measured[cell.id] ?? CGFloat(estimate * 21 + 4)) + 24
            let existing = values[cell.row..<(cell.row + cell.rowSpan)].reduce(0, +)
            if content > existing { values[cell.row + cell.rowSpan - 1] += content - existing }
        }
        return values
    }
    /// Keep merged row clusters together while virtualizing large tables.
    private var clusters: [Range<Int>] {
        let byRow = Dictionary(grouping: model.cells, by: \.row)
        var result: [Range<Int>] = [], row = 0
        while row < model.rowCount {
            var end = row + 1, scanning = row
            while scanning < end {
                for cell in byRow[scanning] ?? [] { end = max(end, cell.row + cell.rowSpan) }
                scanning += 1
            }
            result.append(row..<end); row = end
        }
        return result
    }
    var body: some View {
        let actualHeights = heights
        return ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(clusters, id: \.lowerBound) { rows in
                    ZStack(alignment: .topLeading) {
                        ForEach(model.cells.filter { rows.contains($0.row) }) { cell in
                            cellView(cell)
                                .frame(width: CGFloat(model.columnWidths[cell.column..<(cell.column + cell.columnSpan)].reduce(0, +)),
                                       height: CGFloat(actualHeights[cell.row..<(cell.row + cell.rowSpan)].reduce(0, +)), alignment: .topLeading)
                                .offset(x: CGFloat(model.columnWidths.prefix(cell.column).reduce(0, +)), y: CGFloat(actualHeights[rows.lowerBound..<cell.row].reduce(0, +)))
                        }
                        if editable {
                            ForEach(0..<model.columnCount, id: \.self) { column in
                                resizeHandle(column: column, row: nil)
                                    .frame(width: 7, height: CGFloat(actualHeights[rows].reduce(0, +)))
                                    .offset(x: CGFloat(model.columnWidths.prefix(column + 1).reduce(0, +)) - 3)
                            }
                            ForEach(rows, id: \.self) { row in
                                resizeHandle(column: nil, row: row)
                                    .frame(width: CGFloat(model.columnWidths.reduce(0, +)), height: 7)
                                    .offset(y: CGFloat(actualHeights[rows.lowerBound...row].reduce(0, +)) - 3)
                            }
                        }
                    }.frame(width: CGFloat(model.columnWidths.reduce(0, +)), height: CGFloat(actualHeights[rows].reduce(0, +)), alignment: .topLeading)
                }
            }.padding(.trailing, 4).padding(.bottom, 4)
        }
        .onAppear { configure() }
        .onChange(of: source) { _, value in
            guard value != controller.lastSource else { return }
            if let parsed = try? DocumentMarkup.locatedBlocks(value).first?.table { controller.model = parsed; measured = [:] }
        }
        .onChange(of: model.cells.map(\.id)) { _, _ in configure() }
    }
    private func configure() {
        controller.onChange = onEdit
        navigator.order = model.cells.sorted { $0.row == $1.row ? $0.column < $1.column : $0.row < $1.row }.map { $0.id.uuidString }
    }
    private func cellView(_ cell: DocumentTable.Cell) -> some View {
        let lines = cell.value.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        let isCode = lines.count >= 2 && lines[0].hasPrefix("```") && lines.last == "```"
        let language = isCode ? String(lines[0].dropFirst(3)) : ""
        let value = isCode ? lines.dropFirst().dropLast().joined(separator: "\n") : cell.value
        let reading = DocumentInlineEditor(markdown: value, fontSize: isCode ? 13 : 14, editable: editable, semibold: cell.header, literal: isCode, focusedOnAppear: true,
                             onFocus: { focused in if focused { activeCell = cell.id; navigator.activeID = cell.id.uuidString }; onFocus(focused) },
                             onHeight: { height in Task { @MainActor in if measured[cell.id] != height { measured[cell.id] = height } } },
                             onBoundary: { navigate(cell, direction: $0) },
                             onView: { navigator.register($0, id: cell.id.uuidString) }, contextMenu: { nativeMenu($0, cell: cell) }) { value in
            guard let index = controller.model.cells.firstIndex(where: { $0.id == cell.id }) else { return }
            controller.model.cells[index].value = isCode ? DocumentMarkup.fencedCode(value, language: language) : value
            controller.publish()
        }
        let alignment: Alignment = cell.attributes["vertical-align"] == "middle" ? .center : (cell.attributes["vertical-align"] == "bottom" ? .bottomLeading : .topLeading)
        let fill = cellFill(cell)
        return Group {
            if editable && activeCell == cell.id {
                reading
            } else if let html = cell.originalHTML, cell.value == cell.originalValue, let spans = DocumentMarkup.inlineSpans(html) {
                Text(cellAttributed(spans, size: isCode ? 13 : 14, semibold: cell.header))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .contentShape(Rectangle())
                    .onTapGesture { if editable { activeCell = cell.id; onFocus(true) } }
            } else {
                markdownCell(isCode ? value : cell.value, size: isCode ? 13 : 14, semibold: cell.header, mono: isCode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .contentShape(Rectangle())
                    .onTapGesture { if editable { activeCell = cell.id; onFocus(true) } }
            }
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .background(fill)
        .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: model.borderWidth))
        .contextMenu { tableMenu(cell) }.clipped()
        .help("点击输入；Tab / Shift-Tab 切换单元格；拖动框线调整宽度和高度；右键管理行列")
    }
    private func cellFill(_ cell: DocumentTable.Cell) -> Color {
        if let name = cell.attributes["background-color"], let fill = DocumentPalette.fill(name) { return Color(hex: fill.0, opacity: fill.1) }
        return cell.header ? Theme.bgOverlay : (cell.row.isMultiple(of: 2) ? Theme.bgSecondary : Theme.cardSurface)
    }
    private func cellAttributed(_ spans: [DocumentMarkup.InlineSpan], size: CGFloat, semibold: Bool) -> AttributedString {
        var attributed = AttributedString()
        for span in spans {
            var run = AttributedString(span.text)
            var font = Font.system(size: size, weight: span.strong || semibold ? .semibold : .regular, design: span.code || span.math ? .monospaced : .default)
            if span.emphasis { font = font.italic() }
            run.font = font
            if span.underline { run.underlineStyle = .single }
            if span.strike { run.strikethroughStyle = .single }
            if let hex = DocumentPalette.ink(span.textColor) { run.foregroundColor = Color(hex: hex) }
            else { run.foregroundColor = span.mention || span.link != nil ? Theme.Ink.claude : Theme.textPrimary }
            if let fill = DocumentPalette.fill(span.background) { run.backgroundColor = Color(hex: fill.0, opacity: fill.1) }
            if let link = span.link.flatMap(URL.init(string:)), DocumentRichText.allowedURL(link) { run.link = link }
            attributed += run
        }
        return attributed
    }
    private func markdownCell(_ value: String, size: CGFloat, semibold: Bool, mono: Bool) -> Text {
        let shown = value.isEmpty ? " " : value
        if mono { return Text(shown).font(.system(size: size, design: .monospaced)).foregroundStyle(Theme.textPrimary) }
        if var parsed = try? AttributedString(markdown: shown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            parsed.foregroundColor = Theme.textPrimary
            parsed.font = .system(size: size, weight: semibold ? .semibold : .regular)
            return Text(parsed)
        }
        return Text(shown).font(.system(size: size, weight: semibold ? .semibold : .regular))
    }
    @ViewBuilder private func tableMenu(_ cell: DocumentTable.Cell) -> some View {
        Button("上方插入行") { change { $0.insertRow(at: cell.row) } }
        Button("下方插入行") { change { $0.insertRow(at: cell.row + cell.rowSpan) } }
        Button("左侧插入列") { change { $0.insertColumn(at: cell.column) } }
        Button("右侧插入列") { change { $0.insertColumn(at: cell.column + cell.columnSpan) } }
        Divider()
        Button("与右侧合并") { change { $0.merge(cell.id, below: false) } }.disabled(model.mergeTarget(cell.id, below: false) == nil)
        Button("与下方合并") { change { $0.merge(cell.id, below: true) } }.disabled(model.mergeTarget(cell.id, below: true) == nil)
        Button("拆分单元格") { change { $0.split(cell.id) } }.disabled(cell.rowSpan == 1 && cell.columnSpan == 1)
        Button(cell.header ? "取消表头样式" : "设为表头样式") {
            change { table in if let index = table.cells.firstIndex(where: { $0.id == cell.id }) { table.cells[index].header.toggle() } }
        }
        Menu("框线粗细") {
            ForEach([0.5, 1, 2, 3], id: \.self) { width in Button("\(width.formatted()) pt") { change { $0.borderWidth = width } } }
        }
        Divider()
        Button("删除所在行", role: .destructive) { change { $0.deleteRow(at: cell.row) } }.disabled(model.rowCount <= 1)
        Button("删除所在列", role: .destructive) { change { $0.deleteColumn(at: cell.column) } }.disabled(model.columnCount <= 1)
    }
    private func navigate(_ cell: DocumentTable.Cell, direction: Int) -> Bool {
        if navigator.move(from: cell.id.uuidString, direction: direction) { return true }
        if direction > 0 && navigator.order.last == cell.id.uuidString {
            change { $0.insertRow(at: $0.rowCount) }
            configure()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                _ = navigator.move(from: cell.id.uuidString, direction: 1)
            }
        }
        return true
    }
    private func nativeMenu(_ menu: NSMenu, cell: DocumentTable.Cell) {
        menu.addItem(.separator())
        func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let handler = DocumentMenuAction(action)
            let item = NSMenuItem(title: title, action: #selector(DocumentMenuAction.run), keyEquivalent: "")
            item.target = handler; item.representedObject = handler; item.isEnabled = enabled
            menu.addItem(item)
        }
        add("上方插入行") { change { $0.insertRow(at: cell.row) } }
        add("下方插入行") { change { $0.insertRow(at: cell.row + cell.rowSpan) } }
        add("左侧插入列") { change { $0.insertColumn(at: cell.column) } }
        add("右侧插入列") { change { $0.insertColumn(at: cell.column + cell.columnSpan) } }
        add("与右侧合并", enabled: model.mergeTarget(cell.id, below: false) != nil) { change { $0.merge(cell.id, below: false) } }
        add("与下方合并", enabled: model.mergeTarget(cell.id, below: true) != nil) { change { $0.merge(cell.id, below: true) } }
        add("拆分单元格", enabled: cell.rowSpan > 1 || cell.columnSpan > 1) { change { $0.split(cell.id) } }
        add("自动适应内容") { change { table in
            table.columnWidths = DocumentTable(cells: table.cells, rowCount: table.rowCount, columnCount: table.columnCount).columnWidths
            table.rowHeights = Array(repeating: 48, count: table.rowCount)
        } }
        add(cell.header ? "取消表头样式" : "设为表头样式") { change { table in
            if let index = table.cells.firstIndex(where: { $0.id == cell.id }) { table.cells[index].header.toggle() }
        } }
        for width in [0.5, 1, 2, 3] { add("框线 \(width.formatted()) pt") { change { $0.borderWidth = width } } }
        add("删除所在行", enabled: model.rowCount > 1) { change { $0.deleteRow(at: cell.row) } }
        add("删除所在列", enabled: model.columnCount > 1) { change { $0.deleteColumn(at: cell.column) } }
    }
    private func change(_ update: (inout DocumentTable) -> Void) { controller.change(undoManager: navigator.activeView?.undoManager, update) }
    private func resizeHandle(column: Int?, row: Int?) -> some View {
        Rectangle().fill(Color.clear).contentShape(Rectangle())
            .onHover { inside in (inside ? (column != nil ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown) : NSCursor.arrow).set() }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if dragStart == nil {
                    // A border can be the first click in the table. Give its native
                    // editor focus so the window undo manager also owns this drag.
                    if let view = navigator.activeView ?? navigator.firstView { view.window?.makeFirstResponder(view) }
                    dragBefore = model; dragStart = column.map { model.columnWidths[$0] } ?? row.map { heights[$0] }
                }
                if let column { controller.model.columnWidths[column] = DocumentTable.clampWidth((dragStart ?? 150) + value.translation.width) }
                if let row { controller.model.rowHeights[row] = DocumentTable.clampHeight((dragStart ?? 48) + value.translation.height) }
            }.onEnded { _ in
                let changed = model
                if let before = dragBefore { controller.model = before; controller.change(undoManager: navigator.activeView?.undoManager) { $0 = changed } }
                dragStart = nil; dragBefore = nil
            })
            .help(column != nil ? "拖动调整列宽" : "拖动调整行高")
    }
}

private final class DocumentMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
