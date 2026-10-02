import AppKit
import SwiftUI

// MARK: - PressableStyle

/// A button style that scales the content down slightly on press, then
/// springs back on release. The tactile foundation for chips, icon buttons,
/// and cards — the small 0.96 scale keeps the press subtle.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

/// Uiverse 3D press: translate down 1pt, collapse the drop shadow.
/// Translation preserves the visual size of compact, variable-width controls.
struct UiversePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed && !reduceMotion ? 1 : 0)
            .shadow(color: .black.opacity(configuration.isPressed ? 0 : 0.08),
                    radius: configuration.isPressed ? 0 : 2, y: configuration.isPressed ? 0 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == UiversePressStyle {
    static var uiversePress: UiversePressStyle { UiversePressStyle() }
}

/// One-shot lift on appear. Delay is staggered so stacked popup sections
/// cascade without animating every inner cell (that would hitch scroll).
///
/// **Currently no call site.** It used to stagger the popup's sections on open;
/// those `.appearLift(...)` calls were removed, and DESIGN.md's "popup sections
/// lift in once" now describes nothing in the code. Kept because the stagger
/// *shape* — a one-shot per section, never per inner cell — is the right one
/// for a surface that wants it, and the `onAppear`-guarded `@State` is the
/// non-obvious half of getting it right.
struct AppearLift: ViewModifier {
    var delay: Double = 0
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                guard !shown else { return }
                withAnimation(reduceMotion ? nil : Theme.Animation.smooth.delay(delay)) { shown = true }
            }
    }
}

extension View {
    func appearLift(delay: Double = 0) -> some View {
        modifier(AppearLift(delay: delay))
    }
}

// MARK: - Action buttons

// The push button used to be declared here, as `adaptiveGlassButton`. It is now
// `ActionButton` in `InstrumentControls.swift`, together with every other control
// shape in the app, so that the button, the chip, the icon action and the switch
// are one file with one press vocabulary and one plate. Nothing that reaches for
// the old name survives: the last call site was migrated with it.

// MARK: - HoverState

/// True while a scroll view is tracking, decelerating or animating.
///
/// Not observable on purpose. Publishing scroll phase re-evaluates the page
/// at the moment the scroll needs the main thread (the same reason
/// `PageScrollActivity` is a reference). Hover writes consult it and drop
/// enter/exit events for the duration, so a flick across a grid does not
/// lift and drop a tile per frame. When the phase returns to idle the page
/// posts one `mouseMoved`, and the tile actually under the pointer catches up.
enum ScrollHoverGate {
    // Each scroll view owns its phase. An idle callback or disappearance in
    // another window must not release the one still moving.
    private static var owners: Set<UUID> = []
    static var scrolling: Bool { !owners.isEmpty }
    private static var since: CFTimeInterval = 0
    private static let holdLimit: CFTimeInterval = 4
    static var isDeferring: Bool { scrolling && CACurrentMediaTime() - since < holdLimit }

    private static var pending: [AnyHashable: () -> Void] = [:]
    private static var watchdog: DispatchWorkItem?
    private static var generation: UInt64 = 0

    /// Coalesce background readings while scrolling. The hold has a deadline
    /// even if idle is lost.
    static func afterScroll(_ key: AnyHashable, _ apply: @escaping () -> Void) {
        guard isDeferring else {
            pending[key] = nil
            apply()
            return
        }
        pending[key] = apply
        scheduleWatchdog()
    }

    private static func scheduleWatchdog() {
        guard watchdog == nil, !pending.isEmpty else { return }
        let expected = generation
        let remaining = max(0, holdLimit - (CACurrentMediaTime() - since))
        let work = DispatchWorkItem {
            guard expected == generation else { return }
            watchdog = nil
            flushIfReady()
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining + 0.01, execute: work)
    }

    private static func flushIfReady() {
        // An idle callback queued by a previous gesture can land after a new
        // gesture has started. Keep that gesture's writes held.
        guard !isDeferring else { scheduleWatchdog(); return }
        watchdog?.cancel()
        watchdog = nil
        generation &+= 1
        let blocks = Array(pending.values)
        pending.removeAll()
        for block in blocks { block() }
    }

