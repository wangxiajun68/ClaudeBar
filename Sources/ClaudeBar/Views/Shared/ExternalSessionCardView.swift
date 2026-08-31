import SwiftUI

/// Compact external-agent session card (Codex / OpenClaw) for the
/// 2-column popup grid: status, tool name, project, model, recency. Teal
/// accent distinguishes the family from Claude (blue) and Cursor (violet).
/// No context data exists for these tools, so the card carries the tool name
/// where Cursor shows its context percent — equal height is preserved.
struct ExternalSessionCardView: View {
    let session: ExternalSessionInfo
    var onDoubleTap: (() -> Void)? = nil

    private var isActive: Bool { session.isActive }
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isActive ? Theme.external : Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .symbolEffect(.pulse, options: .repeating, isActive: isActive)
                Text(session.projectFolder.isEmpty ? session.kind.displayName : session.projectFolder)
                    .font(Theme.Font.rowTitle)
                    .foregroundColor(Theme.textPrimary.opacity(0.9))
                    .lineLimit(1)
                Spacer()
                Text(session.kind.displayName)
                    .font(Theme.Font.badgeMono)
                    .foregroundColor(Theme.externalHi.opacity(0.9))
            }

            // Always-rendered model line (space-reserved) keeps both cards
            // in a grid row equal height.
            Text(session.model.isEmpty ? " " : session.model)
                .font(Theme.Font.microMono)
                .foregroundColor(isActive ? Theme.textPrimary.opacity(0.65) : Theme.textTertiary())
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 4) {
                Spacer()
                Text(session.relativeUpdated)
                    .font(Theme.Font.microMono)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .glassEffect(
            .regular.tint(isActive ? Theme.external.opacity(isHovered ? 0.20 : 0.12) : Color.white.opacity(0.05)),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isActive ? Theme.external.opacity(isHovered ? 0.55 : 0.35) : Theme.hairline, lineWidth: 1)
        )
        .hoverState($isHovered)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.kind.displayName)，\(session.projectFolder)，\(isActive ? "运行中" : "空闲")")
        .onTapGesture(count: 2) { onDoubleTap?() }
    }
}
