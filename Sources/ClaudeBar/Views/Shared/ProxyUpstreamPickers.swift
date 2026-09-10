import SwiftUI

/// Local-proxy routing: CC and Codex follow the vendors selected on the
/// Models page. Third-party clients get their own pickers and do not rewrite
/// `settings.json` / `config.toml`.
struct ProxyUpstreamPickers: View {
    @EnvironmentObject var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @ObservedObject private var prefs = AppPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            followRow(
                title: "Claude Code",
                value: Self.describe(providerStore.activeProvider?.name,
                                     model: providerStore.activeProvider?.activeModel?.name),
                tint: Theme.claude,
                empty: providerStore.providers.isEmpty)

            Divider()

            followRow(
                title: "Codex",
                value: Self.describe(codexStore.activeProvider?.name,
                                     model: codexStore.activeProvider?.activeModel?.name),
                tint: Theme.codex,
                empty: codexStore.providers.isEmpty)

            Divider()

            pickerRow(
                title: "第三方 OpenAI",
                caption: "Chat Completions / Responses。默认跟随 Codex；可另选供应商，不影响 Codex。",
                tint: Theme.codex,
                followLabel: "与 Codex 相同",
                providers: codexStore.providers.map {
                    ProxyVendorChoice(id: $0.id, name: $0.name, host: Self.host($0.baseURL))
                },
                selection: Binding(
                    get: { prefs.proxyThirdPartyOpenAIProviderID },
                    set: { id in
                        prefs.proxyThirdPartyOpenAIProviderID = id
                        codexStore.syncProxyRuntime()
                    }))

            Divider()

            pickerRow(
                title: "第三方 Anthropic",
                caption: "/v1/messages。默认跟随 Claude Code；可另选供应商，不影响 Claude Code。",
                tint: Theme.claude,
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

    private func followRow(title: String, value: String, tint: Color, empty: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s6) {
            HStack(alignment: .center, spacing: Theme.Space.s16) {
                Text(title)
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textPrimary)
                Spacer(minLength: Theme.Space.s12)
                if empty {
                    Button("去添加") {
                        NotificationCenter.default.post(name: .openProvidersEditor, object: nil)
                    }
                    .adaptiveGlassButton()
                    .tint(tint)
                    .fixedSize()
                } else {
                    Text(value)
                        .font(Theme.Font.bodySmall)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(minHeight: 22)
            Text("在「模型」页选择。本地代理开启后走各自供应商，互不影响。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pickerRow(
        title: String,
        caption: String,
        tint: Color,
        followLabel: String,
        providers: [ProxyVendorChoice],
        selection: Binding<UUID?>
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s6) {
            HStack(alignment: .center, spacing: Theme.Space.s16) {
                Text(title)
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textPrimary)
                Spacer(minLength: Theme.Space.s12)
                if providers.isEmpty {
                    Text("无供应商")
                        .font(Theme.Font.bodySmall)
                        .foregroundColor(Theme.textTertiary())
                } else {
                    Picker("", selection: selection) {
                        Text(followLabel).tag(Optional<UUID>.none)
                        ForEach(providers) { p in
                            Text(p.menuLabel).tag(Optional(p.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 280)
                    .tint(tint)
                }
            }
            .frame(minHeight: 22)
            Text(caption)
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func host(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }

    static func describe(_ name: String?, model: String?) -> String {
        guard let name, !name.isEmpty else { return "未选择" }
        if let model, !model.isEmpty { return "\(name) · \(model)" }
        return name
    }

    static func statusLine(
        codex: CodexProvider?,
        claude: Provider?,
        thirdOpenAI: CodexProvider?,
        thirdAnthropic: Provider?,
        running: Bool,
        port: Int
    ) -> String {
        if !running { return "未启用" }
        var parts = ["已启用  127.0.0.1:\(port)"]
        if let p = claude { parts.append("CC \(p.name)") }
        if let p = codex { parts.append("Codex \(p.name)") }
        let tp = thirdOpenAI?.name
        if let tp, tp != codex?.name { parts.append("第三方 \(tp)") }
        else if thirdAnthropic?.name != nil, thirdAnthropic?.name != claude?.name {
            parts.append("第三方 \(thirdAnthropic!.name)")
        }
        return parts.joined(separator: "  ·  ")
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
