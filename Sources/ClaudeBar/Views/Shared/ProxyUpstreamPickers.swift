import SwiftUI

/// Local-proxy routing as settings tiles: CC and Codex follow the vendors
/// selected on the Models page. Third-party clients get their own pickers and
/// do not rewrite `settings.json` / `config.toml`.
///
/// Rendered through the settings `TileGrid` so these four rows card-ify with
/// every other setting instead of being a lone full-width list.
struct ProxyUpstreamPickers: View {
    @ProviderState(.configuration) var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @ObservedObject private var prefs = AppPreferences.shared

    var body: some View {
        TileGrid(.pageSetting) {
            followTile(
                title: "Claude Code",
                value: Self.describe(providerStore.activeProvider?.name,
                                     model: providerStore.activeProvider?.activeModel?.name),
                tint: Theme.claude,
                empty: providerStore.providers.isEmpty)

            followTile(
                title: "Codex",
                value: Self.describe(codexStore.activeProvider?.name,
                                     model: codexStore.activeProvider?.activeModel?.name),
                tint: Theme.codex,
                empty: codexStore.providers.isEmpty)

            pickerTile(
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

            pickerTile(
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

    private func followTile(title: String, value: String, tint: Color, empty: Bool) -> some View {
        SettingTile(icon: "arrow.triangle.branch", title: title,
                    caption: "跟随「模型」页的当前供应商。",
                    tint: tint, compact: true) {
            if empty {
                Button("去添加") {
                    NotificationCenter.default.post(.showMainWindow(page: .providers, editor: true))
                }
                .adaptiveGlassButton(tint: tint)
            } else {
                // The value is a read-out, not a control: keep it in the tile's
                // own type scale so it does not read as an editable field.
                Text(value)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(value)
            }
        }
    }

    private func pickerTile(
        title: String,
        caption: String,
        tint: Color,
        followLabel: String,
        providers: [ProxyVendorChoice],
        selection: Binding<UUID?>
    ) -> some View {
        SettingTile(icon: "arrow.triangle.branch", title: title, caption: caption, tint: tint, compact: true) {
            if providers.isEmpty {
                Text("无供应商")
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
            } else {
                Menu {
                    Button(followLabel) { selection.wrappedValue = nil }
                    ForEach(providers) { p in
                        Button(p.menuLabel) { selection.wrappedValue = p.id }
                    }
                } label: {
                    let current = providers.first { $0.id == selection.wrappedValue }
                    InstrumentMenuLabel(title: current?.name ?? followLabel, tint: tint)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
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
