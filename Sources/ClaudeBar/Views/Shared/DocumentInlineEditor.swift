import AppKit
import SwiftUI

/// Always-editable text, sized to its content. It remains the same native view
/// while typing, so selection, IME composition, links and undo stay native.
struct DocumentInlineEditor: NSViewRepresentable {
    let markdown: String
    let fontSize: CGFloat
    let editable: Bool
    var semibold: Bool
    var literal: Bool
    var focusedOnAppear: Bool
    var onFocus: (Bool) -> Void
    var onHeight: (CGFloat) -> Void
    var contextMenu: (NSMenu) -> Void
    var onView: (DocumentTextView) -> Void
    var onBoundary: (Int) -> Bool
    let onChange: (String) -> Void
    init(markdown: String, fontSize: CGFloat, editable: Bool, semibold: Bool = false, literal: Bool = false, focusedOnAppear: Bool = false,
         onFocus: @escaping (Bool) -> Void = { _ in }, onHeight: @escaping (CGFloat) -> Void = { _ in },
         onBoundary: @escaping (Int) -> Bool = { _ in false }, onView: @escaping (DocumentTextView) -> Void = { _ in }, contextMenu: @escaping (NSMenu) -> Void = { _ in }, onChange: @escaping (String) -> Void) {
        self.markdown = markdown; self.fontSize = fontSize; self.editable = editable
        self.semibold = semibold; self.literal = literal; self.focusedOnAppear = focusedOnAppear; self.onFocus = onFocus; self.onHeight = onHeight
        self.onBoundary = onBoundary; self.onView = onView; self.contextMenu = contextMenu; self.onChange = onChange
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DocumentInlineEditor
        var published = ""
        var height: CGFloat = 0
        init(_ parent: DocumentInlineEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? DocumentTextView, !view.hasMarkedText(), let storage = view.textStorage else { return }
            let value = parent.literal ? view.string : DocumentRichText.markdown(storage)
            guard value != published else { return }
            published = value
            parent.onChange(value)
            view.invalidateIntrinsicContentSize()
            parent.onHeight(view.intrinsicContentSize.height)
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)), DocumentRichText.allowedURL(url) else { return true }
            NSWorkspace.shared.open(url); return true
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let name = NSStringFromSelector(selector), selection = textView.selectedRange()
            if name == "insertTab:" { return parent.onBoundary(1) }
            if name == "insertBacktab:" { return parent.onBoundary(-1) }
            if ["moveUp:", "moveLeft:"].contains(name), selection.location == 0 { return parent.onBoundary(-1) }
            if ["moveDown:", "moveRight:"].contains(name), selection.upperBound == (textView.string as NSString).length { return parent.onBoundary(1) }
            return false
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> DocumentTextView {
        let view = DocumentTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        view.isAutomaticLinkDetectionEnabled = !literal
        view.isRichText = !literal; view.importsGraphics = false; view.drawsBackground = false
        view.allowsUndo = true; view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        applyText(view)
        view.delegate = context.coordinator
        updateNSView(view, context: context)
        onView(view)
        view.setAccessibilityLabel("文档正文，点击即可输入；链接单击打开，Option 点击编辑链接文本")
        if focusedOnAppear { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
        return view
    }
    func updateNSView(_ view: DocumentTextView, context: Context) {
        context.coordinator.parent = self
        if view.window?.firstResponder !== view && context.coordinator.published != markdown { applyText(view); context.coordinator.published = markdown }
        view.isEditable = editable; view.isSelectable = true
        view.insertionPointColor = NSColor(Theme.textPrimary)
        view.extendMenu = contextMenu
        view.focusChanged = onFocus
        view.heightChanged = onHeight
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: DocumentTextView, context: Context) -> CGSize? {
        let width = max(40, proposal.width ?? 600)
        view.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let height = view.intrinsicContentSize.height
        if context.coordinator.height != height {
            context.coordinator.height = height
            DispatchQueue.main.async { onHeight(height) }
        }
        return CGSize(width: width, height: height)
    }
    private func applyText(_ view: NSTextView) {
        let font = literal ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) : NSFont.systemFont(ofSize: fontSize, weight: semibold ? .semibold : .regular)
        let text = literal ? NSAttributedString(string: markdown, attributes: [.font: font, .foregroundColor: NSColor(Theme.textPrimary)]) : DocumentRichText.attributed(markdown, size: fontSize, semibold: semibold)
        view.textStorage?.setAttributedString(text)
        view.typingAttributes = [.font: font, .foregroundColor: NSColor(Theme.textPrimary)]
        view.invalidateIntrinsicContentSize()
    }
}

