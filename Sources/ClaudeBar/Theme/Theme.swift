import SwiftUI
import AppKit

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

/// Design tokens for ClaudeBar: a light **status sheet**.
///
/// THESIS: the popup is a CatStatus-class instrument — white cards on ice,
/// hero numbers, charts that carry color. It refuses tinted-glass admin tiles.
/// OWN-WORLD: ice canvas #EEF3F8, white raised cards, SF Rounded metrics,
/// mint alive, purple heatmap, color only in data.
/// STORY: glance the machine, pick a model, resume a session.
/// FIRST VIEWPORT: switcher HUD, one-line machine KPIs, then models / sessions / usage.
/// FORM: iOS widget / CatStatus craft, user-pinned.
/// FINISH: unreviewed and undocumented is unfinished; this build ends with
/// the finish review, the verdict, and DESIGN.md
enum Theme {
    // MARK: Foundation — ice in light, graphite in dark
    static var isDark: Bool { AppPreferences.shared.isDark }

    static var bgPrimary: Color { isDark ? Color(hex: 0x16181C) : Color(hex: 0xEEF3F8) }
    static var bgSecondary: Color { isDark ? Color(hex: 0x1E2228) : Color(hex: 0xF7FAFC) }
    static var bgTertiary: Color { cardSurface }
    static var bgOverlay: Color { isDark ? Color(hex: 0x2A3038) : Color(hex: 0xE4EBF2) }
    static var cardSurface: Color { isDark ? Color(hex: 0x252A31) : Color.white }

    static var base0: Color { bgPrimary }
    static var base1: Color { bgSecondary }
    static var base2: Color { cardSurface }
    static var base3: Color { bgOverlay }
    static var base4: Color { isDark ? Color(hex: 0x3A424C) : Color(hex: 0xC5D0DC) }

    // MARK: Signals (green = load · blue = GPU · amber = memory · violet = usage)
    static let claude = Color(hex: 0x3D7DFF)
    static let claudeHi = Color(hex: 0x5B9CFF)
    static let cursor = Color(hex: 0x8B7CFF)
    static let cursorHi = Color(hex: 0xA99BFF)
    static let codex = Color(hex: 0x6B7280)

    static let chartGreen = Color(hex: 0x34C759)
    static let chartBlue = Color(hex: 0x5B9CFF)
    static let chartAmber = Color(hex: 0xFF9F0A)
    static let chartPurple = Color(hex: 0xBF5AF2)

    static let external = Color(hex: 0x30D158)
    static let externalHi = Color(hex: 0x64E07A)

    static let accent = claude
    static let accentDim = Color(hex: 0x2B62D6)
    static let cursorAccent = cursor

    /// Session-kind hue — blue for Claude, violet for Cursor.
    static func signal(isCursor: Bool) -> Color {
        isCursor ? cursor : claude
    }

    // MARK: Text
    static var textPrimary: Color { isDark ? Color(hex: 0xF5F5F7) : Color(hex: 0x1C1C1E) }
    static var textSecondary: Color { isDark ? Color(hex: 0xA8ADB4) : Color(hex: 0x6E6E73) }
    static func textTertiary(_ opacity: Double = 0.38) -> Color {
        isDark ? Color.white.opacity(min(1, opacity + 0.18)) : Color.black.opacity(opacity)
    }

    // MARK: Semantic
    static let statusBusy = claude
    static let statusActive = cursor
    static let statusIdle = Color(hex: 0x8E8E93)
    static let statusWarning = Color(hex: 0xFF9F0A)
    static let statusError = Color(hex: 0xFF3B30)
    static let statusSuccess = Color(hex: 0x34C759)

