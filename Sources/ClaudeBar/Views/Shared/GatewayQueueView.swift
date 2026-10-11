import SwiftUI
import AppKit

/// A continuous route, with real requests docking at transport checkpoints.
/// Core Animation owns travel and frame-driven return signals, not a UI clock.
struct GatewayQueueView: View {
    var snapshot: FreeModelGateway.Snapshot
    var pool: FreeModelPool
    var connections: [CodexProvider]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inViewport = true
    @State private var windowVisible = false
    @State private var compact = false
    @State private var inspectedID: UUID?
    @State private var inspectedStage: Stage?

    private enum Stage: Int, CaseIterable {
        case queued, connecting, waiting, streaming
        var title: String {
            switch self { case .queued: return "排队"; case .connecting: return "连接上游"
            case .waiting: return "等待输出"; case .streaming: return "接收输出" }
        }
        var station: String {
            switch self { case .queued: return "排队入口"; case .connecting: return "连接站"
            case .waiting: return "等待站"; case .streaming: return "输出站" }
        }
        var symbol: String {
            switch self { case .queued: return "square.stack.3d.up"; case .connecting: return "antenna.radiowaves.left.and.right"
            case .waiting: return "hourglass"; case .streaming: return "waveform" }
        }
        var tint: Color {
            switch self { case .queued: return Theme.Ink.warning; case .streaming: return Theme.Ink.success
            default: return Theme.Ink.claude }
        }
    }
    private struct Item: Identifiable {
        var id: UUID
        var stage: Stage
        var providerID: UUID
        var routing: GatewayTaskRouting
        var since: Date
        var deadline: Date?
        var position: Int?
        var attempt: Int
        var pulses = 0
        var tag: String { String(id.uuidString.prefix(6)) }
        var symbol: String {
            switch routing.kind { case .coding: return "chevron.left.forwardslash.chevron.right"
            case .debugging: return "ladybug"; case .reasoning: return "brain"
            case .extraction: return "doc.text.magnifyingglass"; case .writing: return "pencil.line"
            case .vision: return "photo"; case .general: return "text.bubble" }
        }
    }
    private var items: [Item] {
        let queued = snapshot.queue.enumerated().map { index, entry in
            Item(id: entry.id, stage: .queued, providerID: entry.providerID, routing: entry.routing,
                 since: entry.enqueuedAt, deadline: entry.deadline, position: index + 1, attempt: entry.attempt)
        }
        let active = snapshot.flights.filter { $0.phase.isActive }.map { flight in
            Item(id: flight.requestID, stage: flight.phase == .connecting ? .connecting : (flight.phase == .waiting ? .waiting : .streaming),
                 providerID: pool.members.first { $0.id == flight.memberID }?.providerID ?? flight.requestID,
                 routing: flight.routing, since: flight.startedAt, attempt: flight.attempt, pulses: flight.outputPulses)
        }
        return queued + active.sorted { $0.since < $1.since }
    }
    private var recent: [FreeModelGateway.Flight] {
        var seen = Set<UUID>()
        return snapshot.flights.filter { flight in !flight.phase.isActive && !items.contains(where: { $0.id == flight.requestID }) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { seen.insert($0.requestID).inserted }.prefix(3).map { $0 }
    }
    private var moving: Bool { inViewport && windowVisible && !reduceMotion }
    private func vessels(_ geometry: GatewayRoadGeometry) -> [GatewayRoadShip] {
        Stage.allCases.flatMap { stage in
            items.filter { $0.stage == stage }.prefix(8).enumerated().map { index, item in
                let start: Double
                if geometry.compact {
                    start = [0.055, 0.22, 0.68, 0.82][stage.rawValue]
                } else { start = [0.085, 0.26, 0.54, 0.80][stage.rawValue] }
                let step = stage == .queued ? -0.018 : 0.023
                return GatewayRoadShip(id: item.id, progress: start + Double(index / 2) * step,
                    lane: index % 2 == 0 ? -7 : 7, phase: stage.rawValue, pulses: item.pulses)
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack { heading; Spacer(minLength: 8); capacity }
                VStack(alignment: .leading, spacing: 8) { heading; capacity }
            }
            GeometryReader { proxy in
                let geometry = GatewayRoadGeometry(width: proxy.size.width)
                let ships = vessels(geometry)
                ZStack(alignment: .topLeading) {
                    GatewayRoad(ships: ships, geometry: geometry, moving: moving)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    ForEach(Stage.allCases, id: \.rawValue) { stage in
                        station(stage, geometry: geometry)
                    }
                    ForEach(ships) { ship in
                        if let item = items.first(where: { $0.id == ship.id }) {
                            requestHit(item)
                                .position(geometry.point(ship.progress, lane: ship.lane))
                        }
                    }
                }
            }.frame(height: compact ? 286 : 162)
                .onGeometryChange(for: Bool.self) { $0.size.width < 640 } action: { compact = $0 }
            HStack(spacing: 8) {
                AppGlyph(name: "paperplane.fill", size: 11).foregroundStyle(Theme.textSecondary)
                Text(items.isEmpty ? (pool.enabled ? "等待请求驶入航道" : "启用 Auto 后显示请求航道") : "飞船代表真实请求 · 停靠表示等待 · 光点返回表示收到输出")
                    .font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
            }
            if !recent.isEmpty {
                HairlineDivider()
                HStack(spacing: 12) {
                    Text("最近尝试").font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
                    ForEach(recent) { flight in
                        HStack(spacing: 4) {
                            AppGlyph(name: flight.phase == .succeeded ? "checkmark" : (flight.phase == .cancelled ? "minus" : "xmark"), size: 9)
                            Text(String(flight.requestID.uuidString.prefix(6))).font(Theme.Font.microMono)
                        }.foregroundStyle(flight.phase == .succeeded ? Theme.Ink.success : (flight.phase == .cancelled ? Theme.textSecondary : Theme.Ink.error))
                            .help("\(flight.phase.title) · 第 \(flight.attempt) 次尝试")
                    }
                    Spacer(minLength: 0)
                }
            }
        }.padding(18).panelCard()
            .background { GatewayQueueVisibility { windowVisible = $0 }.frame(width: 0, height: 0) }
            .onScrollVisibilityChange(threshold: 0.05) { inViewport = $0 }
    }
    private var heading: some View {
        HStack(spacing: 8) {
            Text("请求航道").font(Theme.Font.chromeEmph).foregroundStyle(Theme.textPrimary)
            Text(snapshot.queued > 0 ? "\(snapshot.queued) 个排队" : "航道畅通")
                .font(Theme.Font.caption).foregroundStyle(snapshot.queued > 0 ? Theme.Ink.warning : Theme.textSecondary)
        }
    }
    private var capacity: some View {
        HStack(spacing: 8) {
            Text("并发 \(snapshot.active) / \(pool.maxConcurrent)").font(Theme.Font.captionMono).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 3) {
                ForEach(0..<pool.maxConcurrent, id: \.self) { index in
                    Capsule().fill(index < snapshot.active ? Theme.Ink.claude : Theme.hairline).frame(width: 4, height: 12)
                }
            }.accessibilityHidden(true)
        }.help("全局实际占用 \(snapshot.active) 个并发额度，上限 \(pool.maxConcurrent)。每供应商另有独立上限。")
    }
    private func station(_ stage: Stage, geometry: GatewayRoadGeometry) -> some View {
        let point = geometry.station(stage.rawValue)
        let count = items.filter { $0.stage == stage }.count
        return ZStack(alignment: .topLeading) {
            Button { inspectedStage = stage } label: {
                ZStack {
                    Circle().strokeBorder(count > 0 ? stage.tint.opacity(0.5) : Theme.hairline,
                        style: StrokeStyle(lineWidth: 1, dash: [2, 4])).frame(width: 46, height: 46)
                    Circle().fill(Theme.cardSurface).frame(width: 34, height: 34)
                        .overlay { Circle().strokeBorder(count > 0 ? stage.tint.opacity(0.7) : Theme.hairline) }
                    AppGlyph(name: stage.symbol, size: 16).foregroundStyle(count > 0 ? stage.tint : Theme.textSecondary)
                }
            }.buttonStyle(.plain).position(point)
                .accessibilityLabel("\(stage.title)，\(count) 个请求；查看停靠的请求")
                .popover(isPresented: Binding(get: { inspectedStage == stage }, set: { if !$0 { inspectedStage = nil } })) { stationContents(stage) }
            VStack(spacing: 4) {
                Text(stage.station).font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Text("\(count) 个请求").font(Theme.Font.micro).foregroundStyle(count > 0 ? stage.tint : Theme.textSecondary)
            }.frame(width: 90).position(x: point.x, y: point.y + 50)
        }
    }
    private func requestHit(_ item: Item) -> some View {
        Button { inspectedID = item.id } label: { Color.clear.frame(width: 24, height: 24).contentShape(Circle()) }
            .buttonStyle(.plain).help(requestHelp(item))
            .accessibilityLabel("请求 \(item.tag)，\(item.stage.title)，\(item.routing.difficulty.displayName)")
            .popover(isPresented: Binding(get: { inspectedID == item.id }, set: { if !$0 { inspectedID = nil } })) {
                if windowVisible { TimelineView(.periodic(from: .now, by: 1)) { context in requestInspector(item, now: context.date) } }
                else { requestInspector(item, now: Date()) }
            }
    }
    private func stationContents(_ stage: Stage) -> some View {
        let occupants = items.filter { $0.stage == stage }
        return VStack(alignment: .leading, spacing: 14) {
            Label("\(stage.title) · \(occupants.count) 个请求", systemImage: stage.symbol).font(Theme.Font.bodySmall.weight(.semibold))
                .foregroundStyle(stage.tint)
            if occupants.isEmpty { Text("当前没有请求停靠").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
            else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 10)], spacing: 12) {
                        ForEach(occupants) { item in
                            Button { inspectedID = item.id } label: {
                                VStack(spacing: 5) {
                                    AppGlyph(name: item.symbol, size: 18).frame(width: 36, height: 36)
                                        .background(stage.tint.opacity(0.08), in: Circle())
                                    Text(item.tag).font(Theme.Font.microMono)
                                }.foregroundStyle(stage.tint)
                            }.buttonStyle(.plain).help(requestHelp(item))
                                .popover(isPresented: Binding(get: { inspectedID == item.id }, set: { if !$0 { inspectedID = nil } })) {
                                    requestInspector(item, now: Date())
                                }
                        }
                    }
                }.frame(maxHeight: 220)
            }
        }.padding(16).frame(width: 300, alignment: .leading).background(Theme.bgPrimary)
    }
    private func requestHelp(_ item: Item) -> String {
        "请求 \(item.tag) · \(item.stage.title)\(item.position.map { " · 第 \($0) 位" } ?? "") · \(providerName(item.providerID)) · \(item.stage == .queued ? "已等待" : "已处理") \(Int(max(0, Date().timeIntervalSince(item.since)))) 秒"
    }
    private func requestInspector(_ item: Item, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                GlyphWell(name: item.symbol, tint: item.stage.tint, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("请求 \(item.tag)").font(Theme.Font.bodySmall.weight(.semibold))
                    Text(item.stage.title + (item.position.map { " · 第 \($0) 位" } ?? ""))
                        .font(Theme.Font.caption).foregroundStyle(item.stage.tint)
                }
                if item.stage == .streaming {
                    GatewayOutputPulse(pulses: item.pulses, moving: moving).frame(width: 8, height: 8)
                }
            }
            Text("\(item.routing.kind.title) · \(item.routing.difficulty.displayName)").font(Theme.Font.caption)
            Text(providerName(item.providerID)).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            Text("\(item.stage == .queued ? "已等待" : "已处理") \(Int(max(0, now.timeIntervalSince(item.since)))) 秒").font(Theme.Font.captionMono)
            if item.attempt > 0 {
                Text(item.stage == .queued ? "等待备用供应商空位" : "第 \(item.attempt) 次实际尝试")
                    .font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
            }
        }.padding(16).frame(width: 240, alignment: .leading).background(Theme.bgPrimary)
    }
    private func providerName(_ id: UUID) -> String { connections.first { $0.id == id }?.name ?? "已保存供应商" }
}

