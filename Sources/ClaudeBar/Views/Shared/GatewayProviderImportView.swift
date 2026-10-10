import SwiftUI

struct GatewayProviderImportRoute: Identifiable {
    let id = UUID()
    var providerIDs: [UUID]
}

/// Protected batch selection: closing never writes; dismissal follows the
/// store's durable-save result, and credentials stay in the provider stores.
struct GatewayProviderImportView: View {
    var providerIDs: [UUID]
    @ObservedObject private var gateway = FreeModelGatewayStore.shared
    @Environment(\.dismiss) private var dismiss
    private struct Entry: Identifiable {
        var providerID: UUID
        var providerName: String
        var model: String
        var context: String
        var assumedContext: Bool
        var id: String { providerID.uuidString + ":" + model }
    }
    @State private var entries: [Entry] = []
    @State private var selected: Set<String> = []
    @State private var query = ""
    @State private var confirmedFree = false
    @State private var tools = false
    @State private var images = false
    @State private var json = false
    @State private var tiers = GatewayTaskDifficulty.allCases
    @State private var submitted = false
    @State private var showSettings = false
    @FocusState private var contextFocus: String?
    private var joined: Set<String> { Set(gateway.pool.members.map(\.id)) }
    private var selectedEntries: [Entry] { entries.filter { selected.contains($0.id) && !joined.contains($0.id) } }
    private var validSelection: Bool {
        !selectedEntries.isEmpty && selectedEntries.allSatisfy { (Int($0.context) ?? 0) > 0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                GlyphWell(name: "square.and.arrow.down", tint: Theme.Ink.cursor, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("加入 Auto 模型池").font(Theme.Font.brand)
                    Text("选择已保存模型 · 复用原供应商凭据").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(.plain).disabled(submitted)
                    .keyboardShortcut(.cancelAction)
            }.padding(20)
            HairlineDivider()
            HStack(spacing: 8) {
                InstrumentSearchField(prompt: "搜索已保存模型或配置", text: $query)
                ActionButton("全选") { selected = Set(entries.filter { !joined.contains($0.id) }.map(\.id)) }
                    .disabled(!gateway.canEdit || submitted || entries.isEmpty)
                ActionButton("清空") { selected.removeAll() }
                    .disabled(!gateway.canEdit || submitted || selected.isEmpty)
            }.padding(.horizontal, 20).padding(.vertical, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = gateway.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(Theme.Font.bodySmall).foregroundStyle(Theme.Ink.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("网关使用远端 OpenAI 兼容 Chat 接口。仅加入你已确认免费的模型；OpenRouter 仍按有效免费目录校验。")
                        .font(Theme.Font.bodySmall).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("已保存模型 · \(entries.count)")
                        Spacer()
                        Text("上下文 tokens")
                    }.font(Theme.Font.microMedium).foregroundStyle(Theme.textSecondary).padding(.top, 4)
                    if !entries.isEmpty && !entries.contains(where: { query.isEmpty || $0.model.localizedCaseInsensitiveContains(query) || $0.providerName.localizedCaseInsensitiveContains(query) }) {
                        Text("没有匹配的已保存模型。").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    }
                    if entries.isEmpty {
                        Text("没有可导入的已保存模型，请先在供应商中配置模型并保存。")
                            .font(Theme.Font.bodySmall).foregroundStyle(Theme.textSecondary)
                    }
                    LazyVStack(spacing: 8) {
                        ForEach($entries) { $entry in
                            if query.isEmpty || entry.model.localizedCaseInsensitiveContains(query)
                                || entry.providerName.localizedCaseInsensitiveContains(query) {
                                importRow(entry: $entry)
                            }
                        }
                    }
                    Text("未配置上下文时暂用 32,768，请核对。其他供应商采用本次声明的能力；OpenRouter 使用免费目录中的上下文与能力，不覆盖已入池模型。")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }
            HairlineDivider()
            VStack(alignment: .leading, spacing: 16) {
                Toggle("确认所选模型可免费使用", isOn: $confirmedFree)
                    .toggleStyle(InstrumentToggleStyle()).disabled(!gateway.canEdit || submitted)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(gateway.saving ? "正在保存…" : "已选 \(selectedEntries.count) 个模型")
                            .font(Theme.Font.chromeEmph).foregroundStyle(Theme.textPrimary).monospacedDigit()
                        Text(tiers.isEmpty ? "请选择任务档位" : tiers.map(\.displayName).joined(separator: " / "))
                            .font(Theme.Font.caption).foregroundStyle(tiers.isEmpty ? Theme.Ink.warning : Theme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    ActionButton("档位与能力", symbol: "slider.horizontal.3") { showSettings = true }
                        .disabled(!gateway.canEdit || submitted)
                        .popover(isPresented: $showSettings) { importSettings.padding(16).frame(width: 520) }
                    ActionButton(tone: .accent, tint: Theme.Ink.cursor, emphasis: .primary, perform: submit) {
                        AppGlyph(name: "plus", size: 12).foregroundStyle(Theme.isDark ? Theme.fieldWell : .white)
                        Text("加入 Auto 池").foregroundStyle(Theme.isDark ? Theme.fieldWell : .white)
                    }
                        .disabled(!gateway.canEdit || !confirmedFree || !validSelection || tiers.isEmpty || submitted)
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(20).background(Theme.cardSurface)
        }.frame(width: 620, height: 680).background(Theme.bgPrimary).foregroundStyle(Theme.textPrimary)
            .interactiveDismissDisabled(submitted)
            .onAppear { syncEntries() }
            .onChange(of: gateway.connections) { _, _ in syncEntries() }
    }

    private var importSettings: some View {
        SettingsGroup(title: "本次导入设置") {
            SettingsRow(title: "承接任务档位", caption: "可多选；后续可为每个模型分别调整。") {
                HStack(spacing: 10) {
                    ForEach(GatewayTaskDifficulty.allCases, id: \.self) { tier in
                        GatewayTierChip(tier: tier, selected: tiers.contains(tier)) {
                            tiers = GatewayTaskDifficulty.allCases.filter { $0 == tier ? !tiers.contains(tier) : tiers.contains($0) }
                        }
                    }
                }
            }
            SettingsDivider()
            SettingsToggleRow(title: "支持工具调用", isOn: $tools)
            SettingsDivider()
            SettingsToggleRow(title: "支持图片输入", isOn: $images)
            SettingsDivider()
            SettingsToggleRow(title: "支持结构化 JSON", isOn: $json)

        }.disabled(!gateway.canEdit || submitted)
    }

    private func importRow(entry: Binding<Entry>) -> some View {
        let item = entry.wrappedValue
        let exists = joined.contains(item.id)
        let picked = selected.contains(item.id) && !exists
        let catalog = gateway.connections.contains { $0.id == item.providerID && FreeModelPool.isOpenRouter($0.baseURL) }
        let invalid = (Int(item.context) ?? 0) <= 0
        return HStack(spacing: 12) {
            if exists {
                AppGlyph(name: "checkmark.circle", size: 18).foregroundStyle(Theme.Ink.success).frame(width: 22)
                    .accessibilityLabel("已在模型池内")
            } else {
                Toggle("选择 \(item.model)", isOn: Binding(get: { selected.contains(item.id) }, set: { value in
                    if value { selected.insert(item.id) } else { selected.remove(item.id) }
                })).toggleStyle(GatewaySelectionStyle(label: "选择 \(item.model)")).disabled(!gateway.canEdit || submitted)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.model).font(Theme.Font.chromeEmph).lineLimit(1).truncationMode(.middle).help(item.model)
                Text(item.providerName + (exists ? " · 已在池内" : ""))
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).help(item.providerName)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                TextField("上下文", text: entry.context)
                    .font(Theme.Font.captionMono).multilineTextAlignment(.trailing)
                    .focused($contextFocus, equals: item.id)
                    .textFieldStyle(InstrumentFieldStyle(focused: contextFocus == item.id, onCard: false)).frame(width: 94)
                    .disabled(exists || catalog || !gateway.canEdit || submitted)
                    .accessibilityLabel("\(item.model) 的上下文长度")
                    .help(catalog ? "OpenRouter 使用免费目录中的上下文长度" : "填写大于零的 token 数量")
                Text(catalog ? "以免费目录为准" : (invalid ? "请输入正整数" : (item.assumedContext ? "未配置 · 请核对" : "已配置")))
                    .font(Theme.Font.micro).foregroundStyle(invalid ? Theme.Ink.error : Theme.textSecondary)
            }
        }.padding(12)
            .background(picked ? Theme.cursor.opacity(Theme.isDark ? 0.1 : 0.06) : Theme.cardSurface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(picked ? Theme.cursor.opacity(0.45) : Theme.hairline)
            }
    }