@MainActor final class DocumentFocusNavigator: ObservableObject {
    private final class WeakView { weak var view: DocumentTextView?; init(_ view: DocumentTextView) { self.view = view } }
    private var views: [String: WeakView] = [:]
    var order: [String] = []
    var activeID: String?
    var activeView: DocumentTextView? { activeID.flatMap { views[$0]?.view } }
    var firstView: DocumentTextView? { order.lazy.compactMap { self.views[$0]?.view }.first }
    func register(_ view: DocumentTextView, id: String) { views[id] = WeakView(view) }
    func move(from id: String, direction: Int) -> Bool {
        guard let index = order.firstIndex(of: id), order.indices.contains(index + direction), let view = views[order[index + direction]]?.view else { return false }
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: direction > 0 ? 0 : (view.string as NSString).length, length: 0))
        view.scrollToVisible(view.bounds)
        return true
    }
}

final class DocumentTextView: NSTextView {
    var openLink: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var extendMenu: (NSMenu) -> Void = { _ in }
    var focusChanged: (Bool) -> Void = { _ in }
    var heightChanged: (CGFloat) -> Void = { _ in }
    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return NSSize(width: NSView.noIntrinsicMetric, height: 28) }
        layoutManager.ensureLayout(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(28, ceil(layoutManager.usedRect(for: textContainer).height) + 4))
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let menu = super.menu(for: event) ?? NSMenu()
        if isEditable { extendMenu(menu) }
        return menu
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); if result { focusChanged(true) }; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); if result { focusChanged(false) }; return result }
    /// Hit testing is shared by real mouse events and isolated native regression fixtures.
    func activateLink(at localPoint: NSPoint, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard !modifiers.contains(.option), let layoutManager, let textContainer, let storage = textStorage else { return false }
        layoutManager.ensureLayout(for: textContainer)
        let point = NSPoint(x: localPoint.x - textContainerOrigin.x, y: localPoint.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return false }
        let bounds = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard bounds.insetBy(dx: -2, dy: -2).contains(point), index < storage.length,
              let url = (storage.attribute(.link, at: index, effectiveRange: nil) as? URL) ?? (storage.attribute(.link, at: index, effectiveRange: nil) as? String).flatMap(URL.init(string:)),
              DocumentRichText.allowedURL(url) else { return false }
        openLink(url); return true
    }
    override func mouseDown(with event: NSEvent) {
        if activateLink(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags) { return }
        super.mouseDown(with: event)
    }
    override func unmarkText() {
        super.unmarkText()
        delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() {
            if key == "z" { if event.modifierFlags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }; return }
            if key == "b" { toggleMark(.boldFontMask); return }
            if key == "i" { toggleMark(.italicFontMask); return }
        }
        super.keyDown(with: event)
    }
    private func toggleMark(_ trait: NSFontTraitMask) {
        guard isEditable, let storage = textStorage else { return }
        let range = selectedRange()
        if range.length == 0 {
            let font = typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: 15)
            let manager = NSFontManager.shared
            typingAttributes[.font] = manager.traits(of: font).contains(trait) ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            return
        }
        let before = NSAttributedString(attributedString: storage)
        let selectedFont = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 15)
        let remove = NSFontManager.shared.traits(of: selectedFont).contains(trait)
        undoManager?.registerUndo(withTarget: self) { $0.restore(before) }
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            let font = value as? NSFont ?? .systemFont(ofSize: 15)
            storage.addAttribute(trait == .boldFontMask ? .documentStrong : .documentEmphasis, value: !remove, range: run)
            storage.addAttribute(.font, value: remove ? NSFontManager.shared.convert(font, toNotHaveTrait: trait) : NSFontManager.shared.convert(font, toHaveTrait: trait), range: run)
        }
        didChangeText(); invalidateIntrinsicContentSize()
    }
    private func restore(_ text: NSAttributedString) {
        if let storage = textStorage {
            let current = NSAttributedString(attributedString: storage)
            undoManager?.registerUndo(withTarget: self) { $0.restore(current) }
            storage.setAttributedString(text); didChangeText(); invalidateIntrinsicContentSize()
        }
    }
}

/// Bridges the supported inline Markdown marks to native text attributes.
/// Unknown pasted styling is omitted rather than emitting arbitrary HTML.
extension NSAttributedString.Key {
    static let documentStrong = NSAttributedString.Key("ClaudeBar.Document.Strong")
    static let documentEmphasis = NSAttributedString.Key("ClaudeBar.Document.Emphasis")
    static let documentCode = NSAttributedString.Key("ClaudeBar.Document.Code")
}

