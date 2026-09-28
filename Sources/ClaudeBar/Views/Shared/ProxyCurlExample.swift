import AppKit
import SwiftUI

/// A request example stays behind one explicit action in advanced proxy settings.
struct ProxyCurlExample: View {
    var model: String
    @State private var showingExample = false

    private var snippet: String { LocalProxyAddress.chatCompletionsCurl(model: model) }

    var body: some View {
        SettingsRow(title: "接入示例", caption: "包含本机鉴权令牌，可复制到其他客户端。") {
            ActionButton("查看示例", tone: .neutral) { showingExample = true }
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
