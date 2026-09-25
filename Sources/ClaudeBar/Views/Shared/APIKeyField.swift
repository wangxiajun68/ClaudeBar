import SwiftUI

/// API tokens are not account passwords. Use a normal text input while editing
/// so macOS does not offer Passwords/strong-password AutoFill. Mask at rest.
struct APIKeyField: View {
    @Binding var text: String
    /// Set for loopback endpoints, where the runtime serves without auth and
    /// the key exists only to satisfy the client's non-empty header. Without
    /// this the field reads as "required and missing" on a healthy local server.
    var localEndpoint = false
    @State private var editing = false
    @FocusState private var focused: Bool

    private var placeholder: String {
        localEndpoint ? "本机服务无需 Key（留空即可）" : "填写或粘贴 API Key"
    }

    private var restText: String {
        if !text.isEmpty { return "••••••••••••••••" }
        return placeholder
    }

    var body: some View {
        HStack(spacing: 8) {
            if editing {
                TextField(placeholder, text: $text)
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
                    Text(restText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        // The key's read state is still a *field*: the same
                        // recessed well and rim as the editable state above it,
                        // so toggling edit does not swap one box design for
                        // another.
                        .instrumentWell(radius: Theme.Radius.md)
                }.buttonStyle(.plain).accessibilityLabel(text.isEmpty ? placeholder : "编辑已保存的 API Key")
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
