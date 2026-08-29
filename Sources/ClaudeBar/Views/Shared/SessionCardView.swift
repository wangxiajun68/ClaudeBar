import SwiftUI

/// Compact session card for the 2-column grid: status, project, context fill,
/// activity, and recency in a tight tile. Shared by the menu-bar popup and the
/// Dashboard's activity feed. Extracted from `MenuBarView.sessionCard`.
struct SessionCardView: View {
    let session: SessionInfo
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textPrimary.opacity(0.9))
                    .lineLimit(1)
                Spacer()
                if session.contextTokens > 0 {
                    Text(session.contextLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(ctxColor.opacity(0.9))
                        .lineLimit(1)
                }
            }

            if session.contextTokens > 0 {
                ContextBar(ratio: ratio, height: 3)
            }

            if !session.currentActivity.isEmpty {
                Text(session.currentActivity)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(isBusy ? Theme.textPrimary.opacity(0.7) : Theme.textTertiary())
                    .lineLimit(1)
            }

            HStack(spacing: 4) {
                if hasAgents {
                    Text("⚙\(session.subagents.count + session.workflows.reduce(0) { $0 + $1.agents.count })")
                        .font(.system(size: 10))
                        .foregroundColor(runningAgents > 0 ? Theme.statusBusy : Theme.textTertiary())
                }
                if !session.model.isEmpty {
                    Text(session.model)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                }
                Spacer()
                Text(session.relativeUpdated)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary())
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .glassEffect(
            .regular.tint(isBusy ? Theme.statusBusy.opacity(isHovered ? 0.20 : 0.12) : Color.white.opacity(0.05)),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isBusy ? Theme.statusBusy.opacity(isHovered ? 0.55 : 0.35) : Theme.hairline, lineWidth: 1)
        )
        .scaleEffect(isHovered ? 1.02 : 1)
        .hoverState($isHovered)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleTap?() }
    }
}
