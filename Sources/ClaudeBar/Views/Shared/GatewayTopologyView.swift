import SwiftUI
import AppKit

extension GatewayTaskDifficulty {
    var displayName: String {
        switch self { case .low: return "轻量"; case .medium: return "常规"; case .high: return "深度" }
    }
    var taskHint: String {
        switch self { case .low: return "提取 · 转换"; case .medium: return "编码 · 工具"; case .high: return "排错 · 推理" }
    }
}

/// A display state, not an inferred model quality score.
enum GatewayMemberState: Equatable {
    case paused, unassigned, credentials, expired, unavailable, cooling, ready, untested
    var title: String {
        switch self {
        case .paused: return "已停用"
        case .unassigned: return "未分配档位"
        case .credentials: return "连接待完善"
        case .expired: return "目录已过期"
        case .unavailable: return "已下架／非免费"
        case .cooling: return "冷却中"
        case .ready: return "最近成功"
        case .untested: return "未测试"
        }
    }
    var tint: Color {
        switch self {
        case .ready: return Theme.statusSuccess
        case .credentials, .expired, .unavailable, .cooling: return Theme.statusWarning
        default: return Theme.statusIdle
        }
    }
    var ink: Color {
        switch self {
        case .ready: return Theme.Ink.success
        case .credentials, .expired, .unavailable, .cooling: return Theme.Ink.warning
        default: return Theme.Ink.idle
        }
    }
    var routable: Bool { self == .ready || self == .untested }
}

struct GatewayMapMember: Equatable, Identifiable {
    var member: FreeModelPool.Member
    var provider: String
    var state: GatewayMemberState
    var id: String { member.id }
}

