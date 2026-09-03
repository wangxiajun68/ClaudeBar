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

    @State private var showPresetPicker = false

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
                    .help("从 Claude 供应商导入")
                }

                Spacer(minLength: 0)

                Button(action: onDuplicate) {
                    Image(systemName: "doc.on.doc")
                }
                .adaptiveGlassButton()
                .disabled(!canDuplicateOrDelete)
                .help("复制")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .adaptiveGlassButton()
                .disabled(!canDuplicateOrDelete)
                .help("删除")
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
    }
}