    private func syncEntries() {
        let previous = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        entries = gateway.connections.filter { providerIDs.contains($0.id) }.flatMap { provider in
            provider.models.compactMap { model -> Entry? in
                let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let id = provider.id.uuidString + ":" + name
                guard !name.isEmpty, seen.insert(id).inserted else { return nil }
                let length = Int(model.contextWindow).flatMap { $0 > 0 ? $0 : nil }
                var entry = previous[id] ?? Entry(providerID: provider.id, providerName: provider.name,
                    model: name, context: String(length ?? 32768), assumedContext: length == nil)
                entry.providerName = provider.name
                return entry
            }
        }
        selected.formIntersection(seen)
    }

    private func submit() {
        let members = selectedEntries.map { entry in
            FreeModelPool.Member(providerID: entry.providerID, model: entry.model, name: entry.model,
                contextLength: Int(entry.context) ?? 0, supportsTools: tools, supportsImages: images,
                supportsJSON: json, difficulties: tiers)
        }
        submitted = true
        gateway.importModels(members, confirmedFree: confirmedFree) { succeeded in
            submitted = false
            if succeeded { dismiss() }
        }
    }
}

/// Fits the directory's existing 22pt status slot without shrinking actions.
struct GatewayProviderImportButton: View {
    var enabled: Bool
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                AppGlyph(name: "plus.circle", size: 12)
                Text("加入 Auto 池").font(Theme.Font.pill)
            }.foregroundStyle(Theme.Ink.cursor).padding(.horizontal, 7).frame(height: 22)
                .background(Theme.cursor.opacity(hovered ? 0.13 : 0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .overlay { RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.cursor.opacity(hovered ? 0.3 : 0.12)) }
        }.buttonStyle(GatewayNodeButtonStyle()).disabled(!enabled).opacity(enabled ? 1 : 0.45)
            .onHover { hovered = $0 && enabled }
            .help(enabled ? "从已保存配置选择模型加入 Auto 池" : "先保存供应商的地址、Key 和模型")
    }
}

/// A native button owns keyboard/focus and disabled behavior; the square
/// makes batch selection distinct from the gateway's on/off switches.
private struct GatewaySelectionStyle: ToggleStyle {
    var label: String
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(configuration.isOn ? Theme.Ink.cursor : Theme.fieldWell)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(configuration.isOn ? Theme.Ink.cursor : Theme.textSecondary.opacity(0.45))
                }
                .overlay {
                    if configuration.isOn { AppGlyph(name: "checkmark", size: 11).foregroundStyle(Theme.isDark ? Theme.fieldWell : .white) }
                }
                .frame(width: 22, height: 22)
        }.buttonStyle(GatewayNodeButtonStyle())
            .accessibilityLabel(label)
            .accessibilityValue(configuration.isOn ? "已选择" : "未选择")
            .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }
}
