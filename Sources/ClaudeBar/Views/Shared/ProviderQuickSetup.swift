import SwiftUI

/// A short credential form; selecting a catalog entry alone never persists it.
struct ProviderQuickSetup: View {
    @State var draft: ProviderSetupDraft
    let onSave: (ProviderSetupDraft) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                ProviderIdentityMark(entry: draft.entry, name: draft.entry.name, size: 56)
                VStack(alignment: .leading, spacing: 7) {
                    Text("接入 " + draft.entry.name).font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text(draft.entry.detail).font(Theme.Font.bodySmall).foregroundStyle(Theme.textSecondary)
                    // Same as the connection editor: the client's own mark,
                    // not a terminal that fits both.
                    Label {
                        Text(draft.client.title)
                    } icon: {
                        ProductBrandMark(codex: draft.client == .codex, well: false)
                            .frame(width: 12, height: 12)
                    }
                    .font(Theme.Font.caption).foregroundStyle(ProviderCardState.ready.color)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(ProviderActionStyle()).help("关闭配置")
            }.padding(24)
            HairlineDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Label("连接凭据", systemImage: "key.horizontal").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        // Same guard as the connection editor: an entry whose
                        // URL does not parse drops the link rather than
                        // trapping the sheet.
                        if let url = URL(string: draft.entry.website) {
                            Link(destination: url) { Label("获取 Key", systemImage: "arrow.up.right") }
                                .font(Theme.Font.caption).foregroundStyle(ProviderCardState.ready.color)
                        }
                    }
                    ProviderFormField("配置名称") { TextField("供应商名称", text: $draft.name) }
                    ProviderFormField("API Key") { APIKeyField(text: $draft.apiKey, localEndpoint: ProviderCatalogEntry.isLocalEndpoint(draft.baseURL)) }
                    ProviderFormField("接口地址") { TextField("https://…", text: $draft.baseURL) }
                    if draft.client == .codex, let endpoint = draft.entry.codex {
                        HStack(spacing: 8) {
                            ForEach(endpoint.supportedWireAPIs, id: \.self) { wire in
                                Button { draft.selectProtocol(wire) } label: {
                                    Label(wire == "chat" ? "Chat Completions" : "Responses", systemImage: draft.wireAPI == wire ? "checkmark.circle.fill" : "circle")
                                }.buttonStyle(ProviderActionStyle(prominent: draft.wireAPI == wire))
                            }
                            Spacer()
                        }
                        Text(draft.wireAPI == "chat" ? "通过本地转换接入 Codex" : "使用供应商原生 Responses 接口")
                            .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    }
                    HairlineDivider().padding(.vertical, 4)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("模型", systemImage: "square.stack.3d.up").font(.system(size: 15, weight: .semibold))
                            Text("已选 \(draft.modelNames.count) 个 · 首个模型用于默认激活")
                                .rollingNumber("已选 \(draft.modelNames.count) 个 · 首个模型用于默认激活")
                                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        ProviderModelFetchButton(baseURL: draft.baseURL, apiKey: draft.apiKey, wireAPI: draft.wireAPI,
                            existingNames: Set(draft.modelNames.map { $0.lowercased() })) { names in
                                draft.additionalModels.append(contentsOf: names.sorted())
                            }.frame(maxWidth: 220, alignment: .trailing)
                    }
                    ProviderFormField("默认模型 ID") { TextField("填写账号可用的模型 ID", text: $draft.model) }
                    if let models = draft.entry.endpoint(for: draft.client)?.models, models.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(models, id: \.self) { model in
                                    Button(model) { draft.model = model }
                                        .buttonStyle(ProviderActionStyle(prominent: draft.model == model))
                                }
                            }.padding(.vertical, 2)
                        }
                    }
                    ForEach(draft.additionalModels, id: \.self) { name in
                        HStack {
                            Label(name, systemImage: "checkmark.circle.fill").lineLimit(1)
                                .foregroundStyle(ProviderCardState.ready.color)
                            Spacer()
                            Button { draft.additionalModels.removeAll { $0 == name } } label: { Image(systemName: "minus") }
                                .buttonStyle(ProviderActionStyle()).help("移除 " + name)
                        }.font(Theme.Font.bodySmall)
                    }
                    if let message = error ?? draft.validationError {
                        Label(message, systemImage: error == nil ? "info.circle" : "exclamationmark.circle")
                            .font(Theme.Font.caption).foregroundStyle(error == nil ? Theme.textSecondary : Theme.Ink.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(24)
            }
            HairlineDivider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("保存配置，再激活").font(Theme.Font.bodySmall).fontWeight(.medium)
                    Text("不会替换当前连接").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(ProviderActionStyle()).keyboardShortcut(.cancelAction)
                Button {
                    guard draft.validationError == nil else { return }
                    if let failure = onSave(draft) { error = failure } else { dismiss() }
                } label: { Label("保存配置", systemImage: "arrow.right") }
                    .buttonStyle(ProviderActionStyle(prominent: true))
                    .disabled(draft.validationError != nil).keyboardShortcut(.defaultAction)
            }.padding(24).background(Theme.bgPrimary)
        }
        .frame(width: 640, height: 660).foregroundStyle(Theme.textPrimary).background(Theme.cardSurface)
        .onChange(of: draft.name) { _, _ in error = nil }
        .onChange(of: draft.apiKey) { _, _ in error = nil }
        .onChange(of: draft.baseURL) { _, _ in error = nil }
    }
}
