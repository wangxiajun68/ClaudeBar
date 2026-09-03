import SwiftUI

/// Glass button + result line used on Settings and the provider editor.
struct ConnectivityProbeButton: View {
    let title: String
    var help: String = "向实际上游发送最短请求，以确认密钥、地址与模型可用。"
    let outcome: ConnectivityOutcome
    var tint: Color = Theme.claude
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s6) {
            Button(action: action) {
                HStack(spacing: Theme.Space.s6) {
                    if outcome.state == .running {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: icon)
                    }
                    Text(title)
                }
            }
            .adaptiveGlassButton()
            .tint(tint)
            .disabled(disabled || outcome.state == .running)
            .help(help)

            if outcome.state != .idle {
                Text(outcome.detail)
                    .font(Theme.Font.caption)
                    .foregroundColor(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private var icon: String {
        switch outcome.state {
        case .idle, .running: return "wifi"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var detailColor: Color {
        switch outcome.state {
        case .passed: return Theme.statusSuccess
        case .failed: return Theme.statusError
        default: return Theme.textTertiary()
        }
    }
}

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
                        .controlSize(.mini)
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
        .accessibilityLabel("检测连通性")
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
