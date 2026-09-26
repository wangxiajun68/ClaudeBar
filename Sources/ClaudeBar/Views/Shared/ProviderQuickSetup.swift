import SwiftUI
import AppKit

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
                    Label(draft.client.title, systemImage: "terminal")
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
                        Link(destination: URL(string: draft.entry.website)!) {
                            Label("获取 Key", systemImage: "arrow.up.right")
                        }.font(Theme.Font.caption).foregroundStyle(ProviderCardState.ready.color)
                    }
                    field("配置名称") { TextField("供应商名称", text: $draft.name) }
                    field("API Key") { APIKeyField(text: $draft.apiKey, localEndpoint: ProviderCatalogEntry.isLocalEndpoint(draft.baseURL)) }
                    field("接口地址") { TextField("https://…", text: $draft.baseURL) }
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
                                .rollingNumber()
                                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        ProviderModelFetchButton(baseURL: draft.baseURL, apiKey: draft.apiKey, wireAPI: draft.wireAPI,
                            existingNames: Set(draft.modelNames.map { $0.lowercased() })) { names in
                                draft.additionalModels.append(contentsOf: names.sorted())
                            }.frame(maxWidth: 220, alignment: .trailing)
                    }
                    field("默认模型 ID") { TextField("填写账号可用的模型 ID", text: $draft.model) }
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

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            content().textFieldStyle(ProviderInputStyle()).font(Theme.Font.bodySmall)
        }
    }
}

/// Bundled brand assets: offline, light/dark variants, no remote image requests.
struct ProviderIdentityMark: View {
    var entry: ProviderCatalogEntry?
    let name: String
    var size: CGFloat = 36
    var body: some View {
        Group {
            if let entry, let image = ProviderBrandImages.image(entry.iconName, dark: Theme.isDark) {
                Image(nsImage: image).resizable().scaledToFit().padding(size * 0.14)
            } else {
                Image(systemName: "server.rack").font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        .accessibilityHidden(true)
    }
}

private enum ProviderBrandImages {
    private static let cache = NSCache<NSString, NSImage>()
    static func image(_ name: String, dark: Bool) -> NSImage? {
        let key = "\(name)-\(dark ? "dark" : "light")"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let url = Bundle.main.url(forResource: key, withExtension: "png", subdirectory: "ProviderIcons")
                ?? Bundle.main.url(forResource: name, withExtension: "ico", subdirectory: "ProviderIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}
