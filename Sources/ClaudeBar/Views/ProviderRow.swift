import SwiftUI

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
    /// Initial expansion state. Collapsed by default so every tile in a grid
    /// row has the same height regardless of model count; the chevron expands
    /// in place.
    var startsExpanded: Bool = false

    @State private var isExpanded: Bool?
    @State private var isHovered = false

    private var expanded: Bool { isExpanded ?? startsExpanded }

    /// The model the env currently points at, falling back to the first model
    /// when settings.json names a model this provider doesn't declare.
    private var activeModel: ModelConfig? {
        provider.models.first {
            $0.name.caseInsensitiveCompare(currentModelName ?? "") == .orderedSame
        } ?? provider.models.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            header
            // Model rows render only while expanded; collapsed tiles are
            // uniform, keeping grid rows even across providers.
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
