import AppKit

/// Hardware-notch geometry for one screen. Screens without a notch get a
/// pseudo-notch as tall as the menu bar so the island still has a home.
struct NotchGeometry: Equatable {
    /// Notch (or pseudo-notch) size in points.
    let size: CGSize
    let hasHardwareNotch: Bool
    /// The screen's global frame (AppKit coordinates, origin bottom-left).
    let screenFrame: CGRect

    static let pseudoNotchWidth: CGFloat = 200

    init(screen: NSScreen) {
        screenFrame = screen.frame
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0 {
            let width = screen.frame.width - left.width - right.width
            size = CGSize(width: max(width, 120), height: screen.safeAreaInsets.top)
            hasHardwareNotch = true
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            size = CGSize(width: Self.pseudoNotchWidth, height: max(menuBar, 24))
            hasHardwareNotch = false
        }
    }

    /// The screen that should host the island: the first one with a hardware
    /// notch, else the menu-bar screen.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil && $0.safeAreaInsets.top > 0 }
            ?? NSScreen.screens.first
    }
}
