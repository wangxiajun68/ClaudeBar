import SwiftUI
import AppKit

/// Dock / window brand: the bundled app icon, squirreled at the token size.
struct BrandMark: View {
    var size: CGFloat = 22

    var body: some View {
        Image(nsImage: Self.appIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityHidden(true)
    }

    /// Resolved once. The icon cannot change while the process lives, and this
    /// is read from a view body that re-renders — `NSImage(named:)` walks the
    /// bundle every call (finding 545). `ProductBrandMark` caches the same
    /// lookup behind a static.
    private static let appIcon: NSImage = {
        if let named = NSImage(named: "AppIcon") { return named }
        return NSApp.applicationIconImage
    }()
}
