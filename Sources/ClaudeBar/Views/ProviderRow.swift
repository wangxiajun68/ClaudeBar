import SwiftUI

// MARK: - Provider tile (宫格)

/// A provider as one tile: name + active capsule, active-model line, model
/// count, and — expanded — the model rows in-tile, separated by hairlines.
/// Shared by the providers page and the popup's dense 2-col grid.
struct ProviderTile: View {
    let provider: Provider
    let isActive: Bool
    let currentModelName: String?
    let onActivateModel: (UUID) -> Void

    /// Popup density: tighter fonts/padding, single-column model list.
    var dense: Bool = false
    /// Start expanded — off by default so every tile in the grid keeps the
    /// same collapsed height regardless of model count (uneven rows were the
    /// "sizes differ" complaint); the chevron expands in place.
    var startsExpanded: Bool = false

    @State private var isExpanded: Bool?
    @State private var isHovered = false

    private var expanded: Bool { isExpanded ?? startsExpanded }

    private var activeModel: ModelConfig? {
        provider.models.first {
            $0.name.caseInsensitiveCompare(currentModelName ?? "") == .orderedSame
        } ?? provider.models.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            header
            // Model rows only when expanded — collapsed tiles are uniform,
            // so the grid rows stay even no matter how many models each
            // provider has.
            if expanded && !provider.models.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(provider.models) { model in
                        modelRow(model)
                    }
                }
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .padding(dense ? Theme.Space.s8 : Theme.Space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .accessibilityLabel("\(provider.name)，\(isActive ? "活跃" : "未激活")，\(provider.models.count) 个模型")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            HStack(spacing: Theme.Space.s6) {
                Text(provider.name)
                    .font(dense ? Theme.Font.rowTitle : Theme.Font.titleSmall)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if isActive {
                    Text("active")
                        .font(Theme.Font.microMedium)
                        .foregroundColor(Theme.statusBusy)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.statusBusy.opacity(0.15)))
                        .transition(.scale.combined(with: .opacity))
                }
                if provider.models.count > 1 {
                    Button(action: {
                        withAnimation(Theme.Animation.snappy) {
                            isExpanded = !(expanded)
                        }
                    }) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(Theme.Font.micro)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            // Always rendered (space-reserved) so tiles in the same grid row
            // keep equal height regardless of whether a model is active.
            Text(activeModel?.name ?? " ")
                .font(dense ? Theme.Font.microMono : Theme.Font.captionMono)
                .foregroundColor(isActive ? Theme.accent : Theme.textTertiary())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                Text("\(provider.models.count) models")
                    .font(Theme.Font.tileDetail)
                    .foregroundColor(Theme.textTertiary(0.35))
                Spacer(minLength: 0)
            }
        }
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

    /// 200000 → "200K", 1000000 → "1M", 128000 → "128K".
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

// MARK: - Legacy row (still used where a row is the right shape)

struct ProviderRow: View {
    let provider: Provider
    let isActive: Bool
    let isExpanded: Bool
    let currentModelName: String?
    let onToggleExpand: () -> Void
    let onActivateModel: (UUID) -> Void

    private var isSingleModel: Bool { provider.models.count <= 1 }

    /// Case-insensitive model name match (settings.json may use different casing).
    private func modelNameMatches(_ model: ModelConfig) -> Bool {
        model.name.caseInsensitiveCompare(currentModelName ?? "") == .orderedSame
    }

    var body: some View {
        VStack(spacing: 0) {
            if isSingleModel {
                singleModelRow
            } else {
                expandableHeader
            }

            if isExpanded && !isSingleModel {
                VStack(spacing: 1) {
                    ForEach(provider.models) { model in
                        modelRow(model)
                    }
                }
                .padding(.leading, 24)
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: - Single Model

    private var singleModelRow: some View {
        Button(action: {
            if let model = provider.models.first {
                onActivateModel(model.id)
            }
        }) {
            HStack(spacing: 10) {
                radioIndicator(isSelected: isActive && provider.models.first?.name == currentModelName)

                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.name)
                        .font(Theme.Font.rowLarge.weight(isActive ? .semibold : .regular))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    if let model = provider.models.first {
                        Text(model.name)
                            .font(Theme.Font.caption)
                            .foregroundColor(isActive ? Theme.accent : Theme.textTertiary())
                    }
                }
                Spacer()
                if isActive && provider.models.first?.name == currentModelName {
                    Image(systemName: "checkmark.circle.fill")
                        .font(Theme.Font.bodySmall).foregroundColor(Theme.statusBusy)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .modifier(ActiveTileEdge(isActive: isActive, selected: isActive))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expandable

    private var expandableHeader: some View {
        Button(action: onToggleExpand) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(Theme.Font.microSemibold)
                    .foregroundColor(Theme.textTertiary(0.5)).frame(width: 10)

                Text(provider.name)
                    .font(Theme.Font.rowLarge.weight(isActive ? .semibold : .regular))
                    .foregroundColor(Theme.textPrimary).lineLimit(1)

                Spacer()

                if isActive {
                    Text("active").font(Theme.Font.microMedium).foregroundColor(Theme.statusBusy)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.statusBusy.opacity(0.15)))
                        .transition(.scale.combined(with: .opacity))
                }
                Text("\(provider.models.count) models")
                    .font(Theme.Font.caption).foregroundColor(Theme.textTertiary(0.35))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .modifier(ActiveTileEdge(isActive: isActive, selected: isActive && provider.models.first?.name == currentModelName))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Model Row

    private func modelRow(_ model: ModelConfig) -> some View {
        Button(action: { onActivateModel(model.id) }) {
            HStack(spacing: 8) {
                radioIndicator(isSelected: isActive && modelNameMatches(model))
                Text(model.name)
                    .font(Theme.Font.microMono)
                    .foregroundColor(modelNameMatches(model) ? Theme.textPrimary : Theme.textTertiary(0.75))
                    .lineLimit(1)
                Spacer()
                if !model.contextTokens.isEmpty {
                    Text(formatContext(model.contextTokens))
                        .font(Theme.Font.microMedium)
                        .foregroundColor(Theme.textTertiary(0.35))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.cardFill(0.06)))
                }
                if modelNameMatches(model) && isActive {
                    Image(systemName: "checkmark")
                        .font(Theme.Font.microSemibold).foregroundColor(Theme.statusBusy)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .modifier(ActiveTileEdge(isActive: modelNameMatches(model) && isActive, selected: modelNameMatches(model) && isActive, corner: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 200000 → "200K", 1000000 → "1M", 128000 → "128K".
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

// The de-carded selection treatment (`ActiveRowEdge`) moved to Theme.swift as
// the shared `ActiveTileEdge` so provider tiles and model rows use one modifier.
