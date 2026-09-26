import SwiftUI

/// 22pt icon on a provider tile. Idle shows a network glyph; result tints it.
struct ConnectivityTileButton: View {
    let outcome: ConnectivityOutcome
    var helpIdle: String = "检测此供应商的模型连通性"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if outcome.state == .running {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .tint(Theme.claude)
                        .scaleEffect(0.85)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: icon)
                        .font(Theme.Font.bodySmall.weight(.semibold))
                        .foregroundColor(color)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(outcome.state == .running)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var icon: String {
        switch outcome.state {
        case .idle, .running: return "wifi"
        case .passed: return "checkmark"
        case .failed: return "xmark"
        }
    }

    private var color: Color {
        switch outcome.state {
        case .passed: return Theme.statusSuccess
        case .failed: return Theme.statusError
        default: return Theme.textTertiary(0.4)
        }
    }

    private var helpText: String {
        switch outcome.state {
        case .idle, .running: return helpIdle
        case .passed, .failed: return outcome.detail
        }
    }
}
