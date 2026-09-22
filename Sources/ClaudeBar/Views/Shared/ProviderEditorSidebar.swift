import SwiftUI

/// Sidebar footer for provider editors.
struct ProviderEditorSidebar: View {
    var accent: Color = Theme.claude
    var canDuplicateOrDelete: Bool
    var onNew: () -> Void
    var onPreset: (CodexProvider) -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void
    var onImportFromClaude: (() -> Void)? = nil
    /// Name of the selected provider, shown in the delete confirmation. Empty
    /// keeps the generic wording.
    var selectedName: String = ""

    @State private var showPresetPicker = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Button(action: onNew) {
                Label("新建", systemImage: "plus")
                    .font(Theme.Font.bodySmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .adaptiveGlassButton(prominent: true)
            .tint(accent)

            Button { showPresetPicker = true } label: {
                Label("从预设添加", systemImage: "sparkles")
                    .font(Theme.Font.bodySmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .adaptiveGlassButton()

            HStack(spacing: Theme.Space.s6) {
                if let onImportFromClaude {
                    Button(action: onImportFromClaude) {
                        Label("导入", systemImage: "square.and.arrow.down")
                            .font(Theme.Font.caption)
                            .lineLimit(1)
                    }
                    .adaptiveGlassButton()
                    .help("从另一侧导入供应商（不会自动同步）")
                }

                Spacer(minLength: 0)

                Button(action: onDuplicate) {
                    Image(systemName: "doc.on.doc")
                }
                .adaptiveGlassButton()
                .disabled(!canDuplicateOrDelete)
                .help("复制")
                .accessibilityLabel("复制")

                Button(role: .destructive) { confirmDelete = true } label: {
                    Image(systemName: "trash")
                }
                .adaptiveGlassButton()
                .disabled(!canDuplicateOrDelete)
                .help("删除")
                .accessibilityLabel("删除")
            }
        }
        .padding(.horizontal, Theme.Space.s8 + 2)
        .padding(.vertical, Theme.Space.s8)
        .sheet(isPresented: $showPresetPicker) {
            PresetPickerSheet(
                onSelect: { preset in
                    showPresetPicker = false
                    onPreset(preset)
                },
                onCancel: { showPresetPicker = false }
            )
        }
        // Destructive and irreversible (there is no undo), in the same window
        // where the VPN module already asks before removing a subscription.
        // The model-row "删除" in the detail pane stays immediate — it drops
        // one model from an unsaved form.
        .alert("删除供应商？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { onDelete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(selectedName.isEmpty
                 ? "该供应商及其模型配置将被移除。"
                 : "将移除「\(selectedName)」及其模型配置。")
        }
    }
}
