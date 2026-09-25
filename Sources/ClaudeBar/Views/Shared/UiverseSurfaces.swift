import SwiftUI

// Native translations of the *surface* language in the Uiverse.io pieces this
// product borrows from: the weather card's inset frame ring and orbit track,
// the 3D card's stacked depth lens and hover tilt, the status button's one-shot
// shine, and the belt's travelling ticks.
//
// Two hard rules, because these hang off grids of up to 200 cards:
//
// 1. **Motion is one of exactly two things** — a one-shot state change, or a
//    Core Animation layer that runs only while its surface is visible and
//    Reduce Motion is off (`DecorativeMotion`). No `TimelineView`, no
//    `repeatForever` on a SwiftUI view: a repeating SwiftUI animation keeps the
//    render server interpolating even when the view is hidden, which is the
//    cost the fan rotors and the island dots were moved off.
// 2. **Ornaments are one `Canvas` each.** The depth lens is three stroked
//    circles; as three `Circle` views that is three layers *per card*, on every
//    inventory tile in the app.

// MARK: - Hover-owned tile

/// A tile that tracks its own hover.
///
/// For a call site whose body has no other use for the flag — a static meter.
/// A card that *does* use hover for something else (a glyph well, a header's
/// `engaged` mark) keeps its own `@State` and calls `.tile(hovered:)` directly:
/// two `.onHover` handlers on one view means two pointer-tracking regions for
/// the same target, which is exactly the kind of doubled work this app's
/// performance notes keep hitting.
struct HoverTileModifier: ViewModifier {
    var tint: Color?
    var dense: Bool
    var lens: DepthLensSpec?
    var framed: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        TileSurface(tint: tint, hovered: hovered, dense: dense, lens: lens,
                    framed: framed, reduceMotion: reduceMotion) {
            content
        }
        .hoverState($hovered)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

extension View {
    func hoverTile(tint: Color? = nil, dense: Bool = false,
                   lens: DepthLensSpec? = nil, framed: Bool = true) -> some View {
        modifier(HoverTileModifier(tint: tint, dense: dense, lens: lens, framed: framed))
    }
}

// MARK: - Inset frame ring (weather card `::after`)

/// The weather card's white `::after` ring, drawn *inside* the surface's own
/// edge so a card reads as a machined panel rather than a filled rectangle.
///
/// The ring is white in both themes, which is why it belongs on surfaces that
/// carry a tint or sit on a dark ground: over a pure white card on the ice
/// canvas a white ring is invisible, so a card with no accent keeps
/// `framed: false`. This is the honest adaptation — the original's boldness
/// comes from the saturated gradient behind it, not from the ring.
struct InnerFrameRing: View {
    var lineWidth: CGFloat = 1
    var inset: CGFloat = 3
    var radius: CGFloat
    var tint: Color?

    var body: some View {
        RoundedRectangle(cornerRadius: max(0, radius - inset), style: .continuous)
            .strokeBorder(tint ?? Theme.innerFrame, lineWidth: lineWidth)
            .padding(inset)
            .allowsHitTesting(false)
    }
}

extension View {
    func innerFrame(_ lineWidth: CGFloat = 1, inset: CGFloat = 3,
                    radius: CGFloat, tint: Color? = nil) -> some View {
        overlay(InnerFrameRing(lineWidth: lineWidth, inset: inset, radius: radius, tint: tint))
    }
}

// MARK: - Depth lens (3D card's stacked circles)

/// Where a depth ornament hangs and how it is drawn. A value type so a card can
/// build it inline without another `@State`.
///
/// It carries **no glyph**: every card that mounts a lens already shows its own
/// mark in its header, and the rings are positioned to be cropped by the card's
/// corner — a symbol there would be a second identity, drawn half off the card.
struct DepthLensSpec {
    /// The hue the rings are drawn in — the card's own accent.
    var tint: Color
    var size: CGFloat = 150
    /// How many rings recede from the corner. Three is the product default:
    /// enough to read as depth without turning the corner into a target.
    var rings: Int = 3
    /// Which corner the rings recede from.
    var align: Alignment = .topTrailing
    /// How far the rings are pushed through that corner, as a fraction of
    /// `size` — so the crop is identical at every density. Zero keeps the whole
    /// stack inside the card, which reads as a badge rather than as depth.
    var overflow: CGFloat = 0.34
}

/// The 3D card's `.logo .circle1…5`: rings receding off the surface's corner.
///
/// The reference stacks five circles of decreasing size whose *offsets* from
/// the corner also grow (8 / 10 / 17 / 23 / 30 px), so their centres drift
/// **toward** the corner as they shrink — they are not concentric, and that
/// drift is what makes the stack read as depth rather than as a target. This
/// reproduces it: ring `n` is inscribed in `size²` shrunk by `shrink · n`,
/// anchored to the same corner with inset `drift · n`.
///
/// One `Canvas`, three arcs. The alternative — one stroked `Circle` view per
/// ring — is three layers per card on a grid that holds up to 200 of them, for
/// a shape whose geometry never changes.
struct DepthLens: View {
    var spec: DepthLensSpec
    var engaged: Bool = false

