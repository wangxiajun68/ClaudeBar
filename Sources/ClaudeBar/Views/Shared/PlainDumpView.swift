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
        tv.textColor = NSColor.labelColor
        tv.insertionPointColor = NSColor.labelColor
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
        // No width sync here: `widthTracksTextView` keeps the container at
        // `frame.width − 2 × textContainerInset`, and the frame follows the clip
        // view. A width recomputed from the scroll view disagrees by the inset
        // difference and would fight the tracking on every update pass.
    }

    private var displayString: String {
        text.isEmpty ? empty : text
    }

    final class Coordinator {
        var textView: NSTextView?
    }
}
