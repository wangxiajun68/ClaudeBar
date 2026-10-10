import SwiftUI

/// Dense, equal-height catalog tiles; no health inference from discovery.
struct GatewayCatalogCard: View, Equatable {
    var model: FreeModelPool.CatalogModel
    var joined: Bool
    var canJoin: Bool
    var onJoin: () -> Void
    @State private var hovered = false
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model && lhs.joined == rhs.joined && lhs.canJoin == rhs.canJoin
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.name).font(Theme.Font.chromeEmph).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).help(model.name)
                Text(model.id).font(Theme.Font.captionMono).foregroundStyle(Theme.textPrimary.opacity(0.72))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(model.id)
            }
            HairlineDivider()
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.contextLength >= 1000 ? "\(model.contextLength / 1000)K" : "\(model.contextLength)")
                        .font(Theme.Font.chromeEmph).monospacedDigit().foregroundStyle(Theme.textPrimary)
                    Text("上下文").font(Theme.Font.micro).foregroundStyle(Theme.textPrimary.opacity(0.72))
                }.help("\(model.contextLength.formatted()) tokens 上下文")
                GatewayCapabilities(tools: model.supportsTools, images: model.supportsImages, json: model.supportsJSON)
                Spacer(minLength: 0)
                if joined {
                    Label("已在池内", systemImage: "checkmark.circle")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Ink.success).fixedSize()
                } else {
                    ActionButton(tone: .accent, tint: Theme.Ink.cursor, perform: onJoin) {
                        AppGlyph(name: "plus", size: 12).foregroundStyle(Theme.Ink.cursor)
                        Text("加入").foregroundStyle(Theme.Ink.cursor)
                    }
                        .disabled(!canJoin).accessibilityLabel("加入 \(model.name)")
                        .help(canJoin ? "加入 Auto 模型池" : "先选择供应商凭据，并等待加载或保存完成")
                }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Theme.cardSurface : Theme.fieldWell, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay { RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.hairline) }
            .onHover { hovered = $0 }
    }
}