    private var steps: Int { max(1, spec.rings) }
    /// Per-ring shrink and drift, as fractions of the lens's own size.
    private static let shrink = 0.18
    private static let drift = 0.045

    var body: some View {
        Canvas { context, canvas in
            let lineWidth = max(1, canvas.width * 0.007)
            for step in 0..<steps {
                let side = spec.size * (1 - Self.shrink * CGFloat(step))
                let inset = spec.size * Self.drift * CGFloat(step)
                // Recede outward-inward: the largest ring is faintest and the
                // smallest the most present — 0.233 → 0.6 in the reference,
                // which is what keeps the innermost ring reading as the front
                // of the stack instead of as a fourth outline.
                let alpha = (engaged ? 0.16 : 0.10) + 0.045 * CGFloat(step)
                context.stroke(Path(ellipseIn: anchoredRect(side: side, inset: inset, in: canvas)),
                               with: .color(spec.tint.opacity(min(0.7, alpha))),
                               lineWidth: lineWidth)
            }
        }
        .frame(width: spec.size, height: spec.size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The ring's square, measured *inward* from the spec's corner — so the
    /// crop is identical however far the lens itself is offset.
    private func anchoredRect(side: CGFloat, inset: CGFloat, in canvas: CGSize) -> CGRect {
        let x: CGFloat
        switch spec.align {
        case .leading, .topLeading, .bottomLeading: x = inset
        default: x = canvas.width - inset - side
        }
        let y: CGFloat
        switch spec.align {
        case .topLeading, .topTrailing, .top: y = inset
        case .bottomLeading, .bottomTrailing, .bottom: y = canvas.height - inset - side
        default: y = (canvas.height - side) / 2
        }
        return CGRect(x: x, y: y, width: side, height: side)
    }
}

/// Where a lens sits inside its card. Kept beside `DepthLensSpec` so a card and
/// the lens's own placement can never disagree about which way it recedes.
enum LensPlacement {
    /// The offset that pushes a lens through the corner it is anchored to.
    ///
    /// A positive x moves the frame toward the trailing edge, which takes the
    /// right-hand arcs further out of the card; a negative y does the same at
    /// the top. Both signs therefore read as "recede". `overflow` is a fraction
    /// of the lens's own size, so the crop is the same at every density.
    static func offset(_ spec: DepthLensSpec) -> CGSize {
        let d = spec.size * spec.overflow
        let x: CGFloat
        switch spec.align {
        case .trailing, .topTrailing, .bottomTrailing: x = d
        case .leading, .topLeading, .bottomLeading: x = -d
        default: x = 0
        }
        let y: CGFloat
        switch spec.align {
        case .top, .topLeading, .topTrailing: y = -d
        case .bottom, .bottomLeading, .bottomTrailing: y = d
        default: y = 0
        }
        return CGSize(width: x, height: y)
    }
}

// MARK: - Depth card

/// The 3D card's *gesture* — a 1pt lift plus a small tilt — layered on top of
/// `.tile()`, which already owns the surface (base, wash, lens, frame).
///
/// Split this way deliberately: `.tile()` is the one card surface in the app
/// and must stay cheap enough for a 200-card inventory grid, where nothing
/// larger than a 2pt lift is affordable. The tilt is a *hero* treatment, so it
/// lives in its own modifier that page-level cards opt into.
///
/// The reference tilts 30°. At card density 2.2° reads as the same gesture with
/// the text still on its baseline, and it is applied only while one card is
/// hovered, so at most one subtree is ever rasterised in 3D.
private struct DepthTiltModifier: ViewModifier {
    var corner: CGFloat
    var shine: Bool
    var hovered: Bool
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(angle, axis: (x: 1, y: 1, z: 0), perspective: 0.6)
            .overlay {
                if shine, !reduceMotion {
                    ShineSweep(active: hovered,
                               tint: Theme.isDark ? .white : .white.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                }
            }
            .animation(reduceMotion ? nil : Theme.Motion.state, value: hovered)
    }

    private var angle: Angle {
        guard hovered, !reduceMotion else { return .degrees(0) }
        return .degrees(2.2)
    }
}

extension View {
    /// The hero-card gesture. Pair it with `.tile(tint:lens:hovered:)` — this
    /// adds only the transform and the one-shot shine, never the surface.
    ///
    /// Keep it off a card that lives in a scrolling grid: a 3D transform on a
    /// moving subtree forces a rasterisation pass per frame, and a grid already
    /// has the hover lift to answer the pointer.
    func depthTilt(corner: CGFloat = 22, shine: Bool = true,
                   hovered: Bool, reduceMotion: Bool = false) -> some View {
        modifier(DepthTiltModifier(corner: corner, shine: shine,
                                   hovered: hovered, reduceMotion: reduceMotion))
    }
}

// MARK: - One-shot shine (`view-status-btn::before`)

/// A soft highlight that crosses the control once when the pointer enters.
///
/// One shot, hover only. The original loops it on a `::before` with a
/// `transition`; a repeating shine on every card in a grid is the exact
/// per-frame cost this file's header rules out, and a shine that never stops
/// stops meaning "you arrived".
struct ShineSweep: View {
    var active: Bool
    var tint: Color = .white
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [tint.opacity(0), tint.opacity(0.5), tint.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: max(12, geo.size.width * 0.5))
                .offset(x: phase * geo.size.width * 1.5)
        }
        .clipped()
        .allowsHitTesting(false)
        .onChange(of: active) { _, on in
            guard on else { phase = -1; return }
            phase = -1
            withAnimation(.easeOut(duration: 0.55)) { phase = 1 }
        }
    }
}

private struct ShineHoverModifier<S: Shape>: ViewModifier {
    var tint: Color
    var shape: S
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if !reduceMotion {
                ShineSweep(active: active, tint: tint).clipShape(shape)
            }
        }
    }
}

