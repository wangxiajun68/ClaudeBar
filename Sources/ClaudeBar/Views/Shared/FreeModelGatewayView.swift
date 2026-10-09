import SwiftUI
import AppKit

struct FreeModelGatewayView: View {
    @ObservedObject private var gateway = FreeModelGatewayStore.shared
    var onAddOpenRouter: () -> Void
    @State private var query = ""
    @State private var providerID: UUID?
    @State private var modelID = ""
    @State private var context = "32768"
    @State private var tools = true
    @State private var images = false
    @State private var json = false
    @State private var difficulties = GatewayTaskDifficulty.allCases
    @State private var confirmedFree = false
    @State private var editingMember: String?
    @ObservedObject private var prefs = AppPreferences.shared

    private var openRouter: [CodexProvider] { gateway.connections.filter { FreeModelPool.isOpenRouter($0.baseURL) } }
    private var selected: CodexProvider? { gateway.connections.first { $0.id == providerID } }
    private var editable: Bool { !gateway.loading && !gateway.saving }
    private var results: [FreeModelPool.CatalogModel] {
        gateway.pool.catalog.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s24) {
                if gateway.loading { ProgressView("读取网关配置…").frame(maxWidth: .infinity) }
                if let error = gateway.error {
                    Text(error).font(Theme.Font.bodySmall).foregroundStyle(Theme.Ink.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                controls
                connection
                pool
                addFromProvider
                discovery
                activity
            }
            .padding(.horizontal, Theme.Space.s24)
            .padding(.bottom, Theme.Space.s24)
        }
        .task {
            // Only the visible panel reads health. Discovery has its own app
            // lifecycle, so switching pages never starts a second network job.
            while !Task.isCancelled {
                await gateway.refreshStatus()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .onChange(of: providerID) { _, _ in
            if let editingMember, gateway.pool.members.first(where: { $0.id == editingMember })?.providerID == providerID { return }
            editingMember = nil
            modelID = selected?.activeModel?.name ?? selected?.models.first?.name ?? ""
            confirmedFree = false
        }
    }

    private var controls: some View {
        SettingsGroup(title: "Auto 模型网关", symbol: "point.3.connected.trianglepath.dotted",
                      caption: "只使用池内模型。工具、图片和上下文不匹配的模型会跳过；限流与故障会自动冷却。免费额度仍由各平台的账户规则决定。") {
            SettingsToggleRow(title: "启用 Auto", caption: "第三方客户端将模型名设为 auto 或 claudebar/auto。",
                isOn: binding(\.enabled))
            SettingsDivider()
            SettingsToggleRow(title: "接管全部第三方请求", caption: "开启后，第三方客户端的显式模型名也会改由池内模型执行。",
                isOn: binding(\.interceptAll))
            SettingsDivider()
            SettingsRow(title: "路由策略") {
                Picker("路由策略", selection: binding(\.strategy)) {
                    ForEach(FreeModelPool.Strategy.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 160)
            }
            SettingsDivider()
            SettingsRow(title: "最多尝试", caption: "只在响应尚未开始时尝试备用模型。") {
                Stepper("\(gateway.pool.maxAttempts) 个模型", value: binding(\.maxAttempts), in: 1...5)
            }
            SettingsDivider()
            SettingsRow(title: "并发上限") {
                Stepper("\(gateway.pool.maxConcurrent) 个请求", value: binding(\.maxConcurrent), in: 1...8)
            }
            SettingsDivider()
            SettingsRow(title: "每分钟上限", caption: "计入备用尝试，避免失败时连续消耗免费额度。") {
                Stepper("\(gateway.pool.requestsPerMinute) 次", value: binding(\.requestsPerMinute), in: 1...60)
            }
        }.disabled(!editable)
    }

    private var connection: some View {
        SettingsGroup(title: "第三方客户端接入") {
            SettingsRow(title: "Base URL", caption: LocalProxyAddress.openaiRoot) {
                ActionButton("复制地址") { copy(LocalProxyAddress.openaiRoot) }
            }
            SettingsDivider()
            SettingsRow(title: "模型名", caption: "OpenAI Chat Completions、Responses 和 Anthropic Messages 均可接入。") {
                ActionButton("复制 auto") { copy("auto") }
            }
            SettingsDivider()
            SettingsRow(title: "自动判断任务", caption: "只填 model: auto 即可。本地规则结合用户目标与工具续轮判断难度；不确定时按 medium。可选 task_difficulty: low / medium / high 覆盖判断。") {
                ActionButton("复制请求示例") {
                    copy("{\"model\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"分析并排查偶发死锁\"}]}")
                }
            }
            SettingsDivider()
            ProxyAccessToken()
            SettingsDivider()
            ProxyCurlExample(model: "auto")
            SettingsDivider()
            SettingsToggleRow(title: "记录第三方流量", caption: "在「流量」页查看每次尝试的实际供应商和模型。", isOn: $prefs.proxyThirdPartyTrafficEnabled)
            if !prefs.codexRoutingEnabled {
                Text("本地代理未启用，请在「设置 → 本地代理」开启后接入。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Ink.warning)
                    .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
    }

    private var pool: some View {
        SettingsGroup(title: "模型池 · \(gateway.pool.members.count)", caption: "为每个模型勾选可承接的任务难度，可多选。路由与备用切换均限于对应难度；未勾选的模型不参与 Auto。未测试表示尚无成功请求。") {
            if gateway.pool.members.isEmpty {
                Text("先从已配置供应商提交免费模型，或从下方发现结果加入。")
                    .font(Theme.Font.bodySmall).foregroundStyle(Theme.textSecondary)
                    .padding(20)
            }
            ForEach(Array(gateway.pool.members.enumerated()), id: \.element.id) { index, member in
                if index > 0 { SettingsDivider() }
                memberRow(member, index: index)
            }
        }
    }

    private func memberRow(_ member: FreeModelPool.Member, index: Int) -> some View {
        let health = gateway.snapshot.health[member.id]
        let provider = gateway.connections.first { $0.id == member.providerID }
        let cooling = (health?.cooldownUntil ?? .distantPast) > Date()
        let missing = provider == nil || provider?.apiKey.isEmpty == true
        let removed = provider.map { FreeModelPool.isOpenRouter($0.baseURL) } == true
            && !gateway.pool.catalog.contains { $0.id == member.model }
        let status = missing ? "缺少凭据" : (removed ? "已下架 / 非免费" : (cooling ? "冷却中" : ((health?.successes ?? 0) > 0 ? "可用" : "未测试")))
        return VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: Theme.Space.s10) {
                Toggle(member.name, isOn: Binding(get: { member.enabled }, set: { enabled in
                    gateway.change { value in
                        if let i = value.members.firstIndex(where: { $0.id == member.id }) { value.members[i].enabled = enabled }
                    }
                })).labelsHidden().toggleStyle(InstrumentToggleStyle(showsLabel: false, width: 48))
                VStack(alignment: .leading, spacing: 3) {
                    Text(member.name).font(Theme.Font.bodySmall).foregroundStyle(Theme.textPrimary)
                    Text("\(provider?.name ?? "已删除供应商") · \(member.model)")
                        .font(Theme.Font.captionMono).foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(status).font(Theme.Font.caption).foregroundStyle(missing || removed ? Theme.Ink.warning : Theme.textSecondary)
                Menu {
                    Button("编辑模型能力") {
                        editingMember = member.id
                        providerID = member.providerID; modelID = member.model
                        context = String(member.contextLength); tools = member.supportsTools
                        images = member.supportsImages; json = member.supportsJSON; confirmedFree = false
                        difficulties = member.difficulties
                    }.disabled(member.discovered)
                    Button("上移") { move(member, by: -1) }.disabled(index == 0)
                    Button("下移") { move(member, by: 1) }.disabled(index == gateway.pool.members.count - 1)
                    Button("移出模型池", role: .destructive) { gateway.change { $0.members.removeAll { $0.id == member.id } } }
                } label: { AppGlyph(name: "ellipsis", size: 16) }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("\(member.name) 模型池操作")
            }
            Text("\(member.discovered ? "目录验证免费" : "用户确认免费") · \(member.contextLength.formatted()) 上下文\(member.supportsTools ? " · 工具" : "")\(member.supportsImages ? " · 图片" : "")\(member.supportsJSON ? " · JSON" : "") · 成功 \(health?.successes ?? 0) / 失败 \(health?.failures ?? 0)")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s16) {
                Text("任务难度").foregroundStyle(Theme.textSecondary)
                ForEach(GatewayTaskDifficulty.allCases, id: \.self) { difficulty in
                    Toggle(difficulty.title, isOn: Binding(get: { member.difficulties.contains(difficulty) }, set: { enabled in
                        gateway.change { value in
                            guard let i = value.members.firstIndex(where: { $0.id == member.id }) else { return }
                            value.members[i].difficulties = GatewayTaskDifficulty.allCases.filter {
                                $0 == difficulty ? enabled : value.members[i].difficulties.contains($0)
                            }
                        }
                    })).toggleStyle(.checkbox)
                }
            }.font(Theme.Font.caption)
            if let until = health?.cooldownUntil, cooling {
                Text("冷却至 \(until.formatted(date: .omitted, time: .standard))")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
        }.padding(.horizontal, 20).padding(.vertical, 14).disabled(!editable)
    }

    private var addFromProvider: some View {
        SettingsGroup(title: "从已有供应商提交", caption: "使用现有 Claude Code / Codex 配置的 OpenAI 兼容接口，不激活供应商、不改客户端配置。其他平台的免费资格与能力由你确认，网关不会把付费模型当作免费额度。") {
            SettingsRow(title: "供应商") {
                Picker("供应商", selection: $providerID) {
                    Text("选择已配置供应商").tag(UUID?.none)
                    ForEach(gateway.connections) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(width: 240)
            }
            SettingsDivider()
            SettingsRow(title: "模型 ID") {
                HStack {
                    TextField("完整模型 ID", text: $modelID).textFieldStyle(InstrumentFieldStyle()).frame(width: 230)
                    Menu("已有模型") {
                        ForEach(selected?.models ?? []) { model in Button(model.name) { modelID = model.name } }
                    }.disabled(selected == nil)
                }
            }
            SettingsDivider()
            SettingsRow(title: "上下文长度") {
                TextField("32768", text: $context).textFieldStyle(InstrumentFieldStyle()).frame(width: 110)
            }
            SettingsDivider()
            SettingsRow(title: "任务难度", caption: "可多选，加入后也能在池内直接调整。") {
                HStack(spacing: Theme.Space.s12) {
                    ForEach(GatewayTaskDifficulty.allCases, id: \.self) { difficulty in
                        Toggle(difficulty.rawValue, isOn: Binding(get: { difficulties.contains(difficulty) }, set: { enabled in
                            difficulties = GatewayTaskDifficulty.allCases.filter { $0 == difficulty ? enabled : difficulties.contains($0) }
                        })).toggleStyle(.checkbox)
                    }
                }
            }
            SettingsDivider()
            SettingsToggleRow(title: "支持工具调用", isOn: $tools)
            SettingsDivider()
            SettingsToggleRow(title: "支持图片输入", isOn: $images)
            SettingsDivider()
            SettingsToggleRow(title: "支持结构化 JSON", isOn: $json)
            SettingsDivider()
            SettingsToggleRow(title: "确认该模型可免费使用", caption: "包含平台赠送额度时，请自行核对额度与超额收费规则。", isOn: $confirmedFree)
            SettingsDivider()
            SettingsRow(title: "提交模型", caption: "OpenRouter 模型须在当前免费目录内；其他平台使用你确认的能力。") {
                ActionButton(gateway.pool.members.contains { $0.providerID == providerID && $0.model == modelID } ? "更新池内模型" : "加入 Auto 池") { addManual() }
                    .disabled(providerID == nil || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !confirmedFree || Int(context) == nil)
            }
        }.disabled(!editable)
    }

    private var discovery: some View {
        SettingsGroup(title: "发现免费模型 · OpenRouter", caption: "只纳入目录中所有已公布价格均为零的文本模型。路由时额外设置零价格上限；收费变化或下架后会跳过，绝不退回付费模型。") {
            SettingsRow(title: "OpenRouter 凭据", caption: "发现目录可匿名读取；请求模型需要已配置的 API Key。") {
                HStack {
                    Picker("OpenRouter 凭据", selection: binding(\.openRouterProviderID)) {
                        Text("选择供应商").tag(UUID?.none)
                        ForEach(openRouter) { Text($0.name).tag(Optional($0.id)) }
                    }.labelsHidden().frame(width: 190)
                    ActionButton("添加", action: onAddOpenRouter)
                }
            }
            SettingsDivider()
            SettingsToggleRow(title: "定期发现免费模型", isOn: binding(\.discoveryEnabled))
            SettingsDivider()
            SettingsRow(title: "发现间隔") {
                Picker("发现间隔", selection: binding(\.refreshHours)) {
                    ForEach([1, 6, 24], id: \.self) { Text("\($0) 小时").tag($0) }
                }.labelsHidden().frame(width: 130)
            }
            SettingsDivider()
            SettingsToggleRow(title: "自动加入新发现模型", caption: "默认关闭；开启后，将新发现模型加入所选 OpenRouter 供应商的池。", isOn: binding(\.automaticallyJoin))
            SettingsDivider()
            SettingsRow(title: "免费目录 · \(gateway.pool.catalog.count)", caption: gateway.pool.discoveredAt.map { "更新于 " + $0.formatted() } ?? "尚未发现免费模型。") {
                ActionButton(gateway.discovering ? "发现中…" : "立即发现") { gateway.discover() }
                    .disabled(gateway.discovering)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s12) {
                TextField("搜索免费模型", text: $query).textFieldStyle(InstrumentFieldStyle())
                if !gateway.pool.catalog.isEmpty && results.isEmpty {
                    Text("没有匹配的免费模型。") .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
                ForEach(results) { model in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.name).font(Theme.Font.bodySmall).foregroundStyle(Theme.textPrimary)
                            Text(model.id).font(Theme.Font.captionMono).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(model.contextLength.formatted()) 上下文\(model.supportsTools ? " · 工具" : "")\(model.supportsImages ? " · 图片" : "")")
                                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 8)
                        let joined = gateway.pool.members.contains { $0.model == model.id && $0.providerID == gateway.pool.openRouterProviderID }
                        ActionButton(joined ? "已加入" : "加入") { gateway.add(model) }
                            .disabled(joined || gateway.pool.openRouterProviderID == nil)
                    }
                }
            }.padding(.horizontal, 20).padding(.bottom, 16)
        }.disabled(!editable)
    }

    private var activity: some View {
        SettingsGroup(title: "网关状态", caption: "仅保留本次运行最近 40 次尝试的模型、状态与延迟，不记录请求正文。延迟指上游响应头耗时。") {
            SettingsRow(title: "已接收 \(gateway.snapshot.requests) 个请求 · 处理中 \(gateway.snapshot.active)") {
                ActionButton("重置冷却") { gateway.resetHealth() }
            }
            ForEach(gateway.snapshot.routes) { route in
                SettingsDivider()
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(route.model).font(Theme.Font.captionMono).foregroundStyle(Theme.textPrimary)
                        Text("\(route.provider) · \(route.difficulty.rawValue)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        Text("\(route.routing.kind.title) · \(route.routing.source.title) · \(route.routing.reason) · \(route.selection)")
                            .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(route.status == 0 ? "已中断" : "HTTP \(route.status)")
                    Text("\(route.latency, specifier: "%.2f") 秒")
                }.font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 20).padding(.vertical, 10)
            }
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<FreeModelPool, Value>) -> Binding<Value> {
        Binding(get: { gateway.pool[keyPath: key] }, set: { newValue in gateway.change { $0[keyPath: key] = newValue } })
    }
    private func move(_ member: FreeModelPool.Member, by offset: Int) {
        gateway.change { value in
            guard let index = value.members.firstIndex(where: { $0.id == member.id }),
                  value.members.indices.contains(index + offset) else { return }
            value.members.swapAt(index, index + offset)
        }
    }
    private func addManual() {
        guard let provider = selected, let length = Int(context), length > 0 else { return }
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if FreeModelPool.isOpenRouter(provider.baseURL) {
            guard let found = gateway.pool.catalog.first(where: { $0.id == model }) else {
                gateway.error = "该 OpenRouter 模型不在当前免费目录中，请先发现并核对完整 ID。"; return
            }
            gateway.change { value in
                var member = found.member(providerID: provider.id)
                member.difficulties = difficulties
                if let index = value.members.firstIndex(where: { $0.id == member.id }) {
                    member.enabled = value.members[index].enabled
                    value.members[index] = member
                } else { value.members.append(member) }
            }
        } else {
            gateway.change { value in
                let member = FreeModelPool.Member(providerID: provider.id, model: model, name: model,
                    contextLength: length, supportsTools: tools, supportsImages: images, supportsJSON: json,
                    difficulties: difficulties)
                if let index = value.members.firstIndex(where: { $0.id == member.id }) {
                    var updated = member; updated.enabled = value.members[index].enabled
                    value.members[index] = updated
                } else { value.members.append(member) }
            }
        }
        confirmedFree = false
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
