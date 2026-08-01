import SwiftUI

struct ProviderRow: View {
    let provider: Provider
    let isActive: Bool
    let isExpanded: Bool
    let currentModelName: String?
    let onToggleExpand: () -> Void
    let onActivateModel: (UUID) -> Void

    private var isSingleModel: Bool { provider.models.count <= 1 }
    private var accentColor: Color { Color(red: 0.29, green: 0.56, blue: 0.85) }

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
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                    if let model = provider.models.first {
                        Text(model.name)
                            .font(.system(size: 10))
                            .foregroundColor(isActive ? accentColor : Color.white.opacity(0.4))
                    }
                }
                Spacer()
                if isActive && provider.models.first?.name == currentModelName {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundColor(.green)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color(red: 0.15, green: 0.35, blue: 0.55) : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isActive ? accentColor.opacity(0.4) : Color.clear, lineWidth: 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expandable

    private var expandableHeader: some View {
        Button(action: onToggleExpand) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.5)).frame(width: 10)

                Text(provider.name)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundColor(.white.opacity(0.9)).lineLimit(1)

                Spacer()

                if isActive {
                    Text("active").font(.system(size: 9, weight: .medium)).foregroundColor(.green)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.15)))
                }
                Text("\(provider.models.count) models")
                    .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.35))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color(red: 0.15, green: 0.35, blue: 0.55, opacity: 0.5) : Color.clear))
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
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(modelNameMatches(model) ? .white : .white.opacity(0.75))
                    .lineLimit(1)
                Spacer()
                if !model.contextTokens.isEmpty {
                    Text(formatContext(model.contextTokens))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.35))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                }
                if modelNameMatches(model) && isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold)).foregroundColor(.green)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(modelNameMatches(model) && isActive ? accentColor.opacity(0.15) : Color.clear))
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
            Circle().strokeBorder(isSelected ? accentColor : Color.gray.opacity(0.4), lineWidth: 1.5)
                .frame(width: 13, height: 13)
            if isSelected {
                Circle().fill(accentColor).frame(width: 7, height: 7)
            }
        }
    }
}
