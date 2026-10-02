import SwiftUI

// Native translations of the Uiverse.io widgets the product actually uses.
// Motion uses native layers, gated by hover/start state and surface visibility.
// Ice canvas stays ice — the dark sparkle pill is the one ink contrast CTA.

// MARK: - Sparkle CTA (MuhammadHasann)

/// Dark capsule with inset highlight, purple/red `--active` glow, rotating
/// border sweep, and a three-point sparkle. Used as VPN 启动 / 停止.
struct SparkleCta: View {
    let title: String
    var spinning: Bool = false
    var kind: Kind = .go
    var action: () -> Void

    enum Kind { case go, stop }

    @State private var hover = false

    @Environment(\.surfaceIsVisible) private var surfaceVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var active: Bool { surfaceVisible && !reduceMotion && (hover || spinning) }

    private var glow: Color {
        kind == .stop ? Theme.statusError : Color(hue: 0.72, saturation: 0.90, brightness: 0.58)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SparkleMark(active: active)
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: active
                                ? [Color.white, Color.white.opacity(0.55)]
                                : [Color.white, Color.white.opacity(0.92)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                ZStack {
                    Capsule().fill(Color(hex: 0x1F1F1F))
                    Capsule()
                        .fill(
                            RadialGradient(
                                colors: overlayColors,
                                center: UnitPoint(x: 0.5, y: 0.92),
                                startRadius: 2,
                                endRadius: 36
                            )
                        )
                        .opacity(active ? 1 : 0)
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.55),
                                    Color.black.opacity(0.45)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                    SweepRing(active: active)
                }
            }
            .overlay {
                Capsule()
                    .stroke(glow.opacity(active ? 0.72 : 0), lineWidth: 6)
                    .blur(radius: 5)
                    .opacity(active ? 1 : 0)
            }
            .shadow(color: Color.black.opacity(active ? 0.04 : 0.22), radius: active ? 2 : 8, y: active ? 0 : 4)
            .scaleEffect(active ? 1.06 : 1)
            .animation(.easeInOut(duration: 0.28), value: active)
        }
        .buttonStyle(SparklePressStyle())
        .fixedSize()
        .onHover { hovering in
            if hover != hovering { hover = hovering }
        }
        .help(title)
    }

    private var overlayColors: [Color] {
        switch kind {
        case .go:
            return [
                Color(hue: 0.74, saturation: 0.42, brightness: 0.82),
                Color(hue: 0.72, saturation: 0.90, brightness: 0.58).opacity(0.82)
            ]
        case .stop:
            return [
                Color(hex: 0xFF8A80),
                Color(hex: 0xC41E3A).opacity(0.88)
            ]
        }
    }
}

/// Press collapses the hover scale back to 1, matching `:active { scale(1) }`.
private struct SparklePressStyle: ButtonStyle {
    /// The CTA's own press feedback. Gated like every other press style in the
    /// app — the sparkle CTA is the largest moving control on the VPN page.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SparkleMark: View {
    var active: Bool
    var body: some View { DecorativeMotion(kind: .sparkles, active: active) }
}

private struct SweepRing: View {
    var active: Bool
    var body: some View {
        DecorativeMotion(kind: .sweep, active: active)
            .opacity(active ? 1 : 0)
            .allowsHitTesting(false)
    }
}

/// Native layer rotation and star pulses; the caption remains static.
struct OrbitLoader: View {
    var size: CGFloat = 44
    var caption: String = "…"
    var spinning: Bool = true
    @Environment(\.surfaceIsVisible) private var windowVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(Theme.chartPurple.opacity(0.10))
                .shadow(color: Color.white.opacity(0.35), radius: size * 0.18)
            DecorativeMotion(kind: .orbit, tint: Theme.chartPurple,
                             active: spinning && windowVisible && !reduceMotion)
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: max(9, size * 0.24), weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(caption.isEmpty ? "启动中" : caption)
    }
}


// MARK: - Usage source mark