struct GatewayRoadShip: Equatable, Identifiable {
    var id: UUID
    var progress: Double
    var lane: CGFloat
    var phase: Int
    var pulses: Int
}
struct GatewayRoadGeometry: Equatable {
    var width: CGFloat
    var compact: Bool { width < 640 }
    func point(_ progress: Double, lane: CGFloat = 0) -> CGPoint {
        let t = max(0, min(1, progress))
        let base: CGPoint
        if !compact { base = CGPoint(x: 22 + (width - 44) * t, y: 64) }
        else if t < 0.35 { base = CGPoint(x: 28 + (width - 80) * t / 0.35, y: 54) }
        else if t > 0.65 { base = CGPoint(x: width - 52 - (width - 80) * (t - 0.65) / 0.35, y: 180) }
        else {
            let q = (t - 0.35) / 0.3, r = 1 - q
            base = CGPoint(x: pow(r,3) * (width - 52) + 3 * r*r*q * (width - 4) + 3*r*q*q * (width - 4) + pow(q,3) * (width - 52),
                           y: pow(r,3) * 54 + 3*r*r*q * 54 + 3*r*q*q * 180 + pow(q,3) * 180)
        }
        guard lane != 0 else { return base }
        let before = point(max(0, t - 0.001)), after = point(min(1, t + 0.001))
        let dx = after.x - before.x, dy = after.y - before.y, length = max(0.001, hypot(dx,dy))
        return CGPoint(x: base.x - dy / length * lane, y: base.y + dx / length * lane)
    }
    func station(_ index: Int) -> CGPoint { point((compact ? [0.09,0.31,0.69,0.92] : [0.14,0.39,0.66,0.93])[index]) }
    func route(from start: Double = 0, to end: Double = 1, lane: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        for i in 0...80 {
            let p = point(start + (end - start) * Double(i) / 80, lane: lane)
            if i == 0 { path.move(to:p) } else { path.addLine(to:p) }
        }
        return path
    }
}
private struct GatewayRoad: NSViewRepresentable {
    var ships: [GatewayRoadShip]
    var geometry: GatewayRoadGeometry
    var moving: Bool
    func makeNSView(context: Context) -> GatewayRoadView { GatewayRoadView() }
    func updateNSView(_ view: GatewayRoadView, context: Context) { view.update(ships: ships, geometry: geometry, moving: moving) }
    static func dismantleNSView(_ view: GatewayRoadView, coordinator: ()) { view.stop() }
}
private final class GatewayRoadView: NSView {
    private struct Vessel {
        var root: CALayer
        var body: CAShapeLayer
        var signal: CAShapeLayer
        var state: GatewayRoadShip
        var lastSignal = Date.distantPast
    }
    private let edge = CAShapeLayer(), road = CAShapeLayer(), center = CAShapeLayer()
    private var vessels: [UUID:Vessel] = [:]
    private var geometry = GatewayRoadGeometry(width: 700)
    private var input: [GatewayRoadShip] = []
    private var moving = false
    private var token: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame:frame); wantsLayer = true
        for item in [edge,road,center] { item.fillColor = nil; item.lineCap = .round; item.lineJoin = .round; layer?.addSublayer(item) }
        edge.lineWidth = 32; road.lineWidth = 30; center.lineWidth = 1; center.lineDashPattern = [3,8]
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let token { NotificationCenter.default.removeObserver(token) }; token = nil
        if let window {
            token = NotificationCenter.default.addObserver(forName:NSWindow.didChangeOcclusionStateNotification,object:window,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.paint(animate:false) }
            }
        }
        paint(animate:false)
    }
    func update(ships: [GatewayRoadShip], geometry: GatewayRoadGeometry, moving: Bool) {
        let animate = self.geometry == geometry
        self.geometry = geometry; self.input = ships; self.moving = moving; paint(animate:animate)
    }
    func stop() {
        moving = false
        for vessel in vessels.values { vessel.root.removeAllAnimations(); vessel.body.removeAllAnimations(); vessel.signal.removeAllAnimations() }
    }
    private func paint(animate: Bool) {
        guard let layer else { return }
        let visible = moving && window?.occlusionState.contains(.visible) == true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for track in [edge,road,center] { track.path = geometry.route() }
        edge.strokeColor = NSColor(Theme.hairline).cgColor
        road.strokeColor = NSColor(Theme.fieldWell).cgColor
        center.strokeColor = NSColor(Theme.textSecondary.opacity(0.35)).cgColor
        let ids = Set(input.map(\.id))
        for id in Array(vessels.keys) where !ids.contains(id) {
            if let vessel = vessels.removeValue(forKey:id) { vessel.root.removeFromSuperlayer(); vessel.signal.removeFromSuperlayer() }
        }
        for state in input {
            var vessel = vessels[state.id] ?? makeVessel(state, in:layer)
            let previous = vessel.state
            let target = geometry.point(state.progress, lane:state.lane)
            let color = NSColor([Theme.Ink.warning,Theme.Ink.claude,Theme.Ink.claude,Theme.Ink.success][state.phase]).cgColor
            vessel.body.fillColor = color; vessel.signal.fillColor = color
            let tangent = geometry.point(min(1,state.progress + 0.001))
            let base = geometry.point(state.progress)
            vessel.body.setAffineTransform(CGAffineTransform(rotationAngle:atan2(tangent.y-base.y,tangent.x-base.x)))
            vessel.root.position = target
            if !visible { vessel.root.removeAllAnimations(); vessel.body.removeAllAnimations(); vessel.signal.removeAllAnimations() }
            else {
                if animate && (previous.progress != state.progress || previous.lane != state.lane) {
                    let travel = CAKeyframeAnimation(keyPath:"position")
                    travel.path = geometry.route(from:previous.progress,to:state.progress,lane:state.lane)
                    travel.duration = 0.75; travel.calculationMode = .paced
                    vessel.root.add(travel,forKey:"travel")
                }
                if state.phase == 2 && vessel.body.animation(forKey:"waiting") == nil {
                    let waiting = CABasicAnimation(keyPath:"opacity")
                    waiting.fromValue = 0.45; waiting.toValue = 1; waiting.duration = 1.8; waiting.autoreverses = true; waiting.repeatCount = .infinity
                    vessel.body.add(waiting,forKey:"waiting")
                } else if state.phase != 2 { vessel.body.removeAnimation(forKey:"waiting") }
                if state.phase == 3 && state.pulses > previous.pulses && Date().timeIntervalSince(vessel.lastSignal) >= 0.5 {
                    vessel.lastSignal = Date()
                    let signal = CAKeyframeAnimation(keyPath:"position")
                    signal.path = geometry.route(from:state.progress,to:0.015,lane:11)
                    signal.duration = 0.85; signal.calculationMode = .paced
                    let fade = CAKeyframeAnimation(keyPath:"opacity")
                    fade.values = [0,1,1,0]; fade.keyTimes = [0,0.1,0.85,1]; fade.duration = 0.85
                    let group = CAAnimationGroup(); group.animations = [signal,fade]; group.duration = 0.85
                    vessel.signal.add(group,forKey:"output")
                }
            }
            vessel.state = state; vessels[state.id] = vessel
        }
        CATransaction.commit()
    }
    private func makeVessel(_ state: GatewayRoadShip, in layer: CALayer) -> Vessel {
        let root = CALayer(), body = CAShapeLayer(), signal = CAShapeLayer()
        let shape = CGMutablePath(); shape.move(to:CGPoint(x:8,y:0)); shape.addLine(to:CGPoint(x:-6,y:-5)); shape.addLine(to:CGPoint(x:-2,y:0)); shape.addLine(to:CGPoint(x:-6,y:5)); shape.closeSubpath()
        body.path = shape; body.lineWidth = 0.75; body.strokeColor = NSColor(Theme.cardSurface).cgColor
        root.addSublayer(body); layer.addSublayer(root)
        signal.path = CGPath(ellipseIn:CGRect(x:-2,y:-2,width:4,height:4),transform:nil); signal.opacity = 0; layer.addSublayer(signal)
        return Vessel(root:root,body:body,signal:signal,state:state)
    }
}

