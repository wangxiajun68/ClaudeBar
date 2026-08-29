import SwiftUI

// MARK: - Color(hex:)

extension Color {
    /// `Color(hex: 0x0B0F18)` or `Color(hex: 0xD97757, opacity: 0.5)`.
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: opacity)
    }
}

// MARK: - Theme

/// Design tokens for ClaudeBar's macOS 26 look: translucent **Liquid Glass**
/// surfaces over a neutral near-black backdrop. The palette is deliberately
/// near-monochrome — a single cool accent (soft blue = Claude Code) and a
/// secondary violet (Cursor) do the identity work, and color is reserved for
/// state (busy / warning / error). Hierarchy comes from typography and weight,
/// not from color on every element.
enum Theme {
    // MARK: Foundation (neutral near-black — no color cast)
    static let base0 = Color(hex: 0x0D0D11)     // window backdrop tint
    static let base1 = Color(hex: 0x15151B)     // sidebar / elevated
    static let base2 = Color(hex: 0x1E2026)     // card glass tint reference
    static let base3 = Color(hex: 0x292C34)     // hover / elevated
    static let base4 = Color(hex: 0x353A45)     // highest

    static let bgPrimary = base0
    static let bgSecondary = base1
    static let bgTertiary = base2
    static let bgOverlay = base3

    // MARK: Signals (soft blue = Claude · violet = Cursor)
    static let claude = Color(hex: 0x4F8EF7)    // soft blue — Claude Code
    static let claudeHi = Color(hex: 0x79ABF9)  // light blue — busy/active
    static let cursor = Color(hex: 0xA78BFA)    // soft violet — Cursor
    static let cursorHi = Color(hex: 0xC0ACFC)  // light violet

    static let accent = claude
    static let accentDim = Color(hex: 0x3A6FD1)
    static let cursorAccent = cursor

    // MARK: Text
    static let textPrimary = Color(hex: 0xF5F5F7)   // Apple white
    static let textSecondary = Color(hex: 0xA1A1A6) // Apple gray
    static func textTertiary(_ opacity: Double = 0.4) -> Color { .white.opacity(opacity) }

    // MARK: Semantic (desaturated — reserved for state only)
    static let statusBusy = claude
    static let statusActive = cursor
    static let statusIdle = Color(hex: 0x8A8F98)
    static let statusWarning = Color(hex: 0xE0A13C) // soft amber
    static let statusError = Color(hex: 0xE46464)   // soft red
    static let statusSuccess = Color(hex: 0x46C58F) // soft green

    // MARK: Surfaces
    static let divider = Color.white.opacity(0.09)
    static let hairline = Color.white.opacity(0.10)
    static func cardFill(_ opacity: Double = 0.06) -> Color { .white.opacity(opacity) }
    static let sidebarFill = base1.opacity(0.35)

    // MARK: Spacing (8pt grid)
    enum Space {
        static let s2: CGFloat = 2
        static let s4: CGFloat = 4
        static let s8: CGFloat = 8
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32
    }

