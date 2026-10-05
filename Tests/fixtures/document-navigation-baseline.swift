// Frozen source-location oracle from a75f9b4; test-only.
enum OriginalNavigation {
    static func sourceLocation(_ heading: DocumentMarkup.Heading, in source: String, headings: [DocumentMarkup.Heading]) -> Int? {
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
}
