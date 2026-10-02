import Foundation

/// A bounded, native document representation. HTML is parsed as data, never executed.
enum MarkdownBlock: Sendable {
    case heading(Int, String), paragraph(String), bullet(Int, String), numbered(Int, String, String)
    case quote(String), code(String, String), table([[String]]), rule
    case task(Int, Bool, String), embed(String, String), image(String, String)
}

enum DocumentMarkup {
    struct Heading: Identifiable, Sendable {
        let id: Int
        let level: Int
        let title: String
        let number: String
    }
    static func outline(_ blocks: [MarkdownBlock]) -> [Heading] {
        let minimum = blocks.compactMap { block -> Int? in if case .heading(let level, _) = block { return level }; return nil }.min() ?? 1
        var counters = Array(repeating: 0, count: 6)
        return blocks.enumerated().compactMap { index, block in
            guard case .heading(let level, let title) = block else { return nil }
            counters[level - 1] += 1
            if level < 6 { for slot in level..<6 { counters[slot] = 0 } }
            let number = counters[(minimum - 1)..<level].map { String(max(1, $0)) }.joined(separator: ".")
            return Heading(id: index, level: level, title: title, number: number)
        }
    }

    struct LocatedBlock: Sendable {
        let block: MarkdownBlock
        let range: NSRange
    }
    static func parse(_ source: String) throws -> [MarkdownBlock] {
        try locatedBlocks(source).map(\.block)
    }
    /// Ranges address the original UTF-16 source, including markup and Unicode.
    /// HTML fragments may produce several blocks sharing one source range.
    static func locatedBlocks(_ source: String) throws -> [LocatedBlock] {
        try Task.checkCancellation()
        var lines = source.components(separatedBy: "\n")
        var baseOffset = 0
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) { baseOffset = lines[0...close].reduce(0) { $0 + $1.utf16.count + 1 }; lines.removeSubrange(0...close) }
        var blocks: [MarkdownBlock] = [], paragraph: [String] = [], table: [[String]] = []
        var offsets = [baseOffset]
        for line in lines { offsets.append(offsets.last! + line.utf16.count + 1) }
        var ranges: [NSRange] = []
        var index = 0, startLine = 0, paragraphStart = 0, paragraphEnd = 0, tableStart = 0, tableEnd = 0
        func span(_ start: Int, _ end: Int) -> NSRange {
            NSRange(location: offsets[start], length: max(0, min((source as NSString).length, offsets[end] - 1) - offsets[start]))
        }
        func emit(_ block: MarkdownBlock) { blocks.append(block); ranges.append(span(startLine, index)) }
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); ranges.append(span(paragraphStart, paragraphEnd)); paragraph.removeAll() }
            if !table.isEmpty { blocks.append(.table(table)); ranges.append(span(tableStart, tableEnd)); table.removeAll() }
        }
        while index < lines.count {
            try Task.checkCancellation()
            startLine = index
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let marker = trimmed.first!, width = trimmed.prefix(while: { $0 == marker }).count
                let language = String(trimmed.dropFirst(width))
                var code: [String] = []
                while index < lines.count {
                    try Task.checkCancellation()
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                    if next.prefix(while: { $0 == marker }).count >= width && next.drop(while: { $0 == marker }).trimmingCharacters(in: .whitespaces).isEmpty { break }
                    code.append(lines[index - 1])
                }
                emit(.code(language, code.joined(separator: "\n"))); continue
            }
            if let tag = htmlBlockTag(trimmed) {
                flush()
                var html = [line]
                // Feishu exports commonly put a whole HTML table on one line.
                if !trimmed.contains("</" + tag) && !["img", "image", "hr", "br"].contains(tag) {
                    while index < lines.count {
                        try Task.checkCancellation()
                        let next = lines[index]; index += 1; html.append(next)
                        if next.lowercased().contains("</" + tag) { break }
                    }
                }
                for block in try HTMLFragment.blocks(html.joined(separator: "\n")) { emit(block) }; continue
            }
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                if !paragraph.isEmpty { flush() }
                if table.isEmpty { tableStart = startLine }; tableEnd = index
                let cells = tableCells(String(trimmed.dropFirst().dropLast()))
                if !cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " } }) { table.append(cells) }
                continue
            }
            if !table.isEmpty { flush() }
            if trimmed.isEmpty { flush(); continue }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { flush(); emit(.rule); continue }
            let marks = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(marks), trimmed.dropFirst(marks).hasPrefix(" ") {
                flush(); emit(.heading(marks, String(trimmed.dropFirst(marks + 1)).replacingOccurrences(of: "\\s+#+\\s*$", with: "", options: .regularExpression))); continue
            }
            if index < lines.count, !trimmed.isEmpty {
                let underline = lines[index].trimmingCharacters(in: .whitespaces)
                if underline.count >= 3 && (underline.allSatisfy { $0 == "=" } || underline.allSatisfy { $0 == "-" }) {
                    flush(); index += 1; emit(.heading(underline.first == "=" ? 1 : 2, trimmed)); continue
                }
            }
            let depth = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flush()
                let value = String(trimmed.dropFirst(2))
                if value.hasPrefix("[ ] ") || value.lowercased().hasPrefix("[x] ") { emit(.task(depth, value.lowercased().hasPrefix("[x]"), String(value.dropFirst(4)))) }
                else { emit(.bullet(depth, value)) }
                continue
            }
            if let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }), !trimmed[..<dot].isEmpty,
               trimmed[..<dot].allSatisfy({ $0.isNumber }), trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flush(); emit(.numbered(depth, String(trimmed[...dot]), String(trimmed[trimmed.index(dot, offsetBy: 2)...]))); continue
            }
            if trimmed.hasPrefix(">") { flush(); emit(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))); continue }
            if trimmed.hasPrefix("!["), let close = trimmed.range(of: "]("), trimmed.hasSuffix(")") {
                flush(); emit(.image(String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close.lowerBound]), String(trimmed[close.upperBound..<trimmed.index(before: trimmed.endIndex)]))); continue
            }
            if paragraph.isEmpty { paragraphStart = startLine }; paragraphEnd = index
            paragraph.append(HTMLFragment.inlineHTML(trimmed))
        }
        flush(); return zip(blocks, ranges).map { LocatedBlock(block: $0.0, range: $0.1) }
    }
    static func replacing(_ range: NSRange, in source: String, with replacement: String) -> String? {
        guard range.location >= 0, range.length >= 0, range.location <= (source as NSString).length,
              range.length <= (source as NSString).length - range.location,
              Range(range, in: source) != nil else { return nil }
        return (source as NSString).replacingCharacters(in: range, with: replacement)
    }
    /// Locate the original source heading for native editor navigation. Fenced
    /// code and HTML pre blocks are excluded, so duplicate text remains unambiguous.
    static func sourceLocation(_ heading: Heading, in source: String, headings: [Heading]) -> Int? {
        let lines = source.components(separatedBy: .newlines)
        var candidates: [(Int, String, Int)] = [], protected: [NSRange] = []
        var offset = 0, fenceStart = 0, fenceWidth = 0
        var fenceMarker: Character = "`"
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let end = offset + line.utf16.count + 1
            defer { offset = end }
            if fenceWidth > 0 {
                if trimmed.prefix(while: { $0 == fenceMarker }).count >= fenceWidth && trimmed.drop(while: { $0 == fenceMarker }).trimmingCharacters(in: .whitespaces).isEmpty {
                    protected.append(NSRange(location: fenceStart, length: end - fenceStart)); fenceWidth = 0
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fenceMarker = trimmed.first!; fenceWidth = trimmed.prefix(while: { $0 == fenceMarker }).count; fenceStart = offset; continue
            }
            let level = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(level), trimmed.dropFirst(level).hasPrefix(" ") {
                let title = String(trimmed.dropFirst(level + 1)).replacingOccurrences(of: "\\s+#+\\s*$", with: "", options: .regularExpression)
                candidates.append((level, title, offset))
            } else if !trimmed.isEmpty, index + 1 < lines.count {
                let underline = lines[index + 1].trimmingCharacters(in: .whitespaces)
                if underline.count >= 3 && (underline.allSatisfy { $0 == "=" } || underline.allSatisfy { $0 == "-" }) {
                    candidates.append((underline.first == "=" ? 1 : 2, trimmed, offset))
                }
            }
        }
        if fenceWidth > 0 { protected.append(NSRange(location: fenceStart, length: (source as NSString).length - fenceStart)) }
        let full = NSRange(source.startIndex..., in: source)
        let pre = try! NSRegularExpression(pattern: "<(pre|table)\\b[\\s\\S]*?</\\1\\s*>", options: .caseInsensitive)
        protected += pre.matches(in: source, range: full).map(\.range)
        candidates.removeAll { candidate in protected.contains { NSLocationInRange(candidate.2, $0) } }
        let html = try! NSRegularExpression(pattern: "<h([1-6])\\b[^>]*>[\\s\\S]*?</h\\1\\s*>", options: .caseInsensitive)
        for match in html.matches(in: source, range: full) where !protected.contains(where: { NSLocationInRange(match.range.location, $0) }) {
            guard let range = Range(match.range, in: source), let blocks = try? HTMLFragment.blocks(String(source[range])),
                  case .heading(let level, let title) = blocks.first else { continue }
            candidates.append((level, title, match.range.location))
        }
        let occurrence = headings.prefix(while: { $0.id != heading.id }).filter { $0.level == heading.level && $0.title == heading.title }.count
        let matches = candidates.sorted { $0.2 < $1.2 }.filter { $0.0 == heading.level && $0.1 == heading.title }
        return matches.indices.contains(occurrence) ? matches[occurrence].2 : nil
    }
    private static func htmlBlockTag(_ line: String) -> String? {
        guard let match = line.range(of: "^<(table|pre|h[1-6]|p|div|ul|ol|blockquote|whiteboard|iframe|file|image|img|video|audio|sheet|bitable|callout|hr)\\b", options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(line[match].dropFirst()).lowercased()
    }
    private static func tableCells(_ line: String) -> [String] {
        var cells: [String] = [], value = "", escaped = false, ticks = false
        for character in line {
            if escaped { value.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "`" { ticks.toggle() }
            if character == "|" && !ticks { cells.append(value.trimmingCharacters(in: .whitespaces)); value = "" }
            else { value.append(character) }
        }
        if escaped { value.append("\\") }
        cells.append(value.trimmingCharacters(in: .whitespaces)); return cells
    }
}

/// Tolerant fragment tokenizer: no web view, CSS, scripts, downloads or external entities.
private enum HTMLFragment {
    private final class Node {
        let tag: String
        let attributes: [String: String]
        var children: [Node] = []
        var value = ""
        init(_ tag: String = "", attributes: [String: String] = [:], value: String = "") { self.tag = tag; self.attributes = attributes; self.value = value }
        var plain: String { tag == "br" ? "\n" : value + children.map(\.plain).joined() }
    }
    private static let tokens = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?-->|<(?:[^\\\"'>]|\\\"[^\\\"]*\\\"|'[^']*')*>")
    private static let attrs = try! NSRegularExpression(pattern: "([a-zA-Z_:][\\w:.-]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
    private static let entities = try! NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")
    private static let inlineCode = try! NSRegularExpression(pattern: "(`+)([\\s\\S]*?)\\1")
    private static func decode(_ value: String) -> String {
        var result = value
        let mapping = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…", "copy": "©", "reg": "®"]
        for match in entities.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let keyRange = Range(match.range(at: 1), in: value), let fullRange = Range(match.range, in: result) else { continue }
            let key = String(value[keyRange])
            var replacement = mapping[key]
            if key.hasPrefix("#x"), let number = UInt32(key.dropFirst(2), radix: 16), let scalar = UnicodeScalar(number) { replacement = String(scalar) }
            else if key.hasPrefix("#"), let number = UInt32(key.dropFirst()), let scalar = UnicodeScalar(number) { replacement = String(scalar) }
            if let replacement { result.replaceSubrange(fullRange, with: replacement) }
        }
        return result
    }
    private static func tree(_ html: String) throws -> Node {
        let root = Node("root")
        var stack = [root], position = html.startIndex, count = 0
        for match in tokens.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            try Task.checkCancellation()
            guard let range = Range(match.range, in: html) else { continue }
            if position < range.lowerBound { stack.last?.children.append(Node(value: decode(String(html[position..<range.lowerBound])))) }
            position = range.upperBound
            let raw = String(html[range])
            if raw.hasPrefix("<!--") || raw.hasPrefix("<!") { continue }
            let closing = raw.hasPrefix("</")
            let tag = String(raw.dropFirst(closing ? 2 : 1).prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })).lowercased()
            if closing {
                if let index = stack.lastIndex(where: { $0.tag == tag }), index > 0 { stack.removeSubrange(index...) }
                continue
            }
            count += 1
            guard count <= 20_000, stack.count <= 64 else { throw CocoaError(.fileReadTooLarge) }
            var attributes: [String: String] = [:]
            for attribute in attrs.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
                guard let key = Range(attribute.range(at: 1), in: raw) else { continue }
                let valueRange = (2...4).compactMap { Range(attribute.range(at: $0), in: raw) }.first
                if let valueRange { attributes[String(raw[key]).lowercased()] = decode(String(raw[valueRange])) }
            }
            let node = Node(tag, attributes: attributes)
            stack.last?.children.append(node)
            if !raw.hasSuffix("/>") && !["br", "hr", "col", "img", "input", "meta", "link", "source"].contains(tag) { stack.append(node) }
        }
        if position < html.endIndex { stack.last?.children.append(Node(value: decode(String(html[position...])))) }
        return root
    }
    private static func safeLink(_ value: String) -> String? {
        guard let url = URL(string: value), url.scheme == "https", url.user == nil, url.host != nil else { return nil }
        return url.absoluteString
    }
    private static func inline(_ node: Node) -> String {
        let inner = node.value + node.children.map(inline).joined()
        switch node.tag {
        case "script", "style", "iframe": return ""
        case "br": return "\n"
        case "b", "strong": return "**" + inner + "**"
        case "i", "em": return "*" + inner + "*"
        case "s", "del": return "~~" + inner + "~~"
        case "a": return safeLink(node.attributes["href"] ?? "").map { "[" + inner.replacingOccurrences(of: "]", with: "\\]") + "](" + $0 + ")" } ?? inner
        case "pre": return "\n```" + (node.attributes["lang"] ?? "") + "\n" + node.plain + "\n```\n"
        case "code": return "`" + node.plain + "`"
        case "p", "div": return inner + "\n"
        case "img", "image": return node.attributes["alt"] ?? "图片"
        default: return inner
        }
    }
    static func inlineHTML(_ value: String) -> String {
        // Inline code is literal, including tags that would otherwise be HTML.
        let matches = inlineCode.matches(in: value, range: NSRange(value.startIndex..., in: value))
        if !matches.isEmpty {
            var output = "", position = value.startIndex
            for match in matches {
                guard let range = Range(match.range, in: value) else { continue }
                output += inlineHTMLText(String(value[position..<range.lowerBound])) + value[range]
                position = range.upperBound
            }
            return output + inlineHTMLText(String(value[position...]))
        }
        return inlineHTMLText(value)
    }
    private static func inlineHTMLText(_ value: String) -> String {
        guard value.contains("<"), value.contains(">"), let root = try? tree(value) else { return decode(value) }
        return root.children.map(inline).joined()
    }
    static func blocks(_ value: String) throws -> [MarkdownBlock] { convert(try tree(value)) }
    private static func convert(_ node: Node) -> [MarkdownBlock] {
        switch node.tag {
        case "script", "style": return []
        case "h1", "h2", "h3", "h4", "h5", "h6": return [.heading(Int(node.tag.suffix(1))!, node.children.map(inline).joined())]
        case "pre": return [.code(node.attributes["lang"] ?? node.attributes["language"] ?? "", node.plain)]
        case "table":
            var rows: [[Node]] = []
            func visit(_ item: Node) {
                if item.tag == "tr" { rows.append(item.children.filter { $0.tag == "td" || $0.tag == "th" }); return }
                for child in item.children where child.tag != "table" { visit(child) }
            }
            visit(node)
            var carries: [Int: (Int, String)] = [:], result: [[String]] = []
            for row in rows {
                var cells: [String] = [], column = 0
                func carry() {
                    while let entry = carries[column], entry.0 > 0 {
                        cells.append("↳ " + entry.1); carries[column] = entry.0 == 1 ? nil : (entry.0 - 1, entry.1); column += 1
                    }
                }
                for cell in row {
                    carry()
                    let value = cell.children.map(inline).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    let width = min(32, max(1, Int(cell.attributes["colspan"] ?? "") ?? 1))
                    let height = min(100, max(1, Int(cell.attributes["rowspan"] ?? "") ?? 1))
                    for offset in 0..<width {
                        cells.append(offset == 0 ? value : "↔")
                        if height > 1 { carries[column] = (height - 1, offset == 0 ? value : "↔") }
                        column += 1
                    }
                }
                carry(); result.append(cells)
            }
            return result.isEmpty ? [] : [.table(result)]
        case "whiteboard", "sheet", "bitable", "iframe", "video", "audio":
            let names = ["whiteboard": "白板", "sheet": "电子表格", "bitable": "多维表格", "iframe": "嵌入内容", "video": "视频", "audio": "音频"]
            return [.embed(node.attributes["title"] ?? names[node.tag] ?? "嵌入内容", node.tag)]
        case "file": return [.embed(node.attributes["name"] ?? node.attributes["filename"] ?? "附件", "file")]
        case "img", "image": return [.image(node.attributes["alt"] ?? node.attributes["title"] ?? "图片", node.attributes["src"] ?? "")]
        case "hr": return [.rule]
        case "blockquote", "callout": return [.quote(node.children.map(inline).joined().trimmingCharacters(in: .whitespacesAndNewlines))]
        case "ul", "ol": return node.children.filter { $0.tag == "li" }.enumerated().map { index, item in node.tag == "ol" ? .numbered(0, "\(index + 1).", item.children.map(inline).joined()) : .bullet(0, item.children.map(inline).joined()) }
        case "p": return [.paragraph(node.children.map(inline).joined().trimmingCharacters(in: .whitespacesAndNewlines))]
        case "": return node.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.paragraph(node.value)]
        default: return node.children.flatMap(convert)
        }
    }
}