    static func set(_ moving: Bool, owner: UUID) {
        let was = scrolling
        if moving { owners.insert(owner) } else { owners.remove(owner) }
        if !was, scrolling { since = CACurrentMediaTime() }
        if was, !scrolling {
            DispatchQueue.main.async {
                flushIfReady()
                if !isDeferring { refresh() }
            }
        }
    }

    static func refresh() {
        guard let window = NSApp.keyWindow else { return }
        guard let event = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: window.mouseLocationOutsideOfEventStream,
            modifierFlags: NSEvent.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ) else { return }
        window.sendEvent(event)
    }
}

/// Tracks pointer-in / pointer-out for a view, wrapped into a bindable
/// `@State` so hover-driven UI can be read declaratively.
struct HoverState: ViewModifier {
    @Binding var isHovered: Bool

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if ScrollHoverGate.isDeferring { return }
                if isHovered != hovering { isHovered = hovering }
            }
    }
}

extension View {
    /// Drive `isHovered` from pointer movement, animated with the theme spring.
    func hoverState(_ isHovered: Binding<Bool>) -> some View {
        modifier(HoverState(isHovered: isHovered))
    }

    /// Drop hover writes for the duration of a flick, then reconcile once.
    ///
    /// A grid of tiles that each own a hover flag lays out once per tile the
    /// pointer crosses. The flag is the one in `ScrollHoverGate`; this is the
    /// scroll view's half of it.
    func scrollHoverGate() -> some View {
        modifier(ScrollHoverGateModifier())
    }
}

private struct ScrollHoverGateModifier: ViewModifier {
    @State private var owner = UUID()
    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in
                ScrollHoverGate.set(phase != .idle, owner: owner)
            }
            .onDisappear { ScrollHoverGate.set(false, owner: owner) }
    }
}

// MARK: - Action chip

/// A compact circular icon button used as the hover-revealed action on rows.
/// Carries its own hover highlight so it feels like a distinct target rather
/// than part of the card surface.
///
/// `.plain` alone gives the button no hit shape: the tappable area is the
/// *rendered glyph* (icon strokes plus the 26×26 background), so clicks land
/// on the transparent corners and fall through to whatever is behind. Wrapping
/// the label in a `contentShape` makes the whole tile a target.
struct ActionChip: View {
    let systemImage: String
    let tint: Color
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            AppGlyph(name: systemImage, size: 12, box: 16)
                .foregroundColor(tint)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(tint.opacity(hover ? 0.22 : 0.10))
                )
                .overlay(
                    Circle()
                        .strokeBorder(tint.opacity(hover ? 0.5 : 0.25), lineWidth: 1)
                )
            .scaleEffect(hover ? 1.08 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hover != hovering { hover = hovering }
        }
        .help(help)
        // `.help` renders a tooltip only; VoiceOver needs the label.
        .accessibilityLabel(help)
    }
}

// MARK: - Icon chip

/// One item in an icon row — the menu-bar popup's action bar, the battery
/// popover's button, the main window's trailing controls.
///
/// Drawn from the `mymiamo` glass menu's *item*: a rounded tile that stays
/// quiet at rest and, on hover, takes a lit fill plus the same inset rim the
/// menu group wears (`inset 2px 2px 5px -2px` top-left, `inset -2px -2px`
/// bottom-right). A row of ten identical flat squares was the plainest thing in
/// the highest-frequency surface in the app; the reference's answer is not more
/// decoration per item but a *shared* well the items sit in, which is
/// `IconChipRow` below.
struct IconChip: View {
    let systemImage: String
    var tint: Color = Theme.textSecondary
    var size: CGFloat = 12
    var tile: CGFloat = 26
    var corner: CGFloat = Theme.Radius.sm
    @State private var hover = false

