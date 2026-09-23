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

    // MARK: Ink — the signal hues as *text*
    //
    // The signal colors above are fill colors (bars, dots, gauge arcs, pill
    // washes). Painted as glyphs on the ice canvas they measure 1.8–3.4:1
    // (`claude` 3.37 · `chartGreen` 1.99 · `chartAmber` 1.84 · `statusIdle`
    // 2.92), well under the 4.5:1 WCAG AA floor for body text — an amber
    // "unavailable" or a green "enabled" was genuinely hard to read.
    //
    // `Ink` holds the same six signals darkened for light mode and lightened
    // for dark mode, all ≥ 4.5:1 against every surface they sit on
    // (`bgPrimary` / `cardSurface` / `bgOverlay`). Use `Theme.x` for anything
    // that is *shape*, `Theme.Ink.x` for anything that is *text or a glyph*.
    enum Ink {
        static var claude: Color { isDark ? Color(hex: 0x6EA8FF) : Color(hex: 0x1D4FB8) }
        static var cursor: Color { isDark ? Color(hex: 0xC08BFF) : Color(hex: 0x7A34B8) }
        static var codex: Color { isDark ? Color(hex: 0xA8ADB4) : Color(hex: 0x5F6368) }
        static var success: Color { isDark ? Color(hex: 0x30D158) : Color(hex: 0x1B7F3A) }
        static var warning: Color { isDark ? Color(hex: 0xFFB340) : Color(hex: 0x8A4B00) }
        static var error: Color { isDark ? Color(hex: 0xFF6B61) : Color(hex: 0xB3261C) }
        static var idle: Color { isDark ? Color(hex: 0xA8ADB4) : Color(hex: 0x5A5A5E) }
    }

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
        static let gridGapPage: CGFloat = 14
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
        /// Nav tabs, card titles, settings titles — one size so chrome doesn't drift.
        static let chrome = SwiftUI.Font.system(size: 13, weight: .medium, design: .rounded)
        static let chromeEmph = SwiftUI.Font.system(size: 13, weight: .semibold, design: .rounded)
        static let brand = SwiftUI.Font.system(size: 16, weight: .semibold, design: .rounded)
        static let section = SwiftUI.Font.system(size: 12, weight: .semibold, design: .rounded)
        static let eyebrow = SwiftUI.Font.system(size: 10, weight: .semibold, design: .rounded)
        static let meta = SwiftUI.Font.system(size: 10, weight: .regular, design: .rounded)
        static let kpi = SwiftUI.Font.system(size: 9, weight: .medium, design: .rounded)
        static let pill = SwiftUI.Font.system(size: 11, weight: .medium, design: .rounded)
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

    /// `contextColor` as readable text — the context label ("48.2k / 200k")
    /// is text, and the raw hues are 1.8–3.4:1 on the light canvas. The bar
    /// itself keeps `contextColor`.
    static func contextInk(_ ratio: Double) -> Color {
        if ratio < 0.6 { return Ink.claude }
        if ratio < 0.85 { return Ink.warning }
        return Ink.error
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

    /// The same per-model hue as readable text, index-aligned with
    /// `barColor(for:)`. A usage tile paints the model's share as a bar *and*
    /// as a "38 %" pill; the bar wants `barColor`, the pill wants this one
    /// (the raw hues land at 1.8–3.4:1 on the light canvas).
    static func barInk(for model: String) -> Color {
        let palette: [Color] = [
            Ink.claude,
            Ink.cursor,
            Ink.success,
            Ink.warning,
            Ink.error,
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
                    .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
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

/// A small machined well: semantic mark, inset edge, interaction-led motion.
struct GlyphWell: View {
    let name: String
    var tint: Color = Theme.textSecondary
    var size: CGFloat = 22
    var engaged = false

    var body: some View {
        SignatureGlyph(name: name, tint: tint, size: size * 0.64, engaged: engaged)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                    .fill(tint.opacity(engaged ? 0.14 : 0.07))
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                    .strokeBorder(tint.opacity(engaged ? 0.3 : 0.14), lineWidth: 0.75)
            }
            .accessibilityHidden(true)
    }
}

/// Status capsule used on metric cards (18核 / 正常 / RPM).
///
/// The fill is a 12 % wash of `tint` while the text is `tint` itself, so every
/// call site hands in a *shape* hue and inherits 1.8–3.4:1 text. `ink` is the
/// readable counterpart: pass the matching `Theme.Ink.x` when the pill is a
/// state readout (运行中 / 正常 / 已启用), and leave it nil for a pill whose
/// tint was already chosen as ink.
struct StatusPill: View {
    let label: String
    var tint: Color = Theme.textSecondary
    var ink: Color? = nil

    var body: some View {
        Text(label)
            .font(Theme.Font.pill)
            .foregroundColor(ink ?? tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// Page heading used by every main-window destination.
struct PageTitle: View {
    let title: String
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            GlyphWell(name: PageIdentity.symbol(title), tint: PageIdentity.ink(title),
                      size: 34, engaged: hovered)
            Text(title)
                .font(Theme.Font.displayHero)
                .tracking(Theme.Tracking.titleSmall)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
        }
        .onHover { hovered = $0 }
        .accessibilityAddTraits(.isHeader)
    }
}
