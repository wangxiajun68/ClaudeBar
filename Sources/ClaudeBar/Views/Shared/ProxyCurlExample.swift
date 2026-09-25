import AppKit
import SwiftUI

/// Compact settings tile with the full, copyable command in a popover.
struct ProxyCurlExample: View {
    var model: String
    @State private var showingExample = false

    private var snippet: String { LocalProxyAddress.chatCompletionsCurl(model: model) }

    var body: some View {
        SettingTile(icon: "terminal", title: "curl 示例",
                    caption: "带本机令牌的请求示例；model 以客户端为准。",
                    tint: Theme.codex) {
            Button("查看") { showingExample = true }
                .adaptiveGlassButton()
        }
        .popover(isPresented: $showingExample, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Space.s12) {
                Text("其他客户端将 Base URL 设为 \(LocalProxyAddress.openaiRoot)，即可走「第三方 OpenAI」上游。代理使用本机令牌鉴权，并由代理注入上游密钥；请求里的 model 仍以客户端为准。")
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                CodeBlock(title: "curl 示例", code: snippet)
            }
            .padding(Theme.Space.s16)
            .frame(width: 560)
        }
    }
}