enum DocumentRichText {
    static func allowedURL(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil else { return false }
        return (["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil)
            || (url.scheme?.lowercased() == "mailto" && !url.path.isEmpty)
    }
    static func escapedHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func html(_ markdown: String) -> String {
        let lines = markdown.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if let first = lines.first, let last = lines.last, lines.count >= 2,
           first.hasPrefix("```"), last.allSatisfy({ $0 == "`" }), last.count >= first.prefix(while: { $0 == "`" }).count {
            let language = String(first.drop(while: { $0 == "`" }))
            return "<pre lang=\"" + escapedHTML(language) + "\"><code>" + escapedHTML(lines.dropFirst().dropLast().joined(separator: "\n")) + "</code></pre>"
        }
        let text = attributed(markdown, size: 15)
        var result = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var value = (text.string as NSString).substring(with: range)
                .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br/>")
            let traits = (attributes[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            if traits.contains(.fixedPitchFontMask) || (attributes[.documentCode] as? Bool == true) { value = "<code>" + value + "</code>" }
            if traits.contains(.italicFontMask) || (attributes[.documentEmphasis] as? Bool == true) { value = "<em>" + value + "</em>" }
            if traits.contains(.boldFontMask) || (attributes[.documentStrong] as? Bool == true) { value = "<strong>" + value + "</strong>" }
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { value = "<del>" + value + "</del>" }
            if let link = attributes[.link] as? URL, allowedURL(link) {
                let address = link.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                value = "<a href=\"" + address + "\">" + value + "</a>"
            }
            result += value
        }
        return result
    }
    static func attributed(_ markdown: String, size: CGFloat, semibold: Bool = false) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: markdown, attributes: [.font: NSFont.systemFont(ofSize: size, weight: semibold ? .semibold : .regular)])
        }
        let result = NSMutableAttributedString(string: String(parsed.characters))
        let full = NSRange(location: 0, length: result.length)
        result.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: semibold ? .semibold : .regular), .foregroundColor: NSColor(Theme.textPrimary)], range: full)
        var offset = 0
        for run in parsed.runs {
            let length = String(parsed.characters[run.range]).utf16.count
            let range = NSRange(location: offset, length: length)
            offset += length
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size, weight: semibold ? .semibold : .regular)
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            result.addAttribute(.font, value: font, range: range)
            if intent.contains(.stronglyEmphasized) { result.addAttribute(.documentStrong, value: true, range: range) }
            if intent.contains(.emphasized) { result.addAttributes([.documentEmphasis: true, .obliqueness: 0.12], range: range) }
            if intent.contains(.code) { result.addAttributes([.documentCode: true, .backgroundColor: NSColor(Theme.bgSecondary)], range: range) }
            if intent.contains(.strikethrough) { result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            if let link = run.link, allowedURL(link) {
                result.addAttributes([.link: link, .foregroundColor: NSColor(Theme.Ink.claude)], range: range)
            }
        }
        // Native automatic detection runs after edits; detect initial bare URLs too.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: result.string, range: full) {
                guard let url = match.url, allowedURL(url), match.range.length > 0 else { continue }
                var canLink = true
                result.enumerateAttributes(in: match.range) { attributes, _, _ in
                    if attributes[.link] != nil || attributes[.documentCode] as? Bool == true { canLink = false }
                }
                if canLink { result.addAttributes([.link: url, .foregroundColor: NSColor(Theme.Ink.claude)], range: match.range) }
            }
        }
        return result
    }
    static func markdown(_ text: NSAttributedString) -> String {
        var result = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let raw = (text.string as NSString).substring(with: range)
            let font = attributes[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            var value: String
            if traits.contains(.fixedPitchFontMask) || (attributes[.documentCode] as? Bool == true) {
                let fence = String(repeating: "`", count: (raw.split(separator: "`", omittingEmptySubsequences: false).count))
                value = fence + " " + raw + " " + fence
            } else {
                value = raw.reduce(into: "") { output, character in
                    if "\\`*_[]<>~".contains(character) { output.append("\\") }
                    output.append(character)
                }
            }
            let leading = String(raw.prefix(while: { $0.isWhitespace }))
            let trailing = String(raw.reversed().prefix(while: { $0.isWhitespace }).reversed())
            if !traits.contains(.fixedPitchFontMask) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { result += raw; return }
                value = trimmed.reduce(into: "") { output, character in
                    if "\\`*_[]<>~".contains(character) { output.append("\\") }
                    output.append(character)
                }
            }
            if traits.contains(.italicFontMask) || (attributes[.documentEmphasis] as? Bool == true) { value = "*" + value + "*" }
            if traits.contains(.boldFontMask) || (attributes[.documentStrong] as? Bool == true) { value = "**" + value + "**" }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { value = "~~" + value + "~~" }
            let link = (attributes[.link] as? URL) ?? (attributes[.link] as? String).flatMap(URL.init(string:))
            if let link, allowedURL(link) {
                let address = link.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                value = "[" + value + "](" + address + ")"
            }
            result += traits.contains(.fixedPitchFontMask) ? value : leading + value + trailing
        }
        return result
    }
}
