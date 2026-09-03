import SwiftUI

/// Pick which remote model IDs to add after a `/models` fetch.
struct ModelImportSheet: View {
    let candidates: [String]
    let existingNames: Set<String>
    let onImport: (Set<String>) -> Void
    let onCancel: () -> Void

    @State private var selection: Set<String>
    @State private var filter = ""

    init(candidates: [String], existingNames: Set<String>,
         onImport: @escaping (Set<String>) -> Void, onCancel: @escaping () -> Void) {
        self.candidates = candidates
        self.existingNames = existingNames
        self.onImport = onImport
        self.onCancel = onCancel
        let importable = candidates.filter { !existingNames.contains($0.lowercased()) }
        _selection = State(initialValue: Set(importable))
    }

    private var filtered: [String] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return candidates }
        return candidates.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            Text("选择要导入的模型")
                .font(Theme.Font.titleSmall)
                .foregroundColor(Theme.textPrimary)

            Text("共 \(candidates.count) 个可用 · 已选 \(selection.count) 个")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textSecondary)

            TextField("筛选模型名称", text: $filter)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: Theme.Space.s8) {
                Button("全选可导入") { selectAllImportable() }
                    .adaptiveGlassButton()
                Button("清空") { selection.removeAll() }
                    .adaptiveGlassButton()
                Spacer()
            }

            List {
                ForEach(filtered, id: \.self) { name in
                    let exists = existingNames.contains(name.lowercased())
                    Button {
                        guard !exists else { return }
                        if selection.contains(name) {
                            selection.remove(name)
                        } else {
                            selection.insert(name)
                        }
                    } label: {
                        HStack(spacing: Theme.Space.s8) {
                            Image(systemName: exists
                                  ? "checkmark.circle.fill"
                                  : (selection.contains(name) ? "checkmark.circle.fill" : "circle"))
                                .foregroundColor(exists ? Theme.textTertiary()
                                                 : (selection.contains(name) ? Theme.claude : Theme.textSecondary))
                            Text(name)
                                .font(Theme.Font.microMono)
                                .foregroundColor(exists ? Theme.textTertiary() : Theme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            if exists {
                                Text("已存在")
                                    .font(Theme.Font.caption)
                                    .foregroundColor(Theme.textTertiary())
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(exists)
                }
            }
            .listStyle(.plain)

            HStack {
                Button("取消", action: onCancel)
                    .adaptiveGlassButton()
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("导入选中 (\(selection.count))") {
                    onImport(selection)
                }
                .adaptiveGlassButton(prominent: true)
                .tint(Theme.claude)
                .disabled(selection.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.s16)
        .frame(width: 480, height: 460)
    }

    private func selectAllImportable() {
        selection = Set(candidates.filter { !existingNames.contains($0.lowercased()) })
    }
}
