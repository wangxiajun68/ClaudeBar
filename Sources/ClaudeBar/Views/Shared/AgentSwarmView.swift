import SwiftUI

/// Codex sub-agents as a **uniform tile grid**: every agent is one card of the
/// same size — dot · nickname · recency — packed into tidy columns and rows.
///
/// Deliberately ordered, not organic. Codex hands one session dozens of children
/// that share its cwd and model, so the useful reading is "who, how many, how
/// busy" — a regular grid shows that at a glance and stays legible at 60 cells,
/// where a spiral or a list stops being readable.
///
/// There is no parent glyph and no connector bus. Both were drawn beside the
/// cluster before, and both cost what they gave: the badge stole a column of
/// width from every row (which is what squeezed the labels down to `Sar…`), and
/// the hairlines read as noise once the cards themselves were already aligned.
/// Uniform cells say the same thing — one session, N agents — by silhouette.
///
/// Cell width is **shared**, not intrinsic: the widest label does not get a
/// wider card, because a ragged grid reads as a mistake. Instead the width is
/// whatever the container divides evenly into whole columns, so every row starts
/// and ends on the same edge.
struct AgentSwarmView: View {
    /// The session that spawned the agents. Kept for the accessibility label —
    /// the grid itself no longer draws it.
    let root: ExternalSessionInfo
    /// Its sub-agents, most recently touched first.
    let children: [ExternalSessionInfo]
    /// Popup variant: smaller one-line cards, no hover label.
    var compact: Bool = false
    var onOpen: ((ExternalSessionInfo) -> Void)? = nil

    @State private var hoveredId: String?