struct GatewayCapabilities: View {
    var tools: Bool
    var images: Bool
    var json: Bool
    var text = false
    var body: some View {
        HStack(spacing: 8) {
            capability("wrench.and.screwdriver", "工具", enabled: tools)
            capability("photo", "图片", enabled: images)
            capability("curlybraces", "JSON", enabled: json)
        }
    }
    private func capability(_ icon: String, _ title: String, enabled: Bool) -> some View {
        HStack(spacing: 4) {
            AppGlyph(name: icon, size: 12)
                .overlay {
                    if !enabled {
                        Rectangle().fill(Theme.textPrimary.opacity(0.72))
                            .frame(width: 14, height: 1).rotationEffect(.degrees(-45))
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            if text { Text(title).font(Theme.Font.caption).strikethrough(!enabled) }
        }
        .foregroundStyle(Theme.textPrimary.opacity(0.72))
        .help("\(title)：\(enabled ? "支持" : "不支持")")
        .accessibilityLabel("\(title)\(enabled ? "支持" : "不支持")")
    }
}

struct GatewayTopologyView: View {
    var members: [GatewayMapMember]
    var flights: [FreeModelGateway.Flight]
    var selectedID: String?
    var selectedTier: GatewayTaskDifficulty?
    var enabled: Bool
    var onSelect: (String) -> Void
    var onTier: (GatewayTaskDifficulty) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inViewport = true

    var body: some View {
        GatewayNodeLayout(count: members.count) {
            source
            ForEach(GatewayTaskDifficulty.allCases, id: \.self) { tier in tierNode(tier) }
            ForEach(members) { item in modelNode(item) }
        }
        .background {
            GeometryReader { proxy in
                let geometry = GatewayTopologyLayout.geometry(width: proxy.size.width, count: members.count)
                GatewayRouteLines(links: links(geometry), moving: inViewport && !reduceMotion)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            GeometryReader { proxy in
                let geometry = GatewayTopologyLayout.geometry(width: proxy.size.width, count: members.count)
                let routes = links(geometry).sorted {
                    let a = $0.flight?.phase.isActive == true ? 2 : ($0.selected ? 1 : 0)
                    let b = $1.flight?.phase.isActive == true ? 2 : ($1.selected ? 1 : 0)
                    return a < b
                }
                Canvas { context, _ in
                    // Physical ports belong to the real link endpoints. The
                    // flow still lives in Core Animation, never in this canvas.
                    for link in routes {
                        let ink = link.flight?.phase.isActive == true ? Theme.Ink.claude
                            : (link.selected ? Theme.Ink.cursor : Theme.textSecondary)
                        for point in [link.points.first, link.points.last].compactMap({ $0 }) {
                            let port = Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
                            context.fill(port, with: .color(Theme.cardSurface))
                            context.stroke(port, with: .color(ink.opacity(link.enabled ? 0.7 : 0.35)), lineWidth: 1)
                        }
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onScrollVisibilityChange(threshold: 0.05) { inViewport = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Auto 路由拓扑；流动线表示正在处理的真实请求")
    }

    private var source: some View {
        let live = flights.filter { $0.phase.isActive }
        return VStack(spacing: 5) {
            AppGlyph(name: "arrow.triangle.branch", size: 20)
                .foregroundStyle(live.isEmpty ? Theme.Ink.cursor : Theme.Ink.claude)
            Text("auto").font(Theme.Font.chromeEmph)
            Text(live.isEmpty ? (enabled ? "等待请求" : "尚未启用") : "\(Set(live.map(\.requestID)).count) 个处理中")
                .font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.fieldWell, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay { RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.hairline) }
    }

    private func tierNode(_ tier: GatewayTaskDifficulty) -> some View {
        let live = flights.filter { $0.phase.isActive && $0.routing.difficulty == tier }
        let count = members.filter { $0.member.enabled && $0.member.difficulties.contains(tier) }.count
        return Button { onTier(tier) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(tier.displayName).font(Theme.Font.chromeEmph)
                    Text(tier.rawValue).font(Theme.Font.microMono).foregroundStyle(Theme.textSecondary)
                }
                Text(live.isEmpty ? "图中 \(count) 个模型" : "\(live.count) 次尝试中")
                    .font(Theme.Font.micro).foregroundStyle(live.isEmpty ? Theme.textSecondary : Theme.Ink.claude)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .background(selectedTier == tier ? Theme.cursor.opacity(Theme.isDark ? 0.16 : 0.08) : Theme.fieldWell,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(selectedTier == tier ? Theme.cursor.opacity(0.7) : Theme.hairline)
            }
        }
        .buttonStyle(GatewayNodeButtonStyle())
        .foregroundStyle(Theme.textPrimary)
        .accessibilityLabel("\(tier.displayName) \(tier.rawValue)，点击筛选对应模型")
        .accessibilityValue(selectedTier == tier ? "已筛选" : "未筛选")
        .help("筛选承接 \(tier.rawValue) 的模型；再次点击取消筛选")
    }

    private func modelNode(_ item: GatewayMapMember) -> some View {
        let live = flights.first { $0.memberID == item.id && $0.phase.isActive }
        return Button { onSelect(item.id) } label: {
            HStack(spacing: 9) {
                Circle().fill(live == nil ? item.state.tint : Theme.claude).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.member.name).font(Theme.Font.chromeEmph).lineLimit(1).truncationMode(.middle)
                    Text(item.provider).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(live?.phase.title ?? item.state.title)
                        .font(Theme.Font.microMedium).foregroundStyle(live == nil ? item.state.ink : Theme.Ink.claude)
                        .fixedSize()
                    Text(contextLabel(item.member.contextLength)).font(Theme.Font.microMono).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selectedID == item.id ? Theme.cursor.opacity(Theme.isDark ? 0.14 : 0.065) : Theme.cardSurface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(selectedID == item.id ? Theme.cursor.opacity(0.7) : Theme.hairline)
            }
        }
        .buttonStyle(GatewayNodeButtonStyle())
        .foregroundStyle(Theme.textPrimary)
        .help("\(item.member.name)\n\(item.member.model)\n\(item.provider) · \(live?.phase.title ?? item.state.title)")
        .accessibilityLabel("\(item.member.name)，\(item.provider)，\(live?.phase.title ?? item.state.title)")
        .accessibilityValue(selectedID == item.id ? "已选中" : "未选中")
    }

    private func links(_ g: GatewayTopologyLayout.Geometry) -> [GatewayVisualLink] {
        let compact = g.size.width < 520
        var result: [GatewayVisualLink] = []
        func recent(_ candidates: [FreeModelGateway.Flight]) -> FreeModelGateway.Flight? {
            candidates.first(where: { $0.phase.isActive }) ?? candidates.first
        }
        for (i, tier) in GatewayTaskDifficulty.allCases.enumerated() {
            let flight = recent(flights.filter { $0.routing.difficulty == tier })
            let start = compact ? CGPoint(x: g.source.midX, y: g.source.maxY) : CGPoint(x: g.source.maxX, y: g.source.midY)
            let end = compact ? CGPoint(x: g.tiers[i].midX, y: g.tiers[i].minY) : CGPoint(x: g.tiers[i].minX, y: g.tiers[i].midY)
            result.append(.init(id: "auto-\(tier.rawValue)", points: [start, end], vertical: compact,
                                selected: selectedTier == tier, enabled: enabled, flight: flight, node: nil))
            for (index, item) in members.enumerated() {
                let relevant = flights.filter { $0.memberID == item.id && $0.routing.difficulty == tier }
                guard item.member.difficulties.contains(tier) || relevant.contains(where: { $0.phase.isActive }) else { continue }
                let from = compact ? CGPoint(x: g.tiers[i].midX, y: g.tiers[i].maxY) : CGPoint(x: g.tiers[i].maxX, y: g.tiers[i].midY)
                let to = CGPoint(x: g.models[index].minX, y: g.models[index].midY)
                let points = compact
                    ? [from, CGPoint(x: from.x, y: 184 + CGFloat(i) * 7), CGPoint(x: 10 + CGFloat(i) * 9, y: 184 + CGFloat(i) * 7), CGPoint(x: 10 + CGFloat(i) * 9, y: to.y), to]
                    : [from, to]
                result.append(.init(id: "\(tier.rawValue)-\(item.id)", points: points, vertical: false,
                    selected: selectedID == item.id && (selectedTier == nil || selectedTier == tier),
                    enabled: item.member.enabled && item.state.routable, flight: recent(relevant), node: g.models[index]))
            }
        }
        return result
    }
    private func contextLabel(_ count: Int) -> String { count >= 1000 ? "\(count / 1000)K" : String(count) }
}

private struct GatewayNodeLayout: Layout {
    var count: Int
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        GatewayTopologyLayout.geometry(width: proposal.width ?? 640, count: count).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let g = GatewayTopologyLayout.geometry(width: bounds.width, count: count)
        let frames = [g.source] + g.tiers + Array(g.models.prefix(count))
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

private struct GatewayVisualLink: Equatable {
    var id: String
    var points: [CGPoint]
    var vertical: Bool
    var selected: Bool
    var enabled: Bool
    var flight: FreeModelGateway.Flight?
    var node: CGRect?
}

/// Core Animation owns the moving strokes; no TimelineView or display timer
/// invalidates the SwiftUI page. Animations stop at idle, offscreen or hidden.
private struct GatewayRouteLines: NSViewRepresentable {
    var links: [GatewayVisualLink]
    var moving: Bool
    func makeNSView(context: Context) -> GatewayLinesView { GatewayLinesView() }
    func updateNSView(_ view: GatewayLinesView, context: Context) { view.update(links: links, moving: moving) }
    static func dismantleNSView(_ view: GatewayLinesView, coordinator: ()) { view.stop() }
}

private final class GatewayLinesView: NSView {
    private struct Stroke {
        var base: CAShapeLayer
        var flow: CAShapeLayer
        var ring: CAShapeLayer
        var lastPulse: Date?
    }
    private var strokes: [String: Stroke] = [:]
    private var links: [GatewayVisualLink] = []
    private var moving = false
    private var tokens: [NSObjectProtocol] = []
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { nil }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for token in tokens { NotificationCenter.default.removeObserver(token) }; tokens.removeAll()
        if let window {
            tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.paint() }
                })
        }
        paint()
    }
    func update(links: [GatewayVisualLink], moving: Bool) {
        self.links = links; self.moving = moving
        paint()
    }
    func stop() {
        moving = false
        for stroke in strokes.values { stroke.flow.removeAllAnimations(); stroke.ring.removeAllAnimations() }
    }
    private func paint() {
        guard let layer else { return }
        let visible = moving && window?.occlusionState.contains(.visible) == true
        let ids = Set(links.map(\.id))
        for id in Array(strokes.keys) where !ids.contains(id) {
            if let stroke = strokes.removeValue(forKey: id) { stroke.base.removeFromSuperlayer(); stroke.flow.removeFromSuperlayer(); stroke.ring.removeFromSuperlayer() }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for link in links {
            var stroke = strokes[link.id] ?? makeStroke(in: layer)
            let path = CGMutablePath()
            if let first = link.points.first { path.move(to: first) }
            if link.points.count == 2, let a = link.points.first, let b = link.points.last {
                if link.vertical {
                    path.addCurve(to: b, control1: CGPoint(x: a.x, y: (a.y + b.y) / 2), control2: CGPoint(x: b.x, y: (a.y + b.y) / 2))
                } else {
                    path.addCurve(to: b, control1: CGPoint(x: (a.x + b.x) / 2, y: a.y), control2: CGPoint(x: (a.x + b.x) / 2, y: b.y))
                }
            } else { for p in link.points.dropFirst() { path.addLine(to: p) } }
            stroke.base.path = path; stroke.flow.path = path
            stroke.base.strokeColor = NSColor(link.selected ? Theme.cursor.opacity(0.45) : Theme.textSecondary.opacity(link.enabled ? 0.26 : 0.14)).cgColor
            stroke.base.lineDashPattern = link.enabled ? nil : [4, 4]
            stroke.flow.strokeColor = NSColor(signal(link.flight?.phase)).cgColor
            stroke.flow.shadowColor = stroke.flow.strokeColor
            stroke.ring.strokeColor = stroke.flow.strokeColor
            stroke.ring.path = link.node.map { CGPath(roundedRect: $0.insetBy(dx: -2, dy: -2), cornerWidth: 14, cornerHeight: 14, transform: nil) }
            let active = link.flight?.phase.isActive == true
            stroke.flow.opacity = active ? 1 : 0
            if visible && active {
                stroke.flow.lineDashPattern = [3, 11]
                let direction: Double = link.flight?.phase == .streaming ? 28 : -28
                if let animation = stroke.flow.animation(forKey: "travel") as? CABasicAnimation, animation.toValue as? Double != direction {
                    stroke.flow.removeAnimation(forKey: "travel")
                }
                if stroke.flow.animation(forKey: "travel") == nil {
                    let animation = CABasicAnimation(keyPath: "lineDashPhase")
                    animation.fromValue = 0; animation.toValue = direction
                    animation.duration = 0.85; animation.repeatCount = .infinity
                    stroke.flow.add(animation, forKey: "travel")
                }
            } else {
                stroke.flow.removeAnimation(forKey: "travel")
                stroke.flow.lineDashPattern = nil
            }
            if let flight = link.flight, stroke.lastPulse != flight.updatedAt {
                stroke.lastPulse = flight.updatedAt
                if visible, Date().timeIntervalSince(flight.updatedAt) < 1.2 {
                    let pulse = CABasicAnimation(keyPath: "opacity")
                    pulse.fromValue = 0.8; pulse.toValue = 0
                    pulse.duration = flight.phase.isActive ? 0.45 : 1.05
                    stroke.ring.add(pulse, forKey: "pulse")
                    if !active { stroke.flow.add(pulse, forKey: "complete") }
                }
            }
            if !visible { stroke.flow.removeAllAnimations(); stroke.ring.removeAllAnimations() }
            strokes[link.id] = stroke
        }
        CATransaction.commit()
    }
    private func signal(_ phase: FreeModelGateway.Flight.Phase?) -> Color {
        switch phase { case .succeeded: return Theme.statusSuccess; case .failed: return Theme.statusError; case .cancelled: return Theme.statusIdle; default: return Theme.claude }
    }
    private func makeStroke(in parent: CALayer) -> Stroke {
        let base = CAShapeLayer(), flow = CAShapeLayer(), ring = CAShapeLayer()
        for shape in [base, flow, ring] {
            shape.fillColor = nil; shape.lineCap = .round; shape.lineJoin = .round
            parent.addSublayer(shape)
        }
        base.lineWidth = 1; flow.lineWidth = 2.5; ring.lineWidth = 1.5
        flow.shadowRadius = 4; flow.shadowOpacity = 0.45; flow.shadowOffset = .zero
        ring.opacity = 0
        return Stroke(base: base, flow: flow, ring: ring)
    }
}

/// Hover and press change ink only: diagram nodes never move away from ports.
struct GatewayNodeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NodeBody(label: configuration.label, pressed: configuration.isPressed)
    }
    private struct NodeBody: View {
        let label: Configuration.Label
        var pressed: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            label.brightness(pressed ? -0.035 : 0)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(Theme.textSecondary.opacity(hovered && enabled ? 0.25 : 0))
                        .allowsHitTesting(false)
                }
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : Theme.Motion.state, value: pressed)
                .animation(reduceMotion ? nil : Theme.Motion.state, value: hovered)
        }
    }
}

/// One selectable difficulty treatment in inspectors and import settings.
struct GatewayTierChip: View {
    var tier: GatewayTaskDifficulty
    var selected: Bool
    var action: () -> Void
    var body: some View {
        ChipButton(on: selected, tint: Theme.Ink.cursor, action: action) {
            AppGlyph(name: selected ? "checkmark" : "plus", size: 10)
            Text(tier.displayName)
            Text(tier.rawValue).font(Theme.Font.microMono)
        }
        .fixedSize()
        .help(tier.taskHint)
        .accessibilityLabel("承接\(tier.displayName)任务")
        .accessibilityValue(selected ? "已选择" : "未选择")
    }
}
