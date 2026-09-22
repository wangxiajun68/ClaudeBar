import AppKit
import SwiftUI

/// Copyable curl against the local proxy. Any OpenAI-compatible client can
/// point its base URL at `LocalProxyAddress.openaiRoot`.
///
/// The snippet itself is rendered by the shared `CodeBlock`; this view owns
/// only the copy and the prose that explains what the command is for.
struct ProxyCurlExample: View {
    var model: String

    private var snippet: String { LocalProxyAddress.chatCompletionsCurl(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s6) {
            Text("其他客户端把 Base URL 设为 \(LocalProxyAddress.openaiRoot) 即走「第三方 OpenAI」上游。代理需要令牌鉴权（密钥由代理注入，不再接受任意 Bearer）——下面的示例已带上本机令牌。请求里的 model 仍以客户端为准。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
                .fixedSize(horizontal: false, vertical: true)
            CodeBlock(title: "curl 示例", code: snippet)
        }
    }
}