    var body: some View {
        if children.isEmpty {
            // No swarm to draw. The callers skip this view entirely when there
            // is nothing to show, but an empty grid is still legal.
            Color.clear
        } else {
            GeometryReader { geo in
                let grid = SwarmGrid(count: children.count, size: geo.size, compact: compact)
                let hovered = children.first { $0.id == hoveredId }
                let shown = min(children.count, grid.visibleCount)

                VStack(alignment: .leading, spacing: grid.spacing) {
                    ForEach(0..<grid.rows, id: \.self) { row in
                        HStack(spacing: grid.spacing) {
                            ForEach(rowCells(row, grid: grid, shown: shown), id: \.index) { cell in
                                tile(cell.item, grid: grid)
                            }
                            // Rows are left-aligned: a short last row reads as
                            // the end of the list rather than a centred orphan.
                            if grid.rowFill < 1 { Spacer(minLength: 0) }
                        }
                        .frame(height: grid.cardHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .bottom) {
                    if !compact, let hovered {
                        hoverLabel(hovered)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
    }

    /// One row's cells, in row-major order: the newest agents across the top.
    /// A `nil` item is the overflow tile, which is always the last cell drawn.
    private func rowCells(_ row: Int, grid: SwarmGrid,
                          shown: Int) -> [(index: Int, item: ExternalSessionInfo?)] {
        var out: [(index: Int, item: ExternalSessionInfo?)] = []
        for column in 0..<grid.columns {
            let index = row * grid.columns + column
            guard index < shown else {
                // Past the visible agents: either the overflow tile or nothing.
                if index == shown, grid.overflow > 0, row == grid.rows - 1 {
                    out.append((index, nil))
                }
                continue
            }
            out.append((index, children[index]))
        }
        return out
    }

    /// Regular grid packing for fixed-size cards.
    ///
    /// Cards tile with a pitch of `cardWidth + gap`; the column count is the one
    /// whose cards come out widest *while still filling the box*, so 6 agents get
    /// big cards and 60 get small ones, same neat arrangement either way. Columns
    /// are capped where a card would fall below `minWidth`, so text stays
    /// readable instead of the layout shrinking to slivers; what does not fit is
    /// reported as `overflow` for the caller to count.
    struct SwarmGrid {
        let spacing: CGFloat
        let cardWidth: CGFloat
        let cardHeight: CGFloat
        let columns: Int
        let rows: Int
        /// Agents drawn before the box runs out (≤ the count it was built with).
        let visibleCount: Int
        /// Agents that did not fit — rendered as one trailing "+N" card.
        let overflow: Int
        /// Share of each row the cards fill, for the left-alignment spacer.
        let rowFill: CGFloat

        /// Card height, in points, **per variant — not a ratio of the width**.
        /// Height is decided by what the card has to say: a caption2 line plus
        /// `verticalPadding` top and bottom. Tying it to the width instead (as
        /// the old chip grid did) made cards shrink below their own text as soon
        /// as a column was added, which is how "Darwin" ended up rendering as a
        /// clipped smear.
        static let pageCardHeight: CGFloat = 38      // dot + nickname + recency
        static let compactCardHeight: CGFloat = 24   // dot + nickname

        /// Largest card drawn on the sessions page.
        static let maxWidth: CGFloat = 132
        /// Narrowest card that still spells a nickname; below this the grid
        /// stops adding columns and starts counting overflow instead.
        static let minWidth: CGFloat = 68
        /// Strip floor — lower than the page's, because a strip card is one
        /// short line and the box it sits in is half a page tile wide.
        private static let compactMinWidth: CGFloat = 56
        private static let compactCap: CGFloat = 104

        /// Vertical padding inside a card, above and below the text. The packed
        /// grid adds `gap` on top of this, so the drawn pitch carries roughly
        /// 2.5× this between one card's text and the next — the cards read as
        /// separate rows instead of one squeezed block.
        static let verticalPadding: CGFloat = 5
        static let compactVerticalPadding: CGFloat = 3

        /// Width the page's tiles are sized against, so tile height and the
        /// drawn cluster agree. Wider tiles simply pack more per row.
        static let tileEstimateWidth: CGFloat = 560

        static let gap: CGFloat = 6

        static func cardHeight(compact: Bool) -> CGFloat { compact ? compactCardHeight : pageCardHeight }
        static func cardCap(compact: Bool) -> CGFloat { compact ? compactCap : maxWidth }
        static func cardFloor(compact: Bool) -> CGFloat { compact ? compactMinWidth : minWidth }
        static func spacing(compact: Bool) -> CGFloat { compact ? 3 : gap }

        init(count: Int, size: CGSize, compact: Bool = false) {
            let cap = Self.cardCap(compact: compact)
            let floorW = Self.cardFloor(compact: compact)
            let cardH = Self.cardHeight(compact: compact)
            let spacing = Self.spacing(compact: compact)
            self.spacing = spacing
            self.cardHeight = cardH

            let gridW = max(1, size.width)
            let gridH = max(1, size.height)

            guard count > 0 else {
                cardWidth = floorW
                columns = 0
                rows = 0
                visibleCount = 0
                overflow = 0
                rowFill = 0
                return
            }

            // Columns the box can hold at all, at the narrowest card that is
            // still worth drawing; and at the *widest* one — the shape the
            // layout aims for, and the one `columns(forWidth:)` predicts.
            let maxColumns = max(1, Int((gridW + spacing) / (floorW + spacing)))
            let wideColumns = max(1, Int((gridW + spacing) / (cap + spacing)))
            let maxRows = max(1, Int((gridH + spacing) / (cardH + spacing)))

            // Never fewer columns than the fan-out needs to fit the rows it has.
            let needed = max(1, Int(ceil(Double(count) / Double(maxRows))))
            let chosen = min(count, maxColumns, max(wideColumns, needed))
            let fits = Int(ceil(Double(count) / Double(chosen))) <= maxRows

            columns = chosen
            if fits {
                rows = max(1, Int(ceil(Double(count) / Double(chosen))))
                visibleCount = count
            } else {
                // The cluster cannot show everything: one slot of the box's
                // budget goes to the trailing "+N" tile, so the count is visible
                // without costing an extra row off the bottom.
                rows = maxRows
                visibleCount = max(0, maxRows * chosen - 1)
            }
            overflow = count - visibleCount
            cardWidth = min(cap, (gridW - CGFloat(max(chosen - 1, 0)) * spacing) / CGFloat(chosen))

            let usedW = cardWidth * CGFloat(columns) + spacing * CGFloat(columns - 1)
            rowFill = gridW > 0 ? min(1, usedW / gridW) : 1
        }

        /// How many cards the grid packs into a row at `width`. A column is
        /// added only if the resulting card still clears `minWidth`.
        static func columns(forWidth width: CGFloat, compact: Bool = false) -> Int {
            let usable = max(1, width)
            return max(1, Int((usable + spacing(compact: compact))
                              / (cardFloor(compact: compact) + spacing(compact: compact))))
        }

        /// A **strip** layout: how many cards fit in a limited number of rows at
        /// a given width, and how tall to reserve for them.
        ///
        /// Used where the cluster cannot have all the room it asks for — a
        /// 61-agent session inside a grid cell, or the popup card. The strip
        /// shows what fits and hands the rest to the `⋯N` badge / popover, so
        /// the card stays a card instead of growing to the height of its
        /// largest fan-out. Sized against a width *estimate*: the drawn box is
        /// usually wider, so the cluster simply comes out roomier than reserved.
        static func strip(count: Int, width: CGFloat, maxRows: Int,
                          compact: Bool = true) -> (visible: Int, height: CGFloat) {
            guard maxRows > 0 else { return (0, 0) }
            let columns = columns(forWidth: width, compact: compact)
            let capacity = columns * maxRows
            // When the strip has to hold more than it can, one slot of the
            // budget buys the trailing "+N" tile instead of an agent: the count
            // is the point, and "how many are not here" must never be hidden.
            let overflow = count > capacity
            let visible = overflow ? max(0, capacity - 1) : max(0, count)
            let drawn = visible + (overflow ? 1 : 0)
            let rows = max(1, Int(ceil(Double(drawn) / Double(columns))))
            let sp = spacing(compact: compact)
            return (visible, CGFloat(rows) * cardHeight(compact: compact) + CGFloat(rows - 1) * sp)
        }

        /// Height the cluster needs to draw **all** of `count` at its largest
        /// cards. The sessions page sizes a full-width tile with this, so a
        /// 200-agent session reserves what its fan-out actually needs.
        static func requiredHeight(count: Int, width: CGFloat, compact: Bool = false) -> CGFloat {
            guard count > 0 else { return 0 }
            let columns = max(1, min(count, columns(forWidth: width, compact: compact)))
            let rows = Int(ceil(Double(count) / Double(columns)))
            let sp = spacing(compact: compact)
            return CGFloat(rows) * cardHeight(compact: compact) + CGFloat(rows - 1) * sp
        }
    }

    // MARK: Cells

    /// One sub-agent tile: status dot + nickname, and its recency underneath
    /// where the tile is tall enough to carry a second line.
    ///
    /// The dot is an **overlay**, not a leading stack item: laid out in the row
    /// it stole horizontal room from every label, so a 56pt card had ~38pt left
    /// for text and truncated even short nicknames ("Darwin" → "D…"). Floated on
    /// the leading edge it costs no width, and the label gets the whole card.
    @ViewBuilder
    private func tile(_ child: ExternalSessionInfo?, grid: SwarmGrid) -> some View {
        if let child {
            childCard(child, grid: grid)
        } else {
            overflowTile(grid.overflow, grid: grid)
        }
    }

    private func childCard(_ child: ExternalSessionInfo, grid: SwarmGrid) -> some View {
        let isHovered = hoveredId == child.id
        let radius: CGFloat = 4
        let showsAge = !compact && grid.cardHeight >= 30
        /// Leading inset of the status dot, and the gap before the label. The
        /// label's leading padding is the sum of the two — sharing a single
        /// "text starts here" constant with the dot's own inset is what let the
        /// dot sit on top of the first letter.
        let inset: CGFloat = 6
        let dot: CGFloat = 4
        let dotGap: CGFloat = 4
        let textInset = inset + dot + dotGap
        // Vertical padding eats into the card, not the text: at strip sizes the
        // padding steps down so the one text line still has room to sit.
        let vPad = compact ? SwarmGrid.compactVerticalPadding : SwarmGrid.verticalPadding
        return VStack(alignment: .leading, spacing: 1) {
            Text(agentLabel(child))
                .font(Theme.Font.microMono)
                .foregroundColor(child.isActive ? Theme.textPrimary.opacity(0.92)
                                                : Theme.textSecondary.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.tail)
            if showsAge {
                RollingNumberText("\(child.relativeUpdated) 前")
                    .font(Theme.Font.tileDetail)
                    .monospacedDigit()
                    .foregroundColor(Theme.textTertiary(0.45))
                    .lineLimit(1)
            }
        }
        // Both lines clear the dot column, so the card's text starts on one
        // vertical rule whether or not the age line is drawn.
        .padding(.leading, textInset)
        .padding(.trailing, inset)
        .padding(.vertical, vPad)
        .frame(width: grid.cardWidth, height: grid.cardHeight,
               alignment: showsAge ? .topLeading : .leading)
        .background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(child.isActive ? Theme.external.opacity(isHovered ? 0.16 : 0.10)
                                     : Theme.cardFill(isHovered ? 0.08 : 0.04))
        }
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(isHovered ? Theme.externalHi
                                        : Theme.external.opacity(child.isActive ? 0.65 : 0.22),
                              lineWidth: isHovered ? 1.3 : 1)
        )
        .overlay(alignment: .leading) {
            // On the leading edge, level with the first text line: half the
            // card's top padding plus half a line of type.
            Circle()
                .fill(child.isActive ? Theme.externalHi : Theme.textTertiary(0.45))
                .frame(width: dot, height: dot)
                .padding(.leading, inset)
                .padding(.top, showsAge ? vPad + 4 : 0)
        }
        .scaleEffect(isHovered ? 1.06 : 1)
        .contentShape(Rectangle())
        .onHover { hovering in
            guard !compact else { return }
            // Edge-triggered: a repeated same-value event used to restart the
            // bounce (a `@State` write invalidates regardless of equality), and
            // one hover re-evaluates every cell in the cluster.
            let next: String? = hovering ? child.id : (hoveredId == child.id ? nil : hoveredId)
            guard next != hoveredId else { return }
            withAnimation(Theme.Animation.bouncy) { hoveredId = next }
        }
        .onTapGesture(count: 2) { onOpen?(child) }
        .help(child.help)
    }

    /// The trailing tile for agents the box could not hold. Deliberately
    /// faceless: a count, not a cell pretending to be an agent.
    private func overflowTile(_ count: Int, grid: SwarmGrid) -> some View {
        Text("+\(count)")
            .font(Theme.Font.microMono)
            .foregroundColor(Theme.textTertiary(0.7))
            .frame(width: grid.cardWidth, height: grid.cardHeight)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.cardFill(0.04))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
            .help("另有 \(count) 个子 agent 未显示")
    }

    /// Pinned detail for the hovered agent — the full identity, since the tile
    /// itself only has room for the nickname.
    private func hoverLabel(_ child: ExternalSessionInfo) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(child.isActive ? Theme.external : Theme.textTertiary(0.6))
                .frame(width: 5, height: 5)
            Text(agentLabel(child))
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textPrimary.opacity(0.9))
                .lineLimit(1)
            Text(child.isActive ? "运行中" : "空闲")
                .font(Theme.Font.tileDetail)
                .foregroundColor(child.isActive ? Theme.externalHi : Theme.textTertiary())
            RollingNumberText("\(child.relativeUpdated) 前")
                .font(Theme.Font.tileDetail)
                .monospacedDigit()
                .foregroundColor(Theme.textTertiary())
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Theme.cardSurface))
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        .padding(.bottom, 2)
        .transition(.opacity)
    }

    /// Card title: the agent's nickname, falling back to a short slice of the
    /// session id so a card always says something.
    private func agentLabel(_ child: ExternalSessionInfo) -> String {
        if !child.agentNickname.isEmpty { return child.agentNickname }
        return String(child.sessionId.prefix(8))
    }

    private var accessibilityText: String {
        let running = children.filter(\.isActive).count
        return "\(root.displayName)，\(children.count) 个子 agent，\(running) 个运行中"
    }
}

private extension ExternalSessionInfo {
    /// Tooltip for a swarm card: agent identity plus what it is doing.
    var help: String {
        var parts: [String] = []
        if !agentNickname.isEmpty { parts.append(agentNickname) }
        if !model.isEmpty { parts.append(model) }
        parts.append(isActive ? "运行中" : "空闲")
        parts.append("\(relativeUpdated) 前")
        if !cwd.isEmpty { parts.append(cwd) }
        return parts.joined(separator: " · ")
    }
}
