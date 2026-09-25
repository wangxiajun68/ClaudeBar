import AppKit
import SwiftUI

// MARK: - Model

/// Where the power goes right now, reduced from `HostStats`.
///
/// Readings follow AlDente's model (see `HardwareSensors.applyPowerReadings`):
/// adapter = SMC `PDTR`, system = SMC `PSTR`, battery = adapter − system,
/// with the battery gauge deciding the direction. Four situations follow,
/// each a different Sankey topology:
///
///     charging    adapter ─┬─▶ battery     the adapter covers the load and
///                          └─▶ Mac         tops the battery up
///     assisting   adapter ─┬─▶ Mac         the adapter is short of the load;
///                 battery ─┘               the battery makes up the gap
///     holding     adapter ───▶ Mac         battery idle (full / optimized)
///     onBattery   battery ───▶ Mac         unplugged
///
/// Watts are rounded to 0.1 so sampler noise below that resolution does not
/// re-render the card.
struct PowerFlow: Equatable {
    enum Mode: Equatable { case charging, assisting, holding, onBattery }

    enum Node: Hashable {
        case adapter, batteryOut, system, batteryIn

        var isSource: Bool { self == .adapter || self == .batteryOut }
    }

    struct Flow: Equatable, Identifiable {
        let from: Node
        let to: Node
        let watts: Double
        var id: String { "\(from)-\(to)" }
    }

    var mode: Mode
    /// Top to bottom on each side: battery above the Mac on the right, the
    /// adapter above the battery on the left.
    var flows: [Flow]
    var input: Double?
    var load: Double?
    /// Battery magnitude, whichever way it flows.
    var battery: Double
    var batteryPercent: Int
    var adapterRated: Int?
    var estimated: Bool
    var hasReadings: Bool

    /// Below this the battery counts as idle.
    private static let idleThreshold = 0.25

    init(host: ProcessSampler.HostStats) {
        func rounded(_ value: Double?) -> Double? { value.map { max(0, ($0 * 10).rounded() / 10) } }
        let signed = host.powerBatteryWatts ?? 0
        let magnitude = rounded(abs(signed)) ?? 0
        var input = rounded(host.powerInputWatts)
        var load = rounded(host.powerSystemWatts)
        batteryPercent = host.batteryPercent
        adapterRated = host.adapterRatedWatts
        estimated = host.powerIsEstimated
        hasReadings = input != nil || load != nil || host.powerBatteryWatts != nil

        if host.batteryExternalPower {
            if signed > Self.idleThreshold {
                mode = .charging
                load = load ?? input.map { max(0, $0 - magnitude) }
                input = input ?? load.map { $0 + magnitude }
                battery = magnitude
                flows = [Flow(from: .adapter, to: .batteryIn, watts: magnitude),
                         Flow(from: .adapter, to: .system, watts: load ?? 0)]
            } else if signed < -Self.idleThreshold {
                mode = .assisting
                input = input ?? load.map { max(0, $0 - magnitude) }
                load = load ?? input.map { $0 + magnitude }
                battery = magnitude
                flows = [Flow(from: .adapter, to: .system, watts: input ?? 0),
                         Flow(from: .batteryOut, to: .system, watts: magnitude)]
            } else {
                mode = .holding
                load = load ?? input
                input = input ?? load
                battery = 0
                flows = [Flow(from: .adapter, to: .system, watts: load ?? 0)]
            }
        } else {
            mode = .onBattery
            load = load ?? magnitude
            input = nil
            battery = magnitude
            flows = [Flow(from: .batteryOut, to: .system, watts: load ?? magnitude)]
        }
        self.input = input
        self.load = load
    }

    var total: Double { flows.reduce(0) { $0 + $1.watts } }
    var sources: [Node] { [.adapter, .batteryOut].filter { node in flows.contains { $0.from == node } } }
    var sinks: [Node] { [.batteryIn, .system].filter { node in flows.contains { $0.to == node } } }

    func watts(of node: Node) -> Double {
        flows.filter { $0.from == node || $0.to == node }.reduce(0) { $0 + $1.watts }
    }

