import SwiftUI

/// API tokens are not account passwords. Use a normal text input while editing
/// so macOS does not offer Passwords/strong-password AutoFill. Mask at rest.
struct APIKeyField: View {
    @Binding var text: String
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if editing {
                TextField("填写或粘贴 API Key", text: $text)
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .textFieldStyle(ProviderInputStyle())
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                    .onSubmit { editing = false }
            } else {
                Button {
                    editing = true
                    focused = true
                } label: {
                    Text(text.isEmpty ? "填写或粘贴 API Key" : "••••••••••••••••")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Theme.bgPrimary, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.textSecondary.opacity(0.25)))
                }.buttonStyle(.plain).accessibilityLabel(text.isEmpty ? "填写 API Key" : "编辑已保存的 API Key")
            }
            Button {
                editing.toggle()
                focused = editing
            } label: { Image(systemName: editing ? "eye.slash" : "eye") }
                .buttonStyle(.plain).help(editing ? "隐藏 Key" : "显示并编辑 Key")
        }
        .onChange(of: focused) { _, value in if !value { editing = false } }
        .onChange(of: editing) { _, value in if value { focused = true } }
    }
}
