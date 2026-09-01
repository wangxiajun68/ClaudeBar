import AppKit
import SwiftUI

/// Expand / collapse token for the raw JSON outline. Parent owns this so the
/// toolbar buttons sit next to the 请求/改写 picker.
final class JSONFoldControl: ObservableObject {
    @Published private(set) var tick = 0
    @Published private(set) var expand: Bool?

    func expandAll() {
        expand = true
        tick += 1
    }

    func collapseAll() {
        expand = false
        tick += 1
    }
}

/// Parsed JSON (or SSE) for the Traffic inspector's 原始 pane.
enum JSONDocument {
    case empty
    case tree(JSONNode)
    case sse(events: [JSONSSEEvent], truncated: Int)
    case text(String)
}

struct JSONSSEEvent: Identifiable {
    let id: Int
    let name: String
    let preview: String
    let node: JSONNode?
    let raw: String
}

struct JSONNode: Identifiable {
    enum Kind { case object, array, string, number, bool, null }

    let id: String
    let key: String
    let kind: Kind
    let count: Int
    let scalar: String?
    let children: [JSONNode]

    var isContainer: Bool { kind == .object || kind == .array }
}

enum JSONTree {
    private static let arrayCap = 80
    private static let sseCap = 400

    static func parse(_ raw: String) -> JSONDocument {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) {
            return .tree(build(key: "", value: obj, path: "$"))
        }
        if looksLikeSSE(trimmed) {
            return parseSSE(trimmed)
        }
        return .text(raw)
    }

    static func pretty(_ raw: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else { return raw }
        return text.replacingOccurrences(of: "\\/", with: "/")
    }

    // MARK: - JSON

    private static func build(key: String, value: Any, path: String) -> JSONNode {
        if value is NSNull {
            return JSONNode(id: path, key: key, kind: .null, count: 0, scalar: "null", children: [])
        }
        if isBool(value), let n = value as? NSNumber {
            let v = n.boolValue ? "true" : "false"
            return JSONNode(id: path, key: key, kind: .bool, count: 0, scalar: v, children: [])
        }
        if let n = value as? NSNumber {
            return JSONNode(id: path, key: key, kind: .number, count: 0, scalar: numberText(n), children: [])
        }
        if let s = value as? String {
            return JSONNode(id: path, key: key, kind: .string, count: 0, scalar: s, children: [])
        }
        if let arr = value as? [Any] {
            let shown = min(arr.count, arrayCap)
            var children: [JSONNode] = []
            children.reserveCapacity(shown)
            for i in 0..<shown {
                children.append(build(key: "", value: arr[i], path: "\(path)/\(i)"))
            }
            return JSONNode(id: path, key: key, kind: .array, count: arr.count, scalar: nil, children: children)
        }
        if let dict = value as? [String: Any] {
            let keys = dict.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let children = keys.map { k in build(key: k, value: dict[k] as Any, path: "\(path)/\(k)") }
            return JSONNode(id: path, key: key, kind: .object, count: dict.count, scalar: nil, children: children)
        }
        let fallback = String(describing: value)
        return JSONNode(id: path, key: key, kind: .string, count: 0, scalar: fallback, children: [])
    }

    private static func isBool(_ any: Any) -> Bool {
        if any is Bool { return true }
        guard let n = any as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func numberText(_ n: NSNumber) -> String {
        let d = n.doubleValue
        if d.rounded() == d, abs(d) <= Double(Int64.max) {
            return "\(n.int64Value)"
        }
        return n.stringValue
    }

    // MARK: - SSE

    private static func looksLikeSSE(_ s: String) -> Bool {
        s.hasPrefix("event:") || s.hasPrefix("data:") || s.contains("\nevent:") || s.contains("\ndata:")
    }

    private static func parseSSE(_ raw: String) -> JSONDocument {
        var parser = LineSSEParser()
        var events: [(String, String, [String: Any]?)] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            if let ev = parser.push(line: trimmed) {
                events.append((ev.name, ev.data, ev.json))
            }
        }
        if let ev = parser.finish() {
            events.append((ev.name, ev.data, ev.json))
        }
        let extra = max(0, events.count - sseCap)
        let slice = extra > 0 ? Array(events.suffix(sseCap)) : events
        let nodes: [JSONSSEEvent] = slice.enumerated().map { i, ev in
            let (name, data, json) = ev
            let node = json.map { build(key: "", value: $0, path: "sse/\(i)") }
            let preview: String
            if let node {
                preview = node.isContainer ? (node.kind == .array ? "[\(node.count)]" : "{\(node.count)}") : (node.scalar ?? "")
            } else {
                preview = String(data.prefix(80))
            }
            return JSONSSEEvent(id: i, name: name.isEmpty ? "data" : name, preview: preview, node: node, raw: data)
        }
        return .sse(events: nodes, truncated: extra)
    }
}

// MARK: - View

struct JSONTreeView: View {
    let source: String
    var empty: String = "(empty)"
    var parseID: String = ""
    @ObservedObject var fold: JSONFoldControl
    @State private var document: JSONDocument?