/// A usage *source* as its own mark: Anthropic's "A\" for CC, OpenAI's knot for
/// Codex, Cursor's cube, and — for 第三方 — ClaudeBar's own rings.
///
/// These are the labels the usage surfaces print most often — the popup's totals
/// bar, the island's usage card, the heatmap legend — and they used to be
/// printed as words while the marks sat unused one layer away in
/// `ProductBrandMark`. The island already names its agent families with that
/// artwork, so a source tally that spells "CC" in type next to a session badge
/// that draws the "A\" is the same app saying the same thing two ways.
///
/// **Every source takes a mark, 第三方 included.** It is not a client, which is
/// why it drew nothing here at first — but a legend where three entries carry a
/// glyph and the fourth is bare text reads as a row that failed to finish, not
/// as a deliberate distinction, and the user reported it as such. ClaudeBar has
/// a mark of its own (the app icon); see `ProductBrandMark.Brand.claudebar`.
///
/// **The page decides both the ink and the tile.** On a light card the artwork
/// must sit on its own tile — a bare black mark on the ice reads as a hole — and
/// on a *black* card that same tile is a *near-white square*, which is exactly
/// what shipped, twice, as "the bottom two icons are still white squares". Only
/// the caller knows which surface it is building, so `onBlackPage` answers both
/// questions at once: no tile and light ink on black, the tile and the theme's
/// ink everywhere else.
///
/// `onBlackPage` has no caller today. Its one black-page user was the island's
/// 本月 legend, and that legend was removed on 2026-09-27 (it did not fit the
/// line and the split bar beside it already said the same thing — see
/// `IslandUsageCard.monthLine`). The parameter stays because the *hazard* is
/// still live: any caller that puts this mark on a non-theme ground re-opens the
/// white-square bug, and the two-line spelling above is the answer that fixed
/// it. `Tests/product-mark-regressions.py` still guards the shape.
struct UsageSourceMark: View {
    let source: UsageSource
    var size: CGFloat = 14
    var font: Font = Theme.Font.micro
    var tint: Color = Theme.textSecondary
    /// `false` (the default) = a themed surface — the popup, a page, a card:
    /// the branded tile plus the theme's ink. `true` = the island's black usage
    /// card, which is black whatever the app theme is: **no tile** (a
    /// `bgSecondary` square is a hole there) and the light ink.
    var onBlackPage: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            // Both properties come from the caller's own ground: the ink
            // (`page:`) and whether the mark may paint its tile (`well:`).
            // See the note on the type — passing only the ink is the bug that
            // put a white square on the island's black card.
            ProductBrandMark(brand: Self.brand(of: source),
                             well: !onBlackPage,
                             page: onBlackPage ? true : nil)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
            Text(source.shortLabel)
                .font(font)
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(source.label)
    }

    /// Every source has artwork now, so this is total rather than optional.
    ///
    /// 第三方 used to return `nil` — it is not a client — and the legend drew it
    /// as bare text beside three marks, which reads as a row that failed to
    /// finish. It is not a *client* but it is still a subject the app is naming,
    /// and the app already has a mark for itself; see
    /// `ProductBrandMark.Brand.claudebar`.
    private static func brand(of source: UsageSource) -> ProductBrandMark.Brand {
        switch source {
        case .claude: return .claude
        case .codex: return .codex
        case .thirdParty: return .claudebar
        }
    }
}

// MARK: - Source stack (Damn good card overlapping circles)

struct SourceStack: View {
    let slices: [SourceRing.Slice]
    var scan: Bool = false

    private var ranked: [SourceRing.Slice] {
        slices.filter { $0.value > 0 }.sorted { $0.value > $1.value }
    }

    var body: some View {
        let items = Array(ranked.prefix(3))
        let sizes: [CGFloat] = items.count == 1 ? [28] : (items.count == 2 ? [24, 32] : [20, 26, 34])
        ZStack {
            HStack(spacing: -10) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, slice in
                    let s = sizes[min(i, sizes.count - 1)]
                    ZStack {
                        Circle().fill(Theme.base2)
                        Circle().fill(slice.color.opacity(0.16))
                        Group {
                            if slice.label == "Cursor" {
                                Image(systemName: "cursorarrow")
                            } else {
                                Text(glyph(slice.label))
                            }
                        }
                        .font(.system(size: s * 0.32, weight: .bold, design: .rounded))
                        .foregroundColor(slice.color)
                    }
                    .frame(width: s, height: s)
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.75), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 6, y: 3)
                    .zIndex(Double(items.count - i))
                    .help("\(slice.label) \(UsageStats.formatTokens(slice.value))")
                }
            }
            if scan, !items.isEmpty {
                ScanLine(active: scan)
                    .frame(width: 1, height: 36)
            }
        }
        .frame(height: 36)
    }

    /// The overlapping-circles stack's own letters. Kept as letters rather than
    /// marks: the three discs are 20–34pt and carry a white ring, so a scaled
    /// brand glyph inside one would be a 7–11pt smudge — and `UsageSourceMark`
    /// is the surface that names a source at a readable size.
    private func glyph(_ label: String) -> String {
        if label.contains("Claude") { return "C" }
        if label.lowercased().contains("codex") { return "X" }
        return "3"
    }
}

private struct ScanLine: View {
    var active: Bool
    @Environment(\.surfaceIsVisible) private var surfaceVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        DecorativeMotion(kind: .scan, tint: Theme.external,
                         active: active && surfaceVisible && !reduceMotion)
            .allowsHitTesting(false)
    }
}
