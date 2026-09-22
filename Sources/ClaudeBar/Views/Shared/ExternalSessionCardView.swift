import SwiftUI

/// Compact Codex session card for the 2-column popup grid.
///
/// A user session with sub-agents keeps the child count in the title rail.
/// The full swarm remains one click away in a popover instead of making every
/// popup row grow with fan-out.
struct ExternalSessionCardView: View {
    let session: ExternalSessionInfo
    /// How many sub-agents sit below this card (0 = a plain session card).
    var descendantCount: Int = 0
    /// Immediate children, rendered inline under the parent. Empty on
    /// sub-agents and on sessions that spawned nothing.
    var childAgents: [ExternalSessionInfo] = []
    var onDoubleTap: (() -> Void)? = nil

    private var isActive: Bool { session.isActive }
    @State private var isHovered = false
    @State private var showSwarm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? Theme.external : Theme.Ink.idle)
                    .frame(width: 6, height: 6)
                Text(session.displayName)
                    .font(Theme.Font.section)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if descendantCount > 0 {
                    Button { showSwarm = true } label: {
                        StatusPill(label: "⋯\(descendantCount)", tint: Theme.externalHi, ink: Theme.Ink.success)
                    }
                    .buttonStyle(.plain)
                    .help("查看 \(descendantCount) 个子 agent")
                }
                StatusPill(label: session.kind.displayName,
                           tint: Theme.external, ink: Theme.Ink.success)
            }

            HStack(spacing: 6) {
                Text(session.contextLabel)
                    .font(Theme.Font.tileMicroValue)
                    .foregroundColor(Theme.Ink.success)
                    .lineLimit(1)
                ContextBar(ratio: session.contextRatio, height: 3)
                    .opacity(session.contextTokens > 0 ? 1 : 0.25)
                    .frame(maxWidth: .infinity)
                SessionLoadChip(key: .standardizedCwd(session.cwd), compact: true)
                Text(session.relativeUpdated)
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
            }

            Text(session.model.isEmpty ? session.cwd : session.model)
                .font(Theme.Font.micro)
                .foregroundColor(isActive ? Theme.textPrimary.opacity(0.7) : Theme.textTertiary())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .tile(hovered: isHovered, dense: true)
        .hoverState($isHovered)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .help("双击以在 Codex 中继续")
        .onTapGesture(count: 2) { onDoubleTap?() }
        .popover(isPresented: $showSwarm, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                Text("\(session.displayName) · \(childAgents.count) 个子 agent")
                    .font(Theme.Font.rowTitle)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                AgentSwarmView(root: session, children: childAgents, onOpen: { _ in onDoubleTap?() })
                    .frame(width: 360, height: 260)
            }
            .padding(Theme.Space.s12)
        }
    }

    private var accessibilityText: String {
        var parts = [session.kind.displayName, session.displayName, isActive ? "运行中" : "空闲"]
        if descendantCount > 0 { parts.append("\(descendantCount) 个子 agent") }
        return parts.joined(separator: "，")
    }
}
