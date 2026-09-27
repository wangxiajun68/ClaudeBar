import SwiftUI

/// The two model switches as one mark: **CC's and Codex's brand glyphs fused**,
/// with the Codex allowance drawn as a lane under them.
///
/// The dashboard status sheet used to say this in two ways at once. The two
/// clients sat in two identical cells whose *only* difference was a small SF
/// Symbol (`command` against `terminal`), and the allowance sat in a third
/// section further down as two striped meters. So the card repeated the same
/// fact — "this is a Codex reading, and here is how much of it is left" — in
/// two places that did not know about each other.
///
/// This is one object instead: `ProductBrandMark`'s own vector artwork for both
/// families, over one lane that carries the windows exactly the way
/// `HardwareIllustration` carries a machine reading — a rail, one bar per
/// window, each bar's height its own remaining allowance. Three things are then
/// true at a glance and none of them twice:
///
/// - **which family** this reading belongs to — the mark above;
/// - **how much is left** in each window — the bars, *countable*, because there
///   is one bar per window and the two windows are never the same figure;
/// - **how soon it comes back** — the reset clock, under each bar.
///
/// The marks are the real brand artwork (`ProductBrandMark`), not SF Symbols, so
/// the card names the two products with the same glyphs the model page, the
/// island and the segmented controls use. The lane's own scanning highlight is
/// **opt-in** (`flow:`) and off by default: it belongs to the dashboard mark,
/// where a rail 40pt across is a surface and one sweep across it reads as a live
/// reading. At popup size the same rail is 30pt and the same sweep is a flicker
/// nothing asked for.
struct CodexModelMark: View {
    enum Style { case tile, inline }

    /// `false` = CC / Claude, `true` = Codex — `ProductBrandMark`'s convention.
    var codex: Bool
    /// Under the mark. The tile passes the model slug; the chip passes nothing.
    var value: String?
    /// The second line: runtime detail (`Aibox`, `余额 …`) or the reset clock.
    var note: String?
    var style: Style = .tile
    var tint: Color = Theme.Ink.claude
    /// One bar per allowance window. Empty = this mark carries no lane.
    var windows: [CodexQuotaWindow] = []
    /// Let the lane's highlight travel. Default off — see the type note.
    var flow = false
    /// Shown when the lane has nothing to draw.
    var laneNote: String?
    /// The lane's own action: clicking the allowance re-reads it.
    ///
    /// The allowance is a *reading*, and a reading you cannot ask for again is
    /// one you are stuck with until the next poll — the card had a 刷新额度
    /// button for exactly this, and it went away with the footer that held it.
    /// The lane is that button now, and it is the honest place for it: the thing
    /// you press is the thing you are asking to be re-read. Nil = not a control
    /// (the popup chip drives its own refresh from its own row).
    var refreshQuota: (() -> Void)?
    /// The refresh is in flight — the lane shows it rather than reporting the
    /// stale figure as if it were the answer.
    var quotaLoading = false

    /// Pointer is on the lane. Held here rather than in the tile's body because
    /// the lane is the control and the tile is not — the whole mark is inside a
    /// button that opens the model page, and this one must not light up when
    /// that button is what the pointer found.
    @State private var laneHovered = false

    var body: some View {
        switch style {
        case .tile: tileBody
        case .inline: inlineBody
        }
    }

    // MARK: - Dashboard tile

    private var tileBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                mark(side: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(codex ? "Codex" : "CC")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(value ?? "—")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.7)
                        .rollingNumber(rolls: false)
                    // The note keeps its line whether or not there is one, so the
                    // two clients' models sit on one baseline.
                    Text(note?.isEmpty == false ? note! : " ")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(inkSoft)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .frame(height: Lane.head, alignment: .top)

