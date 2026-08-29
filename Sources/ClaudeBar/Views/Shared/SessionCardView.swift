import SwiftUI

/// Compact session card for the 2-column grid: status, project, context fill,
/// activity, and recency in a tight tile. Shared by the menu-bar popup and the
/// Dashboard's activity feed. Extracted from `MenuBarView.sessionCard`.
struct SessionCardView: View {
    let session: SessionInfo
    /// Busy heartbeat trail for this session (oldest → newest); nil = N/A.
    var heartbeat: [Bool]? = nil
    var onDoubleTap: (() -> Void)? = nil

    private var isBusy: Bool { session.status == .busy }
    private var ratio: Double { session.contextRatio }
    private var ctxColor: Color { Theme.contextColor(ratio) }
    private var hasAgents: Bool { !session.subagents.isEmpty || !session.workflows.isEmpty }
    private var runningAgents: Int {
        session.subagents.filter { $0.status == .running }.count
            + session.workflows.reduce(0) { $0 + $1.runningCount }
    }
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isBusy ? Theme.statusBusy : Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .symbolEffect(.pulse, options: .repeating, isActive: isBusy)
                Text(session.projectFolder.isEmpty ? "session" : session.projectFolder)
                    .font(Theme.Font.rowTitle)
                    .foregroundColor(Theme.textPrimary.opacity(0.9))
                    .lineLimit(1)
                Spacer()
                if session.contextTokens > 0 {
                    Text(session.contextLabel)
                        .font(Theme.Font.microMono.weight(.medium))
                        .foregroundColor(ctxColor.opacity(0.9))
                        .lineLimit(1)
                }
            }

            // Always rendered (dimmed when no data) so every card in the
            // grid row keeps the same height regardless of context data.
            ContextBar(ratio: ratio, height: 3)
                .opacity(session.contextTokens > 0 ? 1 : 0.25)

            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    // Always render the activity line (space-reserved when
                    // empty) so the card height doesn't jitter between polls.
                    Text(session.currentActivity.isEmpty ? " " : session.currentActivity)
                        .font(Theme.Font.microMono)
                        .foregroundColor(isBusy ? Theme.textPrimary.opacity(0.7) : Theme.textTertiary(0.55))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if hasAgents {
                            Text("⚙\(session.subagents.count + session.workflows.reduce(0) { $0 + $1.agents.count })")
                                .font(Theme.Font.micro)
                                .foregroundColor(runningAgents > 0 ? Theme.statusBusy : Theme.textTertiary())
                        }
                        if !session.model.isEmpty {
                            Text(session.model)
                                .font(Theme.Font.microMono)
                                .foregroundColor(Theme.textTertiary(0.55))
                                .lineLimit(1)
                        }
                        Spacer()
                        if let heartbeat {
                            HeartbeatSparkline(trail: heartbeat)
                        }
                        Text(session.relativeUpdated)
                            .font(Theme.Font.micro)
                            .foregroundColor(Theme.textTertiary(0.55))
                    }
                }
                Spacer(minLength: 0)
            }
            .overlay(alignment: .topTrailing) {
                // Subagent chord: one vertical line per live subagent —
                // taller and glowing while running, dim stub when done.
                // Overlaid (not stacked) so the card height stays stable.
                if runningAgents > 0 {
                    AgentChordLines(running: runningAgents, total: agentTotal)
                        .frame(height: 22)
                        .offset(x: 0, y: 2)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .animation(Theme.Animation.smooth, value: runningAgents)
        .glassEffect(
            .regular.tint(isBusy ? Theme.statusBusy.opacity(isHovered ? 0.20 : 0.12) : Color.white.opacity(0.05)),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isBusy ? Theme.statusBusy.opacity(isHovered ? 0.55 : 0.35) : Theme.hairline, lineWidth: 1)
        )
        .hoverState($isHovered)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.projectFolder)，\(isBusy ? "忙碌" : "空闲")，上下文 \(session.contextLabel)")
        .accessibilityHint("连按在终端中恢复会话")
        .onTapGesture(count: 2) { onDoubleTap?() }
    }

    private var agentTotal: Int {
        session.subagents.count + session.workflows.reduce(0) { $0 + $1.agents.count }
    }
}

/// Vertical bars, one per subagent of the session. Running agents render as
/// tall glowing lines; finished ones as short dim stubs — like audio level
/// meters frozen mid-mix.
private struct AgentChordLines: View {
    let running: Int
    let total: Int

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<total, id: \.self) { i in
                let isRunning = i < running
                Capsule()
                    .fill(isRunning ? Theme.statusBusy.opacity(0.85) : Theme.textTertiary(0.18))
                    .frame(width: 2.5, height: isRunning ? 20 : 7)
                    // Tall lines get a faint glow via a blurred underlay.
                    .background {
                        if isRunning {
                            Capsule()
                                .fill(Theme.statusBusy.opacity(0.35))
                                .frame(height: 20)
                                .blur(radius: 2.5)
                        }
                    }
            }
        }
    }
}
