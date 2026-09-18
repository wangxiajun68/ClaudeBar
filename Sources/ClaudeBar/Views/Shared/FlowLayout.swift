import SwiftUI

/// Content-sized items packed left to right, wrapping to a new row when the
/// next one does not fit — a "tag cloud" whose rows start on a shared edge.
///
/// Each subview is measured at its **ideal** size and placed at exactly that
/// size, so nothing is ever compressed to fit a column. That is the difference
/// between this and a `LazyVGrid` of equal cells: the grid is tidier as a
/// silhouette, but keeping it tidy is what forces a label to truncate. Here the
/// row rhythm stays regular and the labels stay whole.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var rowSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: width.isFinite ? width : widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        for row in rows(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(subviews: Subviews, width: CGFloat) -> [Row] {
        var out: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > width {
                out.append(current)
                current = Row()
            }
            current.indices.append(index)
            current.width += current.indices.count == 1 ? size.width : spacing + size.width
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { out.append(current) }
        return out
    }
}
