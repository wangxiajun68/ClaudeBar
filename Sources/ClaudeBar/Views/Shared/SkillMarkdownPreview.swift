import AppKit
import SwiftUI

private enum MarkdownBlock: Sendable {
    case heading(Int, String)
    case paragraph(String)
    case bullet(Int, String)
    case numbered(Int, String, String)
    case quote(String)
    case code(String, String)
    case table([[String]])
    case rule
}

/// A native, selectable Markdown reading surface. Parsing is deliberately
/// bounded and runs off the main actor; no HTML or script is evaluated.
struct SkillMarkdownPreview: View {
    private enum PreviewError: Error { case tooLarge }
    let file: URL
    @State private var blocks: [MarkdownBlock] = []
    @State private var message: String?
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView("正在读取 Skill 文档")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else if let message {
                ContentUnavailableView(message, systemImage: "doc.text")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVStack(alignment: .leading, spacing: Theme.Space.s12) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .task(id: file.path) {
            loading = true
            message = nil
            do {
                let parsed = try await Task.detached(priority: .utility) {
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 512_000 else { throw PreviewError.tooLarge }
                    let data = try Data(contentsOf: file, options: .mappedIfSafe)
                    guard data.count <= 512_000 else { throw PreviewError.tooLarge }
                    return Self.parse(String(decoding: data, as: UTF8.self))
                }.value
                blocks = parsed
                if parsed.isEmpty { message = "文档没有可预览的内容" }
            } catch {
                message = "无法读取 SKILL.md，请检查文件是否仍在原位置。"
            }
            loading = false
        }
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let value):
            inline(value)
                .font(level == 1 ? Theme.Font.titleSmall : (level == 2 ? Theme.Font.section : Theme.Font.chromeEmph))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, level == 1 ? Theme.Space.s12 : Theme.Space.s8)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let value):
            inline(value)
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let depth, let value):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                Text("•").foregroundStyle(Theme.Ink.claude)
                inline(value).foregroundStyle(Theme.textPrimary)
            }
            .font(Theme.Font.bodySmall)
            .padding(.leading, CGFloat(min(depth, 3)) * 14)
        case .numbered(let depth, let number, let value):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                Text(number).foregroundStyle(Theme.Ink.claude)
                inline(value).foregroundStyle(Theme.textPrimary)
            }
            .font(Theme.Font.bodySmall)
            .padding(.leading, CGFloat(min(depth, 3)) * 14)
        case .quote(let value):
            inline(value)
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, Theme.Space.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.Ink.claude.opacity(0.5)).frame(width: 2)
                }
        case .code(let language, let value):
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                HStack {
                    Text(language.isEmpty ? "代码" : language)
                        .font(Theme.Font.microMedium)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.Font.microMedium)
                    .foregroundStyle(Theme.Ink.claude)
                }
                ScrollView(.horizontal) {
                    Text(value)
                        .font(Theme.Font.captionMono)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(Theme.Space.s12)
            .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        case .table(let rows):
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        HStack(alignment: .top, spacing: Theme.Space.s12) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inline(cell)
                                    .font(rowIndex == 0 ? Theme.Font.microSemibold : Theme.Font.caption)
                                    .foregroundStyle(Theme.textPrimary)
                                    .frame(width: 170, alignment: .leading)
                            }
                        }
                        .padding(Theme.Space.s10)
                        .background(rowIndex == 0 ? Theme.bgOverlay : Theme.cardSurface)
                        if rowIndex < rows.count - 1 { HairlineDivider() }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.hairline))
        case .rule:
            HairlineDivider().padding(.vertical, Theme.Space.s4)
        }
    }

    private func inline(_ raw: String) -> Text {
        if let value = try? AttributedString(markdown: raw,
                                              options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(value)
        }
        return Text(raw)
    }

    private static func parse(_ source: String) -> [MarkdownBlock] {
        var lines = source.components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(0...close)
        }
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var table: [[String]] = []
        var language = ""
        var fenced = false
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph.removeAll()
            }
            if !table.isEmpty {
                blocks.append(.table(table))
                table.removeAll()
            }
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                if fenced { blocks.append(.code(language, code.joined(separator: "\n"))); code.removeAll() }
                else { language = String(trimmed.dropFirst(3)); code.removeAll() }
                fenced.toggle()
                continue
            }
            if fenced { code.append(line); continue }
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                if !paragraph.isEmpty { flush() }
                let cells = trimmed.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 == "-" || $0 == ":" } }) {
                    table.append(cells)
                }
                continue
            }
            if !table.isEmpty { flush() }
            if trimmed.isEmpty { flush(); continue }
            if trimmed == "---" || trimmed == "***" { flush(); blocks.append(.rule); continue }
            let marks = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(marks), trimmed.dropFirst(marks).hasPrefix(" ") {
                flush()
                blocks.append(.heading(marks, String(trimmed.dropFirst(marks + 1))))
                continue
            }
            let depth = (line.count - line.drop(while: { $0 == " " }).count) / 2
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flush(); blocks.append(.bullet(depth, String(trimmed.dropFirst(2)))); continue
            }
            if let dot = trimmed.firstIndex(of: "."),
               trimmed[..<dot].allSatisfy({ $0.isNumber }),
               trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.numbered(depth, String(trimmed[...dot]),
                                        String(trimmed[trimmed.index(dot, offsetBy: 2)...])))
                continue
            }
            if trimmed.hasPrefix("> ") {
                flush(); blocks.append(.quote(String(trimmed.dropFirst(2)))); continue
            }
            paragraph.append(trimmed)
        }
        flush()
        if fenced { blocks.append(.code(language, code.joined(separator: "\n"))) }
        return blocks
    }
}