    // MARK: Corner radii
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 18
    }

    // MARK: Typography (SF Pro — refined, weight-driven hierarchy)
    enum Tracking {
        static let titleLarge: CGFloat = -0.03
        static let titleMedium: CGFloat = -0.02
        static let titleSmall: CGFloat = -0.01
        static let bodyLarge: CGFloat = -0.005
        static let body: CGFloat = 0
        static let caption: CGFloat = 0.03
        static let captionMono: CGFloat = 0
    }

    enum Font {
        static let titleLarge = SwiftUI.Font.system(size: 28, weight: .bold)
        static let titleMedium = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let titleSmall = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let bodyLarge = SwiftUI.Font.system(size: 14, weight: .regular)
        static let body = SwiftUI.Font.system(size: 13, weight: .regular)
        static let bodySmall = SwiftUI.Font.system(size: 11, weight: .regular)
        static let caption = SwiftUI.Font.system(size: 10, weight: .regular)
        static let captionMono = SwiftUI.Font.system(size: 9, weight: .regular, design: .monospaced)
        static let labelSection = SwiftUI.Font.system(size: 10, weight: .semibold)

        /// Large telemetry readouts. SF Pro semibold; pair with
        /// `.monospacedDigit()` for aligned tabular figures — more premium
        /// than a full monospace face for display numbers.
        static let displayMetric = SwiftUI.Font.system(size: 30, weight: .semibold)
        static let displayMetricSmall = SwiftUI.Font.system(size: 19, weight: .semibold)
    }

    // MARK: Context health color
    static func contextColor(_ ratio: Double) -> Color {
        if ratio < 0.6 { return statusBusy }
        if ratio < 0.85 { return statusWarning }
        return statusError
    }

    // MARK: Usage bar palette (hash-stable per model name)
    /// Muted cool tones — blue, violet, teal, amber, coral.
    static func barColor(for model: String) -> Color {
        let palette: [Color] = [
            Color(hex: 0x4F8EF7),  // blue
            Color(hex: 0xA78BFA),  // violet
            Color(hex: 0x46C58F),  // teal
            Color(hex: 0xE0A13C),  // amber
            Color(hex: 0xE46464),  // coral
        ]
        return palette[abs(model.hashValue) % palette.count]
    }

    // MARK: Animation (speed-first)
    enum Animation {
        static let bouncy = SwiftUI.Animation.bouncy(duration: 0.24, extraBounce: 0.16)
        static let smooth = SwiftUI.Animation.smooth(duration: 0.20, extraBounce: 0)
        static let lively = SwiftUI.Animation.bouncy(duration: 0.42, extraBounce: 0.26)
        static let pulse = SwiftUI.Animation.easeInOut(duration: 1.1)
        static let snappy = SwiftUI.Animation.bouncy(duration: 0.18, extraBounce: 0.10)
    }

    enum Motion {
        static let page = SwiftUI.Animation.easeOut(duration: 0.18)
        static let state = SwiftUI.Animation.easeOut(duration: 0.15)
    }

    // MARK: Radar graticule palette
    enum Radar {
        static let ring = Color.white.opacity(0.10)
        static let ringMid = Color.white.opacity(0.05)
        static let crosshair = Color.white.opacity(0.06)
        static let sweep = Color(hex: 0x4F8EF7, opacity: 0.08)
        static let sweepEdge = Color(hex: 0x4F8EF7, opacity: 0.28)
    }

    // MARK: Gradients
    static let accentGradient = LinearGradient(
        colors: [claudeHi, claude],
        startPoint: .top, endPoint: .bottom
    )
    static let cursorGradient = LinearGradient(
        colors: [cursorHi, cursor],
        startPoint: .top, endPoint: .bottom
    )
    static func barGradient(for model: String) -> LinearGradient {
        let c = barColor(for: model)
        return LinearGradient(colors: [c, c.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
    }
    static func contextGradient(_ ratio: Double) -> LinearGradient {
        let c = contextColor(ratio)
        return LinearGradient(colors: [c, c.opacity(0.5)], startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Soft drop shadow

struct ShadowCardModifier: ViewModifier {
    var radius: CGFloat = 12
    var y: CGFloat = 4
    var opacity: Double = 0.35

    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(opacity * 0.5), radius: radius * 0.5, y: y * 0.4)
            .shadow(color: .black.opacity(opacity), radius: radius, y: y)
    }
}

extension View {
    func shadowCard(radius: CGFloat = 12, y: CGFloat = 4, opacity: Double = 0.35) -> some View {
        modifier(ShadowCardModifier(radius: radius, y: y, opacity: opacity))
    }

    /// A tinted halo — the soft glow of a live signal. Reserved for busy/active
    /// and selection; never decoration.
    func beaconGlow(_ color: Color, radius: CGFloat = 18, opacity: Double = 0.22) -> some View {
        shadow(color: color.opacity(opacity), radius: radius, y: 0)
    }

    func ambientGlow(_ color: Color, radius: CGFloat = 20, opacity: Double = 0.25) -> some View {
        shadow(color: color.opacity(opacity), radius: radius, y: 6)
    }
}

// MARK: - Liquid Glass panel (native macOS 26 glassEffect)

/// The primary content surface: **native macOS 26 Liquid Glass** — real blur,
/// specular edge highlights, and translucency, with a whisper of white tint to
/// keep content readable over the backdrop. The whole app surfaces as one
/// continuous glass console rather than painted panels.
struct PanelCardModifier: ViewModifier {
    var radius: CGFloat = Theme.Radius.md
    var fill: Double = 0.07

    func body(content: Content) -> some View {
        content
            .glassEffect(
                .regular.tint(Color.white.opacity(fill)),
                in: RoundedRectangle(cornerRadius: radius)
            )
    }
}

extension View {
    /// Apply the Liquid Glass card surface (native `glassEffect`).
    func panelCard(radius: CGFloat = Theme.Radius.md, fill: Double = 0.07) -> some View {
        modifier(PanelCardModifier(radius: radius, fill: fill))
    }
}

// MARK: - Glass card (alias)

/// Floating-surface glass. Kept as an alias of the panel surface so call sites
/// stay semantic; the whole app is one glass language.
struct GlassCardModifier: ViewModifier {
    var radius: CGFloat = Theme.Radius.md
    var fill: Double = 0.07
    var border: Double = 0.12

    func body(content: Content) -> some View {
        content
            .glassEffect(
                .regular.tint(Color.white.opacity(fill)),
                in: RoundedRectangle(cornerRadius: radius)
            )
    }
}

extension View {
    func glassCard(radius: CGFloat = Theme.Radius.md,
                   fill: Double = 0.07,
                   border: Double = 0.12) -> some View {
        modifier(GlassCardModifier(radius: radius, fill: fill, border: border))
    }
}

// MARK: - Elevation tiers

enum Elevation {
    case flat
    case raised
    case floating
    case overlay
}

extension View {
    func elevation(_ tier: Elevation) -> some View {
        switch tier {
        case .flat:     return AnyView(self)
        case .raised:   return AnyView(self.shadowCard(radius: 8, y: 3, opacity: 0.25))
        case .floating: return AnyView(self.shadowCard(radius: 16, y: 8, opacity: 0.4))
        case .overlay:  return AnyView(self.shadowCard(radius: 30, y: 16, opacity: 0.5))
        }
    }

    func glassContainer(spacing: CGFloat? = nil) -> some View {
        GlassEffectContainer(spacing: spacing) { self }
    }

    func topLuminance(_ color: Color = .white, opacity: Double = 0.12, height: CGFloat = 1) -> some View {
        overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(opacity), color.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(height: height * 8)
                .mask(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .allowsHitTesting(false)
        }
    }
}
