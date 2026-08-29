import SwiftUI

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
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Color.clear)
                        .glassEffect(.regular.tint(Theme.claude.opacity(0.16)), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
            }
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
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Color.clear)
                        .glassEffect(.regular.tint(Theme.claude.opacity(0.16)), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
            }
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
            .background {
                if modelNameMatches(model) && isActive {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.clear)
                        .glassEffect(.regular.tint(Theme.claude.opacity(0.16)), in: RoundedRectangle(cornerRadius: 4))
                }
            }
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
            Circle().strokeBorder(isSelected ? Theme.accent : Color.gray.opacity(0.4), lineWidth: 1.5)
                .frame(width: 13, height: 13)
            if isSelected {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Theme.Animation.bouncy, value: isSelected)
    }
}
