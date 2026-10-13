import AppKit

/// Hardware-notch geometry, or a detached capsule below the menu bar.
struct NotchGeometry: Equatable {
    let size: CGSize
    let hasHardwareNotch: Bool
    /// Global AppKit coordinates, with the origin at the bottom left.
    let screenFrame: CGRect
    var topInset: CGFloat = 0
    var anchorY: CGFloat { screenFrame.maxY - topInset }

    func topRect(_ size: CGSize) -> CGRect {
        CGRect(x: screenFrame.midX - size.width / 2, y: anchorY - size.height,
               width: size.width, height: size.height)
    }

    init(screen: NSScreen) {
        screenFrame = screen.frame
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0 {
            let width = screen.frame.width - left.width - right.width
            size = CGSize(width: max(width, 120), height: screen.safeAreaInsets.top)
            hasHardwareNotch = true
        } else {
            size = CGSize(width: 0, height: 28)
            hasHardwareNotch = false
            topInset = max(0, screen.frame.maxY - screen.visibleFrame.maxY) + 8
        }
    }

    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil && $0.safeAreaInsets.top > 0 }
            ?? NSScreen.screens.first
    }
}

enum IslandDisplayPolicy: String, CaseIterable, Identifiable {
    case all, builtIn, selected
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "所有屏幕"
        case .builtIn: return "仅内置屏"
        case .selected: return "指定屏幕"
        }
    }
}

struct IslandDisplayOption: Identifiable {
    let id: String
    let name: String
    let isBuiltIn: Bool
    let geometry: NotchGeometry

    @MainActor static var current: [IslandDisplayOption] {
        NSScreen.screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let displayID = number?.uint32Value ?? 0
            let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
            let id = uuid.map { CFUUIDCreateString(nil, $0) as String } ?? String(displayID)
            return IslandDisplayOption(id: id, name: screen.localizedName,
                                       isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                                       geometry: NotchGeometry(screen: screen))
        }
    }
}

/// Pure selection and routing; unplugging a chosen display never rewrites the
/// preference, so its own island returns when it is connected again.
enum IslandDisplaySelection {
    static func eligible(_ displays: [IslandDisplayOption], policy: IslandDisplayPolicy,
                         selected: String) -> [IslandDisplayOption] {
        let preferred = displays.first { $0.isBuiltIn } ?? displays.first
        switch policy {
        case .all:
            // Mirrored screens can share coordinates: one entry per viewport.
            var frames: [CGRect] = []
            return displays.sorted { $0.isBuiltIn && !$1.isBuiltIn }.filter { display in
                guard !frames.contains(display.geometry.screenFrame) else { return false }
                frames.append(display.geometry.screenFrame)
                return true
            }
        case .builtIn:
            return preferred.map { [$0] } ?? []
        case .selected:
            return (displays.first { $0.id == selected } ?? preferred).map { [$0] } ?? []
        }
    }

    static func target(_ displays: [IslandDisplayOption], pointer: CGPoint,
                       last: String?) -> String? {
        displays.first { $0.geometry.screenFrame.contains(pointer) }?.id
            ?? displays.first { $0.id == last }?.id
            ?? displays.first { $0.isBuiltIn }?.id ?? displays.first?.id
    }
}
