import SwiftUI

/// Compact session card for the 2-column grid: status, project, context fill,
/// activity, and recency in a tight tile. Used by the menu-bar popup.
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isBusy ? Theme.statusBusy : Color.gray.opacity(0.45))
                    .frame(width: 6, height: 6)
                Text(session.projectFolder.isEmpty ? "session" : session.projectFolder)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                StatusPill(
                    label: isBusy ? "运行中" : "空闲",
                    tint: isBusy ? Theme.statusBusy : Theme.statusIdle
                )
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.contextLabel)
                    .font(Theme.Font.tileMicroValue)
                    .foregroundColor(ctxColor)
                    .lineLimit(1)
                Spacer()
                SessionLoadChip(key: .pid(session.pid), compact: true)
            }

            ContextBar(ratio: ratio, height: 4)
                .opacity(session.contextTokens > 0 ? 1 : 0.25)

            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.currentActivity.isEmpty ? " " : session.currentActivity)
                        .font(Theme.Font.micro)
                        .foregroundColor(isBusy ? Theme.textPrimary.opacity(0.75) : Theme.textTertiary(0.55))
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        if hasAgents {
                            Text("⚙\(session.subagents.count + session.workflows.reduce(0) { $0 + $1.agents.count })")
                                .font(Theme.Font.micro)
                                .foregroundColor(runningAgents > 0 ? Theme.statusBusy : Theme.textTertiary())
                        }
                        if !session.model.isEmpty {
                            Text(session.model)
                                .font(Theme.Font.micro)
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
                if runningAgents > 0 {
                    AgentChordLines(running: runningAgents, total: agentTotal)
                        .frame(height: 18)
                        .offset(x: 0, y: 2)
                        .transition(.opacity)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(Theme.Animation.smooth, value: runningAgents)
        .tile(hovered: isHovered, dense: true)
        .hoverState($isHovered)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.projectFolder)，\(isBusy ? "运行中" : "空闲")，上下文 \(session.contextLabel)")
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
                    // Static (no animation) — blur layers are expensive to
                    // keep live; the underlay only changes with `running`.
                    // Pre-composited low-alpha capsule instead of `.blur`:
                    // a live blur offscreen-renders a new layer per bar, and
                    // at 2.5 opacity the result is visually indistinguishable.
                    .background {
                        if isRunning {
                            Capsule()
                                .fill(Theme.statusBusy.opacity(0.12))
                                .frame(width: 4.5, height: 24)
                        }
                    }
            }
        }
    }
}
