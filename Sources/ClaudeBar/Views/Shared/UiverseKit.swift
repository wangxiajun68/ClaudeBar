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
/// Codex, and — for 第三方 — ClaudeBar's own rings.
///
/// The one caller is the traffic page's source chip (`TrafficRow.sourceChip`),
/// which used to print every source as a word alone while these marks sat
/// unused one layer away in `ProductBrandMark`. The island already names its
/// agent families with that artwork, so a chip that spells "CC" in type next to
/// a session badge that draws the "A\" is the same app saying the same thing two
/// ways. A client the proxy cannot place (`CaptureSource.other`) has no usage
/// source at all — `CaptureSource.mark` answers `nil` for it — so its chip
/// keeps the word alone.
///
/// **Every source takes a mark, 第三方 included.** It is not a client, which is
/// why it drew nothing here at first — but a legend where three entries carry a
/// glyph and the fourth is bare text reads as a row that failed to finish, not
/// as a deliberate distinction, and the user reported it as such. ClaudeBar has
/// a mark of its own (the app icon); see `ProductBrandMark.Brand.claudebar`.
struct UsageSourceMark: View {
    let source: UsageSource
    var size: CGFloat = 14
    var font: Font = Theme.Font.micro
    var tint: Color = Theme.textSecondary

    var body: some View {
        HStack(spacing: 4) {
            ProductBrandMark(brand: Self.brand(of: source),
                             well: true, page: nil)
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

    /// The same mapping the view draws through; see `UsageSource.brandMark`.
    private static func brand(of source: UsageSource) -> ProductBrandMark.Brand {
        source.brandMark
    }
}

/// The one source→brand mapping. Every surface that names a usage source with
/// the client's own artwork — the popup's totals rows, the usage report's
/// source tally, `UsageSourceMark` — asks here; each used to hand-roll the same
/// switch and had to be kept total on its own.
///
/// **Every source takes a mark, 第三方 included.** It used to answer `nil` — it
/// is not a client — and the legend drew it as bare text beside three marks,
/// which reads as a row that failed to finish. It is not a *client* but it is
/// still a subject the app is naming, and the app already has a mark for
/// itself; see `ProductBrandMark.Brand.claudebar`.
extension UsageSource {
    var brandMark: ProductBrandMark.Brand {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .thirdParty: return .claudebar
        }
    }
}
