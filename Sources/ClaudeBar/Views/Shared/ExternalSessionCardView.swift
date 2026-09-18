import SwiftUI

/// Compact Codex session card for the 2-column popup grid.
///
/// A **user** session with sub-agents shows a `⋯N` badge in place of the tool
/// name and lists its children inline, indented under a rule — the popup's
/// half of the parent/child tree (the sessions page shows the full-width
/// version). Sub-agent cards never appear as roots in the grid, so the
/// relationship is visible without expanding anything.
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? Theme.external : Color.gray.opacity(0.45))
                    .frame(width: 6, height: 6)
                Text(session.displayName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if descendantCount > 0 {
                    Button { showSwarm = true } label: {
                        StatusPill(label: "⋯\(descendantCount)", tint: Theme.externalHi)
                    }
                    .buttonStyle(.plain)
                    .help("查看 \(descendantCount) 个子 agent")
                }
                StatusPill(label: session.kind.displayName, tint: Theme.external)
            }

            Text(session.model.isEmpty ? " " : session.model)
                .font(Theme.Font.micro)
                .foregroundColor(isActive ? Theme.textPrimary.opacity(0.7) : Theme.textTertiary())
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                SessionLoadChip(key: .standardizedCwd(session.cwd), compact: true)
                Spacer()
                Text(session.relativeUpdated)
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
            }

            if !childAgents.isEmpty {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                    .padding(.vertical, 1)
                AgentSwarmView(root: session,
                               children: Array(childAgents.prefix(Self.swarmStrip.visible)),
                               compact: true,
                               onOpen: { _ in onDoubleTap?() })
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.swarmStrip.height)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    /// Keep the popup card bounded on a wide fan-out; the sessions page shows
    /// the same cluster much larger. The strip below draws a two-row slice of
    /// it and the `⋯N` badge counts the rest.
    private static let maxVisibleChildren = 32
    /// Popup clusters get a fixed strip — cards in a grid row must stay the
    /// same height, so the swarm packs smaller cards into whatever it is given
    /// rather than the card growing with the fan-out. Sized for the widest
    /// fan-out it will ever hold, so every card in the popup gets the same
    /// strip whether its session has 3 agents or 32.
    private static var swarmStrip: (visible: Int, height: CGFloat) {
        AgentSwarmView.SwarmGrid.strip(count: maxVisibleChildren,
                                       width: 260,
                                       maxRows: 2,
                                       compact: true)
    }
    /// The strip is drawn from a fixed-height box, so it is built from the same
    /// width the reservation used — a narrower box would pack fewer columns and
    /// report an overflow the row has no space for.
    private static let swarmStripWidth: CGFloat = 260

    private func childRow(_ child: ExternalSessionInfo) -> some View {
        HStack(spacing: 4) {
            Text("↳")
                .font(Theme.Font.tileDetail)
                .foregroundColor(Theme.textTertiary(0.7))
            Circle()
                .fill(child.isActive ? Theme.external : Theme.textTertiary(0.6))
                .frame(width: 4, height: 4)
            Text(child.agentNickname.isEmpty ? child.sessionId : child.agentNickname)
                .font(Theme.Font.tileDetail)
                .foregroundColor(child.isActive ? Theme.textPrimary.opacity(0.8) : Theme.textTertiary())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(child.relativeUpdated)
                .font(Theme.Font.tileDetail)
                .foregroundColor(Theme.textTertiary(0.7))
                .lineLimit(1)
        }
    }

    private var accessibilityText: String {
        var parts = [session.kind.displayName, session.displayName, isActive ? "运行中" : "空闲"]
        if descendantCount > 0 { parts.append("\(descendantCount) 个子 agent") }
        return parts.joined(separator: "，")
    }
}
