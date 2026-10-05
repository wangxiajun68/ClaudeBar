import AppKit
import SwiftUI

@MainActor final class DocumentTableController: ObservableObject {
    @Published var model: DocumentTable { didSet { cachedLayout = nil } }
    private var cachedLayout: (measured: [UUID: Double], layout: DocumentTable.Layout)?
    var onChange: (String) -> Void = { _ in }
    var lastSource = ""
    init(_ model: DocumentTable) { self.model = model }
    /// Focus/selection updates do not change table geometry. Keep one result;
    /// model mutations (including nested inout edits/undo) invalidate it.
    func layout(measured: [UUID: Double]) -> DocumentTable.Layout {
        if let cachedLayout, cachedLayout.measured == measured { return cachedLayout.layout }
        let layout = model.layout(measured: measured)
        cachedLayout = (measured, layout)
        return layout
    }
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
    var body: some View {
        let layout = controller.layout(measured: measured.mapValues { Double($0) })
        let columns = layout.columnOffsets, heights = layout.rowOffsets
        return ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(layout.clusters) { cluster in
                    let rows = cluster.rows
                    ZStack(alignment: .topLeading) {
                        ForEach(cluster.cellIndices.map { model.cells[$0] }) { cell in
                            cellView(cell)
                                .frame(width: CGFloat(columns[cell.column + cell.columnSpan] - columns[cell.column]),
                                       height: CGFloat(heights[cell.row + cell.rowSpan] - heights[cell.row]), alignment: .topLeading)
                                .offset(x: CGFloat(columns[cell.column]), y: CGFloat(heights[cell.row] - heights[rows.lowerBound]))
                        }
                        if editable {
                            ForEach(0..<model.columnCount, id: \.self) { column in
                                resizeHandle(column: column, row: nil)
                                    .frame(width: 7, height: CGFloat(heights[rows.upperBound] - heights[rows.lowerBound]))
                                    .offset(x: CGFloat(columns[column + 1]) - 3)
                            }
                            ForEach(rows, id: \.self) { row in
                                resizeHandle(column: nil, row: row)
                                    .frame(width: CGFloat(columns.last!), height: 7)
                                    .offset(y: CGFloat(heights[row + 1] - heights[rows.lowerBound]) - 3)
                            }
                        }
                    }.frame(width: CGFloat(columns.last!), height: CGFloat(heights[rows.upperBound] - heights[rows.lowerBound]), alignment: .topLeading)
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
        let alignment: Alignment = cell.attributes["vertical-align"] == "middle" ? .center : (cell.attributes["vertical-align"] == "bottom" ? .bottomLeading : .topLeading)
        let fill = cellFill(cell)
        return Group {
            if editable && activeCell == cell.id {
                editor(cell)
            } else {
                DocumentTableCellText(cell: cell, textColor: Theme.textPrimary, linkColor: Theme.Ink.claude)
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
    private func editor(_ cell: DocumentTable.Cell) -> DocumentInlineEditor {
        let lines = cell.value.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        let isCode = lines.count >= 2 && lines[0].hasPrefix("```") && lines.last == "```"
        let language = isCode ? String(lines[0].dropFirst(3)) : ""
        let value = isCode ? lines.dropFirst().dropLast().joined(separator: "\n") : cell.value
        return DocumentInlineEditor(markdown: value, fontSize: isCode ? 13 : 14, editable: editable, semibold: cell.header, literal: isCode, focusedOnAppear: true,
                             onFocus: { focused in if focused { activeCell = cell.id; navigator.activeID = cell.id.uuidString }; onFocus(focused) },
                             onHeight: { height in Task { @MainActor in if measured[cell.id] != height { measured[cell.id] = height } } },
                             onBoundary: { navigate(cell, direction: $0) },
                             onView: { navigator.register($0, id: cell.id.uuidString) }, contextMenu: { nativeMenu($0, cell: cell) }) { value in
            guard let index = controller.model.cells.firstIndex(where: { $0.id == cell.id }) else { return }
            controller.model.cells[index].value = isCode ? DocumentMarkup.fencedCode(value, language: language) : value
            controller.publish()
        }
    }
    private func cellFill(_ cell: DocumentTable.Cell) -> Color {
        if let name = cell.attributes["background-color"], let fill = DocumentPalette.fill(name) { return Color(hex: fill.0, opacity: fill.1) }
        return cell.header ? Theme.bgOverlay : (cell.row.isMultiple(of: 2) ? Theme.bgSecondary : Theme.cardSurface)
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
                    dragBefore = model
                    dragStart = column.map { model.columnWidths[$0] } ?? row.map { row in
                        let offsets = controller.layout(measured: measured.mapValues { Double($0) }).rowOffsets
                        return offsets[row + 1] - offsets[row]
                    }
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

/// Stable read-only content has no dependency on focus, selection or edit mode.
/// Pass appearance colors explicitly so changing the theme invalidates the text.
private struct DocumentTableCellText: View {
    let cell: DocumentTable.Cell
    let textColor: Color
    let linkColor: Color
    var body: some View {
        let lines = cell.value.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        let isCode = lines.count >= 2 && lines[0].hasPrefix("```") && lines.last == "```"
        let value = isCode ? lines.dropFirst().dropLast().joined(separator: "\n") : cell.value
        if let html = cell.originalHTML, cell.value == cell.originalValue, let spans = DocumentMarkup.inlineSpans(html) {
            Text(cellAttributed(spans, size: isCode ? 13 : 14, semibold: cell.header))
        } else {
            markdownCell(value, size: isCode ? 13 : 14, semibold: cell.header, mono: isCode)
        }
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
            else { run.foregroundColor = span.mention || span.link != nil ? linkColor : textColor }
            if let fill = DocumentPalette.fill(span.background) { run.backgroundColor = Color(hex: fill.0, opacity: fill.1) }
            if let link = span.link.flatMap(URL.init(string:)), DocumentRichText.allowedURL(link) { run.link = link }
            attributed += run
        }
        return attributed
    }
    private func markdownCell(_ value: String, size: CGFloat, semibold: Bool, mono: Bool) -> Text {
        let shown = value.isEmpty ? " " : value
        if mono { return Text(shown).font(.system(size: size, design: .monospaced)).foregroundStyle(textColor) }
        if var parsed = try? AttributedString(markdown: shown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            parsed.foregroundColor = textColor
            parsed.font = .system(size: size, weight: semibold ? .semibold : .regular)
            return Text(parsed)
        }
        return Text(shown).font(.system(size: size, weight: semibold ? .semibold : .regular))
    }
}
