import SwiftUI

/// Full preset picker — clearer than a cramped Menu on a narrow sidebar.
struct PresetPickerSheet: View {
    let onSelect: (CodexProvider) -> Void
    let onCancel: () -> Void

    @State private var filter = ""

    private var filtered: [(label: String, provider: CodexProvider)] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return CodexPreset.all }
        return CodexPreset.all.filter {
            $0.label.lowercased().contains(q) || $0.provider.baseURL.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            Text("选择供应商预设")
                .font(Theme.Font.titleSmall)
                .foregroundColor(Theme.textPrimary)

            Text("只需填写 API Key，地址与协议已预置。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textSecondary)

            TextField("搜索预设", text: $filter)
                .textFieldStyle(.roundedBorder)

            List {
                ForEach(filtered, id: \.label) { preset in
                    Button {
                        onSelect(preset.provider)
                    } label: {
                        HStack(alignment: .top, spacing: Theme.Space.s12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.label)
                                    .font(Theme.Font.body)
                                    .foregroundColor(Theme.textPrimary)
                                if preset.provider.baseURL.isEmpty {
                                    Text("手动填写 Base URL")
                                        .font(Theme.Font.caption)
                                        .foregroundColor(Theme.textTertiary())
                                } else {
                                    Text(preset.provider.baseURL)
                                        .font(Theme.Font.captionMono)
                                        .foregroundColor(Theme.textSecondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            Text(preset.provider.wireAPI == "chat" ? "Chat" : "Responses")
                                .font(Theme.Font.microSemibold)
                                .foregroundColor(Theme.textTertiary())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.cardFill(0.08)))
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .adaptiveGlassButton()
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Space.s16)
        .frame(width: 460, height: 480)
    }
}