    var body: some View {
        SignatureGlyph(name: systemImage, tint: hover ? tint : tint.opacity(0.85),
                       size: size + 4, engaged: hover)
            .frame(width: tile, height: tile)
            .background {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(tint.opacity(hover ? 0.15 : 0))
            }
            .overlay {
                // The lit rim appears with the fill, so the tile reads as a
                // glass item lighting up rather than as a square that changed
                // colour.
                if hover {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(tint.opacity(0.30), lineWidth: 0.75)
                }
            }
            .overlay {
                if hover {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(Theme.isDark ? 0.10 : 0.75),
                                         .clear,
                                         Color.white.opacity(Theme.isDark ? 0.05 : 0.35)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            }
            .onHover { if hover != $0 { hover = $0 } }
            .animation(Theme.Motion.state, value: hover)
    }
}

/// The milled well an icon row sits in — the `mymiamo` menu's own glass track.
///
/// This is the half of the reference that fixes a ten-chip row: the items share
/// one translucent capsule with a lit top rim and a soft bottom rule, so the bar
/// reads as a single control strip rather than as ten unrelated squares on the
/// canvas. The row's own items (`IconChip`) then only need a hover highlight,
/// which is why they could give up their resting fill entirely.
///
/// One shape, one gradient overlay, drawn once for the whole row — no per-item
/// layer, so a bar of ten chips is two layers, not twenty.
struct IconChipRow<Content: View>: View {
    var spacing: CGFloat = Theme.Space.s4
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: spacing) { content() }
            .padding(.horizontal, Theme.Space.s6)
            .padding(.vertical, Theme.Space.s4)
            .background {
                Capsule()
                    .fill(Theme.cardFill(0.06))
                    .overlay {
                        Capsule().strokeBorder(Theme.hairline, lineWidth: 1)
                    }
            }
            .overlay {
                // The lit rim: bright along the top edge, fading before it
                // reaches the bottom — the same top-lit convention the tiles and
                // the segmented cradle use.
                Capsule()
                    .strokeBorder(
                        LinearGradient(colors: [Theme.innerFrameMuted, .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1
                    )
                    .padding(1.5)
                    .allowsHitTesting(false)
            }
    }
}

/// The island's per-digit roll, shared by the island, the menu-bar popup and
/// the main window. Only the glyphs move; the view's frame stays put.
///
/// **`.numericText` only — no implicit `.animation(value:)`.** A previous
/// version also carried `.animation(.snappy(duration: 0.38), value: value)`,
/// which made this the app's worst idle cost. Every instance is driven by a
/// value the sampler updates once a second (a hero percentage, a session
/// count, a context label), so the modifier opened a *fresh* animated
/// transaction on every tick, and an in-flight transaction makes the display
/// cycle run the whole hosting view's layout + display list. The `sample`
/// signature moved cleanly: `+[NSAnimationContext runAnimationGroup:]` inside
/// `NSHostingView.layout()` fell from 31 % of main-thread samples to 13 %, and
/// `stepIdle` (the display-cycle observer re-laying out the window every
/// frame) from 56 % to 3 %. `.numericText` already animates the digits, so
/// removing the modifier costs the roll nothing: the transition *is* the
/// animation.
///
/// The `ps -p PID -o time=` delta on the dashboard is a *noisy* metric on this
/// machine (a Chrome renderer holds half a core, and the app's own idle figure
/// swings 10-27 % between 20 s windows with no interaction). Treat the sample
/// attribution above as the evidence and the CPU delta as corroboration only.
///
/// The rule is the one `UiverseSurfaces.swift` states for repeating motion,
/// applied to *implicit* motion: on a hot surface, a modifier keyed to a
/// per-second value is not free even when the value rarely changes.
/// `Tests/inflight-animation-regressions.py` holds this and
/// `SectionHeader.trailingView` to it.
///
/// This is the **one** definition of the roll: `View.rollingNumber()` below
/// carries the identical transition, and this wrapper exists only so a figure
/// reads as a *figure* at the call site. Every numeric `Text` in the app — on
/// every page, in the popup, on the island — goes through one of the two, so
/// "所有数字都逐位滚动" is one rule, not one rule per screen.
struct RollingNumberText: View {
    let value: String
    /// See `RollingNumberModifier.rolls` — false keeps the figure live and drops
    /// the transition (a reading faster than the roll can settle, or a surface
    /// no one is looking at).
    var rolls = true

    init(_ value: String, rolls: Bool = true) {
        self.value = value
        self.rolls = rolls
    }

