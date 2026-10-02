import SwiftUI

/// Dense popup row: identity, context/load, activity/model, and recency.
struct SessionCardView: View {
    let session: SessionInfo
    /// Busy heartbeat trail for this session (oldest → newest); nil = N/A.
    var heartbeat: [Bool]? = nil
    var onDoubleTap: (() -> Void)? = nil

    private var isBusy: Bool { session.isBusy }
    private var isWaiting: Bool { session.isWaiting }
    /// The card's three-state capsule; see `Theme.sessionStatus`.
    private var status: (label: String, tint: Color, ink: Color) {
        Theme.sessionStatus(waiting: isWaiting, active: isBusy,
                            accent: Theme.statusBusy, ink: Theme.Ink.claude)
    }
    private var ratio: Double { session.contextRatio }
    private var ctxColor: Color { Theme.contextInk(ratio) }
    @State private var isHovered = false

    var body: some View {
        // Derived once per render. `cardLabel` runs the whole condense/shorten
        // pipeline (a tag strip, four `replacingOccurrences`, then a
        // per-scalar width pass) and `contextLabel` formats two token counts;
        // both were read twice — once for the visible text, once for the
        // accessibility label. `runningAgents`/`agentTotal` were separate
        // walks over `subagents` + `workflows`, each read twice.
        let label = session.cardLabel
        let contextLabel = session.contextLabel
        let agentTotals = agentTotals()
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isBusy ? Theme.statusBusy : Theme.Ink.idle)
                    .frame(width: 6, height: 6)
                SessionTitleLine(label: label)
                Spacer()
                if agentTotals.total > 0 {
                    Label("\(agentTotals.total)", systemImage: "point.3.connected.trianglepath.dotted")
                        .rollingNumber("\(agentTotals.total)")
                        .font(Theme.Font.micro)
                        .foregroundColor(agentTotals.running > 0 ? Theme.statusBusy : Theme.textTertiary())
                        .labelStyle(.titleAndIcon)
                }
                StatusPill(
                    label: status.label,
                    tint: status.tint,
                    ink: status.ink
                )
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                RollingNumberText(contextLabel)
                    .font(Theme.Font.tileMicroValue)
                    .foregroundColor(ctxColor)
                    .lineLimit(1)
                ContextBar(ratio: ratio, height: 3)
                    .opacity(session.contextTokens > 0 ? 1 : 0.25)
                    .frame(maxWidth: .infinity)
                SessionLoadChip(key: .pid(session.pid), compact: true)
                RollingNumberText(session.relativeUpdated)
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary(0.55))
            }

            HStack(spacing: 6) {
                Text(statusLine)
                    .font(Theme.Font.micro)
                    .foregroundColor(isBusy || isWaiting ? Theme.textPrimary.opacity(0.75)
                                                         : Theme.textTertiary(0.55))
                    .lineLimit(1)
                if !session.model.isEmpty {
                    Text("· \(session.model)")
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textTertiary(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let heartbeat {
                    HeartbeatSparkline(trail: heartbeat)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Nothing on this card is animated by the count changing — the pill is
        // plain text and the figure rides `RollingNumberText`'s own roll — so an
        // implicit `.animation(_:value:)` keyed on `agentTotals.running` was an
        // animated transaction opened by every session poll (2.5 s busy, 5 s
        // idle) that had nothing to interpolate. Only the hover lift below is a
        // state change worth animating, and `.tile`/`.hoverState` carry their own.
        // Same hue the full-page session tile takes. A popup column carries all
        // three agent families, so the accent is the only thing that makes a
        // row's family readable before the title is. No lens: a dense row has
        // no corner to spare and the ornament would sit under the status pill.
        .tile(tint: Theme.claude, hovered: isHovered, dense: true)
        .hoverState($isHovered)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label.accessibilityText)，\(status.label)，上下文 \(contextLabel)")
        .accessibilityHint("连按在终端中恢复会话")
        .onTapGesture(count: 2) { onDoubleTap?() }
    }

    /// The activity line doubles as the reason line while parked: what the
    /// session is blocked on is the only useful thing to say about it.
    private var statusLine: String {
        // `waitingReason` is non-empty whenever `isWaiting` — its own `""`
        // arm resolves to "等待你确认" — so it needs no default here.
        if isWaiting { return session.waitingReason }
        return session.displayActivity.isEmpty ? "等待下一步" : session.displayActivity
    }

    /// How many agents this session spawned, and how many are running.
    private func agentTotals() -> (total: Int, running: Int) {
        var total = session.subagents.count
        var running = session.subagents.filter { $0.status == .running }.count
        for workflow in session.workflows {
            total += workflow.totalCount
            running += workflow.runningCount
        }
        return (total, running)
    }
}

// MARK: - Two-part session title

/// `folder | title` — the header every session card uses, whatever the agent.
///
/// Built as one `Text` rather than two views in an `HStack`: an `HStack` gives
/// each half its own width negotiation, so a long folder pushes the title out
/// of the row entirely. Concatenation lets the whole line truncate together at
/// the tail, which is where the information density already drops off — and it
/// keeps the folder's own budget (applied in `SessionTitle`) meaningful.
///
/// The separator is a full-width pipe: it reads as an unambiguous divider
/// between two *kinds* of text (a path fragment and a sentence), which a middle
/// dot does not — the dot already means "sub-field of the same value" on the
/// activity line (`Bash · build.sh`).
struct SessionTitleLine: View {
    let label: SessionTitle.Label
    var font: SwiftUI.Font = Theme.Font.section

    var body: some View {
        Group {
            if label.title.isEmpty {
                // Folder-only sessions must not render "ClaudeBar | ClaudeBar".
                Text(label.folder)
                    .foregroundColor(Theme.textPrimary)
            } else {
                Text(label.folder + " | ")
                    .foregroundColor(Theme.textTertiary())
                    + Text(label.title)
                    .foregroundColor(Theme.textPrimary)
            }
        }
        .font(font)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(label.title.isEmpty ? label.folder : "\(label.folder) | \(label.title)")
        .accessibilityLabel(label.accessibilityText)
    }
}
