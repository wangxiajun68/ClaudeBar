import Foundation

/// Editable table topology and sizes, independent of AppKit and cloud transport.
struct DocumentTable: Sendable {
    struct Cell: Identifiable, Sendable {
        var id = UUID()
        var row: Int
        var column: Int
        var rowSpan = 1
        var columnSpan = 1
        var value: String
        var header = false
        var originalValue = ""
        var originalHTML: String?
        var attributes: [String: String] = [:]
    }
    var cells: [Cell]
    var rowCount: Int
    var columnCount: Int
    var columnWidths: [Double]
    var rowHeights: [Double]
    var borderWidth = 1.0
    var attributes: [String: String] = [:]
    init(cells: [Cell], rowCount: Int, columnCount: Int) {
        self.cells = cells; self.rowCount = rowCount; self.columnCount = columnCount
        var longest = Array(repeating: 0, count: columnCount)
        var hasCode = Array(repeating: false, count: columnCount)
        for cell in cells where (0..<columnCount).contains(cell.column) {
            if cell.value.contains("```") { hasCode[cell.column] = true }
            for line in cell.value.components(separatedBy: "\n") {
                longest[cell.column] = max(longest[cell.column], line.count)
            }
        }
        columnWidths = (0..<columnCount).map { column in
            hasCode[column] ? 300 : min(300, max(150, Double(longest[column]) * 7 + 24))
        }
        rowHeights = Array(repeating: 48, count: rowCount)
    }
    init(rows: [[String]]) {
        let count = rows.map(\.count).max() ?? 1
        let cells = rows.enumerated().flatMap { row, values in
            (0..<count).map { column in Cell(row: row, column: column, value: values.indices.contains(column) ? values[column] : "", header: row == 0) }
        }
        self.init(cells: cells, rowCount: max(1, rows.count), columnCount: max(1, count))
        fillHoles()
    }
    static func clampWidth(_ value: Double) -> Double { min(1200, max(72, value.isFinite ? value : 150)) }
    static func clampHeight(_ value: Double) -> Double { min(2000, max(32, value.isFinite ? value : 48)) }
    struct RowCluster: Identifiable {
        var id: Int { rows.lowerBound }
        let rows: Range<Int>
        let cellIndices: [Int]
    }
    struct Layout {
        let rowOffsets: [Double]
        let columnOffsets: [Double]
        let clusters: [RowCluster]
    }
    /// One linear pass per layout. Lazy rows receive their own cell indices;
    /// scrolling no longer scans every cell for each row that becomes visible.
    func layout(measured: [UUID: Double]) -> Layout {
        func offsets(_ sizes: [Double]) -> [Double] {
            var result = [0.0]
            result.reserveCapacity(sizes.count + 1)
            for size in sizes { result.append(result.last! + size) }
            return result
        }
        let columns = offsets(columnWidths)
        var heights = rowHeights
        var byRow = Array(repeating: [Int](), count: rowCount)
        for index in cells.indices {
            let cell = cells[index]
            byRow[cell.row].append(index)
            let content: Double
            if let height = measured[cell.id] {
                content = height + 24
            } else {
                let width = max(40, columns[cell.column + cell.columnSpan] - columns[cell.column] - 24)
                let lines = cell.value.components(separatedBy: "\n")
                let estimate = lines.reduce(0) { $0 + max(1, Int(ceil(Double($1.count) * 8 / width))) }
                content = Double(estimate * 21 + 4) + 24
            }
            let end = cell.row + cell.rowSpan
            let existing = heights[cell.row..<end].reduce(0, +)
            if content > existing { heights[end - 1] += content - existing }
        }
        var clusters: [RowCluster] = [], row = 0
        while row < rowCount {
            var end = row + 1, scanning = row
            var indices: [Int] = []
            while scanning < end {
                for index in byRow[scanning] {
                    end = max(end, cells[index].row + cells[index].rowSpan)
                    indices.append(index)
                }
                scanning += 1
            }
            clusters.append(RowCluster(rows: row..<end, cellIndices: indices))
            row = end
        }
        return Layout(rowOffsets: offsets(heights), columnOffsets: columns, clusters: clusters)
    }
    static func dimension(_ value: String, property: String) -> Double? {
        if let number = Double(value.replacingOccurrences(of: "px", with: "").trimmingCharacters(in: .whitespaces)) { return number }
        guard let range = value.range(of: "(?:^|;)\\s*" + property + ":\\s*([0-9.]+)(?:px)?(?:;|$)", options: .regularExpression) else { return nil }
        return Double(value[range].split(separator: ":").last!.replacingOccurrences(of: "px", with: "").replacingOccurrences(of: ";", with: "").trimmingCharacters(in: .whitespaces))
    }
    func cell(atRow row: Int, column: Int) -> Cell? {
        cells.first { row >= $0.row && row < $0.row + $0.rowSpan && column >= $0.column && column < $0.column + $0.columnSpan }
    }
    mutating func fillHoles() {
        var occupied: Set<Int> = []
        for cell in cells {
            for row in cell.row..<(cell.row + cell.rowSpan) { for column in cell.column..<(cell.column + cell.columnSpan) {
                occupied.insert(row * columnCount + column)
            } }
        }
        for row in 0..<rowCount { for column in 0..<columnCount where !occupied.contains(row * columnCount + column) {
            cells.append(Cell(row: row, column: column, value: "", header: row == 0))
        } }
    }
    mutating func insertRow(at position: Int) {
        guard rowCount < 5000 else { return }
        let position = min(rowCount, max(0, position))
        for index in cells.indices {
            if cells[index].row >= position { cells[index].row += 1 }
            else if cells[index].row + cells[index].rowSpan > position { cells[index].rowSpan += 1 }
        }
        rowCount += 1; rowHeights.insert(48, at: position); fillHoles()
    }
    mutating func insertColumn(at position: Int) {
        guard columnCount < 64 else { return }
        let position = min(columnCount, max(0, position))
        for index in cells.indices {
            if cells[index].column >= position { cells[index].column += 1 }
            else if cells[index].column + cells[index].columnSpan > position { cells[index].columnSpan += 1 }
        }
        columnCount += 1; columnWidths.insert(150, at: position); fillHoles()
    }
    mutating func deleteRow(at position: Int) {
        guard rowCount > 1, (0..<rowCount).contains(position) else { return }
        cells.removeAll { $0.row == position && $0.rowSpan == 1 }
        for index in cells.indices {
            if cells[index].row > position { cells[index].row -= 1 }
            else if cells[index].row + cells[index].rowSpan > position { cells[index].rowSpan -= 1 }
        }
        rowCount -= 1; rowHeights.remove(at: position)
    }
    mutating func deleteColumn(at position: Int) {
        guard columnCount > 1, (0..<columnCount).contains(position) else { return }
        cells.removeAll { $0.column == position && $0.columnSpan == 1 }
        for index in cells.indices {
            if cells[index].column > position { cells[index].column -= 1 }
            else if cells[index].column + cells[index].columnSpan > position { cells[index].columnSpan -= 1 }
        }
        columnCount -= 1; columnWidths.remove(at: position)
    }
    func mergeTarget(_ id: UUID, below: Bool) -> UUID? {
        guard let cell = cells.first(where: { $0.id == id }) else { return nil }
        return cells.first { other in
            below ? other.row == cell.row + cell.rowSpan && other.column == cell.column && other.columnSpan == cell.columnSpan
                  : other.column == cell.column + cell.columnSpan && other.row == cell.row && other.rowSpan == cell.rowSpan
        }?.id
    }
    mutating func merge(_ id: UUID, below: Bool) {
        guard let target = mergeTarget(id, below: below), let first = cells.firstIndex(where: { $0.id == id }), let second = cells.firstIndex(where: { $0.id == target }) else { return }
        if !cells[second].value.isEmpty { cells[first].value += (cells[first].value.isEmpty ? "" : "\n") + cells[second].value }
        if below { cells[first].rowSpan += cells[second].rowSpan } else { cells[first].columnSpan += cells[second].columnSpan }
        cells[first].originalHTML = nil; cells.remove(at: second)
    }
    mutating func split(_ id: UUID) {
        guard let index = cells.firstIndex(where: { $0.id == id }) else { return }
        let cell = cells[index]
        cells[index].rowSpan = 1; cells[index].columnSpan = 1
        for row in cell.row..<(cell.row + cell.rowSpan) { for column in cell.column..<(cell.column + cell.columnSpan) where row != cell.row || column != cell.column {
            cells.append(Cell(row: row, column: column, value: "", header: cell.header))
        } }
    }
    /// Keep original unedited cell HTML, including mentions and embedded content.
    func html(renderInline: (String) -> String) -> String {
        func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;") }
        func attrs(_ values: [String: String]) -> String {
            values.keys.sorted().filter { !$0.lowercased().hasPrefix("on") }.map { " " + $0 + "=\"" + escape(values[$0]!) + "\"" }.joined()
        }
        var tableAttrs = attributes
        tableAttrs["border"] = String(borderWidth)
        var output = "<table" + attrs(tableAttrs) + "><colgroup>"
        for width in columnWidths { output += "<col width=\"\(Int(width.rounded()))\"/>" }
        output += "</colgroup><tbody>"
        // Group once instead of filtering the full table for every output row.
        let byRow = Dictionary(grouping: cells.indices, by: { cells[$0].row })
        for row in 0..<rowCount {
            output += "<tr height=\"\(Int(rowHeights[row].rounded()))\">"
            for index in (byRow[row] ?? []).sorted(by: { cells[$0].column < cells[$1].column }) {
                let cell = cells[index]
                let tag = cell.header ? "th" : "td"
                var cellAttrs = cell.attributes
                cellAttrs["rowspan"] = cell.rowSpan > 1 ? String(cell.rowSpan) : nil
                cellAttrs["colspan"] = cell.columnSpan > 1 ? String(cell.columnSpan) : nil
                let body = cell.originalHTML != nil && cell.value == cell.originalValue ? cell.originalHTML! : renderInline(cell.value)
                output += "<" + tag + attrs(cellAttrs) + ">" + body + "</" + tag + ">"
            }
            output += "</tr>"
        }
        return output + "</tbody></table>"
    }
}