    // MARK: Surfaces
    static var divider: Color { isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08) }
    static var hairline: Color { divider }
    static func cardFill(_ opacity: Double = 0.04) -> Color {
        isDark ? Color.white.opacity(min(1, opacity * 2.4)) : Color.black.opacity(opacity)
    }
    static var sidebarFill: Color { bgSecondary }

    static var windowNSColor: NSColor {
        isDark
            ? NSColor(srgbRed: 22/255, green: 24/255, blue: 28/255, alpha: 1)
            : NSColor(srgbRed: 238/255, green: 243/255, blue: 248/255, alpha: 1)
    }

    static var nsAppearance: NSAppearance {
        NSAppearance(named: isDark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
    }

    // MARK: Spacing (8pt grid)
    enum Space {
        static let s2: CGFloat = 2
        static let s4: CGFloat = 4
        static let s6: CGFloat = 6
        static let s8: CGFloat = 8
        static let s10: CGFloat = 10
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32
        /// Grid gap — popup density (2-col tiles in the 400pt panel).
        static let gridGap: CGFloat = 8
        /// Grid gap — main-window pages (tile grids).
        static let gridGapPage: CGFloat = 10
    }

    // MARK: Corner radii
    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    // MARK: Typography
    //
    // macOS system text styles only (SF Pro / SF Mono). No bundled custom fonts.
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
        static let titleLarge = SwiftUI.Font.largeTitle.weight(.bold)
        static let titleMedium = SwiftUI.Font.title2.weight(.semibold)
        static let titleSmall = SwiftUI.Font.headline
        static let bodyLarge = SwiftUI.Font.body
        static let body = SwiftUI.Font.body
        static let bodySmall = SwiftUI.Font.subheadline
        static let caption = SwiftUI.Font.caption
        static let captionMono = SwiftUI.Font.caption.monospaced()
        static let labelSection = SwiftUI.Font.caption.weight(.semibold)

        static let displayMetric = SwiftUI.Font.system(size: 28, weight: .semibold, design: .rounded)
        static let displayMetricSmall = SwiftUI.Font.system(size: 24, weight: .semibold, design: .rounded)
        static let displayHero = SwiftUI.Font.system(size: 22, weight: .bold, design: .rounded)

        // Popup-density aliases — still system styles, one step smaller where needed.
        static let rowTitle = SwiftUI.Font.subheadline.weight(.medium)
        static let rowLarge = SwiftUI.Font.body
        static let micro = SwiftUI.Font.caption2
        static let microMedium = SwiftUI.Font.caption2.weight(.medium)
        static let microSemibold = SwiftUI.Font.caption2.weight(.semibold)
        static let microMono = SwiftUI.Font.caption2.monospaced()
        static let badgeMono = SwiftUI.Font.caption2.monospaced()
        static let console = SwiftUI.Font.footnote.monospaced()

        static func systemIcon(_ size: CGFloat) -> SwiftUI.Font {
            SwiftUI.Font.system(size: size)
        }

        static let tileValue = SwiftUI.Font.system(size: 28, weight: .semibold, design: .rounded)
        static let tileValueSmall = SwiftUI.Font.system(size: 22, weight: .semibold, design: .rounded)
        static let tileMicroValue = SwiftUI.Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()
        static let tileLabel = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let tileDetail = SwiftUI.Font.caption2
    }

    // MARK: Grid column templates
    /// Column templates for the tile grids — the single place that decides
    /// how a data domain lays out as a 宫格.
    enum GridLayout {
        enum Preset {
            case pageMetric      // 4 equal metric tiles across the page
            case pageSession     // adaptive session tiles (≥280pt)
            case pageUsage       // adaptive per-model usage tiles
            case pageProvider    // adaptive provider tiles
            case popupSession    // 2-col popup
            case popupProvider   // 2-col popup
            case popupUsage      // 2-col popup
            case pageSetting     // settings control tiles
        }

        static func columns(_ preset: Preset) -> [GridItem] {
            switch preset {
            case .pageMetric:
                Array(repeating: GridItem(.flexible(minimum: 0), spacing: Space.gridGapPage, alignment: .top), count: 4)
            case .pageSession:
                [GridItem(.adaptive(minimum: 280), spacing: Space.gridGapPage, alignment: .top)]
            case .pageUsage, .pageProvider:
                [GridItem(.adaptive(minimum: 240), spacing: Space.gridGapPage, alignment: .top)]
            case .pageSetting:
                [GridItem(.adaptive(minimum: 200), spacing: Space.gridGapPage, alignment: .top)]
            case .popupProvider, .popupUsage:
                [GridItem(.flexible(), spacing: Space.gridGap, alignment: .top),
                 GridItem(.flexible(), spacing: Space.gridGap, alignment: .top)]
            case .popupSession:
                [GridItem(.flexible(), spacing: Space.gridGap, alignment: .top)]
            }
        }

        /// Equal-height grid: fixed column count, or adaptive from a minimum width.
        static func equalRow(_ preset: Preset) -> (fixed: Int?, minWidth: CGFloat) {
            switch preset {
            case .pageMetric: return (4, 0)
            case .pageSession: return (nil, 280)
            case .pageUsage, .pageProvider: return (nil, 240)
            case .pageSetting: return (nil, 200)
            case .popupProvider, .popupUsage: return (2, 0)
            case .popupSession: return (1, 0)
            }
        }

        /// Equal-width mosaic columns that fill the row — no leftover gutter.
        static func mosaic(columns: Int, spacing: CGFloat = 1) -> [GridItem] {
            Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
                  count: max(2, columns))
        }
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
            chartBlue,
            chartPurple,
            chartGreen,
            chartAmber,
            statusError,
        ]
        return palette[djb2(model) % palette.count]
    }

    /// Stable string hash — unlike String.hashValue, djb2 is deterministic
    /// across launches and processes, so the main app and Widget always tint
    /// the same model the same color.
    static func djb2(_ s: String) -> Int {
        var h: UInt64 = 5_381
        for b in s.utf8 {
            h = (h &* 33) &+ UInt64(b)
        }
        return Int(h % UInt64(Int.max))
    }

    // MARK: Animation (speed-first, state-driven only)
    enum Animation {
        static let bouncy = SwiftUI.Animation.bouncy(duration: 0.24, extraBounce: 0.16)
        static let smooth = SwiftUI.Animation.smooth(duration: 0.20, extraBounce: 0)
        static let pulse = SwiftUI.Animation.easeInOut(duration: 1.1)
        static let snappy = SwiftUI.Animation.bouncy(duration: 0.18, extraBounce: 0.10)
    }

    enum Motion {
        static let page = SwiftUI.Animation.easeOut(duration: 0.18)
        static let state = SwiftUI.Animation.easeOut(duration: 0.15)
    }
}

