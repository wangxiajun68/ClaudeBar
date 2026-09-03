import SwiftUI

/// A provider as one tile: name + active capsule, active-model line, model
/// count, and — expanded — the model rows in-tile, separated by hairlines.
/// Shared by the providers page and the popup's dense 2-col grid.
struct ProviderTile: View {
    let provider: Provider
    let isActive: Bool
    let currentModelName: String?
    let onActivateModel: (UUID) -> Void
    var onToggleCapture: (() -> Void)? = nil
    var testOutcome: ConnectivityOutcome = .idle
    var onTest: (() -> Void)? = nil

    /// Popup density: tighter fonts/padding, single-column model list.
    var dense: Bool = false
    /// Initial expansion state. Collapsed by default so every tile in a grid
    /// row has the same height regardless of model count; the chevron expands
    /// in place.
    var startsExpanded: Bool = false

    @State private var isExpanded: Bool?
    @State private var isHovered = false

    private var expanded: Bool { isExpanded ?? startsExpanded }

    /// Collapsed multi-model tiles show only the active row so they match
    /// single-model tiles; expanding reveals the rest.
    private var listedModels: [ModelConfig] {
        guard !provider.models.isEmpty else { return [] }
        if expanded || provider.models.count == 1 { return provider.models }
        if let active = activeModel { return [active] }
        return Array(provider.models.prefix(1))
    }

