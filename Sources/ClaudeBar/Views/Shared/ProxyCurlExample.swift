import AppKit
import SwiftUI

/// Copyable curl against the local proxy, as a full-width card. Any
/// OpenAI-compatible client can point its base URL at
/// `LocalProxyAddress.openaiRoot`.
///
/// The snippet itself is rendered by the shared `CodeBlock`; this view owns the
/// card, the copy button and the prose that explains what the command is for.
/// `CodeBlock` deliberately does *not* carry a `panelCard()` of its own — the
/// help page renders half a dozen of them and they must stay inset code wells
/// rather than six nested cards.
struct ProxyCurlExample: View {
    var model: String

    private var snippet: String { LocalProxyAddress.chatCompletionsCurl(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            // The prose explains the snippet, so it belongs to the card rather
            // than floating loose above it.
            HStack(alignment: .top, spacing: Theme.Space.s8) {
                GlyphWell(name: "terminal", tint: Theme.codex, size: 18)
                Text("其他客户端把 Base URL 设为 \(LocalProxyAddress.openaiRoot) 即走「第三方 OpenAI」上游。代理需要令牌鉴权（密钥由代理注入，不再接受任意 Bearer）——下面的示例已带上本机令牌。请求里的 model 仍以客户端为准。")
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The snippet keeps `CodeBlock`'s own inset surface: a code well
            // inside the card, not a second card.
            CodeBlock(title: "curl 示例", code: snippet)
        }
        .padding(Theme.Space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }
}