    var headline: (label: String, tint: Color, ink: Color) {
        switch mode {
        case .charging: return ("充电中", Theme.chartGreen, Theme.Ink.success)
        case .assisting: return ("电池补电", Theme.chartAmber, Theme.Ink.warning)
        case .holding: return ("电源直供", Self.adapterYellow, Theme.textSecondary)
        case .onBattery: return ("电池供电", Theme.chartAmber, Theme.Ink.warning)
        }
    }

    /// One sentence that states the balance in words.
    var summary: String {
        guard hasReadings else { return "暂无功率读数。" }
        let w = Self.format
        switch mode {
        case .charging:
            return "电源输入 \(w(input ?? 0))：\(w(load ?? 0)) 供整机运行，\(w(battery)) 充入电池。"
        case .assisting:
            return "整机需要 \(w(load ?? 0))，电源只能提供 \(w(input ?? 0))，电池补足其余 \(w(battery))。"
        case .holding:
            return "电池不充不放（已充满或优化充电暂停），电源 \(w(input ?? load ?? 0)) 直接供整机。"
        case .onBattery:
            return "未接电源，电池以 \(w(battery)) 为整机供电。"
        }
    }

    static let adapterYellow = Color(hex: 0xFFD60A)

    static func color(_ node: Node) -> Color {
        switch node {
        case .adapter: return adapterYellow
        case .batteryOut: return Theme.chartAmber
        case .batteryIn: return Theme.chartGreen
        case .system: return Theme.chartBlue
        }
    }

    static func caption(_ flow: Flow) -> String {
        switch (flow.from, flow.to) {
        case (.adapter, .batteryIn): return "充入电池"
        case (.adapter, .system): return "供给整机"
        default: return "电池供电"
        }
    }

    static func format(_ watts: Double) -> String { String(format: "%.1f W", watts) }
}

// MARK: - Card

/// Energy Sankey shared by the dashboard, the menu popup and the battery
/// popover.
struct PowerFlowCard: View {
    var compact = false
    private let sampler = ProcessSampler.shared

    var body: some View {
        let host = sampler.host
        if host.batteryInstalled {
            VStack(spacing: 0) {
                PowerFlowContent(flow: PowerFlow(host: host), compact: compact)
                    .equatable()
                Divider().padding(.horizontal, compact ? 10 : 18)
                if compact {
                    CompactBatteryChargeControl().padding(10)
                } else {
                    BatteryChargeControls().padding(18)
                }
            }
            .panelCard()
        }
    }
}

private struct PowerFlowContent: View, Equatable {
    let flow: PowerFlow
    let compact: Bool

    var body: some View {
        let headline = flow.headline
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(headline.tint.gradient)
                Text(compact ? "能源" : "能源流向").font(Theme.Font.chromeEmph)
                StatusPill(label: headline.label, tint: headline.tint, ink: headline.ink)
                    .contentTransition(.opacity)
                Spacer(minLength: 4)
                Text(flow.estimated ? "电池侧估算" : (compact ? "实时" : "SMC 实时"))
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
            }
            EnergySankey(flow: flow, style: compact ? .compact : .full)
                .frame(height: compact ? 84 : 200)
            if !compact {
                Text(flow.summary)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textSecondary)
                }
        }
        .padding(compact ? 10 : 18)
        // Retimed on the *mode*, not on `flow`.
        //
        // `PowerFlow` is published once per sampler tick — 1 Hz — because the
        // watt readings move by a tenth of a watt every second and the card
        // should follow them exactly. Keying the implicit animation on `flow`
        // therefore opened a new 0.5 s animated transaction every second, and
        // an in-flight transaction makes every display cycle run the whole
        // hosting view's layout + display list: measured with the dashboard
        // open, that was 33–41 % of a core on the main thread, versus 3–8 %
        // with this key. The mode only changes when the topology does
        // (充电中 → 电源直供 …), so the crossfade still plays exactly when
        // there is something to cross-fade; the numbers themselves update
        // through their own `.contentTransition(.numericText())`.
        .animation(.smooth(duration: 0.5), value: flow.mode)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("能源流向，\(headline.label)。\(flow.summary)")
    }
}

// MARK: - Sankey

