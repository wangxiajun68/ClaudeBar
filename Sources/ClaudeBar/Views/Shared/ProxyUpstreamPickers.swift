import SwiftUI

/// Only third-party routes need preferences. CC and Codex are configured on
/// the Models page; repeating their read-only status here obscures these choices.
struct ProxyUpstreamPickers: View {
    @ProviderState(.configuration) var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @ObservedObject private var prefs = AppPreferences.shared

    var body: some View {
        VStack(spacing: 0) {
            pickerRow(
                title: "第三方 OpenAI",
                caption: "Chat Completions / Responses 接口。默认跟随 Codex；未配置时使用 Claude Code 供应商的 OpenAI 兼容接口。",
                followLabel: "自动跟随供应商",
                providers: codexStore.providers.map {
                    ProxyVendorChoice(id: $0.id, name: $0.name, host: Self.host($0.baseURL))
                },
                selection: Binding(
                    get: { prefs.proxyThirdPartyOpenAIProviderID },
                    set: { id in
                        prefs.proxyThirdPartyOpenAIProviderID = id
                        codexStore.syncProxyRuntime()
                    }))

            SettingsDivider()
            pickerRow(
                title: "第三方 Anthropic",
                caption: "Messages 接口。",
                followLabel: "与 Claude Code 相同",
                providers: providerStore.providers.map {
                    ProxyVendorChoice(id: $0.id, name: $0.name, host: Self.host($0.baseURL))
                },
                selection: Binding(
                    get: { prefs.proxyThirdPartyAnthropicProviderID },
                    set: { id in
                        prefs.proxyThirdPartyAnthropicProviderID = id
                        codexStore.syncProxyRuntime()
                    }))
        }
    }

    private func pickerRow(
        title: String,
        caption: String,
        followLabel: String,
        providers: [ProxyVendorChoice],
        selection: Binding<UUID?>
    ) -> some View {
        SettingsRow(title: title, caption: caption) {
            if providers.isEmpty {
                Button("添加供应商") {
                    NotificationCenter.default.post(.showMainWindow(page: .providers, editor: true))
                }
                .buttonStyle(.link)
            } else {
                Picker(title, selection: Binding(
                    get: { providers.contains(where: { $0.id == selection.wrappedValue }) ? selection.wrappedValue : nil },
                    set: { selection.wrappedValue = $0 })) {
                    Text(followLabel).tag(nil as UUID?)
                    ForEach(providers) { p in
                        Text(p.menuLabel).tag(Optional(p.id))
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        }
    }

    static func host(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }
}

private struct ProxyVendorChoice: Identifiable {
    var id: UUID
    var name: String
    var host: String

    var menuLabel: String {
        host.isEmpty ? name : "\(name)  (\(host))"
    }
}
