import Foundation

/// A bounded, native document representation. HTML is parsed as data, never executed.
enum MarkdownBlock: Sendable {
    case heading(Int, String), paragraph(String), bullet(Int, String), numbered(Int, String, String)
    case quote(String), callout(String), code(String, String), table([[String]]), rule
    case task(Int, Bool, String), embed(String, String), image(String, String)
}

/// Feishu hue names from the official docx XML palette. Views turn these into Theme colors.
enum DocumentPalette {
    private static let hues: [String: UInt] = [
        "red": 0xD4534A, "orange": 0xE07A2F, "yellow": 0xC59212, "green": 0x2F8F5B,
        "blue": 0x3D7DFF, "purple": 0x7A5CC4, "gray": 0x6E7580
    ]
    private static func parts(_ name: String) -> (UInt, String)? {
        let value = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let hex = hues[value] { return (hex, "solid") }
        for (prefix, kind) in [("light-", "light"), ("medium-", "medium")] where value.hasPrefix(prefix) {
            if let hex = hues[String(value.dropFirst(prefix.count))] { return (hex, kind) }
        }
        return nil
    }
    static func ink(_ name: String) -> UInt? { parts(name)?.0 }
    static func fill(_ name: String) -> (UInt, Double)? {
        guard let (hex, kind) = parts(name) else { return nil }
        return (hex, kind == "light" ? 0.16 : (kind == "medium" ? 0.30 : 0.22))
    }
}

enum DocumentMarkup {
    struct Heading: Identifiable, Sendable {
        let id: Int
        let level: Int
        let title: String
        let number: String
    }
    /// Numbered outline of the document's headings.
    ///
    /// Feishu's docx XML goes up to `<h9>`, and `HTMLFragment` converts all
    /// nine, but the numbering only ever had six slots: a level-7 heading
    /// indexed `counters[6]` and trapped. Levels are therefore clamped into
    /// the six-deep numbering model instead of trusted.
    static func outline(_ blocks: [MarkdownBlock]) -> [Heading] {
        func depth(_ level: Int) -> Int { min(max(level, 1), 6) }
        let minimum = blocks.compactMap { block -> Int? in
            if case .heading(let level, _) = block { return depth(level) }
            return nil
        }.min() ?? 1
        var counters = Array(repeating: 0, count: 6)
        return blocks.enumerated().compactMap { index, block in
            guard case .heading(let rawLevel, let title) = block else { return nil }
            let level = depth(rawLevel)
            counters[level - 1] += 1
            for slot in level..<6 { counters[slot] = 0 }
            let number = counters[(minimum - 1)..<level].map { String(max(1, $0)) }.joined(separator: ".")
            return Heading(id: index, level: level, title: title, number: number)
        }
    }

