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
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? Theme.cursorAccent : Theme.Ink.idle)
                    .frame(width: 6, height: 6)
                Text(session.projectFolder.isEmpty ? "cursor" : session.projectFolder)
                    .font(Theme.Font.section)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if hasAgents {
                    Label("\(session.subagents.count)", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(Theme.Font.micro)
                        .foregroundColor(runningAgents > 0 ? Theme.statusBusy : Theme.textTertiary())
                        .labelStyle(.titleAndIcon)
                }
                StatusPill(
                    label: isActive ? "运行中" : "空闲",
                    tint: isActive ? Theme.cursorAccent : Theme.statusIdle,
                    ink: isActive ? Theme.Ink.cursor : Theme.Ink.idle
                )
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.contextLabel)
                    .font(Theme.Font.tileMicroValue)
                    .foregroundColor(accentColor)
                ContextBar(ratio: ratio, height: 3)
                    .opacity(session.contextPercent >= 0 ? 1 : 0.25)
                    .frame(maxWidth: .infinity)
                SessionLoadChip(key: .cursor, compact: true, shared: true)
                Text(session.relativeUpdated)
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
            }

            Text(session.currentActivity.isEmpty ? "等待下一步" : session.currentActivity)
                .font(Theme.Font.micro)
                .foregroundColor(isActive ? Theme.textPrimary.opacity(0.7) : Theme.textTertiary())
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .tile(hovered: isHovered, dense: true)
        .hoverState($isHovered)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.projectFolder.isEmpty ? "Cursor" : session.projectFolder)，\(isActive ? "运行中" : "空闲")")
        .accessibilityHint("连按在 Cursor 中打开")
        .onTapGesture(count: 2) { onDoubleTap?() }
    }
}
