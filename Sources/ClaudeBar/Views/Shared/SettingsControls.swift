import SwiftUI

/// Settings use one quiet surface per group, with aligned rows inside it.
/// Controls keep their own accessible labels; the visible label is never the
/// only way to identify a switch or field.
struct SettingsGroup<Content: View>: View {
    let title: String
    var caption: String = ""
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0, content: content)
                .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Theme.divider, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var caption: String = ""
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                if !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .frame(minHeight: 58)
        .accessibilityElement(children: .contain)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(height: 1)
            .padding(.horizontal, 20)
            .accessibilityHidden(true)
    }
}

struct SettingsToggleRow: View {
    let title: String
    var caption: String = ""
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, caption: caption) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.claude)
                .accessibilityLabel(title)
        }
    }
}
