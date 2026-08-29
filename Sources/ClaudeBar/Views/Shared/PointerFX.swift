import SwiftUI

// MARK: - Tilt-on-hover

/// A pointer-driven 3D tilt + specular highlight. As the cursor moves over
/// the view, the card rotates on X/Y axes toward it (perspective tilt, like a
/// card held in hand), a soft specular sheen sweeps across the surface
/// following the light, and the card lifts with a deepened shadow. When the
/// pointer leaves, everything springs back to neutral. This is the signature
/// "premium tactile" interaction — the surface *responds* to where you are.
///
/// Uses `onContinuousHover` (macOS 13+) so we get live pointer coordinates,
/// not just enter/leave. The tilt is bounded (~10°) so it stays classy.
struct TiltOnHover: ViewModifier {
    var maxAngle: Double = 10
    var maxLift: CGFloat = 8
    @State private var location: CGPoint? = nil
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                if size != newSize { size = newSize }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    withAnimation(Theme.Animation.smooth) {
                        location = point
                    }
                case .ended:
                    withAnimation(Theme.Animation.lively) {
                        location = nil
                    }
                @unknown default:
                    break
                }
            }
            // 3D rotation toward the pointer. Tilt angle grows with distance
            // from center along each axis; sign chosen so the card "leans in"
            // toward the cursor (trailing edge lifts).
            .rotation3DEffect(
                .degrees(tiltX),
                axis: (x: 1, y: 0, z: 0),
                anchor: .center,
                perspective: 0.4
            )
            .rotation3DEffect(
                .degrees(tiltY),
                axis: (x: 0, y: 1, z: 0),
                anchor: .center,
                perspective: 0.4
            )
            // Lift + deepen the shadow on hover so the tilt reads as real
            // elevation, not a flat rotation.
            .scaleEffect(isHovering ? 1.015 : 1)
            .shadowCard(
                radius: isHovering ? 26 : 14,
                y: isHovering ? maxLift : 5,
                opacity: isHovering ? 0.6 : 0.4
            )
            // Specular sheen: a radial highlight positioned at the pointer,
            // only visible while hovering. Sweeps across as you move — the
            // "light following the cursor" that sells the material as glass.
            .overlay {
                if let location, size != .zero {
                    SpecularSheen(location: location, size: size)
                        .allowsHitTesting(false)
                }
            }
    }

    private var isHovering: Bool { location != nil }

    /// Rotation about the X axis (vertical tilt). Cursor in the upper half
    /// tilts the top toward the viewer.
    private var tiltX: Double {
        guard let location, size.height > 0 else { return 0 }
        let norm = (location.y / size.height) - 0.5   // -0.5 ... 0.5
        return -norm * 2 * maxAngle
    }

    /// Rotation about the Y axis (horizontal tilt). Cursor on the right tilts
    /// the right edge away, as if turning a card.
    private var tiltY: Double {
        guard let location, size.width > 0 else { return 0 }
        let norm = (location.x / size.width) - 0.5
        return norm * 2 * maxAngle
    }
}

extension View {
    /// Pointer-tracking 3D tilt + specular sheen + lift. Apply to cards that
    /// should feel like physical, light-catching objects.
    func tiltOnHover(maxAngle: Double = 10, maxLift: CGFloat = 8) -> some View {
        modifier(TiltOnHover(maxAngle: maxAngle, maxLift: maxLift))
    }
}

// MARK: - Specular sheen

/// A radial gradient highlight positioned at a point — the moving specular
/// reflection that makes a surface read as glass/metal. Cheap: one overlay.
private struct SpecularSheen: View {
    let location: CGPoint
    let size: CGSize

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.22), Color.white.opacity(0)],
                        center: UnitPoint(x: location.x / max(1, size.width),
                                         y: location.y / max(1, size.height)),
                        startRadius: 0,
                        endRadius: max(size.width, size.height) * 0.7
                    )
                )
        }
    }
}

// MARK: - Cursor spotlight (window-level)

/// A window-wide pointer-following light field. A large, very soft accent
/// radial gradient tracks the cursor across the whole window, sitting under
/// the content but above the aurora. It gives the entire surface a sense that
/// the cursor is a light source — the background subtly brightens around you
/// wherever you move. Purely ambient; non-interactive.
struct CursorSpotlight: View {
    @State private var location: CGPoint = .init(x: -1000, y: -1000)

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        withAnimation(.linear(duration: 0.12)) {
                            location = point
                        }
                    case .ended:
                        withAnimation(Theme.Animation.smooth) {
                            location = .init(x: -1000, y: -1000)
                        }
                    @unknown default: break
                    }
                }
                .overlay {
                    RadialGradient(
                        colors: [Theme.claude.opacity(0.06), Theme.base4.opacity(0.03), Theme.claude.opacity(0)],
                        center: UnitPoint(x: location.x / max(1, geo.size.width),
                                         y: location.y / max(1, geo.size.height)),
                        startRadius: 0,
                        endRadius: 380
                    )
                    .allowsHitTesting(false)
                    .blendMode(.plusLighter)
                }
        }
        .ignoresSafeArea()
    }
}
