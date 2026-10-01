import SwiftUI

/// Exact source-to-model token flow. Both ends of every ribbon use one shared
/// angular scale; layout gaps never inflate a small or zero-valued observation.
struct UsageRelationshipPlot: View {
    struct Row {
        let name: String
        let tokens: Int
        let cells: [Int]
    }

    let rows: [Row]
    let sourceLabels: [String]
    let sourceColors: [Color]

    private struct Node {
        let index: Int
        let start: Double
        let end: Double
    }
    private struct Ribbon {
        let source: Int
        let tokens: Double
        let sourceStart: Double
        let sourceEnd: Double
        let modelStart: Double
        let modelEnd: Double
    }
    private struct Diagram {
        let sources: [Node]
        let models: [Node]
        let ribbons: [Ribbon]
        let total: Double
    }

    private var diagram: Diagram {
        let displayed = Array(rows.prefix(8))
        let sourceCount = min(3, sourceLabels.count)
        let cells = displayed.map { row in
            (0..<sourceCount).map { index in
                row.cells.indices.contains(index) ? Double(max(0, row.cells[index])) : 0
            }
        }
        let sourceTotals = (0..<sourceCount).map { source in cells.reduce(0.0) { $0 + $1[source] } }
        let modelTotals = cells.map { $0.reduce(0, +) }
        let sourceIndices = sourceTotals.indices.filter { sourceTotals[$0] > 0 }
        let modelIndices = modelTotals.indices.filter { modelTotals[$0] > 0 }
        let total = sourceTotals.reduce(0, +)
        guard total > 0, total.isFinite else { return Diagram(sources: [], models: [], ribbons: [], total: 0) }

        let gap = 0.045
        let largestCount = max(sourceIndices.count, modelIndices.count)
        let occupied = Double.pi - 0.14 - Double(max(0, largestCount - 1)) * gap
        let tokenAngle = occupied / total
        func nodes(indices: [Int], totals: [Double], start: Double) -> [Node] {
            let padding = (Double.pi - occupied - Double(max(0, indices.count - 1)) * gap) / 2
            var cursor = start + padding
            return indices.map { index in
                let end = cursor + totals[index] * tokenAngle
                let node = Node(index: index, start: cursor, end: end)
                cursor = end + gap
                return node
            }
        }
        let sources = nodes(indices: sourceIndices, totals: sourceTotals, start: .pi / 2)
        let models = nodes(indices: modelIndices, totals: modelTotals, start: -.pi / 2)
        var sourceCursor = Dictionary(uniqueKeysWithValues: sources.map { ($0.index, $0.start) })
        var modelCursor = Dictionary(uniqueKeysWithValues: models.map { ($0.index, $0.start) })
        var ribbons: [Ribbon] = []
        for source in sourceIndices {
            for model in modelIndices {
                let value = cells[model][source]
                guard value > 0 else { continue }
                let width = value * tokenAngle
                let sourceStart = sourceCursor[source]!
                let modelStart = modelCursor[model]!
                ribbons.append(Ribbon(source: source, tokens: value,
                                      sourceStart: sourceStart, sourceEnd: sourceStart + width,
                                      modelStart: modelStart, modelEnd: modelStart + width))
                sourceCursor[source] = sourceStart + width
                modelCursor[model] = modelStart + width
            }
        }
        return Diagram(sources: sources, models: models,
                       ribbons: ribbons.sorted { $0.tokens > $1.tokens }, total: total)
    }

    var body: some View {
        let layout = diagram
        Canvas { context, size in
            guard layout.total > 0 else {
                context.draw(Text("暂无匹配来源记录").font(Theme.Font.caption).foregroundColor(Theme.textSecondary),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) * 0.38
            let innerRadius = radius - 7
            for ribbon in layout.ribbons {
                var path = Path()
                path.move(to: point(ribbon.sourceStart, center: center, radius: innerRadius))
                path.addArc(center: center, radius: innerRadius,
                            startAngle: .radians(ribbon.sourceStart), endAngle: .radians(ribbon.sourceEnd), clockwise: false)
                path.addQuadCurve(to: point(ribbon.modelStart, center: center, radius: innerRadius), control: center)
                path.addArc(center: center, radius: innerRadius,
                            startAngle: .radians(ribbon.modelStart), endAngle: .radians(ribbon.modelEnd), clockwise: false)
                path.addQuadCurve(to: point(ribbon.sourceStart, center: center, radius: innerRadius), control: center)
                path.closeSubpath()
                let color = sourceColor(ribbon.source)
                context.fill(path, with: .color(color.opacity(Theme.isDark ? 0.40 : 0.30)))
                context.stroke(path, with: .color(color.opacity(Theme.isDark ? 0.48 : 0.32)), lineWidth: 0.5)
            }
            for source in layout.sources {
                drawNode(source, context: &context, center: center, radius: radius, color: sourceColor(source.index))
                let label = compactSource(sourceLabels[source.index])
                context.draw(Text(label).font(Theme.Font.microMedium).foregroundColor(Theme.textPrimary),
                             at: point((source.start + source.end) / 2, center: center, radius: radius + 17))
            }
            for model in layout.models {
                drawNode(model, context: &context, center: center, radius: radius, color: Theme.textSecondary.opacity(Theme.isDark ? 0.8 : 0.6))
                context.draw(Text("\(model.index + 1)").font(Theme.Font.microMono).foregroundColor(Theme.textPrimary),
                             at: point((model.start + model.end) / 2, center: center, radius: radius + 17))
            }
        }
        .frame(width: 280, height: 260)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .help(accessibilitySummary)
    }

    private func point(_ angle: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + CGFloat(cos(angle)) * radius,
                y: center.y + CGFloat(sin(angle)) * radius)
    }

    private func drawNode(_ node: Node, context: inout GraphicsContext, center: CGPoint, radius: CGFloat, color: Color) {
        var arc = Path()
        arc.addArc(center: center, radius: radius,
                   startAngle: .radians(node.start), endAngle: .radians(node.end), clockwise: false)
        context.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: 10, lineCap: .butt))
    }

    private func sourceColor(_ index: Int) -> Color {
        sourceColors.indices.contains(index) ? sourceColors[index] : Color(hex: 0x6A9BCC)
    }

    private func compactSource(_ label: String) -> String {
        if label.localizedCaseInsensitiveContains("claude") { return "CC" }
        if label.localizedCaseInsensitiveContains("codex") { return "Codex" }
        return String(label.prefix(3))
    }

    private var accessibilitySummary: String {
        let entries = rows.prefix(8).enumerated().map { index, row in
            let cells = sourceLabels.prefix(3).enumerated().map { source, label in
                let value = row.cells.indices.contains(source) ? max(0, row.cells[source]) : 0
                return "\(label) \(value.formatted()) Token"
            }.joined(separator: "，")
            return "模型 \(index + 1)，\(row.name)，模型总量 \(row.tokens.formatted()) Token；\(cells)"
        }.joined(separator: "。")
        return "来源与模型流向图，两端弧宽使用相同 Token 比例，零值不绘制。\(entries)"
    }
}