extension View {
    /// Add the one-shot shine to a control that already tracks its own hover.
    ///
    /// `active` is passed in rather than tracked here on purpose: the owner
    /// already needs the flag for its fill, and two `.onHover` handlers on one
    /// view means two pointer-tracking regions for the same target.
    ///
    /// It is an accent on top of the affordance, never the affordance itself —
    /// a pointer that never arrives leaves the control looking complete.
    func shineOnHover<S: Shape>(tint: Color = .white, shape: S, active: Bool) -> some View {
        modifier(ShineHoverModifier(tint: tint, shape: shape, active: active))
    }
}

// MARK: - Segmented capsule (glass menu)

/// The glass menu: a capsule with an inset top/bottom highlight, a **sliding**
/// pill for the selection, and a hover that lifts the item's own ink.
///
/// Replaces the previous "capsule of loose capsules", where every item carried
/// its own capsule, border and shadow — so a four-item filter drew four cards
/// inside an outer card and the selection was only readable as "which one has a
/// fill". Here the group is one surface and the selection is one moving pill,
/// which is what makes the state legible at a glance.
///
/// Cost: one `matchedGeometryEffect` pill (a single transform, animated by the
/// render server) and no per-item layers. The inset highlight is the group's
/// own `::after`, drawn once.
struct SegmentedCapsule<Item: Hashable>: View {
    let items: [Item]
    let selection: Item
    let title: (Item) -> String
    var symbol: ((Item) -> String)? = nil
    var count: ((Item) -> Int)? = nil
    /// Accent for the selected pill's edge and its count.
    var tint: Color = Theme.Ink.claude
    /// Per-item accent, for a group whose items are different things (the
    /// connector platform row: Claude / Codex / Cursor each keep their own hue).
    /// Falls back to `tint`.
    var itemTint: ((Item) -> Color)? = nil
    /// Draw the product brand mark instead of the instrument glyph. `true`
    /// selects the Codex lockup, `false` the Claude one, `nil` means the item
    /// has no brand mark and falls back to `symbol`.
    var brand: ((Item) -> Bool?)? = nil
    /// A live marker on an item: the VPN page uses it for the group the core is
    /// actually exiting through, which is a *different fact* from the group the
    /// user is browsing — and the previous shape expressed both at once by
    /// tinting the same label two ways, so "where the traffic goes" and "what I
    /// am looking at" were the same colour.
    var dotted: ((Item) -> Bool)? = nil
    /// Stretch each item to share the width equally. Off for a filter that
    /// should hug its labels (a page toolbar); on for a row that has to span
    /// the surface it filters.
    var fillsWidth: Bool = false
    let onSelect: (Item) -> Void

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 1) {
            ForEach(items, id: \.self) { item in
                let on = item == selection
                SegmentedItem(title: title(item),
                              symbol: symbol?(item),
                              brand: brand.flatMap { $0(item) },
                              count: count?(item),
                              active: on,
                              dotted: dotted?(item) ?? false,
                              tint: itemTint?(item) ?? tint,
                              fillsWidth: fillsWidth) {
                    guard !on else { return }
                    onSelect(item)
                }
                .background {
                    if on {
                        SelectionPill(tint: itemTint?(item) ?? tint)
                            .matchedGeometryEffect(id: "segmentedPill", in: pill)
                    }
                }
            }
        }
        .padding(3)
        // The group's inset highlight: a top-lit rim and a bottom rule, i.e. a
        // capsule milled out of the canvas rather than laid on it.
        .background(CapsuleCradle())
        .overlay {
            Capsule()
                .strokeBorder(
                    LinearGradient(colors: [Theme.innerFrameMuted, .clear],
                                   startPoint: .top, endPoint: .center),
                    lineWidth: 1)
                .padding(2)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : Theme.Animation.snappy, value: selection)
        .accessibilityElement(children: .contain)
    }
}

