import SwiftUI

/// Dense popup row: identity, context/load, activity/model, and recency.
struct SessionCardView: View {
    let session: SessionInfo
    /// Busy heartbeat trail for this session (oldest → newest); nil = N/A.
    var heartbeat: [Bool]? = nil
    var onDoubleTap: (() -> Void)? = nil

    private var isBusy: Bool { session.status == .busy }
    private var ratio: Double { session.contextRatio }
    private var ctxColor: Color { Theme.contextInk(ratio) }
    private var hasAgents: Bool { !session.subagents.isEmpty || !session.workflows.isEmpty }
    private var runningAgents: Int {
        session.subagents.filter { $0.status == .running }.count
            + session.workflows.reduce(0) { $0 + $1.runningCount }
    }
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isBusy ? Theme.statusBusy : Theme.Ink.idle)
                    .frame(width: 6, height: 6)
                Text(session.projectFolder.isEmpty ? "session" : session.projectFolder)
                    .font(Theme.Font.section)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if hasAgents {
                    Label("\(agentTotal)", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(Theme.Font.micro)
                        .foregroundColor(runningAgents > 0 ? Theme.statusBusy : Theme.textTertiary())
                        .labelStyle(.titleAndIcon)
                }
                StatusPill(
                    label: isBusy ? "运行中" : "空闲",
                    tint: isBusy ? Theme.statusBusy : Theme.statusIdle,
                    ink: isBusy ? Theme.Ink.claude : Theme.Ink.idle
                )
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.contextLabel)
                    .font(Theme.Font.tileMicroValue)
                    .foregroundColor(ctxColor)
                    .lineLimit(1)
                ContextBar(ratio: ratio, height: 3)
                    .opacity(session.contextTokens > 0 ? 1 : 0.25)
                    .frame(maxWidth: .infinity)
                SessionLoadChip(key: .pid(session.pid), compact: true)
                Text(session.relativeUpdated)
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary(0.55))
            }

            HStack(spacing: 6) {
                Text(session.currentActivity.isEmpty ? "等待下一步" : session.currentActivity)
                    .font(Theme.Font.micro)
                    .foregroundColor(isBusy ? Theme.textPrimary.opacity(0.75) : Theme.textTertiary(0.55))
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