    var body: some View {
        Text(value)
            // The figure itself is the transition's key, so the roll runs when
            // this number changed — not when anything else in the view did.
            .rollingNumber(value, rolls: rolls)
    }
}

// MARK: - Rolling figures

/// The app's one digit-roll: `.numericText` carried by the value change itself,
/// with no implicit `.animation(_:value:)` — see the `RollingNumberText` note
/// above for why that modifier is the app's worst idle cost.
///
/// Applied as a `ViewModifier` (not a `Text` method) so that **any** view that
/// renders a figure can take it without giving up its own type: a `Text` keeps
/// every `Text`-only modifier (`lineLimit`, `minimumScaleFactor`, …) chained
/// after `.rollingNumber()`, and a styled label rolled in place needs no
/// restructure. It is the common method the whole app routes through; the
/// `Text`-returning form (`Text(_:).rollingNumber(_:)` still being a `Text`)
/// would have forced every call site to reorder its modifiers.
struct RollingNumberModifier: ViewModifier {
    var enabled: Bool = true
    /// The rendered figure, and the roll's transition key: the transaction opens
    /// because *this* number changed, not because some value in the view
    /// happened to tick.
    ///
    /// **Not optional, and not defaulted.** A modifier is handed an opaque
    /// `_ViewModifier_Content`, not the `Text` it wraps — the erasure cannot be
    /// cast back or reflected, and `String(describing:)` of it is identical for
    /// every wrapping — so the modifier cannot read the number out of its own
    /// content and the caller has to state it. The previous shape (`String? = nil`
    /// with a `String(describing: Self.self)` fallback) was worse than a
    /// compile error: the fallback is constant, so no transaction closure was
    /// ever entered and every site that passed nothing rolled in silence.
    var figure: String
    /// Whether this figure rolls at all.
    ///
    /// The digit roll is a transition, so it runs on its own display cycle every
    /// time the number changes — for a 1 Hz reading that is a redraw of the
    /// surface per tick, whether or not anyone is looking at it. These are the
    /// figures that must **not** roll:
    ///
    /// - **a surface nobody is looking at.** The island's panel is mounted on
    ///   every display, over full-screen apps, forever; its collapsed wings tick
    ///   with the sampler. Rolling a number no one can see buys a per-tick
    ///   display cycle for nothing. The owners already track this
    ///   (`UIWakePolicy.hasVisibleWindow`, `surfaceIsVisible` in a `body`); the
    ///   figure asks via `rolls` instead of each owner remembering to gate.
    /// - **a value fed at >1 Hz.** The resource strip's CPU / GPU / 内存 / 硬盘
    ///   heroes sample as often as once a second while a detail popover is open.
    ///   At that rate the transition never settles: the tile is mid-roll when the
    ///   next reading lands, so it never shows a readable frame and it redraws
    ///   the whole card per sample. Coat every other figure in the app.
    ///
    /// A figure that is *not* rolling still updates; it just swaps, and it does
    /// not keep an animated transaction alive between readings.
    var rolls: Bool = true

    /// What the roll's transition is keyed on.
    ///
    /// `.numericText` says what happens to the glyphs **during a transition**;
    /// it does not create one. SwiftUI runs a content transition only when the
    /// change arrives inside an animation transaction (`withAnimation`, or an
    /// `.animation` SwiftUI itself opened). A plain state write from a 1 Hz
    /// sampler — what feeds almost every figure in this app — arrives in a
    /// *non-animated* transaction, so the digits swapped instantly and the roll
    /// was invisible in the running app.
    ///
    /// The fix used to be an implicit `.animation(_:value:)` on each figure, and
    /// that had a real cost: keyed on a value the sampler updates once a second,
    /// it opened a *fresh* animated transaction on every tick. While any
    /// transaction is in flight, every display cycle re-runs the whole hosting
    /// view's layout and display list — not only the cycles where the
    /// interpolated property moves. Measured on the dashboard:
    /// `+[NSAnimationContext runAnimationGroup:]` inside `NSHostingView.layout()`
    /// for 31 % of main-thread samples with it, 13 % without
    /// (docs/technical/08-performance.md).
    ///
    /// So the transaction is opened once here, keyed on the **rendered value**,
    /// rather than by a modifier sitting on a per-poll input. It still only runs
    /// when a figure actually changed, nothing stays resident on a 1 Hz value,
    /// and the app keeps exactly one definition of the roll. Doing it here rather
    /// than at each call site is also the only form a `Text` can take:
    /// `withAnimation` needs a data source to write to, and a figure is usually a
    /// *computed string* handed to a leaf — `RollingNumberText(UsageStats.formatTokens(n))`
    /// has no source to write to and no way to wrap its parent's update.
    struct Transition: Equatable {
        var value: String
        /// Reduce Motion makes the roll an identity transition: the value still
        /// updates, it just stops sliding.
        var reduceMotion: Bool
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.surfaceIsVisible) private var surfaceIsVisible

