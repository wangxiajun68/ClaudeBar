import SwiftUI

/// Compact Cursor session card for the 2-column grid: status, project, context
/// fill percent, activity, and recency. Cursor uses a purple accent to
/// distinguish it from Claude's green. Extracted from `MenuBarView.cursorSessionCard`.
struct CursorSessionCardView: View {
    let session: CursorSessionInfo
    var onDoubleTap: (() -> Void)? = nil

    private var isActive: Bool { session.status == .active }
    private var ratio: Double { session.contextRatio }
    private var accentColor: Color {
        ratio < 0.6 ? Theme.cursorAccent : (ratio < 0.85 ? Theme.statusWarning : Theme.statusError)
    }
    private var hasAgents: Bool { !session.subagents.isEmpty }
    private var runningAgents: Int { session.subagents.filter { $0.status == .running }.count }
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isActive ? Theme.cursorAccent : Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .symbolEffect(.pulse, options: .repeating, isActive: isActive)
                Text(session.projectFolder.isEmpty ? "cursor" : session.projectFolder)
                    .font(Theme.Font.rowTitle)
                    .foregroundColor(Theme.textPrimary.opacity(0.9))
                    .lineLimit(1)
                Spacer()
                if session.contextPercent >= 0 {
                    Text(session.contextLabel)
                        .font(Theme.Font.microMono.weight(.medium))
                        .foregroundColor(accentColor.opacity(0.9))
                }
            }

            if session.contextPercent >= 0 {
                ContextBar(ratio: ratio, height: 3)
            }

            if !session.currentActivity.isEmpty {
                Text(session.currentActivity)
                    .font(Theme.Font.microMono)
                    .foregroundColor(isActive ? Theme.textPrimary.opacity(0.65) : Theme.textTertiary())
                    .lineLimit(1)
            }

            HStack(spacing: 4) {
                if hasAgents {
                    Text("⚙\(session.subagents.count)")
                        .font(Theme.Font.micro)
                        .foregroundColor(runningAgents > 0 ? Theme.statusBusy : Theme.textTertiary())
                }
                Spacer()
                Text(session.relativeUpdated)
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .glassEffect(
            .regular.tint(isActive ? Theme.cursorAccent.opacity(isHovered ? 0.20 : 0.12) : Color.white.opacity(0.05)),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isActive ? Theme.cursorAccent.opacity(isHovered ? 0.55 : 0.35) : Theme.hairline, lineWidth: 1)
        )
        .scaleEffect(isHovered ? 1.02 : 1)
        .hoverState($isHovered)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleTap?() }
    }
}
