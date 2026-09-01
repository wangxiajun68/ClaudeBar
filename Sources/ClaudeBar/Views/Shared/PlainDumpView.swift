import AppKit
import SwiftUI

/// AppKit dump for large payloads. SwiftUI `Text` + `textSelection` layouts
/// every glyph and freezes on 100KB+ JSON; `NSTextView` with
/// non-contiguous layout paints the viewport only.
struct PlainDumpView: NSViewRepresentable {
    var text: String
    var empty: String = "(empty)"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = NSColor(white: 0.90, alpha: 1)
        tv.insertionPointColor = .white
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 4
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.string = displayString
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)

        scroll.documentView = tv
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        let next = displayString
        if tv.string != next {
            tv.string = next
        }
        let width = scroll.contentView.bounds.width
        if width > 8 {
            tv.textContainer?.containerSize = NSSize(
                width: max(8, width - 16),
                height: CGFloat.greatestFiniteMagnitude)
        }
    }

    private var displayString: String {
        text.isEmpty ? empty : text
    }

    final class Coordinator {
        var textView: NSTextView?
    }
}