/// Solid end blocks joined by softly tinted bands proportional to watts.
/// A low-contrast wave travels toward each destination.
///
/// Rendering: blocks and bands are SwiftUI shapes redrawn only on a new
/// reading. The wave is Core Animation (`SankeyWaveLayer`): gradient layers
/// masked to each band, translated by a repeating animation the render
/// server runs — no per-frame work in this process. It runs only while the
/// card is on screen, a window is visible, the app is active and Reduce
/// Motion is off.
private struct EnergySankey: View {
    enum Style { case compact, full }

    let flow: PowerFlow
    let style: Style

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appActive = NSApplication.shared.isActive
    @State private var onScreen = false
    @Environment(\.surfaceIsVisible) private var windowVisible

    private var animating: Bool { onScreen && windowVisible && appActive && !reduceMotion && flow.total > 0 }
    private var compact: Bool { style == .compact }
    private var neutral: Color { scheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.065) }

    var body: some View {
        GeometryReader { proxy in
            let layout = SankeyLayout(flow: flow, size: proxy.size, compact: compact)
            ZStack(alignment: .topLeading) {
                ForEach(layout.ribbons) { ribbon in
                    RibbonShape(x0: layout.ribbonLeft, x1: layout.ribbonRight, left: ribbon.left, right: ribbon.right)
                        .fill(PowerFlow.color(ribbon.flow.to).opacity(scheme == .dark ? 0.14 : 0.09))
                }

                SankeyWaveLayer(waves: waves(layout), animating: animating,
                                travel: (layout.ribbonLeft, layout.ribbonRight),
                                pace: pace, dark: scheme == .dark)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)

                ForEach(layout.nodes) { node in
                    block(node, layout: layout)
                }

                ForEach(layout.ribbons) { ribbon in
                    ribbonLabel(ribbon)
                        .position(x: (layout.ribbonLeft + layout.ribbonRight) / 2,
                                  y: (ribbon.left.mid + ribbon.right.mid) / 2)
                }
            }
        }
        .onAppear {
            onScreen = true
            appActive = NSApplication.shared.isActive
        }
        .onDisappear { onScreen = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
    }

    /// Wave speed steps with the total so a jittering reading never retimes it.
    private var pace: Int {
        switch flow.total {
        case ..<0.25: return 0
        case ..<10: return 1
        case ..<30: return 2
        case ..<60: return 3
        default: return 4
        }
    }

    private func waves(_ layout: SankeyLayout) -> [SankeyWave] {
        layout.ribbons.map { ribbon in
            let path = RibbonShape(x0: layout.ribbonLeft, x1: layout.ribbonRight,
                                   left: ribbon.left, right: ribbon.right)
                .path(in: .zero).cgPath
            return SankeyWave(id: ribbon.flow.id, path: path, destination: ribbon.flow.to)
        }
    }

    // MARK: Blocks

    @ViewBuilder
    private func block(_ box: SankeyLayout.NodeBox, layout: SankeyLayout) -> some View {
        let source = box.node.isSource
        let outer = min(compact ? 12 : 24, box.span.height / 2)
        let inner: CGFloat = compact ? 3 : 5
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: source ? outer : inner, bottomLeadingRadius: source ? outer : inner,
            bottomTrailingRadius: source ? inner : outer, topTrailingRadius: source ? inner : outer,
            style: .continuous)
        let x = source ? layout.blockWidth / 2 : layout.size.width - layout.blockWidth / 2
        shape
            .fill(neutral)
            .overlay { blockContent(box, source: source) }
            .frame(width: layout.blockWidth, height: max(2, box.span.height))
            .position(x: x, y: box.span.mid)
    }

    private func blockContent(_ box: SankeyLayout.NodeBox, source: Bool) -> some View {
        let tint = PowerFlow.color(box.node)
        let roomy = box.span.height >= (compact ? 34 : 60)
        return VStack(spacing: compact ? 1 : 5) {
            Image(systemName: symbol(box.node))
                .font(.system(size: compact ? 12 : 19, weight: .semibold))
                .foregroundStyle(source ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.85)))
                .symbolRenderingMode(.hierarchical)
            if roomy {
                RollingNumberText(detail(box.node))
                    .font(.system(size: compact ? 10.5 : 16, weight: source ? .semibold : .medium,
                                  design: .rounded).monospacedDigit())
                    .foregroundColor(source ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if !compact, box.node == .adapter, let rated = flow.adapterRated, box.span.height >= 84 {
                Text("\(rated) W 适配器")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 4)
    }

    private func symbol(_ node: PowerFlow.Node) -> String {
        switch node {
        case .adapter: return "powerplug.fill"
        case .batteryIn: return "battery.100percent.bolt"
        case .batteryOut:
            switch flow.batteryPercent {
            case ..<13: return "battery.0percent"
            case ..<38: return "battery.25percent"
            case ..<63: return "battery.50percent"
            case ..<88: return "battery.75percent"
            default: return "battery.100percent"
            }
        case .system: return "laptopcomputer"
        }
    }

    /// Sources carry their output; sinks name themselves (the band already
    /// carries the watts).
    private func detail(_ node: PowerFlow.Node) -> String {
        switch node {
        case .adapter: return String(format: "%.0f W", flow.watts(of: node))
        case .batteryOut: return "\(flow.batteryPercent)% · " + String(format: "%.0f W", flow.watts(of: node))
        case .batteryIn: return "\(flow.batteryPercent)%"
        case .system: return "整机"
        }
    }

    private func ribbonLabel(_ ribbon: SankeyLayout.Ribbon) -> some View {
        let showsCaption = !compact && ribbon.thickness >= 48
        return VStack(spacing: 1) {
            RollingNumberText(PowerFlow.format(ribbon.flow.watts))
                .font(.system(size: compact ? 12.5 : 21, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(Theme.textPrimary)
            if showsCaption {
                Text(PowerFlow.caption(ribbon.flow))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, compact ? 6 : 12)
        .padding(.vertical, compact ? 3 : 6)
        .background(Theme.cardSurface.opacity(0.94), in: RoundedRectangle(cornerRadius: compact ? 7 : 12))
    }
}

// MARK: - Layout

/// Pure geometry: block spans and band ends for a given size.
///
/// Each band keeps one thickness end to end. Bands leaving one node sit flush
/// against each other; nodes on the side with more of them are separated by
/// `nodeGap`, and the side with fewer is centered — so a split reads as the
/// band fanning out, as in AlDente.
private struct SankeyLayout {
    struct Span: Equatable {
        var top: CGFloat
        var bottom: CGFloat
        var height: CGFloat { bottom - top }
        var mid: CGFloat { (top + bottom) / 2 }
    }

    struct NodeBox: Identifiable {
        let node: PowerFlow.Node
        let span: Span
        var id: PowerFlow.Node { node }
    }

    struct Ribbon: Identifiable {
        let flow: PowerFlow.Flow
        let left: Span
        let right: Span
        var thickness: CGFloat { left.height }
        var id: String { flow.id }
    }

    let size: CGSize
    let blockWidth: CGFloat
    let ribbonLeft: CGFloat
    let ribbonRight: CGFloat
    private(set) var nodes: [NodeBox] = []
    private(set) var ribbons: [Ribbon] = []

    init(flow: PowerFlow, size: CGSize, compact: Bool) {
        self.size = size
        blockWidth = compact ? 50 : min(112, max(80, size.width * 0.13))
        let blockGap: CGFloat = compact ? 4 : 7
        ribbonLeft = blockWidth + blockGap
        ribbonRight = max(ribbonLeft + 1, size.width - blockWidth - blockGap)

        let nodeGap: CGFloat = compact ? 8 : max(18, size.height * 0.16)
        let rows = CGFloat(max(flow.sources.count, flow.sinks.count, 1))
        let usable = max(1, size.height - nodeGap * (rows - 1))

        // A trickle still needs room for its label: floor each share, then
        // renormalize so the bands still fill the height.
        let total = flow.total
        let floor = flow.flows.count > 1 ? 0.24 : 1
        let raw = flow.flows.map { item in
            total > 0 ? max(floor, item.watts / total) : 1 / Double(max(1, flow.flows.count))
        }
        let rawSum = raw.reduce(0, +)
        var thickness: [String: CGFloat] = [:]
        for (item, share) in zip(flow.flows, raw) {
            thickness[item.id] = usable * CGFloat(share / max(rawSum, 0.0001))
        }

        func stack(_ side: [PowerFlow.Node], flowsAt: (PowerFlow.Node) -> [PowerFlow.Flow]) -> ([NodeBox], [String: Span]) {
            let heights = side.map { node in flowsAt(node).reduce(CGFloat(0)) { $0 + (thickness[$1.id] ?? 0) } }
            let sideHeight = heights.reduce(0, +) + nodeGap * CGFloat(max(0, side.count - 1))
            var y = (size.height - sideHeight) / 2
            var boxes: [NodeBox] = []
            var ends: [String: Span] = [:]
            for (index, node) in side.enumerated() {
                boxes.append(NodeBox(node: node, span: Span(top: y, bottom: y + heights[index])))
                var cursor = y
                for item in flowsAt(node) {
                    let t = thickness[item.id] ?? 0
                    ends[item.id] = Span(top: cursor, bottom: cursor + t)
                    cursor += t
                }
                y += heights[index] + nodeGap
            }
            return (boxes, ends)
        }

        let (leftBoxes, leftEnds) = stack(flow.sources) { node in flow.flows.filter { $0.from == node } }
        let (rightBoxes, rightEnds) = stack(flow.sinks) { node in flow.flows.filter { $0.to == node } }
        nodes = leftBoxes + rightBoxes
        ribbons = flow.flows.compactMap { item in
            guard let left = leftEnds[item.id], let right = rightEnds[item.id] else { return nil }
            return Ribbon(flow: item, left: left, right: right)
        }
    }
}

// MARK: - Band shape

/// A horizontal band with S-curved edges; its four edge ordinates animate,
/// so a new reading eases the widths instead of jumping. Bands leaving one
/// node leave a hairline between them, as AlDente draws them.
private struct RibbonShape: Shape {
    var x0: CGFloat
    var x1: CGFloat
    var left: SankeyLayout.Span
    var right: SankeyLayout.Span

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(left.top, left.bottom), AnimatablePair(right.top, right.bottom)) }
        set {
            left = SankeyLayout.Span(top: newValue.first.first, bottom: newValue.first.second)
            right = SankeyLayout.Span(top: newValue.second.first, bottom: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        let bend = (x1 - x0) * 0.5
        let hair: CGFloat = 0.5
        let lt = left.top + hair, lb = left.bottom - hair
        let rt = right.top + hair, rb = right.bottom - hair
        var path = Path()
        path.move(to: CGPoint(x: x0, y: lt))
        path.addCurve(to: CGPoint(x: x1, y: rt),
                      control1: CGPoint(x: x0 + bend, y: lt),
                      control2: CGPoint(x: x1 - bend, y: rt))
        path.addLine(to: CGPoint(x: x1, y: rb))
        path.addCurve(to: CGPoint(x: x0, y: lb),
                      control1: CGPoint(x: x1 - bend, y: rb),
                      control2: CGPoint(x: x0 + bend, y: lb))
        path.closeSubpath()
        return path
    }
}

// MARK: - Wave (Core Animation)

private struct SankeyWave: Equatable {
    let id: String
    let path: CGPath
    let destination: PowerFlow.Node

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.path == rhs.path && lhs.destination == rhs.destination
    }
}

private struct SankeyWaveLayer: NSViewRepresentable {
    let waves: [SankeyWave]
    let animating: Bool
    let travel: (from: CGFloat, to: CGFloat)
    let pace: Int
    let dark: Bool

    func makeNSView(context: Context) -> SankeyWaveView { SankeyWaveView() }

    func updateNSView(_ view: SankeyWaveView, context: Context) {
        view.apply(waves: waves, animating: animating, travel: travel, pace: pace, dark: dark)
    }
}

/// A subtle monochrome wave per destination. The shared clock preserves
/// continuity as readings change without flashing or cycling through hues.
private final class SankeyWaveView: NSView {
    private struct Band {
        let container = CALayer()
        let mask = CAShapeLayer()
        let gradient = CAGradientLayer()
    }

    private let clock = CALayer()
    private var bands: [String: Band] = [:]
    private var waves: [SankeyWave] = []
    private var animating = false
    private var travel: (from: CGFloat, to: CGFloat) = (0, 0)
    private var pace = 0
    private var dark = true
    private var renderedSize: CGSize = .zero
    private static let sweepKey = "sweep"

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(clock)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clock.frame = bounds
        for band in bands.values {
            band.container.frame = bounds
            band.mask.frame = bounds
            band.gradient.bounds.size.height = bounds.height
            band.gradient.position.y = bounds.midY
        }
        CATransaction.commit()
        if bounds.size != renderedSize {
            apply(waves: waves, animating: animating, travel: travel, pace: pace, dark: dark)
        }
    }

    func apply(waves: [SankeyWave], animating: Bool, travel: (from: CGFloat, to: CGFloat), pace: Int, dark: Bool) {
        let geometryChanged = travel != self.travel
        let sizeChanged = bounds.size != renderedSize
        guard waves != self.waves || animating != self.animating || geometryChanged || sizeChanged
                || pace != self.pace || dark != self.dark else { return }
        self.waves = waves
        self.animating = animating
        self.travel = travel
        self.pace = pace
        self.dark = dark
        renderedSize = bounds.size

        let live = Set(waves.map(\.id))
        for (id, band) in bands where !live.contains(id) {
            band.container.removeFromSuperlayer()
            bands[id] = nil
        }

        let wavePeriod: CGFloat = max(240, min(480, (travel.to - travel.from) * 0.65))
        let repeatCount = max(3, Int(ceil(bounds.width / wavePeriod)) + 2)
        let gradientWidth = CGFloat(repeatCount) * wavePeriod
        let opacity: [CGFloat] = dark ? [0.02, 0.05, 0.16, 0.05] : [0.01, 0.03, 0.11, 0.03]
        let stopCount = repeatCount * opacity.count
        let locations = (0...stopCount).map { NSNumber(value: Double($0) / Double(stopCount)) }
        for wave in waves {
            let isNew = bands[wave.id] == nil
            let band = bands[wave.id] ?? makeBand()
            bands[wave.id] = band

            // Outline follows the SwiftUI band's ease; a new band just appears.
            CATransaction.begin()
            CATransaction.setDisableActions(isNew)
            CATransaction.setAnimationDuration(0.5)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            band.mask.path = wave.path
            CATransaction.commit()

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            band.gradient.colors = (0...stopCount).map { index in
                NSColor(PowerFlow.color(wave.destination)).withAlphaComponent(opacity[index % opacity.count]).cgColor
            }
            band.gradient.locations = locations
            band.gradient.frame = CGRect(x: -wavePeriod, y: 0,
                                         width: gradientWidth, height: bounds.height)
            band.container.isHidden = false
            CATransaction.commit()

            if !animating {
                band.gradient.removeAnimation(forKey: Self.sweepKey)
            } else if band.gradient.animation(forKey: Self.sweepKey) == nil || geometryChanged || sizeChanged {
                let sweep = CABasicAnimation(keyPath: "position.x")
                let origin = band.gradient.position.x
                sweep.fromValue = origin
                sweep.toValue = origin + wavePeriod
                sweep.duration = 1
                sweep.timingFunction = CAMediaTimingFunction(name: .linear)
                sweep.repeatCount = .infinity
                sweep.isRemovedOnCompletion = false
                band.gradient.add(sweep, forKey: Self.sweepKey)
            }
        }

        if animating {
            // Points per second across the band; one animation cycle is one pass.
            let speeds: [CGFloat] = [0, 24, 32, 40, 48]
            setSpeed(Float(speeds[pace] / wavePeriod))
        } else {
            clock.speed = 1
            clock.timeOffset = 0
            clock.beginTime = 0
        }
    }

    private func makeBand() -> Band {
        let band = Band()
        band.container.frame = bounds
        band.mask.frame = bounds
        band.mask.fillColor = NSColor.black.cgColor
        band.container.mask = band.mask
        band.gradient.startPoint = CGPoint(x: 0, y: 0.5)
        band.gradient.endPoint = CGPoint(x: 1, y: 0.5)
        band.container.addSublayer(band.gradient)
        clock.addSublayer(band.container)
        return band
    }

    /// Retimes without a jump: freeze the current local time into
    /// `timeOffset`, restart the clock now, then apply the new rate.
    private func setSpeed(_ speed: Float) {
        guard clock.speed != speed else { return }
        let now = CACurrentMediaTime()
        let local = clock.convertTime(now, from: nil)
        clock.timeOffset = local
        clock.beginTime = now
        clock.speed = speed
    }
}
