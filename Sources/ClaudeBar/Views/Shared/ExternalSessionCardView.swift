import SwiftUI

/// Compact Codex session card for the 2-column popup grid.
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
                SessionLoadChip(key: .standardizedCwd(session.cwd), compact: true)
                Spacer()
                Text(session.relativeUpdated)
                    .font(Theme.Font.microMono)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Theme.external.opacity(isHovered ? 0.16 : 0.10) : Color.white.opacity(0.05))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isActive ? Theme.external.opacity(isHovered ? 0.55 : 0.35) : Theme.hairline, lineWidth: 1)
        )
        .hoverState($isHovered)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.kind.displayName)，\(session.projectFolder)，\(isActive ? "运行中" : "空闲")")
        .help("双击以在 Codex 中继续")
        .onTapGesture(count: 2) { onDoubleTap?() }
    }
}