    /// Presentation metadata carried beside the original source. Editing still
    /// replaces the source range, so unread markup is left untouched.
    struct Chrome: Sendable {
        var emoji = ""
        var background = ""
        var border = ""
        var textColor = ""
        var align = ""
        var ratio = 0.0
        var column = 0
        var columns = 1
        var caption = ""
        var language = ""
        var link = ""
        var sequence = ""
        var numbered = false
        var width = 0.0
        var height = 0.0
    }
    struct InlineSpan: Sendable {
        var text: String
        var strong = false
        var emphasis = false
        var strike = false
        var code = false
        var underline = false
        var link: String?
        var textColor = ""
        var background = ""
        var math = false
        var mention = false
    }
    struct LocatedBlock: Sendable {
        let block: MarkdownBlock
        var range: NSRange
        var htmlTag: String? = nil
        var table: DocumentTable? = nil
        var group: String? = nil
        var role: String? = nil
        var chrome = Chrome()
    }
    static func inlineSpans(_ source: String) -> [InlineSpan]? { HTMLFragment.spans(source) }
    static func parse(_ source: String) throws -> [MarkdownBlock] {
        try locatedBlocks(source).map(\.block)
    }
    /// Ranges address the original UTF-16 source, including markup and Unicode.
    /// HTML fragments may produce several blocks sharing one source range.
    static func locatedBlocks(_ source: String) throws -> [LocatedBlock] {
        try Task.checkCancellation()
        var rawLines = source.components(separatedBy: "\n")
        var lines = rawLines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let sourceLength = (source as NSString).length
        var baseOffset = 0
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) { baseOffset = rawLines[0...close].reduce(0) { $0 + $1.utf16.count + 1 }; lines.removeSubrange(0...close); rawLines.removeSubrange(0...close) }
        var blocks: [MarkdownBlock] = [], paragraph: [String] = [], table: [[String]] = []
        var offsets = [baseOffset]
        for line in rawLines { offsets.append(offsets.last! + line.utf16.count + 1) }
        var ranges: [NSRange] = []
        var htmlTags: [String?] = []
        var tables: [DocumentTable?] = []
        var chromes: [Chrome] = []
        var groups: [String?] = []
        var roles: [String?] = []
        var index = 0, startLine = 0, paragraphStart = 0, paragraphEnd = 0, tableStart = 0, tableEnd = 0
        func span(_ start: Int, _ end: Int) -> NSRange {
            NSRange(location: offsets[start], length: max(0, min(sourceLength, offsets[end] - (end > 0 && rawLines[end - 1].hasSuffix("\r") ? 2 : 1)) - offsets[start]))
        }
        func emit(_ block: MarkdownBlock) { blocks.append(block); ranges.append(span(startLine, index)); htmlTags.append(nil); tables.append(nil); chromes.append(Chrome()); groups.append(nil); roles.append(nil) }
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); ranges.append(span(paragraphStart, paragraphEnd)); htmlTags.append(nil); tables.append(nil); chromes.append(Chrome()); groups.append(nil); roles.append(nil); paragraph.removeAll() }
            if !table.isEmpty { blocks.append(.table(table)); ranges.append(span(tableStart, tableEnd)); htmlTags.append(nil); tables.append(DocumentTable(rows: table)); chromes.append(Chrome()); groups.append(nil); roles.append(nil); table.removeAll() }
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
                let void = ["img", "image", "hr", "br", "source", "sheet", "cite", "bookmark", "task", "chat_card", "sub-page-list", "html5-block"]
                // Feishu exports commonly put a whole HTML table on one line. Self-closing tags stay on that line.
                if !trimmed.lowercased().contains("</" + tag) && !trimmed.contains("/>") && !void.contains(tag) {
                    while index < lines.count {
                        try Task.checkCancellation()
                        let next = lines[index]; index += 1; html.append(next)
                        if next.lowercased().contains("</" + tag) { break }
                    }
                }
                let origin = offsets[startLine]
                for item in try HTMLFragment.located(html.joined(separator: "\n")) {
                    blocks.append(item.block)
                    ranges.append(NSRange(location: origin + item.range.location, length: item.range.length))
                    htmlTags.append(item.htmlTag); tables.append(item.table)
                    chromes.append(item.chrome); groups.append(item.group.map { "\(origin):\($0)" }); roles.append(item.role)
                }; continue
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
        flush()
        var located = blocks.indices.map { LocatedBlock(block: blocks[$0], range: ranges[$0], htmlTag: htmlTags[$0], table: tables[$0], group: groups[$0], role: roles[$0], chrome: chromes[$0]) }
        let minimum = located.compactMap { item -> Int? in if case .heading(let level, _) = item.block, item.chrome.numbered { return level }; return nil }.min() ?? 1
        var counters = Array(repeating: 0, count: 9)
        for index in located.indices {
            guard case .heading(let level, _) = located[index].block, located[index].chrome.numbered, (1...9).contains(level) else { continue }
            counters[level - 1] += 1
            if level < 9 { for slot in level..<9 { counters[slot] = 0 } }
            located[index].chrome.sequence = counters[(minimum - 1)..<level].map { String(max(1, $0)) }.joined(separator: ".")
        }
        return located
    }
    static func fencedCode(_ value: String, language: String) -> String {
        let longest = value.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces).prefix(while: { $0 == "`" }).count }.max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + language + "\n" + value + "\n" + fence
    }
    static func table(_ source: String, rows: [[String]]) -> DocumentTable {
        (try? HTMLFragment.tableModel(source)) ?? DocumentTable(rows: rows)
    }
    static func replacing(_ range: NSRange, in source: String, with replacement: String) -> String? {
        guard range.location >= 0, range.length >= 0, range.location <= (source as NSString).length,
              range.length <= (source as NSString).length - range.location,
              Range(range, in: source) != nil else { return nil }
        let start = source.utf16.index(source.utf16.startIndex, offsetBy: range.location)
        let end = source.utf16.index(start, offsetBy: range.length)
        guard start.samePosition(in: source.unicodeScalars) != nil,
              end.samePosition(in: source.unicodeScalars) != nil else { return nil }
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
    private static let blockTags: Set<String> = ["table", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "h7", "h8", "h9", "p", "div", "ul", "ol", "blockquote", "whiteboard", "iframe", "file", "image", "img", "video", "audio", "sheet", "bitable", "callout", "hr", "title", "grid", "checkbox", "bookmark", "button", "time", "source", "figure", "task", "chat_card", "sub-page-list", "okr", "html5-block"]
    private static func htmlBlockTag(_ line: String) -> String? {
        guard line.first == "<" else { return nil }
        let name = line.dropFirst().prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" }).lowercased()
        return blockTags.contains(name) ? name : nil
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
        var range = NSRange(location: 0, length: 0)
        var contentStart = 0
        var contentEnd = 0
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
        root.range = NSRange(location: 0, length: (html as NSString).length)
        var stack = [root], position = html.startIndex, count = 0
        for match in tokens.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            try Task.checkCancellation()
            guard let range = Range(match.range, in: html) else { continue }
            if position < range.lowerBound {
                let node = Node(value: decode(String(html[position..<range.lowerBound])))
                node.range = NSRange(position..<range.lowerBound, in: html)
                stack.last?.children.append(node)
            }
            position = range.upperBound
            let raw = String(html[range])
            if raw.hasPrefix("<!--") || raw.hasPrefix("<!") { continue }
            let closing = raw.hasPrefix("</")
            let tag = String(raw.dropFirst(closing ? 2 : 1).prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })).lowercased()
            if closing {
                if let index = stack.lastIndex(where: { $0.tag == tag }), index > 0 {
                    for node in stack[index...] {
                        node.range.length = match.range.upperBound - node.range.location
                        node.contentEnd = match.range.location
                    }
                    stack.removeSubrange(index...)
                }
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
            node.range = match.range; node.contentStart = match.range.upperBound; node.contentEnd = match.range.upperBound
            stack.last?.children.append(node)
            if !raw.hasSuffix("/>") && !["br", "hr", "col", "img", "input", "meta", "link", "source"].contains(tag) { stack.append(node) }
        }
        if position < html.endIndex {
            let node = Node(value: decode(String(html[position...])))
            node.range = NSRange(position..<html.endIndex, in: html); stack.last?.children.append(node)
        }
        for node in stack.dropFirst() { node.range.length = (html as NSString).length - node.range.location; node.contentEnd = (html as NSString).length }
        return root
    }
    private static let structuralTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "h7", "h8", "h9", "ul", "ol", "checkbox", "pre", "blockquote", "hr", "img", "image", "table", "grid", "callout", "title"]
    static func located(_ html: String) throws -> [DocumentMarkup.LocatedBlock] {
        let root = try tree(html)
        func placed(_ node: Node, blocks: [MarkdownBlock]) -> [DocumentMarkup.LocatedBlock] {
            blocks.map { block in
                var item = DocumentMarkup.LocatedBlock(block: block, range: node.range, htmlTag: node.tag, chrome: chrome(node))
                if case .table = block { item.table = try? tableModel((html as NSString).substring(with: node.range)) }
                return item
            }
        }
        func grouped(_ node: Node, role: String, chrome: DocumentMarkup.Chrome, depth: Int) -> [DocumentMarkup.LocatedBlock] {
            let id = role + ":" + String(node.range.location)
            var children = node.children.flatMap { walk($0, depth: depth) }
            if children.isEmpty {
                let label = chrome.caption.isEmpty ? (role == "okr" ? "OKR" : "") : chrome.caption
                children = label.isEmpty ? [] : [DocumentMarkup.LocatedBlock(block: .paragraph(label), range: node.range, htmlTag: node.tag, chrome: chrome)]
            }
            return children.map { item in
                var copy = item
                if copy.group == nil { copy.group = id; copy.role = role; copy.chrome = merged(chrome, copy.chrome) }
                return copy
            }
        }
        func walk(_ node: Node, depth: Int = 0) -> [DocumentMarkup.LocatedBlock] {
            if node.tag == "ul" || node.tag == "ol" {
                var result: [DocumentMarkup.LocatedBlock] = []
                let start = Int(node.attributes["seq"] ?? node.attributes["start"] ?? "") ?? 1
                for (index, item) in node.children.filter({ $0.tag == "li" }).enumerated() {
                    let nested = item.children.filter { structuralTags.contains($0.tag) || $0.tag == "ul" || $0.tag == "ol" }
                    let value = item.children.filter { !structuralTags.contains($0.tag) && $0.tag != "ul" && $0.tag != "ol" }.map(inline).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    let end = nested.first?.range.location ?? item.contentEnd
                    let block: MarkdownBlock = node.tag == "ol" ? .numbered(depth, "\(start + index).", value) : .bullet(depth, value)
                    var located = DocumentMarkup.LocatedBlock(block: block, range: NSRange(location: item.contentStart, length: max(0, end - item.contentStart)), htmlTag: "")
                    located.chrome.align = item.attributes["align"] ?? ""
                    result.append(located)
                    for child in nested { result += walk(child, depth: depth + 1) }
                }
                return result
            }
            if node.tag == "grid" {
                let columns = node.children.filter { $0.tag == "column" }
                let id = "grid:" + String(node.range.location)
                var result: [DocumentMarkup.LocatedBlock] = []
                for (index, column) in columns.enumerated() {
                    var style = DocumentMarkup.Chrome()
                    style.ratio = Double(column.attributes["width-ratio"] ?? "") ?? 0
                    style.column = index
                    style.columns = max(1, columns.count)
                    var children = column.children.flatMap { walk($0, depth: depth) }
                    if children.isEmpty { children = [.init(block: .paragraph(""), range: column.range, htmlTag: "p")] }
                    for item in children {
                        var copy = item
                        copy.group = id
                        copy.role = "grid"
                        copy.chrome.ratio = style.ratio
                        copy.chrome.column = style.column
                        copy.chrome.columns = style.columns
                        result.append(copy)
                    }
                }
                return result
            }
            if node.tag == "callout" || node.tag == "blockquote" || node.tag == "okr" {
                let style = chrome(node)
                let nested = node.children.contains { structuralTags.contains($0.tag) || $0.tag == "okr-objective" }
                if nested || node.tag == "okr" { return grouped(node, role: node.tag, chrome: style, depth: depth) }
            }
            if ["root", "div", "section", "article", "figure", "column"].contains(node.tag) { return node.children.flatMap { walk($0, depth: depth) } }
            return placed(node, blocks: convert(node))
        }
        return walk(root)
    }
    private static func merged(_ outer: DocumentMarkup.Chrome, _ inner: DocumentMarkup.Chrome) -> DocumentMarkup.Chrome {
        var chrome = outer
        if !inner.align.isEmpty { chrome.align = inner.align }
        if !inner.caption.isEmpty { chrome.caption = inner.caption }
        if !inner.language.isEmpty { chrome.language = inner.language }
        if !inner.link.isEmpty { chrome.link = inner.link }
        if !inner.sequence.isEmpty { chrome.sequence = inner.sequence }
        if inner.numbered { chrome.numbered = true }
        if inner.width > 0 { chrome.width = inner.width }
        if inner.height > 0 { chrome.height = inner.height }
        chrome.ratio = inner.ratio
        chrome.column = inner.column
        chrome.columns = inner.columns
        return chrome
    }
    private static func chrome(_ node: Node) -> DocumentMarkup.Chrome {
        var chrome = DocumentMarkup.Chrome()
        chrome.emoji = node.attributes["emoji"] ?? ""
        chrome.background = node.attributes["background-color"] ?? ""
        chrome.border = node.attributes["border-color"] ?? ""
        chrome.textColor = node.attributes["text-color"] ?? ""
        chrome.align = node.attributes["align"] ?? ""
        chrome.caption = node.attributes["caption"] ?? ""
        chrome.language = node.attributes["lang"] ?? node.attributes["language"] ?? node.attributes["type"] ?? ""
        chrome.link = node.attributes["href"] ?? node.attributes["src"] ?? ""
        chrome.numbered = node.attributes["seq"] == "auto"
        chrome.width = Double(node.attributes["width"] ?? "") ?? 0
        chrome.height = Double(node.attributes["height"] ?? "") ?? 0
        if node.tag == "okr" { chrome.caption = [node.attributes["user-name"], node.attributes["cycle-name"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
        if node.tag == "whiteboard" { chrome.caption = node.plain.trimmingCharacters(in: .whitespacesAndNewlines) }
        if node.tag == "time", let ms = Double(node.attributes["expire-time"] ?? "") {
            chrome.caption = Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .shortened)
        }
        return chrome
    }

    static func tableModel(_ html: String) throws -> DocumentTable? {
        let root = try tree(html)
        func firstTable(_ node: Node) -> Node? {
            if node.tag == "table" { return node }
            return node.children.lazy.compactMap(firstTable).first
        }
        guard let table = firstTable(root) else { return nil }
        var rows: [Node] = [], cols: [Node] = []
        func visit(_ node: Node) {
            if node.tag == "tr" { rows.append(node); return }
            if node.tag == "col" { cols.append(node); return }
            for child in node.children where child.tag != "table" { visit(child) }
        }
        visit(table)
        var cells: [DocumentTable.Cell] = [], occupied: Set<String> = []
        var count = 0
        for (row, node) in rows.enumerated() {
            var column = 0
            for cell in node.children where cell.tag == "td" || cell.tag == "th" {
                while occupied.contains("\(row):\(column)") { column += 1 }
                let rowSpan = min(max(1, Int(cell.attributes["rowspan"] ?? "") ?? 1), max(1, rows.count - row))
                let columnSpan = min(32, max(1, Int(cell.attributes["colspan"] ?? "") ?? 1))
                let value = cell.children.map(inline).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                let inner = (html as NSString).substring(with: NSRange(location: cell.contentStart, length: max(0, cell.contentEnd - cell.contentStart)))
                cells.append(.init(row: row, column: column, rowSpan: rowSpan, columnSpan: columnSpan, value: value, header: cell.tag == "th", originalValue: value, originalHTML: inner, attributes: cell.attributes))
                for r in row..<(row + rowSpan) { for c in column..<(column + columnSpan) { occupied.insert("\(r):\(c)") } }
                column += columnSpan; count = max(count, column)
            }
        }
        guard count > 0, !rows.isEmpty else { return nil }
        var model = DocumentTable(cells: cells, rowCount: rows.count, columnCount: count)
        model.attributes = table.attributes
        for index in model.columnWidths.indices where cols.indices.contains(index) {
            if let width = DocumentTable.dimension(cols[index].attributes["width"] ?? cols[index].attributes["style"] ?? "", property: "width") { model.columnWidths[index] = DocumentTable.clampWidth(width) }
        }
        for index in model.rowHeights.indices {
            if let height = DocumentTable.dimension(rows[index].attributes["height"] ?? rows[index].attributes["style"] ?? "", property: "height") { model.rowHeights[index] = DocumentTable.clampHeight(height) }
        }
        if let border = Double(table.attributes["border"] ?? "") { model.borderWidth = min(4, max(0.5, border)) }
        model.fillHoles()
        return model
    }
    private static func safeLink(_ value: String) -> String? {
        guard let url = URL(string: value), url.user == nil, url.password == nil,
              ((["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil)
               || (url.scheme == "mailto" && !url.path.isEmpty)) else { return nil }
        return url.absoluteString
    }
    private static func inline(_ node: Node) -> String {
        let inner = node.value + node.children.map(inline).joined()
        switch node.tag {
        case "script", "style", "iframe": return ""
        case "br": return "\n"
        case "b", "strong": return "**" + inner + "**"
        case "i", "em": return "*" + inner + "*"
        case "s", "del", "strike": return "~~" + inner + "~~"
        case "u": return inner
        case "a": return safeLink(node.attributes["href"] ?? "").map { "[" + inner.replacingOccurrences(of: "]", with: "\\]") + "](" + $0 + ")" } ?? inner
        case "pre": return "\n```" + (node.attributes["lang"] ?? "") + "\n" + node.plain + "\n```\n"
        case "code": return "`" + node.plain + "`"
        case "latex": return "$" + node.plain + "$"
        case "cite", "mention":
            let label = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty { return "@" + label }
            switch node.attributes["type"] { case "doc": return "@文档"; case "citation": return "@引用"; default: return "@成员" }
        case "p", "div": return inner + "\n"
        case "img", "image": return node.attributes["alt"] ?? node.attributes["caption"] ?? "图片"
        default: return inner
        }
    }
    static func spans(_ source: String) -> [DocumentMarkup.InlineSpan]? {
        guard source.contains("<"), source.contains(">"), let root = try? tree(source), root.children.contains(where: { !$0.tag.isEmpty }) else { return nil }
        var result: [DocumentMarkup.InlineSpan] = []
        func append(_ text: String, _ style: DocumentMarkup.InlineSpan) {
            guard !text.isEmpty else { return }
            var span = style
            span.text = text
            result.append(span)
        }
        func walk(_ node: Node, _ style: DocumentMarkup.InlineSpan) {
            if node.tag.isEmpty { append(node.value, style); return }
            var next = style
            switch node.tag {
            case "script", "style", "iframe": return
            case "br": append("\n", style); return
            case "b", "strong": next.strong = true
            case "i", "em": next.emphasis = true
            case "s", "del", "strike": next.strike = true
            case "u": next.underline = true
            case "code": next.code = true
            case "latex": next.math = true
            case "a": next.link = safeLink(node.attributes["href"] ?? "")
            case "span":
                if let color = node.attributes["text-color"] { next.textColor = color }
                if let background = node.attributes["background-color"] { next.background = background }
            case "cite", "mention":
                next.mention = true
                let label = node.children.map(\.plain).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = node.attributes["type"] == "doc" ? "文档" : (node.attributes["type"] == "citation" ? "引用" : "成员")
                append(label.isEmpty ? fallback : label, next)
                return
            default: break
            }
            if node.children.isEmpty { append(node.value, next) }
            else { for child in node.children { walk(child, next) } }
        }
        for child in root.children { walk(child, DocumentMarkup.InlineSpan(text: "")) }
        return result.isEmpty ? nil : result
    }
    private static func list(_ node: Node, depth: Int) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        let start = Int(node.attributes["start"] ?? "") ?? 1
        for (index, item) in node.children.filter({ $0.tag == "li" }).enumerated() {
            let value = item.children.filter { $0.tag != "ul" && $0.tag != "ol" }.map(inline).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(node.tag == "ol" ? .numbered(depth, "\(start + index).", value) : .bullet(depth, value))
            for child in item.children where child.tag == "ul" || child.tag == "ol" {
                result += list(child, depth: depth + 1)
            }
        }
        return result
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
        case "title": return [.heading(1, node.children.map(inline).joined().trimmingCharacters(in: .whitespacesAndNewlines))]
        case "h1", "h2", "h3", "h4", "h5", "h6", "h7", "h8", "h9": return [.heading(Int(node.tag.suffix(1))!, node.children.map(inline).joined().trimmingCharacters(in: .whitespacesAndNewlines))]
        case "checkbox": return [.task(0, node.attributes["done"]?.lowercased() == "true", node.children.map(inline).joined().trimmingCharacters(in: .whitespacesAndNewlines))]
        case "bookmark": return [.embed(node.attributes["name"] ?? node.attributes["href"] ?? "链接", "bookmark")]
        case "button": return [.embed(node.children.map(inline).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "按钮" : node.children.map(inline).joined().trimmingCharacters(in: .whitespacesAndNewlines), "button")]
        case "time": return [.embed(node.children.map(inline).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "日期提醒" : node.children.map(inline).joined().trimmingCharacters(in: .whitespacesAndNewlines), "time")]
        case "source": return [.embed(node.attributes["name"] ?? "附件", "file")]
        case "task": return [.embed("任务", "task")]
        case "chat_card": return [.embed("群聊", "chat")]
        case "sub-page-list": return [.embed("子页面", "pages")]
        case "html5-block": return [.embed(node.attributes["alt"] ?? "HTML 内容", "html")]
        case "okr-objective", "okr-key-result":
            let kind = node.tag == "okr-objective" ? "目标" : "关键结果"
            let percent = node.attributes["percent"].map { $0.isEmpty ? "" : $0 + "%" } ?? ""
            let title = [kind, node.attributes["status"] ?? "", percent].filter { !$0.isEmpty }.joined(separator: " · ")
            return [.heading(node.tag == "okr-objective" ? 3 : 4, title)] + node.children.flatMap(convert)
        case "okr-progress": return node.children.flatMap(convert)
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
        case "blockquote": return [.quote(node.children.map(inline).joined().trimmingCharacters(in: .whitespacesAndNewlines))]
        case "callout": return [.callout(node.children.map(inline).joined().trimmingCharacters(in: .whitespacesAndNewlines))]
        case "ul", "ol": return list(node, depth: 0)
        case "p": return [.paragraph(node.children.map(inline).joined().trimmingCharacters(in: .whitespacesAndNewlines))]
        case "": return node.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.paragraph(node.value)]
        default: return node.children.flatMap(convert)
        }
    }
}
