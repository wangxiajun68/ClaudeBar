import SwiftUI

/// A single, quiet panel per purpose. The header belongs to the panel rather
/// than floating between unrelated controls; settings never hover or lift.
struct SettingsGroup<Content: View>: View {
    let title: String
    var symbol: String = ""
    var caption: String = ""
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                if !symbol.isEmpty {
                    AppGlyph(name: symbol, size: 15).foregroundColor(Theme.Ink.claude)
                }
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textPrimary).accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            SettingsDivider()
            VStack(spacing: 0, content: content)
            if !caption.isEmpty {
                Text(caption).font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline))
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var caption: String = ""
    @ViewBuilder var control: () -> Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                description.frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                control().controlSize(.small).fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 12) {
                description
                control().controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(minHeight: 64)
        .accessibilityElement(children: .contain)
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textPrimary)
            if !caption.isEmpty {
                Text(caption).font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        HairlineDivider(inset: 20).accessibilityHidden(true)
    }
}

struct SettingsToggleRow: View {
    let title: String
    var caption: String = ""
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, caption: caption) {
            Toggle(title, isOn: $isOn).labelsHidden()
                .toggleStyle(InstrumentToggleStyle(showsLabel: false, width: 48))
                .accessibilityLabel(title)
        }
    }
}