// MARK: - Soft drop shadow

struct ShadowCardModifier: ViewModifier {
    var radius: CGFloat = 12
    var y: CGFloat = 4
    var opacity: Double = 0.08

    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(opacity * 0.5), radius: radius * 0.5, y: y * 0.4)
            .shadow(color: .black.opacity(opacity), radius: radius, y: y)
    }
}

extension View {
    func shadowCard(radius: CGFloat = 12, y: CGFloat = 4, opacity: Double = 0.08) -> some View {
        modifier(ShadowCardModifier(radius: radius, y: y, opacity: opacity))
    }
}

// MARK: - Panel card (translucent surface; native glass buttons on macOS 26+)

/// The primary content surface: translucent fill with a hairline border.
/// On macOS 26+, toolbar buttons use native Liquid Glass via `adaptiveGlassButton()`.
struct PanelCardModifier: ViewModifier {
    var radius: CGFloat = Theme.Radius.lg
    var fill: Double = 1
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tint?.opacity(0.10) ?? Theme.cardSurface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

extension View {
    func panelCard(radius: CGFloat = Theme.Radius.lg, fill: Double = 1, tint: Color? = nil) -> some View {
        modifier(PanelCardModifier(radius: radius, fill: fill, tint: tint))
    }
}

// MARK: - Active tile edge (de-carded selection for tiles & rows)

/// Selection treatment shared by provider tiles and model rows: a 2px accent
/// edge on the leading side plus a quiet tint fill. (Formerly the private
/// `ActiveRowEdge` in ProviderRow.swift.)
struct ActiveTileEdge: ViewModifier {
    var isActive: Bool
    var selected: Bool
    var corner: CGFloat = Theme.Radius.sm

    func body(content: Content) -> some View {
        content
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(Theme.chartGreen.opacity(0.10))
                }
            }
    }
}

// MARK: - Hairline sectioning (de-carded layout primitives)

/// A single hairline rule — the de-carded alternative to nested glass cards.
/// Sections separate with a 1px line and spacing, not another surface.
struct HairlineDivider: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.horizontal, inset)
    }
}

/// 1pt vertical rule for side-by-side panes. Never use `HairlineDivider`
/// inside an HStack — a height-only rectangle expands and eats the gap.
struct VerticalHairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }
}

/// Hairline section container: no background, no corner — just spacing and
/// optional top/bottom rules. Replaces `.panelCard()` nesting for list areas.
struct SectionBlock<Content: View>: View {
    var topRule: Bool = true
    var bottomRule: Bool = true
    var inset: CGFloat = Theme.Space.s16
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            if topRule { HairlineDivider(inset: inset) }
            content()
                .padding(.horizontal, inset)
            if bottomRule { HairlineDivider(inset: inset) }
        }
        .padding(.vertical, Theme.Space.s6)
    }
}

extension View {
    /// Just the hairline rules of a section — for stacks that manage their
    /// own inner padding. The de-carded alternative to `.panelCard()`.
    func sectionRules(inset: CGFloat = Theme.Space.s16,
                      top: Bool = true, bottom: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if top { HairlineDivider(inset: inset) }
            self
            if bottom { HairlineDivider(inset: inset) }
        }
        .padding(.vertical, Theme.Space.s4)
    }
}

// MARK: - Aligned glyphs

/// One optical box for every SF Symbol in chrome (nav, rows, chips).
/// Symbols sit in a 16×16 frame at 13pt medium / hierarchical so mixed
/// outlines don't dance on the baseline.
struct AppGlyph: View {
    let name: String
    var size: CGFloat = 13
    var weight: SwiftUI.Font.Weight = .medium
    var box: CGFloat = 16

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: weight))
            .symbolRenderingMode(.hierarchical)
            .frame(width: box, height: box, alignment: .center)
    }
}

/// CatStatus-style icon well: tinted rounded square, not a naked SF Symbol.
struct GlyphWell: View {
    let name: String
    var tint: Color = Theme.textSecondary
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundColor(tint)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(Theme.cardFill(0.06))
            )
    }
}

/// Status capsule used on metric cards (18核 / 正常 / RPM).
struct StatusPill: View {
    let label: String
    var tint: Color = Theme.textSecondary

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// Page heading used by every main-window destination.
struct PageTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Theme.Font.displayHero)
            .foregroundColor(Theme.textPrimary)
            .lineLimit(1)
            .fixedSize()
    }
}
