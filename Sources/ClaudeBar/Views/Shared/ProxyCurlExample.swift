import AppKit
import SwiftUI

struct ProxyAccessToken: View {
    @State private var token = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "API Key（本机令牌）", caption: "填入第三方客户端的 API Key；上游密钥由代理注入。") {
                ActionButton(copied ? "已复制" : "复制 Key", tone: .neutral) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                .disabled(token.isEmpty)
            }
            Text(token.isEmpty ? "令牌尚未生成，请先启用本地代理。" : token)
                .font(Theme.Font.console)
                .foregroundColor(token.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.s12)
                .instrumentWell(onCard: true)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .task {
            // Display only: opening settings must not create or rotate credentials.
            let path = FilePaths.proxyTokenFile
            token = await Task.detached {
                (try? String(contentsOf: path, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            }.value
        }
    }
}

/// A request example stays behind one explicit action in advanced proxy settings.
struct ProxyCurlExample: View {
    var model: String
    @State private var showingExample = false
    /// Filled on open: the token read creates `proxy-token` on first use, which
    /// must not be a side effect of rendering the settings page.
    @State private var snippet = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "接入示例", caption: "包含本机鉴权令牌，可复制到其他客户端。") {
                ActionButton(showingExample ? "收起示例" : "查看示例", tone: .neutral) {
                    if !showingExample {
                        snippet = LocalProxyAddress.chatCompletionsCurl(model: model)
                    }
                    showingExample.toggle()
                }
            }
            if showingExample {
                VStack(alignment: .leading, spacing: Theme.Space.s12) {
                    Text("其他客户端将 Base URL 设为 \(LocalProxyAddress.openaiRoot)，即可走「第三方 OpenAI」上游。请求里的 model 以客户端为准。")
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    CodeBlock(title: "curl 示例", code: snippet)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
    }
}