/// The milled well a segmented group sits in: a faint fill with a hairline.
/// Its own view so the two shape modifiers stay out of the type checker's way
/// inside `SegmentedCapsule`'s already-long body.
private struct CapsuleCradle: View {
    var body: some View {
        Capsule()
            .fill(Theme.cardFill(0.05))
            .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 1) }
    }
}

/// The sliding selection: one pill the render server moves between items, whose
/// own edge is the group's accent. Its own view (rather than inline) because
/// the fill + border + shadow + matchedGeometry chain in one `background`
/// closure was enough for the type checker to give up.
private struct SelectionPill: View {
    let tint: Color

    var body: some View {
        Capsule()
            .fill(Theme.cardSurface)
            .overlay { Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 1) }
            .shadow(color: .black.opacity(0.09), radius: 5, y: 2)
    }
}

private struct SegmentedItem: View {
    let title: String
    let symbol: String?
    /// `nil` = no brand mark, `false` = Claude, `true` = Codex — the same
    /// convention `ProductBrandMark` uses, so the caller's item type does not
    /// have to map itself onto the mark's own enum.
    let brand: Bool?
    let count: Int?
    let active: Bool
    /// Draw the live marker: the traffic is actually going through this item.
    var dotted: Bool = false
    let tint: Color
    var fillsWidth: Bool = false
    let action: () -> Void

    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s6) {
                if dotted {
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                        .overlay { if active { BusyDotHalo(tint: tint) } }
                        .accessibilityHidden(true)
                }
                if let brand {
                    ProductBrandMark(codex: brand)
                        .frame(width: 15, height: 15)
                        .opacity(active ? 1 : 0.72)
                } else if let symbol {
                    SignatureGlyph(name: symbol,
                                   tint: active ? tint : Theme.textSecondary,
                                   size: 13, engaged: active || hovered)
                }
                Text(title)
                    .font(active ? Theme.Font.chromeEmph : Theme.Font.chrome)
                    .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                if let count {
                    Text("\(count)")
                        .font(Theme.Font.microMono)
                        .monospacedDigit()
                        .foregroundStyle(active ? tint : Theme.textTertiary())
                        .contentTransition(.numericText())
                    if fillsWidth { Spacer(minLength: 0) }
                }
            }
            .padding(.horizontal, Theme.Space.s12)
            .frame(height: 30)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background {
                if hovered && !active {
                    Capsule().fill(Theme.cardFill(0.06))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .hoverState($hovered)
        .shineOnHover(tint: Theme.isDark ? .white : .white.opacity(0.85),
                      shape: Capsule(),
                      active: hovered && !reduceMotion)
        .help("\(title)\(count.map { " · \($0) 项" } ?? "")")
        .accessibilityLabel("\(title)\(count.map { "，\($0) 项" } ?? "")")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// The halo around a live dot: a static ring, not a pulse. A repeating ring on
/// every live item is a per-frame animation on chrome that is almost always on
/// screen — the same reason the session tiles use a static halo.
private struct BusyDotHalo: View {
    let tint: Color

    var body: some View {
        Circle()
            .strokeBorder(tint.opacity(0.35), lineWidth: 1.5)
            .scaleEffect(1.9)
            .accessibilityHidden(true)
    }
}

// MARK: - Orbit gauge (weather card orbit path + celestial body)

/// An arc track with a body riding it — the weather card's orbit, used as a
/// meter instead of an animation: the body sits where the value sits on its own
/// range, and it is the only part that moves.
///
/// `Circle().trim` rather than a `Canvas` or a `Shape`: a trim is a single
/// stroked layer the render server can resize on its own, so a card in a
/// scrolling grid never re-runs path construction.
///
/// Angles follow SwiftUI's own convention — trim starts at 3 o'clock and runs
/// clockwise in screen space (y down), which is what `rotationEffect` rotates
/// by, so the body's position is `cos`/`sin` of the same angle in that frame.
struct OrbitGauge: View {
    /// 0…1 on the gauge's own range.
    var progress: Double
    var tint: Color
    var trackTint: Color = Theme.hairline
    var lineWidth: CGFloat = 6
    var bodySize: CGFloat = 11
    /// Where the arc begins, in degrees clockwise from 3 o'clock.
    var sweep: Double = -215
    /// How much of the circle the arc covers. Below 360 it reads as a gauge;
    /// at 360 it is a ring.
    var span: Double = 300
    var glow: Bool = true

    private var clamped: Double { min(max(progress, 0), 1) }

    private var bodyCenter: CGPoint {
        let angle = (sweep + span * clamped) * .pi / 180
        return CGPoint(x: cos(angle), y: sin(angle))
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = max(1, (side - lineWidth) / 2)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle()
                    .trim(from: 0, to: span / 360)
                    .stroke(trackTint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(sweep))
                Circle()
                    .trim(from: 0, to: max(0.0001, span / 360 * clamped))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(sweep))
                Circle()
                    .fill(Theme.cardSurface)
                    .frame(width: bodySize, height: bodySize)
                    .overlay(Circle().strokeBorder(tint, lineWidth: max(1.5, bodySize * 0.22)))
                    .shadow(color: glow ? tint.opacity(0.55) : .clear, radius: bodySize * 0.5)
                    .position(x: center.x + bodyCenter.x * radius,
                              y: center.y + bodyCenter.y * radius)
            }
            .animation(Theme.Motion.state, value: clamped)
        }
        // No fixed frame of its own: the gauge fills whatever box it is given
        // (the quota chip sizes it at 15pt, the expanded gauge at 30), and a
        // hard `bodySize` frame here would clip it to the *dot's* size.
        .frame(minWidth: bodySize * 2, minHeight: bodySize * 2)
        .accessibilityHidden(true)
    }
}