            // Both clients reserve the same two row boxes, and the one without
            // an allowance simply leaves its boxes empty: a value and its
            // neighbour's value are then on one line across the whole card.
            Group {
                if hasLane {
                    laneControl
                } else {
                    Color.clear
                }
            }
            .frame(height: laneReserve, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Popup chip cell

    private var inlineBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                mark(side: 13)
                Text(codex ? "Codex" : "CC")
                    .font(Theme.Font.eyebrow)
                    .foregroundStyle(tint)
            }
            if let value {
                Text(value)
                    .font(Theme.Font.section)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let note {
                Text(note)
                    .rollingNumber()
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if hasLane {
                laneView.padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// True when the lane has something to draw. The two callers disagree about
    /// an empty lane on purpose: the tile keeps 22pt of empty rail so both
    /// client cells stay the same height, while a chip showing the empty rail
    /// under a 9pt caption is just slack.
    private var hasLane: Bool {
        !windows.isEmpty || (laneNote?.isEmpty == false)
    }

    /// What the lane occupies in the tile. The refresh chip is only drawn when
    /// the caller gave the lane an action, but its row is reserved either way:
    /// a chip that appears when a quota call starts would otherwise move the
    /// card's own height at the exact moment a figure was arriving.
    private var laneReserve: CGFloat {
        Lane.windows + (refreshQuota == nil ? 0 : Lane.chipHeight)
    }

    // MARK: - Brand mark

    /// A **themed** surface (`Theme.cardSurface` / `Theme.bgSecondary` — the
    /// popup's header chip, the dashboard's greeting band), so the ink is the
    /// theme's and `page:` stays `nil`. It used to pass
    /// `AppPreferences.shared.isDark ? nil : false`, which resolved to the black
    /// `-light` file in light mode: legible on the white chip, but the opposite
    /// pair from every icon well beside it, and it is the same inversion that
    /// made the island's marks invisible. Only a caller whose ground does *not*
    /// follow the theme (the island, the greeting card's own sky) passes `page:`.
    /// The tile is dropped (`well: false`) — see `ProductBrandMark`.
    private func mark(side: CGFloat) -> some View {
        ProductBrandMark(codex: codex, well: false)
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(codex ? 0.16 : 0.22), radius: 5, y: 2)
            .accessibilityHidden(true)
    }

    // MARK: - Allowance lane

    /// The three dimensions the lane's table is built from, in points.
    ///
    /// Constants rather than values derived from the drawing, because **the CC
    /// mark has no lane at all**: anything derived from the mark's own size
    /// would put the Codex half of the row on a different baseline from the CC
    /// half beside it, and the two halves of one row have to agree.
    private enum Lane {
        /// One window's row: its label above its own rail.
        static let rowHeight: CGFloat = 18
        static let railHeight: CGFloat = 5
        /// Label columns. The gap between the rail and each of them is 6.
        static let labelWidth: CGFloat = 42
        static let clockWidth: CGFloat = 80
        /// The refresh chip's own row above the windows.
        ///
        /// It was an overlay on the first row, which put it straight on top of
        /// 5 小时 and the head of its rail — the chip is a word and a glyph, not
        /// something a label can sit behind. Giving it a row costs 15pt and buys
        /// a control that overlaps nothing.
        static let chipHeight: CGFloat = 15
        /// The windows' table alone, and the same table with the chip's row.
        static let windows = rowHeight * 2
        static let table = windows
        /// Name + model + note above the table — one fixed height, so a mark
        /// with no `note` still puts its model on the same line as its
        /// neighbour's.
        static let head: CGFloat = 54
    }

    /// `head` + the windows' table, the mark's own height. The row reserves it
    /// whether or not there is anything to draw in the lane.
    static let reserve: CGFloat = Lane.head + Lane.windows

    /// The lane as a control, when the caller gave it something to do.
    ///
    /// The first version of this said "clickable" with a hover tint: the reset
    /// clocks lit up while the pointer was on the lane. That is an affordance
    /// only if you already suspect the lane is a control — and the question it
    /// drew ("点哪里是刷新 codex 额度？") is the proof that nobody did. A control
    /// you have to be told about is not a control.
    ///
    /// So the lane carries one, in words: a 刷新 chip on the first row, where a
    /// reader looking for "how do I re-read this" finds it without hovering
    /// anything. The **whole lane stays the target** — the chip is the label for
    /// the affordance, not a 40pt button you have to hit — but the thing that
    /// says a control exists is visible at rest instead of appearing under the
    /// pointer.
    @ViewBuilder
    private var laneControl: some View {
        if let refreshQuota {
            Button(action: refreshQuota) {
                VStack(alignment: .leading, spacing: 0) {
                    refreshChip
                        .frame(height: Lane.chipHeight, alignment: .top)
                    laneView
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(quotaLoading)
            .hoverState($laneHovered)
            .help(quotaLoading ? "正在获取 Codex 额度" : "点击刷新 Codex 额度")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(quotaLoading ? "正在获取 Codex 额度" : "刷新 Codex 额度，\(laneSummary)")
            .accessibilityAddTraits(.isButton)
        } else {
            laneView
        }
    }

    /// `↻ 刷新` on the lane's first row, in the mark's own hue — the visible half
    /// of the affordance. It takes the loading state for its own: while the call
    /// is out it reads 刷新中…, so the control reports what pressing it did.
    private var refreshChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 8.5, weight: .semibold))
            Text(quotaLoading ? "刷新中…" : (laneHovered ? "刷新额度" : "刷新"))
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(Capsule().fill(tint.opacity(laneHovered || quotaLoading ? 0.20 : 0.13)))
        .overlay(Capsule().strokeBorder(tint.opacity(laneHovered ? 0.45 : 0.26), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: laneHovered)
        .accessibilityHidden(true)
    }

    /// The lane's reading as one sentence, for the control's tooltip and label.
    private var laneSummary: String {
        guard !windows.isEmpty else { return laneNote ?? "暂无额度数据" }
        return windows.prefix(2)
            .map { "\($0.label)剩余 \(Int((100 - $0.usedPercent).rounded()))%" }
            .joined(separator: "，")
    }

    private var laneView: some View {
        Group {
            if windows.isEmpty {
                placard
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !sweeping)) { timeline in
                    laneCanvas(at: timeline.date)
                }
            }
        }
        .frame(height: Lane.windows, alignment: .top)
        .accessibilityHidden(true)
    }

