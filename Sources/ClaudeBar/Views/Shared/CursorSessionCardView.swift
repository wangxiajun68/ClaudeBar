import SwiftUI

/// Compact Cursor session card for the 2-column grid: status, project, context
/// fill percent, activity, and recency. Purple accent distinguishes it from
/// Claude's green.
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? Theme.cursorAccent : Color.gray.opacity(0.45))
                    .frame(width: 6, height: 6)
                Text(session.projectFolder.isEmpty ? "cursor" : session.projectFolder)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                StatusPill(
                    label: isActive ? "运行中" : "空闲",
                    tint: isActive ? Theme.cursorAccent : Theme.statusIdle
                )
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.contextLabel)
                    .font(Theme.Font.tileMicroValue)
                    .foregroundColor(accentColor)
                Spacer()
                SessionLoadChip(key: .cursor, compact: true, shared: true)
            }

            ContextBar(ratio: ratio, height: 4)
                .opacity(session.contextPercent >= 0 ? 1 : 0.25)

            Text(session.currentActivity.isEmpty ? " " : session.currentActivity)
                .font(Theme.Font.micro)
                .foregroundColor(isActive ? Theme.textPrimary.opacity(0.7) : Theme.textTertiary())
                .lineLimit(2)

            HStack(spacing: 6) {
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
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile(hovered: isHovered, dense: true)
        .hoverState($isHovered)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.projectFolder.isEmpty ? "Cursor" : session.projectFolder)，\(isActive ? "运行中" : "空闲")")
        .accessibilityHint("连按在 Cursor 中打开")
        .onTapGesture(count: 2) { onDoubleTap?() }
    }
}