// MARK: - Conveyor belt (belt card's travelling ticks)

/// The belt's repeating ticks, travelling along a strip. Used where a surface
/// is *doing* something continuous — a scan, a live stream — so liveness is
/// drawn rather than pulsed, and it stops the moment the work does.
struct ConveyorBelt: View {
    var tint: Color = Theme.chartBlue
    var height: CGFloat = 4
    var running: Bool = true

    @Environment(\.surfaceIsVisible) private var surfaceVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DecorativeMotion(kind: .conveyor, tint: tint,
                         active: running && surfaceVisible && !reduceMotion)
            .frame(height: height)
            .clipShape(Capsule())
            .opacity(running ? 1 : 0.30)
            .animation(Theme.Motion.state, value: running)
            .accessibilityHidden(true)
    }
}

// MARK: - Page header card (weather card frame ring, at page scale)

/// The band that opens a page: a live count, a title, and the page's own
/// controls, on **one** surface from the tile family.
///
/// This is the piece that fixes the specific complaint that 「连接器页面太平庸」.
/// Every page used to open with a hand-rolled white rounded rectangle and a 1px
/// grey border — `ConnectorInventoryHeader` literally inlined `panelCard` minus
/// its wash and minus its inner frame ring (`ConnectorsView.swift:414-419`) —
/// which is the exact shape of a generic admin dashboard's header and the exact
/// reason the page read as plain while the cards *below* it were distinct.
///
/// A header earns its place in the family the same way a card does, by carrying
/// the same four parts:
///
/// 1. an accent wash (the page's hue at ~6 %), so the header and the grid under
///    it are the same object seen twice;
/// 2. the **inner frame ring** — the weather card's `::after`. The ring is white
///    and only visible *because* of the wash behind it, which is why the two
///    always travel together and why a wash-less white rect could never show it;
/// 3. a **depth lens** off the trailing corner, receding past the edge, so the
///    header has a foreground and a background rather than a flat fill;
/// 4. a hairline edge that lifts to the accent when the pointer is anywhere on
///    the band — a header is a surface you interact with (its buttons, its
///    filters), so it should answer a pointer like one.
///
/// The optional `orbit` slot draws the weather card's sky path across the band
/// with a body sitting at `orbitProgress`. It is a *reading*, not a loop: the
/// header is usually the page's summary, so the arc shows how far through that
/// summary's range the page currently is. Pass `nil` for no arc.
struct PageHeaderCard<Content: View>: View {
    var tint: Color = Theme.Ink.claude
    /// The hue for the wash, lens and hairline. Defaults to `tint` — pass a
    /// `Theme.Ink.*` value for text and the raw shape hue here together, so
    /// the band follows the same ink/shape rule as every card.
    var faceTint: Color? = nil
    /// 0…1, drawn on the sky path when `orbit` is non-nil.
    var orbit: Double? = nil
    @ViewBuilder var content: () -> Content

