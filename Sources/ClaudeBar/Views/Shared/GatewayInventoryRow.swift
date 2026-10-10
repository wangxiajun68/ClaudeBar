import SwiftUI

/// Stream pulses do not re-evaluate inventory rows whose configuration and
/// health are unchanged. Only visible rows are mounted by the parent's stack.
struct GatewayInventoryRow: View, Equatable {
    var item: GatewayMapMember
    var selected: Bool
    var editable: Bool
    var canMoveUp = true
    var canMoveDown = true
    var onSelect: () -> Void
    var onEnable: (Bool) -> Void
    var onEdit: () -> Void
    var onMove: (Int) -> Void
    var onRemove: () -> Void
    @State private var hovered = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.selected == rhs.selected && lhs.editable == rhs.editable
            && lhs.canMoveUp == rhs.canMoveUp && lhs.canMoveDown == rhs.canMoveDown
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Toggle("启用 \(item.member.name)", isOn: Binding(get: { item.member.enabled }, set: onEnable))
                    .labelsHidden().toggleStyle(InstrumentToggleStyle(showsLabel: false, width: 42))
                    .disabled(!editable)
                Button(action: onSelect) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.member.name).font(Theme.Font.chromeEmph).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        Text(item.member.model).font(Theme.Font.captionMono).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help("\(item.member.model)\n点击在拓扑中查看和分配任务")
                Menu {
                    Button("查看模型详情", action: onSelect)
                    Button("编辑模型能力", action: onEdit).disabled(item.member.discovered)
                    Button("上移优先级") { onMove(-1) }.disabled(!canMoveUp)
                    Button("下移优先级") { onMove(1) }.disabled(!canMoveDown)
                    Button("移出模型池", role: .destructive, action: onRemove)
                } label: { AppGlyph(name: "ellipsis", size: 16).frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).fixedSize().disabled(!editable)
                .accessibilityLabel("\(item.member.name) 模型操作")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { facts; Spacer(minLength: 8); coverage; state }
                VStack(alignment: .leading, spacing: 8) { facts; HStack { coverage; Spacer(); state } }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 15)
        .background(selected ? Theme.cursor.opacity(Theme.isDark ? 0.12 : 0.05) : (hovered ? Theme.cardFill(0.02) : .clear),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .onHover { hovered = $0 }
        .overlay(alignment: .bottom) { HairlineDivider().padding(.horizontal, 12) }
    }
    private var facts: some View {
        HStack(spacing: 10) {
            Text("\(item.provider) · \(item.member.contextLength.formatted()) 上下文")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
            GatewayCapabilities(tools: item.member.supportsTools, images: item.member.supportsImages, json: item.member.supportsJSON)
        }
    }
    private var coverage: some View {
        HStack(spacing: 5) {
            ForEach(item.member.difficulties, id: \.self) { tier in
                Text(tier.rawValue).font(Theme.Font.microMono).foregroundStyle(Theme.Ink.cursor)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(Theme.cursor.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
        }.fixedSize()
    }
    private var state: some View {
        HStack(spacing: 5) {
            Circle().fill(item.state.tint).frame(width: 6, height: 6)
            Text(item.state.title).font(Theme.Font.caption).foregroundStyle(item.state.ink)
        }.fixedSize()
    }
}
