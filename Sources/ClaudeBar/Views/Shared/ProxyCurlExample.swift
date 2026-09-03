import AppKit
import SwiftUI

/// Copyable curl against the local proxy. Any OpenAI-compatible client can
/// point its base URL at `LocalProxyAddress.openaiRoot`.
struct ProxyCurlExample: View {
    var model: String
    @State private var copied = false

    private var snippet: String { LocalProxyAddress.chatCompletionsCurl(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s6) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                Text("curl 示例")
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textPrimary)
                Spacer(minLength: Theme.Space.s8)
                Button(copied ? "已复制" : "复制") { copy() }
                    .font(Theme.Font.caption)
                    .buttonStyle(.glass)
                    .tint(Theme.codex)
                    .fixedSize()
            }
            Text("其他 OpenAI 兼容客户端把 Base URL 设为 \(LocalProxyAddress.openaiRoot) 即可走当前激活的供应商。本地 Bearer 任意填写，密钥由代理注入。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
                .fixedSize(horizontal: false, vertical: true)
            Text(snippet)
                .font(Theme.Font.console)
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.s12)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.cardFill(0.08)))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