    @State private var hovered = false

    private var face: Color { faceTint ?? tint }

    var body: some View {
        content()
            .padding(.horizontal, Theme.Space.s16)
            .padding(.vertical, Theme.Space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tile(tint: face, hovered: hovered,
                  lens: DepthLensSpec(tint: face, size: 168, rings: 3))
            .overlay(alignment: .trailing) {
                if let orbit {
                    OrbitGauge(progress: orbit, tint: face,
                               trackTint: face.opacity(0.18),
                               lineWidth: 3, bodySize: 7, sweep: 180, span: 180)
                        .frame(width: 58, height: 58)
                        .padding(.trailing, 13)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .hoverState($hovered)
    }
}

// MARK: - Instrument KPI tile ornament (stat-widget ring + ground shadow)

/// The `stat-widget`'s conic reading ring, at tile scale: a value circled by the
/// share of its own range, with the plate inside.
///
/// Distinct from `OrbitGauge` on purpose. `OrbitGauge` is a *trim* with a body
/// riding the end of the arc — a pointer at a position. This is a *ring* whose
/// filled portion is the reading, with the number printed in its middle: the
/// two answer different questions ("where on the dial" vs "how much of the
/// whole"), and the machine tiles want the second.
///
/// The ring is a conic gradient (the reference's `conic-gradient`, native), so
/// it is one drawn layer per tile and never a stroked path with a computed
/// trim — a `Canvas` over a grid of them would rebuild per frame under scroll.
struct InstrumentRing: View {
    /// 0…1 on the ring's own range.
    var progress: Double
    var tint: Color
    var size: CGFloat = 40
    var thickness: CGFloat = 4
    /// The plate's own fill — `cardSurface` on a white tile, so the number
    /// reads on the same ground as the tile around it.
    var plate: Color = Theme.cardSurface

    private var clamped: Double { progress.isFinite ? min(1, max(0, progress)) : 0 }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(tint.opacity(0.16), lineWidth: thickness)
            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: tint.opacity(0.55), location: 0),
                            .init(color: tint, location: max(0.001, clamped * 0.72)),
                            .init(color: tint, location: max(0.002, clamped)),
                            .init(color: .clear, location: min(1, clamped + 0.001))
                        ]),
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    )
                )
                .mask(Circle().strokeBorder(tint, lineWidth: thickness))
            Circle()
                .fill(plate)
                .padding(thickness)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
