import SwiftUI

/// Compact Cursor session card for the 2-column grid: status, project, context
/// fill percent, activity, and recency. Purple accent distinguishes it from
/// Claude's green.
struct CursorSessionCardView: View {
    let session: CursorSessionInfo
    var onDoubleTap: (() -> Void)? = nil

    private var isActive: Bool { session.isBusy }
    private var isWaiting: Bool { session.isWaiting }
    /// The card's three-state capsule; see `Theme.sessionStatus`.
    private var status: (label: String, tint: Color, ink: Color) {
        Theme.sessionStatus(waiting: isWaiting, active: isActive,
                            accent: Theme.cursorAccent, ink: Theme.Ink.cursor)
    }
    private var ratio: Double { session.contextRatio }
    private var accentColor: Color {
        switch Theme.ContextLevel(ratio) {
        case .ok: return Theme.cursorAccent
        case .warn: return Theme.statusWarning
        case .critical: return Theme.statusError
        }
    }
    @State private var isHovered = false

    var body: some View {
        // Derived once: `cardLabel` runs the full condense/shorten pipeline and
        // was read twice (the visible title and the accessibility label), and
        // `runningAgents` walked `subagents` again for the same render.
        let label = session.cardLabel
        let agentCount = session.subagents.count
        let running = session.subagents.filter { $0.status == .running }.count
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? Theme.cursorAccent : Theme.Ink.idle)
                    .frame(width: 6, height: 6)
                SessionTitleLine(label: label)
                Spacer()
                if agentCount > 0 {
                    Label("\(agentCount)", systemImage: "point.3.connected.trianglepath.dotted")
                        .rollingNumber("\(agentCount)")
                        .font(Theme.Font.micro)
                        .foregroundColor(running > 0 ? Theme.statusBusy : Theme.textTertiary())
                        .labelStyle(.titleAndIcon)
                }
                StatusPill(label: status.label, tint: status.tint, ink: status.ink)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                RollingNumberText(session.contextLabel)
                    .font(Theme.Font.tileMicroValue)
                    .foregroundColor(accentColor)
                ContextBar(ratio: ratio, height: 3)
                    .opacity(session.contextPercent >= 0 ? 1 : 0.25)
                    .frame(maxWidth: .infinity)
                SessionLoadChip(key: .cursor, compact: true, shared: true)
                RollingNumberText(session.relativeUpdated)
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
            }

            // Cursor's own "Edited a.py, b.py" summary, on its own line. The
            // row is always rendered (blank when absent) so a card with a
            // subtitle is not taller than one without — tiles in a grid row
            // share the tallest sibling.
            Text(session.cardSubtitle.isEmpty ? " " : session.cardSubtitle)
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(session.subtitle)

            // The activity line doubles as the reason line while parked — see
            // `statusLine`.
            Text(statusLine)
                .font(Theme.Font.micro)
                .foregroundColor(isWaiting ? Theme.statusWarning
                                           : (isActive ? Theme.textPrimary.opacity(0.7)
                                                       : Theme.textTertiary()))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .tile(tint: Theme.cursor, hovered: isHovered, dense: true)
        .hoverState($isHovered)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label.accessibilityText)，\(status.label)")
        .accessibilityHint("连按在 Cursor 中打开")
        .onTapGesture(count: 2) { onDoubleTap?() }
    }

    /// The activity line: what the agent is doing, or — while the run is held
    /// up on the user — what it is waiting for. A pending plan is the decision
    /// Cursor actually surfaces (应用 / 拒绝), so it names that rather than
    /// claiming the session is still working.
    private var statusLine: String {
        if isWaiting { return "等待你确认计划" }
        return session.displayActivity.isEmpty ? "等待下一步" : session.displayActivity
    }
}
