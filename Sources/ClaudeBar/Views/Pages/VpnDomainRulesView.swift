import SwiftUI

/// Rules live in the VPN workspace's trailing panel, alongside node management.
struct VpnDomainRulesView: View {
    var onClose: () -> Void = {}
    @ObservedObject private var manager = VpnManager.shared
    @State private var rules: [VpnDomainRule] = []
    @State private var domain = ""
    @State private var route = VpnDomainRule.Route.direct
    @State private var includesSubdomains = true
    @State private var query = ""
    @State private var filter: VpnDomainRule.Route?
    @State private var message: String?
    @State private var saved = false
    @FocusState private var domainFocused: Bool

    private var visibleRules: [VpnDomainRule] {
        VpnDomainRules.ordered(rules).filter {
            (filter == nil || $0.route == filter) && (query.isEmpty || $0.domain.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(24)
            HairlineDivider()
            composer.padding(24)
            HairlineDivider()
            listToolbar.padding(.horizontal, 24).padding(.vertical, 16)
            listHeader
            ScrollView {
                LazyVStack(spacing: 0) {
                    if visibleRules.isEmpty {
                        emptyState
                    } else {
                        ForEach(visibleRules) { rule in
                            ruleRow(rule)
                            HairlineDivider().padding(.horizontal, 24)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            HairlineDivider()
            footer.padding(24)
        }
        .background(Theme.cardSurface)
        .foregroundColor(Theme.textPrimary)
        .onAppear { rules = VpnDomainRules.load() }
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("域名规则").font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("决定哪些域名直连，哪些跟随主代理组。")
                    .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
            }
            Spacer()
            ActionButton("关闭", symbol: "xmark", action: onClose)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                InstrumentField(focused: domainFocused, onCard: true) {
                    HStack(spacing: 10) {
                        AppGlyph(name: "globe", size: 16).foregroundColor(Theme.textSecondary)
                        TextField("example.com", text: $domain)
                            .textFieldStyle(.plain).font(Theme.Font.body)
                            .focused($domainFocused).onSubmit { addRule() }
                            .accessibilityLabel("添加规则的域名")
                    }
                    .padding(.horizontal, 12).frame(height: 42)
                }
                routeSelector(route, select: { route = $0 })
                ActionButton("添加规则", symbol: "plus", emphasis: .primary) { addRule() }
                    .disabled(domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Toggle("包含子域名", isOn: $includesSubdomains)
                    .toggleStyle(.checkbox).font(Theme.Font.caption)
                Spacer()
                Text("手动规则优先 · 更具体的域名优先")
                    .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            }
            if let message {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(Theme.Font.caption).foregroundColor(Theme.Ink.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var listToolbar: some View {
        HStack(spacing: 16) {
            Menu {
                Button("全部规则 · \(rules.count)") { filter = nil }
                ForEach(VpnDomainRule.Route.allCases, id: \.self) { item in
                    Button("\(item.title) · \(rules.filter { $0.route == item }.count)") { filter = item }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(filter?.title ?? "全部规则").font(Theme.Font.bodySmall.weight(.semibold))
                    Text("\(visibleRules.count)").font(Theme.Font.captionMono).foregroundColor(Theme.textSecondary)
                    AppGlyph(name: "chevron.down", size: 10)
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 150, alignment: .leading)
            Spacer()
            InstrumentSearchField(prompt: "搜索域名", text: $query).frame(width: 220)
        }
    }

    private var listHeader: some View {
        HStack(spacing: 16) {
            Text("域名").frame(maxWidth: .infinity, alignment: .leading)
            Text("匹配范围").frame(width: 130, alignment: .leading)
            Text("连接方式").frame(width: 144, alignment: .leading)
            Color.clear.frame(width: 30, height: 1)
        }
        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 24).frame(height: 32)
        .background(Theme.bgSecondary.opacity(0.65))
    }

    private func ruleRow(_ rule: VpnDomainRule) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                AppGlyph(name: rule.route == .direct ? "arrow.right" : "arrow.triangle.branch", size: 14)
                    .foregroundColor(rule.route == .direct ? Theme.Ink.success : Theme.Ink.claude)
                Text(rule.domain).font(Theme.Font.bodySmall.weight(.medium))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(rule.domain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("仅此域名") { setScope(rule, includesSubdomains: false) }
                Button("含子域名") { setScope(rule, includesSubdomains: true) }
            } label: {
                Text(rule.includesSubdomains ? "含子域名" : "仅此域名").font(Theme.Font.caption)
            }
            .menuStyle(.borderlessButton).frame(width: 130, alignment: .leading)
            routeSelector(rule.route) { selected in
                var updated = rules
                if let index = updated.firstIndex(where: { $0.id == rule.id }) {
                    updated[index].route = selected
                    persist(updated)
                }
            }
            .frame(width: 144, alignment: .leading)
            Button { persist(rules.filter { $0.id != rule.id }) } label: {
                AppGlyph(name: "trash", size: 14).frame(width: 30, height: 32)
            }
            .buttonStyle(.plain).foregroundColor(Theme.textSecondary)
            .accessibilityLabel("删除 \(rule.domain) 规则").help("删除规则")
        }
        .padding(.horizontal, 24).frame(height: 58)
    }

    private func routeSelector(_ selected: VpnDomainRule.Route,
                               select: @escaping (VpnDomainRule.Route) -> Void) -> some View {
        SegmentedCapsule(items: VpnDomainRule.Route.allCases, selection: selected,
                         title: { $0.title }, tint: selected == .direct ? Theme.Ink.success : Theme.Ink.claude,
                         onSelect: select)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("连接方式")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            AppGlyph(name: rules.isEmpty ? "arrow.triangle.branch" : "magnifyingglass", size: 24)
                .foregroundColor(Theme.textSecondary)
            Text(rules.isEmpty ? "从一个域名开始" : "没有匹配的规则").font(Theme.Font.bodySmall.weight(.medium))
            Text(rules.isEmpty ? "输入域名，选择直连或代理，然后添加规则。" : "试试其他关键词或切换规则类型。")
                .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 56)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Label(saved ? "已保存，待应用" : "规则自动保存", systemImage: saved ? "checkmark.circle" : "checkmark.shield")
                    .font(Theme.Font.caption.weight(.medium)).foregroundColor(saved ? Theme.Ink.success : Theme.textSecondary)
                Text(manager.isRunning ? "重启 VPN 后生效，现有连接可能中断。" : "下次启动 VPN 时生效。")
                    .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            }
            Spacer()
            ActionButton("重启并应用", symbol: "arrow.clockwise", emphasis: .primary) {
                manager.reloadConfig()
                onClose()
            }
            .disabled(!manager.isRunning)
        }
    }

    private func setScope(_ rule: VpnDomainRule, includesSubdomains: Bool) {
        guard !rules.contains(where: { $0.id != rule.id && $0.domain == rule.domain && $0.includesSubdomains == includesSubdomains }) else {
            message = "此域名已有相同匹配范围的规则，请修改已有规则。"
            return
        }
        var updated = rules
        if let index = updated.firstIndex(where: { $0.id == rule.id }) {
            updated[index].includesSubdomains = includesSubdomains
            persist(updated)
        }
    }

    private func addRule() {
        guard let normalized = VpnDomainRules.normalize(domain) else {
            message = "请输入域名，不含协议、端口或路径；国际化域名使用 Punycode。"
            return
        }
        guard !rules.contains(where: { $0.domain == normalized && $0.includesSubdomains == includesSubdomains }) else {
            message = "此域名规则已存在，请直接修改连接方式。"
            return
        }
        if persist(rules + [VpnDomainRule(domain: normalized, includesSubdomains: includesSubdomains, route: route)]) {
            domain = ""
            domainFocused = true
        }
    }

    @discardableResult
    private func persist(_ updated: [VpnDomainRule]) -> Bool {
        do {
            try VpnDomainRules.save(updated)
            rules = updated
            message = nil
            saved = true
            return true
        } catch {
            message = "保存失败：\(error.localizedDescription)"
            return false
        }
    }
}