    /// The model the env currently points at, falling back to the first model
    /// when settings.json names a model this provider doesn't declare.
    private var activeModel: ModelConfig? {
        provider.models.first {
            $0.name.caseInsensitiveCompare(currentModelName ?? "") == .orderedSame
        } ?? provider.models.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(alignment: .top, spacing: Theme.Space.s6) {
                header
                    .frame(maxWidth: .infinity, alignment: .leading)
                if onTest != nil {
                    ConnectivityTileButton(outcome: testOutcome, action: { onTest?() })
                }
                captureToggle
            }
            if !listedModels.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(listedModels) { model in
                        modelRow(model)
                    }
                }
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .padding(dense ? Theme.Space.s8 : Theme.Space.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile(hovered: isHovered, dense: dense)
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle()
                    .fill(Theme.claude)
                    .frame(width: 2)
                    .clipShape(RoundedRectangle(cornerRadius: 1))
            }
        }
        .hoverState($isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.name)，\(isActive ? "当前" : "未激活")，\(provider.models.count) 个模型")
    }

    @ViewBuilder
    private var header: some View {
        Button(action: headerAction) {
            headerStack(activeModelName: activeModel?.name, accent: Theme.accent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(headerHelp)
        .disabled(provider.models.isEmpty)
    }

    private var captureToggle: some View {
        Button {
            onToggleCapture?()
        } label: {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(Theme.Font.bodySmall.weight(.semibold))
                .foregroundColor(provider.captureEnabled ? Theme.external : Theme.textTertiary(0.4))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(onToggleCapture == nil ? 0 : 1)
        .allowsHitTesting(onToggleCapture != nil)
        .help(provider.captureEnabled
              ? "关闭流量记录，请求直连上游"
              : "启用流量记录，请求将显示在「流量」页")
        .accessibilityLabel(provider.captureEnabled ? "关闭流量记录" : "启用流量记录")
    }

    private var headerHelp: String {
        if provider.models.count > 1 { return expanded ? "收起模型" : "展开模型" }
        if provider.models.count == 1 { return isActive ? "当前供应商" : "切换到此供应商" }
        return ""
    }

    private func headerAction() {
        if provider.models.count > 1 {
            toggleExpanded()
        } else if let id = provider.models.first?.id {
            onActivateModel(id)
        }
    }

    private func headerStack(activeModelName: String?, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            HStack(spacing: Theme.Space.s6) {
                Text(provider.name)
                    .font(dense ? Theme.Font.rowTitle : Theme.Font.titleSmall)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if isActive {
                    Text("当前")
                        .font(Theme.Font.microMedium)
                        .foregroundColor(Theme.statusBusy)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.statusBusy.opacity(0.15)))
                        .transition(.scale.combined(with: .opacity))
                }
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(Theme.Font.bodySmall.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .opacity(provider.models.count > 1 ? 1 : 0)
            }
            Text(activeModelName ?? " ")
                .font(dense ? Theme.Font.microMono : Theme.Font.captionMono)
                .foregroundColor(isActive ? accent : Theme.textTertiary())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                Text("\(provider.models.count) 个模型")
                    .font(Theme.Font.tileDetail)
                    .foregroundColor(Theme.textTertiary(0.35))
                Spacer(minLength: 0)
            }
        }
    }

    private func toggleExpanded() {
        guard provider.models.count > 1 else { return }
        withAnimation(Theme.Animation.snappy) { isExpanded = !expanded }
    }

    // MARK: Model row (in-tile, reuses ActiveTileEdge)

    private func modelRow(_ model: ModelConfig) -> some View {
        let selected = isActive
            && model.name.caseInsensitiveCompare(currentModelName ?? "") == .orderedSame
        return Button(action: { onActivateModel(model.id) }) {
            HStack(spacing: Theme.Space.s6) {
                radioIndicator(isSelected: selected)
                Text(model.name)
                    .font(dense ? Theme.Font.microMono : Theme.Font.captionMono)
                    .foregroundColor(selected ? Theme.textPrimary : Theme.textTertiary(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if !model.contextTokens.isEmpty {
                    Text(formatContext(model.contextTokens))
                        .font(Theme.Font.microMedium)
                        .foregroundColor(Theme.textTertiary(0.35))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.cardFill(0.06)))
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(Theme.Font.microSemibold).foregroundColor(Theme.statusBusy)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .modifier(ActiveTileEdge(isActive: selected, selected: selected, corner: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Compact context-window label: 200000 → "200K", 1000000 → "1M".
    private func formatContext(_ tokens: String) -> String {
        guard let n = Int(tokens), n > 0 else { return tokens }
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return m == m.rounded() ? "\(Int(m))M" : String(format: "%.1fM", m)
        } else if n >= 1_000 {
            return "\(Int(round(Double(n) / 1_000)))K"
        }
        return tokens
    }

    private func radioIndicator(isSelected: Bool) -> some View {
        ZStack {
            Circle().strokeBorder(isSelected ? Theme.accent : Theme.statusIdle.opacity(0.4), lineWidth: 1.5)
                .frame(width: 13, height: 13)
            if isSelected {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Theme.Animation.bouncy, value: isSelected)
    }
}

// MARK: - Codex Provider Tile

/// Codex flavor of `ProviderTile` — same tile chrome, Codex tint, model rows
/// route through `CodexProviderStore.activate`.
struct CodexProviderTile: View {
    let provider: CodexProvider
    let isActive: Bool
    let activeModelID: UUID?
    let onActivateModel: (UUID) -> Void

    var dense: Bool = false
    var startsExpanded: Bool = false

    @State private var isExpanded: Bool?
    @State private var isHovered = false

    private var expanded: Bool { isExpanded ?? startsExpanded }

    private var listedModels: [CodexModelConfig] {
        guard !provider.models.isEmpty else { return [] }
        if expanded || provider.models.count == 1 { return provider.models }
        if let id = activeModelID ?? provider.models.first?.id,
           let active = provider.models.first(where: { $0.id == id }) {
            return [active]
        }
        return Array(provider.models.prefix(1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            header
            if !listedModels.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(listedModels) { model in
                        modelRow(model)
                    }
                }
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .padding(dense ? Theme.Space.s8 : Theme.Space.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile(tint: Theme.codex.opacity(0.06), hovered: isHovered, dense: dense)
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle()
                    .fill(Theme.codex)
                    .frame(width: 2)
                    .clipShape(RoundedRectangle(cornerRadius: 1))
            }
        }
        .hoverState($isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.name)，\(isActive ? "当前" : "未激活")，\(provider.models.count) 个模型")
    }

    @ViewBuilder
    private var header: some View {
        Button(action: headerAction) {
            headerStack.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(headerHelp)
        .disabled(provider.models.isEmpty)
    }

    private var headerHelp: String {
        if provider.models.count > 1 { return expanded ? "收起模型" : "展开模型" }
        if provider.models.count == 1 { return isActive ? "当前供应商" : "切换到此供应商" }
        return ""
    }

    private func headerAction() {
        if provider.models.count > 1 {
            toggleExpanded()
        } else if let id = provider.models.first?.id {
            onActivateModel(id)
        }
    }

    private var headerStack: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            HStack(spacing: Theme.Space.s6) {
                Text(provider.name)
                    .font(dense ? Theme.Font.rowTitle : Theme.Font.titleSmall)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if isActive {
                    Text("当前")
                        .font(Theme.Font.microMedium)
                        .foregroundColor(Theme.statusBusy)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.statusBusy.opacity(0.15)))
                        .transition(.scale.combined(with: .opacity))
                }
                if provider.captureEnabled {
                    Text("记录")
                        .font(Theme.Font.microMedium)
                        .foregroundColor(Theme.external)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.external.opacity(0.15)))
                }
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(Theme.Font.bodySmall.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .opacity(provider.models.count > 1 ? 1 : 0)
            }
            Text(provider.activeModel?.name ?? " ")
                .font(dense ? Theme.Font.microMono : Theme.Font.captionMono)
                .foregroundColor(isActive ? Theme.codex : Theme.textTertiary())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                Text("\(provider.models.count) 个模型")
                    .font(Theme.Font.tileDetail)
                    .foregroundColor(Theme.textTertiary(0.35))
                Spacer(minLength: 0)
            }
        }
    }

    private func toggleExpanded() {
        guard provider.models.count > 1 else { return }
        withAnimation(Theme.Animation.snappy) { isExpanded = !expanded }
    }

    private func modelRow(_ model: CodexModelConfig) -> some View {
        let selected = isActive && model.id == (activeModelID ?? provider.models.first?.id)
        return Button(action: { onActivateModel(model.id) }) {
            HStack(spacing: Theme.Space.s6) {
                radioIndicator(isSelected: selected)
                Text(model.name)
                    .font(dense ? Theme.Font.microMono : Theme.Font.captionMono)
                    .foregroundColor(selected ? Theme.textPrimary : Theme.textTertiary(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if !model.contextWindow.isEmpty, let n = Int(model.contextWindow), n > 0 {
                    Text(formatContext(model.contextWindow))
                        .font(Theme.Font.microMedium)
                        .foregroundColor(Theme.textTertiary(0.35))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.cardFill(0.06)))
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(Theme.Font.microSemibold).foregroundColor(Theme.statusBusy)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .modifier(ActiveTileEdge(isActive: selected, selected: selected, corner: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formatContext(_ tokens: String) -> String {
        guard let n = Int(tokens), n > 0 else { return tokens }
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return m == m.rounded() ? "\(Int(m))M" : String(format: "%.1fM", m)
        } else if n >= 1_000 {
            return "\(Int(round(Double(n) / 1_000)))K"
        }
        return tokens
    }

    private func radioIndicator(isSelected: Bool) -> some View {
        ZStack {
            Circle().strokeBorder(isSelected ? Theme.codex : Theme.statusIdle.opacity(0.4), lineWidth: 1.5)
                .frame(width: 13, height: 13)
            if isSelected {
                Circle().fill(Theme.codex).frame(width: 7, height: 7)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Theme.Animation.bouncy, value: isSelected)
    }
}
