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

/// Design tokens for ClaudeBar: translucent **Liquid Glass** surfaces over a
/// neutral near-black backdrop. The palette is deliberately near-monochrome —
/// a single cool accent (soft blue = Claude Code) and a secondary violet
/// (Cursor) do the identity work, and color is reserved for state (busy /
/// warning / error). Hierarchy comes from typography and weight, not from
/// color on every element.
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

    /// Session-kind hue — blue for Claude, violet for Cursor.
    static func signal(isCursor: Bool) -> Color {
        isCursor ? cursor : claude
    }

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
        static let s6: CGFloat = 6
        static let s8: CGFloat = 8
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32
        /// Grid gap — popup density (2-col tiles in the 560pt panel).
        static let gridGap: CGFloat = 6
        /// Grid gap — main-window pages (tile grids).
        static let gridGapPage: CGFloat = 12
    }

    // MARK: Corner radii
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 18
    }

    // MARK: Typography
    //
    // Three-layer type system:
    //   • Display faces — classical serifs for page titles and metric values:
    //     **Kaiti SC** (楷体) renders CJK with calligraphic brush character, and
    //     **Palatino** carries the Latin glyphs with a Renaissance old-style
    //     serif of matching spirit. A SwiftUI `custom` font renders one family;
    //     mixing two is done per-string by the `display(...)` helpers below,
    //     which type the leading run in Palatino and the whole string in Kaiti
    //     (CoreText resolves Latin from Kaiti's fallback to Palatino when
    //     Palatino is absent — the metric-value helper composes both faces).
    //   • Text faces — SF Pro (system) for UI chrome, rows, captions: maximum
    //     legibility at small sizes, zero rasterization cost.
    //   • Mono faces — system monospaced for data columns and model names.
    enum Tracking {
        static let titleLarge: CGFloat = -0.03
        static let titleMedium: CGFloat = -0.02
        static let titleSmall: CGFloat = -0.01
        static let bodyLarge: CGFloat = -0.005
        static let body: CGFloat = 0
        static let caption: CGFloat = 0.03
        static let captionMono: CGFloat = 0
    }

    /// Calligraphic CJK display face (system-shipped Xingkai.ttc). 行楷's
    /// slender, tapering brush strokes are the closest system face to 瘦金体's
    /// sharp elegance; reserved for display sizes only (small CJK text falls
    /// back to SF Pro tiers for legibility).
    private static let displayCJK = "Xingkai SC"
    /// Old-style Latin serif (Palatino.ttc) for titles/numbers — its humanist
    /// proportions pair naturally with 楷体's brush rhythm.
    private static let displayLatin = "Palatino"

    enum Font {
        // Display tier — titles and hero numbers. Kaiti covers CJK; Latin
        // strings (model names, "Axon", digits) resolve through Palatino via
        // the cascade below.
        static let titleLarge = SwiftUI.Font.custom(displayCJK, size: 28).weight(.bold)
        static let titleMedium = SwiftUI.Font.custom(displayCJK, size: 20).weight(.semibold)
        static let titleSmall = SwiftUI.Font.custom(displayCJK, size: 14).weight(.semibold)
        static let bodyLarge = SwiftUI.Font.system(size: 14, weight: .regular)
        static let body = SwiftUI.Font.system(size: 13, weight: .regular)
        static let bodySmall = SwiftUI.Font.system(size: 11, weight: .regular)
        static let caption = SwiftUI.Font.system(size: 10, weight: .regular)
        static let captionMono = SwiftUI.Font.system(size: 9, weight: .regular, design: .monospaced)
        static let labelSection = SwiftUI.Font.system(size: 10, weight: .semibold)

        /// Large telemetry readouts — the serif face makes the numbers the
        /// visual anchor of a tile. Palatino's old-style figures keep the
        /// classical feel while staying tabular-friendly at a glance.
        static let displayMetric = SwiftUI.Font.custom(displayLatin, size: 30).weight(.semibold)
        static let displayMetricSmall = SwiftUI.Font.custom(displayLatin, size: 19).weight(.semibold)

        // Popup-density aliases — the menu-bar panel runs tighter than pages.
        // These exist so view files never hand-roll `.system(size:)` inline.
        /// 11px medium row-title (popup session/provider lines).
        static let rowTitle = SwiftUI.Font.system(size: 11, weight: .medium)
        /// 13px row title (provider list lines).
        static let rowLarge = SwiftUI.Font.system(size: 13, weight: .regular)
        /// 10px popup micro text; use the weighted variants for emphasis.
        static let micro = SwiftUI.Font.system(size: 10, weight: .regular)
        static let microMedium = SwiftUI.Font.system(size: 10, weight: .medium)
        static let microSemibold = SwiftUI.Font.system(size: 10, weight: .semibold)
        /// 10px monospaced — data only (activity, model names).
        static let microMono = SwiftUI.Font.system(size: 10, weight: .regular, design: .monospaced)
        /// 9px monospaced badge (context chips, model badges).
        static let badgeMono = SwiftUI.Font.system(size: 9, weight: .regular, design: .monospaced)

        /// Parametric system-icon size (SF Symbols), tokenized so view files
        /// never hand-roll `.system(size:)` for icon fonts.
        static func systemIcon(_ size: CGFloat) -> SwiftUI.Font {
            SwiftUI.Font.system(size: size)
        }

        // Tile typography — the 宫格 (grid) readouts. Tile values use the
        // Latin display serif (Palatino); labels and details stay on SF Pro
        // for small-size legibility.
        /// Page metric tile value (Dashboard stats, usage totals).
        static let tileValue = SwiftUI.Font.custom(displayLatin, size: 22).weight(.semibold)
        /// Popup / dense tile value.
        static let tileValueSmall = SwiftUI.Font.custom(displayLatin, size: 16).weight(.semibold)
        /// Micro tile value inside dense tiles (per-model tokens).
        static let tileMicroValue = SwiftUI.Font.system(size: 13, weight: .semibold, design: .monospaced)
        /// Tile label (uppercase-feel caption above the value).
        static let tileLabel = SwiftUI.Font.system(size: 10, weight: .semibold)
        /// Tile detail / tertiary line under a value.
        static let tileDetail = SwiftUI.Font.system(size: 10, weight: .regular)
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
        }

        static func columns(_ preset: Preset) -> [GridItem] {
            switch preset {
            case .pageMetric:
                Array(repeating: GridItem(.flexible(), spacing: Space.gridGapPage), count: 4)
            case .pageSession:
                [GridItem(.adaptive(minimum: 280), spacing: Space.gridGapPage, alignment: .top)]
            case .pageUsage, .pageProvider:
                [GridItem(.adaptive(minimum: 240), spacing: Space.gridGapPage, alignment: .top)]
            case .popupSession, .popupProvider, .popupUsage:
                // Top-aligned cells: tiles in a row share a baseline instead
                // of floating at differing centers.
                [GridItem(.flexible(), spacing: Space.gridGap, alignment: .top),
                 GridItem(.flexible(), spacing: Space.gridGap, alignment: .top)]
            }
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
            Color(hex: 0x4F8EF7),  // blue
            Color(hex: 0xA78BFA),  // violet
            Color(hex: 0x46C58F),  // teal
            Color(hex: 0xE0A13C),  // amber
            Color(hex: 0xE46464),  // coral
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
}

// MARK: - Liquid Glass panel (native macOS 26 glassEffect)

/// The primary content surface: **native macOS 26 Liquid Glass** — real blur,
/// specular edge highlights, and translucency, with a whisper of white tint to
/// keep content readable over the backdrop.
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
                    RoundedRectangle(cornerRadius: corner)
                        .fill(Theme.claude.opacity(0.10))
                }
            }
            .overlay(alignment: .leading) {
                if isActive {
                    Rectangle()
                        .fill(selected ? Theme.claude : Theme.claude.opacity(0.45))
                        .frame(width: 2)
                        .clipShape(RoundedRectangle(cornerRadius: 1))
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