    func body(content: Content) -> some View {
        if enabled {
            content
                .monospacedDigit()
                .contentTransition(reduceMotion || !rolls || !surfaceIsVisible
                                   ? .identity : .numericText(countsDown: true))
                .transaction(value: transition) { transaction in
                    // The whole gate, not just the environment half: `rolls:
                    // false` and an invisible surface must not install an
                    // animation either — the key still changes on every
                    // reading, so a guard that read only `reduceMotion` would
                    // keep an animated transaction alive per tick for exactly
                    // the figures that opted out of rolling.
                    guard !reduceMotion, rolls, surfaceIsVisible,
                          transaction.animation == nil else { return }
                    transaction.animation = Theme.Animation.roll
                }
        } else {
            content
        }
    }

    /// Keyed on the rendered value, so it is `Equatable` without the modifier
    /// having to know the figure's type.
    private var transition: Transition {
        Transition(value: figure,
                   reduceMotion: reduceMotion || !rolls || !surfaceIsVisible)
    }
}

extension View {
    /// Give a figure the island's per-digit roll.
    ///
    /// Use it on the `Text` that *renders the number* — a bare count, a
    /// percentage, a token figure, or a sentence with a figure inside it (the
    /// transition rolls only the digits, so the surrounding copy stays put).
    /// Do **not** put it on a container: the roll belongs to the leaf that
    /// draws the digits, the same way the island's own figures are leaves.
    ///
    /// `figure` is the rendered value and is what the roll is keyed on, so the
    /// transaction opens only when the figure moves. It is the first parameter
    /// and it has **no default** on purpose: a `ViewModifier` is handed an
    /// opaque `_ViewModifier_Content`, not the `Text` it wraps — that erasure
    /// cannot be cast back, cannot be reflected, and `String(describing:)` of it
    /// is the same for every wrapping — so this modifier cannot read the number
    /// out of its own content. A site that says nothing would silently roll
    /// nothing at all: the transaction's key would be the type name, which never
    /// changes, so the closure that installs `Theme.Animation.roll` would never
    /// be entered and `.numericText` would have no animation to run in. Pass the
    /// same expression the label renders:
    ///
    ///     Text("已选 \(n) 项").rollingNumber("已选 \(n) 项")
    ///     Text(open ? opener : inlineValue).rollingNumber(open ? opener : inlineValue)
    ///
    /// (Both forms are what the app uses; `RollingNumberText` is the same thing
    /// pre-composed and remains the house style for a figure that is a value.)
    ///
    /// Pass `enabled: false` when the same `Text` sometimes shows a figure and
    /// sometimes a label (a JSON value that is a number only in one kind).
    ///
    /// Reduce Motion turns the roll into an identity transition; the value
    /// still updates, it just stops sliding.
    ///
    /// `rolls: false` keeps the figure live but drops the transition — for a
    /// reading that arrives faster than the roll can settle (the resource
    /// strip's 1 Hz sensors) or for a surface no one is looking at. See
    /// `RollingNumberModifier.rolls`.
    ///
    /// A call site that *is* already inside its own animation leaves this
    /// alone: the transform checks `transaction.animation == nil` before it
    /// installs the roll, so an upstream spring owns the change instead of
    /// nesting a second animation inside it.
    func rollingNumber(_ figure: String, enabled: Bool = true,
                       rolls: Bool = true) -> some View {
        modifier(RollingNumberModifier(enabled: enabled, figure: figure, rolls: rolls))
    }
}