private struct GatewayQueueVisibility: NSViewRepresentable {
    var changed: (Bool) -> Void
    func makeNSView(context: Context) -> GatewayQueueVisibilityView {
        let view = GatewayQueueVisibilityView(); view.changed = changed; return view
    }
    func updateNSView(_ view: GatewayQueueVisibilityView, context: Context) { view.changed = changed }
}
private final class GatewayQueueVisibilityView: NSView {
    var changed: ((Bool) -> Void)?
    private var token: NSObjectProtocol?
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let token { NotificationCenter.default.removeObserver(token) }; token = nil
        if let window {
            token = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishVisibility() }
            }
        }
        publishVisibility()
    }
    private func publishVisibility() {
        let visible = window?.occlusionState.contains(.visible) == true
        DispatchQueue.main.async { [weak self] in self?.changed?(visible) }
    }
}

private struct GatewayOutputPulse: NSViewRepresentable {
    var pulses: Int
    var moving: Bool
    func makeNSView(context: Context) -> GatewayOutputDot { GatewayOutputDot() }
    func updateNSView(_ view: GatewayOutputDot, context: Context) { view.update(pulses: pulses, moving: moving) }
}
private final class GatewayOutputDot: NSView {
    private var previous = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(Theme.Ink.success).cgColor
        layer?.cornerRadius = 4
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { layer?.removeAllAnimations() } }
    func update(pulses: Int, moving: Bool) {
        defer { previous = pulses }
        guard moving, window?.occlusionState.contains(.visible) == true else { layer?.removeAllAnimations(); return }
        guard pulses > previous else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.3; pulse.toValue = 1; pulse.autoreverses = true; pulse.duration = 0.18
        layer?.add(pulse, forKey: "output")
    }
}