    var body: some View {
        Group {
            switch document ?? .empty {
            case .empty:
                Text(source.isEmpty ? empty : "解析中…")
                    .font(Theme.Font.bodySmall)
                    .foregroundColor(Theme.textTertiary())
                    .padding(Theme.Space.s16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .tree(let root):
                ScrollView {
                    JSONNodeRow(node: root, depth: 0, fold: fold, defaultOpen: true)
                        .padding(.horizontal, Theme.Space.s12)
                        .padding(.vertical, Theme.Space.s8)
                }
            case .sse(let events, let truncated):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if truncated > 0 {
                            Text("共 \(events.count + truncated) 个事件，显示最后 \(events.count) 个")
                                .font(Theme.Font.caption)
                                .foregroundColor(Theme.statusWarning)
                                .padding(.bottom, 4)
                        }
                        ForEach(events) { ev in
                            JSONSSERow(event: ev, fold: fold)
                        }
                    }
                    .padding(.horizontal, Theme.Space.s12)
                    .padding(.vertical, Theme.Space.s8)
                }
            case .text(let s):
                PlainDumpView(text: s, empty: empty)
            }
        }
        .task(id: parseID.isEmpty ? "\(source.count)" : parseID) {
            let src = source
            let doc = await Task.detached(priority: .utility) { JSONTree.parse(src) }.value
            document = doc
        }
    }
}

private struct JSONSSERow: View {
    let event: JSONSSEEvent
    @ObservedObject var fold: JSONFoldControl
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Theme.textTertiary())
                        .frame(width: 10)
                    Text(event.name)
                        .font(Theme.Font.microMono)
                        .foregroundColor(Theme.textSecondary)
                    Text(event.preview)
                        .font(Theme.Font.microMono)
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            if open {
                if let node = event.node {
                    JSONNodeRow(node: node, depth: 1, fold: fold, defaultOpen: true)
                } else {
                    Text(event.raw)
                        .font(Theme.Font.microMono)
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                        .padding(.leading, 16)
                }
            }
        }
        .onChange(of: fold.tick) { _, _ in
            if let v = fold.expand { open = v }
        }
    }
}

private struct JSONNodeRow: View {
    let node: JSONNode
    let depth: Int
    @ObservedObject var fold: JSONFoldControl
    var defaultOpen: Bool
    @State private var open: Bool

    init(node: JSONNode, depth: Int, fold: JSONFoldControl, defaultOpen: Bool) {
        self.node = node
        self.depth = depth
        self.fold = fold
        self.defaultOpen = defaultOpen
        let start: Bool
        if let v = fold.expand {
            start = v && depth <= 6
        } else {
            start = defaultOpen
        }
        _open = State(initialValue: start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if open, node.isContainer {
                ForEach(node.children) { child in
                    JSONNodeRow(
                        node: child,
                        depth: depth + 1,
                        fold: fold,
                        defaultOpen: false)
                }
                closer
            } else if open, node.kind == .string, let scalar = node.scalar, isLongString(scalar) {
                Text(quoted(scalar))
                    .font(Theme.Font.microMono)
                    .foregroundColor(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, CGFloat(depth + 1) * 14)
                    .padding(.bottom, 2)
            }
        }
        .onChange(of: fold.tick) { _, _ in
            guard node.isContainer || (node.kind == .string && isLongString(node.scalar ?? "")) else { return }
            if let v = fold.expand {
                open = v && depth <= 6
            }
        }
    }

    private var header: some View {
        Button {
            if expandable { open.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Group {
                    if expandable {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                    } else {
                        Color.clear
                    }
                }
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(Theme.textTertiary())
                .frame(width: 10)

                if !node.key.isEmpty {
                    Text("\"\(node.key)\":")
                        .font(Theme.Font.microMono)
                        .foregroundColor(Theme.textSecondary)
                }

                Text(open && node.isContainer ? opener : inlineValue)
                    .font(Theme.Font.microMono)
                    .foregroundColor(valueColor)
                    .lineLimit(open && node.kind == .string ? 20 : 1)
                    .textSelection(.enabled)

                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 14)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var closer: some View {
        Text(node.kind == .array ? "]" : "}")
            .font(Theme.Font.microMono)
            .foregroundColor(Theme.textSecondary)
            .padding(.leading, CGFloat(depth) * 14 + 14)
    }

    private var expandable: Bool {
        node.isContainer || (node.kind == .string && isLongString(node.scalar ?? ""))
    }

    private var opener: String {
        node.kind == .array ? "[" : "{"
    }

    private var inlineValue: String {
        switch node.kind {
        case .object:
            return node.count == 0 ? "{}" : "{ \(node.count) }"
        case .array:
            return node.count == 0 ? "[]" : "[ \(node.count) ]"
        case .string:
            return quoted(clip(node.scalar ?? "", 80))
        case .number, .bool, .null:
            return node.scalar ?? ""
        }
    }

    private var valueColor: Color {
        switch node.kind {
        case .string: return Theme.textPrimary
        case .number, .bool: return Theme.claudeHi
        case .null: return Theme.textTertiary()
        default: return Theme.textSecondary
        }
    }

    private func isLongString(_ s: String) -> Bool {
        s.count > 80 || s.contains("\n")
    }

    private func quoted(_ s: String) -> String {
        "\"\(s)\""
    }

    private func clip(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        if one.count <= n { return one }
        return String(one.prefix(n)) + "…"
    }
}