    /// What the lane says when it has no reading to draw: the reason, in the
    /// mark's own type. The rail is still there, empty, because an allowance
    /// that cannot be read has not stopped being an allowance — and because a
    /// lane that collapses to nothing moves the card's own height every time a
    /// quota call starts.
    private var placard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(laneNote ?? "暂无额度数据")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(quotaLoading ? tint : inkSoft)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Capsule()
                .fill(Theme.hairline.opacity(0.6))
                .frame(height: Lane.railHeight)
        }
        .padding(.top, 2)
    }

    /// The lane's own view, split out of the timeline closure above.
    ///
    /// Not a style choice: written inline, the two closures plus the loop pushed
    /// the body past what the type checker will solve and the whole
    /// `TimelineView` failed to infer its `Content`.
    private func laneCanvas(at date: Date) -> some View {
        // One row per window, top down: the window's name and its reset clock,
        // then the rail that *is* its reading. The row's type is a sibling
        // overlay rather than something drawn in the canvas — `GraphicsContext`
        // can only resolve a `Text` and draw it at a point, doing its own
        // baseline math, and a label that computes its own centering is one that
        // lands a point off centre at whichever of the mark's two sizes it is
        // not being drawn at.
        let t = date.timeIntervalSinceReferenceDate
        return Canvas { context, size in
            for index in 0..<min(2, windows.count) {
                draw(row: windows[index], index: index, width: size.width,
                     t: t, into: &context)
            }
        }
        .overlay(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(Array(windows.prefix(2).enumerated()), id: \.element.id) { _, window in
                    HStack(spacing: 6) {
                        Text(window.label).frame(width: Lane.labelWidth, alignment: .leading)
                        Spacer(minLength: 0)
                        // Right-aligned in a column of its own: with two rows of
                        // differing label widths a left-aligned clock starts at
                        // a visibly different x per row and the pair reads as a
                        // broken column rather than as two rows of one table.
                        Text(window.resetShort).frame(width: Lane.clockWidth, alignment: .trailing)
                    }
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    // The lane is a control only when it was given one, and the
                    // pointer is what says so. Loading keeps the same lit ink:
                    // the answer is not the stale figure on screen, and the
                    // rows should not flicker between two colors while it
                    // arrives.
                    .foregroundStyle(quotaLoading || laneHovered && refreshQuota != nil
                                     ? tint : inkSoft)
                    // The label sits on the row's top line, the rail under it.
                    .frame(height: Lane.rowHeight - Lane.railHeight, alignment: .top)
                    .padding(.bottom, Lane.railHeight)
                }
            }
        }
    }

    /// One window's row: the rail beneath its label, and the fill that is the
    /// window's own remaining allowance.
    private func draw(row window: CodexQuotaWindow, index: Int, width: CGFloat,
                      t: Double, into context: inout GraphicsContext) {
        let railY = Lane.rowHeight * CGFloat(index + 1) - Lane.railHeight
        let rail = CGRect(x: Lane.labelWidth + 6, y: railY,
                          width: max(8, width - Lane.labelWidth - Lane.clockWidth - 12),
                          height: Lane.railHeight)
        context.fill(Path(roundedRect: rail, cornerRadius: rail.height * 0.4),
                     with: .color(Theme.hairline.opacity(0.6)))
        let remaining = max(0, min(100, 100 - window.usedPercent)) / 100
        let amount = remaining < 0.005 ? 0.005 : CGFloat(remaining)
        let fill = CGRect(x: rail.minX, y: rail.minY,
                          width: max(2.5, rail.width * amount), height: rail.height)
        context.fill(Path(roundedRect: fill, cornerRadius: rail.height * 0.4),
                     with: .color(quotaTint(remaining)))
        ticks(rail, into: &context)
        if sweeping { sweep(fill, t, into: &context) }
    }

    /// Tenths of the scale across the whole rail, so the fill's length is a
    /// *reading* rather than a ratio to eyeball — the segmented rail
    /// `CodexQuotaGauges` wears at meter size, at lane size.
    private func ticks(_ rail: CGRect, into context: inout GraphicsContext) {
        var canvas = context
        canvas.clip(to: Path(rail))
        var paths = Path()
        var x = rail.minX + rail.width / 10
        while x < rail.maxX {
            paths.move(to: CGPoint(x: x, y: rail.minY))
            paths.addLine(to: CGPoint(x: x, y: rail.maxY))
            x += rail.width / 10
        }
        canvas.stroke(paths, with: .color(.black.opacity(0.30)), lineWidth: 1.1)
    }

    /// An angled highlight travelling across the fill, clipped to it: the same
    /// drawing as `HardwareIllustration.sweep`, one idea with two readers.
    private func sweep(_ r: CGRect, _ t: Double, into context: inout GraphicsContext) {
        guard r.width > 6 else { return }
        var layer = context
        layer.clip(to: Path(roundedRect: r, cornerRadius: r.height * 0.4))
        let travel = r.width + r.height
        let head = r.minX - r.height + travel * CGFloat(t.truncatingRemainder(dividingBy: 1.6) / 1.6)
        let w = max(r.height, 1.2) * 1.1
        layer.fill(Path(r.insetBy(dx: -1, dy: -1)),
                   with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0), location: 0),
                        .init(color: .white.opacity(0.42), location: 0.5),
                        .init(color: .white.opacity(0), location: 1)]),
                    startPoint: CGPoint(x: head - w, y: r.minY),
                    endPoint: CGPoint(x: head + w, y: r.maxY)))
    }

    private var inkSoft: Color { .white.opacity(0.62) }

    private var sweeping: Bool { flow && !windows.isEmpty }

    /// Same rule as `CodexQuotaGauges`: the gate is the *reading*, so the color
    /// changes only when the answer does.
    private func quotaTint(_ remaining: Double) -> Color {
        remaining <= 0.10 ? Color(hex: 0xFFA7A0)
            : remaining <= 0.25 ? Color(hex: 0xFFE1A6)
            : Color(hex: 0xFFD98A)
    }
}

private extension CodexQuotaWindow {
    /// `10月4日 09:07 重置` → `10月4日 09:07`. The lane prints the clock alone,
    /// because the bar beside it already says what the reading is a reading of.
    var resetShort: String {
        resetClock.replacingOccurrences(of: " 重置", with: "")
    }
}
