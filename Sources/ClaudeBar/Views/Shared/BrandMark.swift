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

    private static var appIcon: NSImage {
        if let named = NSImage(named: "AppIcon") { return named }
        return NSApp.applicationIconImage
    }
}
