import SwiftUI

// MARK: - Agent mark

/// An agent family's mark in a tinted well. While busy, a short arc orbits
/// it.
///
/// `IslandOrbit` is a SwiftUI `.rotationEffect` driven by a `repeatForever`
/// animation, **not** a render-server layer like `DecorativeMotion` — see the
/// warning there and in `UiverseSurfaces.swift`. That matters here because the
/// island's collapsed hot zone is ~220 × 38 pt *inside* a 640 × 386 panel: a
/// brief pointer pass over the notch (WASD-ing under a full-width window) can
/// grow the island to its full expanded box, start the orbit, and then
/// collapse back — and a `repeatForever` keeps the render server interpolating
/// whether or not the view is on screen. Once that happens the panel goes on
/// paying for a full `NSHostingView` layout + rasterization every display
/// cycle at 10 Hz while collapsed (measured; see
/// `docs/technical/17-ui-audit-backlog.md` §7), which is also the likeliest
/// explanation for the *bimodal* idle figures this app shows after a session
/// of interacting with the island: a fresh launch with nibbles ON measures
/// ~2–3 %, the same build minutes later measures ~20–30 % with no further
/// input.
///
/// The fix is to drive the orbit the way the fan rotors and the island's own
/// pulsing dots already are — a Core Animation layer gated on
/// `window?.occlusionState` — and that is deliberately **not** done here: it is
/// a change to the app's most visible surface, it needs an eye on the rotation
/// to confirm nothing regressed visually, and it belongs with the panel-size
/// fix in the backlog entry rather than before it. Deleting the orbit would be
/// the wrong trade — the busy indicator is the point of the badge.
struct IslandAgentBadge: View {
    let agent: IslandAgent
    var busy = false
    var size: CGFloat = 26

    var body: some View {
        let tint = IslandStyle.color(agent)
        ZStack {
            Circle().fill(tint.opacity(0.16))
            IslandAgentMark(agent: agent)
                .frame(width: size * 0.56, height: size * 0.56)
            if busy {
                IslandOrbit(color: tint, lineWidth: max(1.5, size * 0.075))
                    .padding(-size * 0.1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(agent.label + (busy ? " 运行中" : ""))
    }
}

struct IslandAgentMark: View {
    let agent: IslandAgent

    var body: some View {
        switch agent {
        case .claude:
            ProductBrandMark(codex: false)
        case .codex:
            ProductBrandMark(codex: true)
        case .cursor:
            Image(systemName: "cursorarrow.rays")
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
                .foregroundStyle(IslandStyle.color(.cursor))
        }
    }
}

/// A 100°, gradient-tailed arc spinning once every 1.1 s.
struct IslandOrbit: View {
    let color: Color
    var lineWidth: CGFloat = 2
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(AngularGradient(colors: [color.opacity(0), color], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(100)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(spinning ? .linear(duration: 1.1).repeatForever(autoreverses: false) : nil,
                       value: spinning)
            .onAppear { spinning = !reduceMotion }
            .onDisappear { spinning = false }
            .onChange(of: reduceMotion) { _, reduce in spinning = !reduce }
    }
}

// MARK: - Session row

/// One live session: badge, project, what it is doing, context fuel, and a
/// hover affordance that says what a click does.
struct IslandSessionRow: View {
    let session: IslandSession
    let cost: ModelPricing.Estimate?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                IslandAgentBadge(agent: session.agent, busy: session.isBusy)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.project.isEmpty ? session.agent.label : session.project)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(IslandStyle.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if hovered {
                            Image(systemName: "arrow.up.forward")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(IslandStyle.color(session.agent))
                        }
                    }
                    HStack(spacing: 6) {
                        subtitle
                            .frame(maxWidth: .infinity, alignment: .leading)
                        RollingNumberText(costLabel)
                            .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(hasPricedCost ? IslandStyle.amber : IslandStyle.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .layoutPriority(1)
                        if session.contextRatio > 0 {
                            IslandContextGauge(ratio: session.contextRatio, compact: true)
                                .fixedSize()
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: IslandStyle.sessionRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.07 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { if hovered != $0 { hovered = $0 } }
        .animation(IslandStyle.hoverSpring, value: hovered)
        .help("\(session.cwd)\n\(costDetail)")
    }

    private var costLabel: String {
        if let dominant = cost?.cost.dominant {
            return ModelPricing.format(dominant.amount, currency: dominant.currency)
        }
        if let cost, cost.unpricedModels > 0 { return "未计价" }
        return "—"
    }

    private var hasPricedCost: Bool { cost?.cost.dominant != nil }

    private var costDetail: String {
        guard let cost else {
            return session.agent == .cursor ? "Cursor 暂无独立会话 token 用量" : "该会话暂无可计价用量"
        }
        var parts: [String] = []
        if let dominant = cost.cost.dominant {
            parts.append(ModelPricing.format(dominant.amount, currency: dominant.currency))
        }
        if let secondary = cost.cost.secondary {
            parts.append(ModelPricing.format(secondary.amount, currency: secondary.currency))
        }
        if cost.unpricedModels > 0 { parts.append("\(cost.unpricedModels) 个模型未计价") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var subtitle: some View {
        if session.isBusy {
            Text(busyLine)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(IslandStyle.color(session.agent).opacity(0.95))
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            // Coarse relative time; a 30 s tick is plenty and keeps the
            // timeline from waking every second.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("等待输入 · " + IslandFormat.ago(session.updatedAt, now: context.date))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(IslandStyle.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var busyLine: String {
        if !session.activity.isEmpty { return session.activity }
        if !session.model.isEmpty { return session.model + " · 运行中" }
        return "思考中…"
    }
}

/// Context-window fuel: a 36pt capsule and the percentage, amber past 60 %,
/// red past 85 % — the same thresholds as `Theme.contextColor`.
struct IslandContextGauge: View {
    let ratio: Double
    var compact = false

    private var color: Color {
        if ratio < 0.6 { return IslandStyle.mint }
        if ratio < 0.85 { return IslandStyle.amber }
        return IslandStyle.coral
    }

    var body: some View {
        HStack(spacing: 6) {
            if !compact {
                Capsule()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 36, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(color).frame(width: max(4, 36 * min(1, ratio)), height: 4)
                    }
            }
            RollingNumberText("\(Int((ratio * 100).rounded()))%")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(compact ? color : IslandStyle.textSecondary)
                .frame(width: 30, alignment: .trailing)
        }
        .help("上下文窗口占用")
    }
}

/// One module's icon well. Its geometry is a constant so a `Canvas`-drawn
/// product mark and an instrument glyph reserve exactly the same square — that
/// equality is what lets a route page and a hardware page share one grid.
///
/// Instrument glyphs are drawn at 0.62 of the well, the same fraction the
/// product marks use, so the two mark families carry the same optical weight.
struct IslandMarkWell: View {
    let kind: InstrumentGlyph.Kind?
    let mark: IslandAgent?
    let tint: Color

    init(kind: InstrumentGlyph.Kind, tint: Color) {
        self.kind = kind
        self.mark = nil
        self.tint = tint
    }

    init(mark: IslandAgent, tint: Color) {
        self.kind = nil
        self.mark = mark
        self.tint = tint
    }

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.16))
            if let mark {
                IslandAgentMark(agent: mark)
                    .frame(width: IslandStyle.markWellSize * 0.62, height: IslandStyle.markWellSize * 0.62)
            } else if let kind {
                InstrumentGlyph(kind: kind, tint: tint)
                    .frame(width: IslandStyle.markWellSize * 0.62, height: IslandStyle.markWellSize * 0.62)
            }
        }
        .frame(width: IslandStyle.markWellSize, height: IslandStyle.markWellSize)
        .accessibilityHidden(true)
    }
}

// MARK: - Rotating glance

/// One module of a glance card: an instrument glyph (or a product mark) in a
/// tinted well, a figure, and the label that figure is in.
///
/// A module is the card's *only* building block, so the grid is uniform by
/// construction: 20pt well + value line (14) + caption line (11), two rows and
/// two columns, and every page — two modules or four — lands on the same
/// baseline as every other page.
private struct IslandMark: Identifiable {
    let id: String
    /// `InstrumentGlyph` kind. Cards use the app's own icon family rather than
    /// whatever SF Symbol happened to read well at 11pt, so a 磁盘 here and a
    /// 磁盘 in the dashboard are the same drawing.
    let kind: InstrumentGlyph.Kind
    let tint: Color
    let value: String
    let caption: String
    /// Set when the module is better served by a real product mark (the routes).
    var mark: IslandAgent? = nil

    init(id: String, kind: InstrumentGlyph.Kind, tint: Color, value: String, caption: String,
         mark: IslandAgent? = nil) {
        self.id = id
        self.kind = kind
        self.tint = tint
        self.value = value
        self.caption = caption
        self.mark = mark
    }

    /// The gauges and the balance card need a figure with a symbol in front of
    /// it; everything else is a bare index.
    init(id: String, symbol: String, tint: Color, value: String, caption: String) {
        self.init(id: id, kind: InstrumentGlyph.kind(for: symbol) ?? .config,
                  tint: tint, value: value, caption: caption)
    }
}

/// One page of the island's right-hand reel. Identity stays stable so a
/// host-stat refresh does not restart the playback task.
private struct IslandGlance: Identifiable {
    let id: String
    let title: String
    let marks: [IslandMark]
    /// The one band that is always the same width on every page: the card.
    var columns = 2
}

/// Auto-advancing status in the space beside the sessions. Playback lives on
/// this view; the rest of the island does not tick with it.
///
/// **Not mounted.** Nothing instantiates this reel (or `NetworkGlancePage`),
/// and `NotchIslandView`'s expanded content is the header + session strip +
/// `IslandUsageCard` only — so `ProcessSampler.MonitorScope.island` and the
/// island tier of `FanMonitor`, which only this view activates, are currently
/// unreachable, and `IslandStyle`'s `glance*` / `mark*` / `pager*` constants
/// are read by nothing but `Tests/island-reel-regressions.py`. Kept as the
/// finished design for that band; mount it in `NotchIslandView.expandedContent`
/// or delete it together with its test.
///
/// Every page is the same 2×2 module grid under a section band, and pages are
/// *grouped by subject* rather than by whatever data happened to arrive:
/// 额度 → 余额 → 算力 → 内存 → 网络 → 外设 → 会话 → 用量 → 路由. Six of those are
/// hardware, so the old single "本机 / 网络与磁盘" pair no longer mixes CPU%,
/// disk capacity and VPN state in one breath.
struct IslandGlanceReel: View {
    let balances: [ProviderStore.SupplierBalance]
    let quota: [CodexQuotaWindow]
    let sessions: [IslandSession]
    let usage: IslandUsage
    let claudeRoute: String
    let codexRoute: String
    let vpnRunning: Bool
    @State private var index = 0
    @State private var paused = false
    @State private var host = ProcessSampler.shared.host
    @State private var fanRPM: [Int] = FanMonitor.shared.fans.prefix(2).map(\.rpm)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Page id of the network card — the one page whose marks come from the
    /// traffic stream, and so the one page rendered by `NetworkGlancePage`.
    static let networkPageID = "network"

    private var slides: [IslandGlance] {
        var frames: [IslandGlance] = []
        if !quota.isEmpty {
            frames.append(IslandGlance(id: "quota", title: "Codex 额度", marks: quotaMarks))
        }
        if !balances.isEmpty {
            frames.append(IslandGlance(id: "balance", title: "供应商余额", marks: balanceMarks))
        }
        frames.append(IslandGlance(id: "compute", title: "算力", marks: computeMarks))
        frames.append(IslandGlance(id: "memory", title: "内存与存储", marks: memoryMarks))
        // Marks are drawn by `NetworkGlancePage`; the frame is here for the
        // pager count and the page order.
        frames.append(IslandGlance(id: Self.networkPageID, title: "网络", marks: []))
        if !peripheralMarks.isEmpty {
            frames.append(IslandGlance(id: "peripheral", title: "电源与外设", marks: peripheralMarks))
        }
        if !agentMarks.isEmpty {
            frames.append(IslandGlance(id: "sessions", title: "会话", marks: agentMarks))
        }
        frames.append(IslandGlance(id: "usage", title: "用量", marks: usageMarks))
        let routes = Array(routeMarks.prefix(2))
        if !routes.isEmpty {
            frames.append(IslandGlance(id: "route", title: "当前模型", marks: routes,
                                       columns: routes.count))
        }
        return frames
    }

    // MARK: quotal

    /// Remaining allowance per Codex window, in the order the quota fetcher
    /// returns them (primary window first). Only two windows ever exist, so the
    /// pair reads as one sentence: "5 小时窗口还剩 39%，重置在 2 小时 21 分后".
    private var quotaMarks: [IslandMark] {
        quota.prefix(2).map { window in
            let remaining = Int(max(0, min(100, 100 - window.usedPercent)).rounded())
            // The clock, not the wait: "5 天后" is the same caption on every
            // poll, while "9月29日 14:30" is a fact you can act on. The wait is
            // still on the hover text.
            let when = window.resetClock.replacingOccurrences(of: " 重置", with: "")
            return IslandMark(id: window.label,
                              // Two half-open gauges would read as the same
                              // instrument twice; the bars mirror what the
                              // dashboard draws for the same two windows.
                              kind: window.label.contains("5") ? .quota : .tokens,
                              tint: remaining <= 10 ? IslandStyle.coral : IslandStyle.cobalt,
                              value: "\(remaining)%",
                              caption: when.isEmpty ? window.label : when)
        }
    }

    // MARK: balance

    /// Provider balances, one module each. The currency symbol is already in
    /// the amount, so the caption is free to be the thing you actually cannot
    /// see anywhere else on the island: which account the money is in.
    private var balanceMarks: [IslandMark] {
        balances.prefix(4).map { balance in
            IslandMark(id: balance.id.uuidString, symbol: "creditcard", tint: IslandStyle.mint,
                       value: balance.amount, caption: balance.name)
        }
    }

    // MARK: compute

    /// CPU and GPU load, then the two temperatures that say whether that load
    /// is a problem. Temperature modules are only added when the sensors
    /// actually answer, so a machine without SMC does not show two blanks.
    private var computeMarks: [IslandMark] {
        var marks = [
            IslandMark(id: "cpu", kind: .cpu, tint: IslandStyle.mint,
                       value: "\(Int(host.cpu.rounded()))%", caption: "CPU 负载"),
            IslandMark(id: "gpu", kind: .gpu, tint: IslandStyle.cobalt,
                       value: "\(Int(host.gpu.rounded()))%", caption: "GPU 负载"),
        ]
        if let celsius = host.cpuTemperatureCelsius, celsius > 0 {
            marks.append(IslandMark(id: "cpu-temp", kind: .power,
                                    tint: temperatureTint(celsius),
                                    value: "\(Int(celsius.rounded()))°C", caption: "CPU 温度"))
        }
        if let celsius = host.gpuTemperatureCelsius, celsius > 0 {
            marks.append(IslandMark(id: "gpu-temp", kind: .power,
                                    tint: temperatureTint(celsius),
                                    value: "\(Int(celsius.rounded()))°C", caption: "GPU 温度"))
        }
        return marks
    }

    /// The dashboard's own thresholds: normal below 75°, amber below 85°.
    private func temperatureTint(_ celsius: Double) -> Color {
        if celsius >= 85 { return IslandStyle.coral }
        if celsius >= 75 { return IslandStyle.amber }
        return IslandStyle.textSecondary
    }

    // MARK: memory & storage

    /// Memory and storage as *absolute* usage with the machine's own capacity
    /// as the caption. "84%" alone says nothing about whether it is time to
    /// close something; "13.5/16.0 GB" does.
    private var memoryMarks: [IslandMark] {
        let memoryUsed = ProcessSampler.Snapshot(memoryBytes: host.memoryUsed).memoryLabel
        let memoryTotal = ProcessSampler.Snapshot(memoryBytes: host.memoryTotal).memoryLabel
        let diskUsed = ProcessSampler.Snapshot(memoryBytes: host.diskUsed).memoryLabel
        let diskTotal = ProcessSampler.Snapshot(memoryBytes: host.diskTotal).memoryLabel
        let pressure = host.memoryPressureLevel
        return [
            IslandMark(id: "mem", kind: .memory,
                       tint: pressure >= 4 ? IslandStyle.coral
                           : (pressure >= 2 ? IslandStyle.amber : IslandStyle.violet),
                       value: memoryUsed,
                       caption: "内存 · 共 \(memoryTotal)"),
            IslandMark(id: "disk", kind: .disk, tint: IslandStyle.violet,
                       value: "\(Int(host.diskPercent.rounded()))%",
                       caption: "磁盘 · 共 \(diskTotal)"),
        ]
    }

    // MARK: network
    //
    // The network page's marks live on `NetworkGlancePage` below, which is the
    // single observer of the traffic stream.

    // MARK: power & peripherals

    /// Battery, its draw and its temperature — the three things the hardware
    /// strip answers when you are on battery, and the ones the old card
    /// dropped entirely.
    private var peripheralMarks: [IslandMark] {
        var marks: [IslandMark] = []
        if host.batteryInstalled {
            marks.append(IslandMark(id: "battery",
                                    kind: .battery,
                                    tint: host.batteryPercent <= 20 ? IslandStyle.coral
                                        : (host.batteryCharging ? IslandStyle.mint : IslandStyle.violet),
                                    value: "\(host.batteryPercent)%",
                                    caption: host.batteryCharging ? "电池 · 充电中" : "电池 · 放电中"))
        }
        if let watts = adapterWatts {
            marks.append(IslandMark(id: "adapter", kind: .power, tint: IslandStyle.amber,
                                    value: String(format: "%.0f W", abs(watts)), caption: "电源输入"))
        }
        if let celsius = host.batteryTemperatureCelsius, celsius > 0 {
            marks.append(IslandMark(id: "battery-temp", kind: .power, tint: temperatureTint(celsius),
                                    value: String(format: "%.0f°C", celsius), caption: "电池温度"))
        }
        if let fan = fanRPM.first {
            marks.append(IslandMark(id: "fan-0", kind: .fan, tint: IslandStyle.clay,
                                    value: "\(fan)", caption: fanRPM.count > 1 ? "左风扇 RPM" : "风扇 RPM"))
        }
        return marks
    }

    /// Adapter input when it is plugged in, battery draw when it is not.
    private var adapterWatts: Double? {
        host.batteryExternalPower ? host.powerInputWatts
            : (host.powerBatteryWatts.map { abs($0) } ?? host.powerSystemWatts)
    }

    // MARK: sessions

    /// One module per agent family that has sessions: how many are alive and
    /// how many of them are working right now.
    private var agentMarks: [IslandMark] {
        IslandAgent.allCases.compactMap { agent in
            let group = sessions.filter { $0.agent == agent }
            guard !group.isEmpty else { return nil }
            let busy = group.filter(\.isBusy).count
            return IslandMark(id: agent.rawValue, kind: agent.markKind,
                              tint: IslandStyle.color(agent),
                              value: "\(group.count)",
                              caption: busy > 0 ? "\(agent.label) · \(busy) 运行中" : "\(agent.label) · 空闲")
        }
    }

    // MARK: usage

    /// Today and the month, with the two facts that give them scale: how today
    /// compares with yesterday, and how far through the month we are.
    private var usageMarks: [IslandMark] {
        var marks = [
            IslandMark(id: "today", kind: .tokens, tint: IslandStyle.mint,
                       value: UsageStats.formatTokens(usage.today), caption: "今日 Token"),
            IslandMark(id: "month", kind: .tokens, tint: IslandStyle.cobalt,
                       value: UsageStats.formatTokens(usage.month), caption: "本月 Token"),
        ]
        if let pace = IslandUsage.pace(usage.today, usage.yesterday) {
            marks.append(IslandMark(id: "pace", kind: .overview,
                                    tint: pace >= 1 ? IslandStyle.amber : IslandStyle.mint,
                                    value: "\(Int((pace * 100).rounded()))%",
                                    caption: "对比昨日"))
        }
        marks.append(IslandMark(id: "calls", kind: .traffic, tint: IslandStyle.amber,
                                value: usage.todayCalls.formatted(), caption: "今日调用"))
        if let cost = usage.todayCost.cost.dominant {
            marks.append(IslandMark(id: "cost", kind: .cost, tint: IslandStyle.amber,
                                    value: ModelPricing.format(cost.amount, currency: cost.currency),
                                    caption: "今日花费"))
        }
        return marks
    }

    // MARK: routes

    private var routeMarks: [IslandMark] {
        var marks: [IslandMark] = []
        if !claudeRoute.isEmpty {
            marks.append(routeMark(id: "claude", mark: .claude, tint: IslandStyle.clay,
                                   title: "Claude Code", route: claudeRoute))
        }
        if !codexRoute.isEmpty {
            marks.append(routeMark(id: "codex", mark: .codex, tint: IslandStyle.cobalt,
                                   title: "Codex", route: codexRoute))
        }
        return marks
    }

    /// "DeepSeek · v4" is a provider and a model, not one string: the model is
    /// what you set, the provider is what answers. Split them into the value
    /// and the caption so the module says both.
    private func routeMark(id: String, mark: IslandAgent, tint: Color,
                           title: String, route: String) -> IslandMark {
        let parts = route.split(separator: "·", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let provider = parts.first ?? route
        let model = parts.count > 1 ? parts[1] : ""
        return IslandMark(id: id, kind: mark.markKind, tint: tint,
                          value: model.isEmpty ? provider : model,
                          caption: model.isEmpty ? title : "\(title) · \(provider)",
                          mark: mark)
    }

    var body: some View {
        let frames = slides
        let current = frames.isEmpty ? 0 : min(index, frames.count - 1)
        ZStack(alignment: .top) {
            if frames.indices.contains(current) {
                // The network page is the only one whose marks depend on the
                // 4 Hz traffic stream, so it is the only one that observes
                // `VpnLiveRates`. Observing it here rebuilt every page (and
                // re-ran `String(format:)`, `VpnFormat.bytes` and the memory
                // labels for all ~9 of them) four times a second.
                if frames[current].id == Self.networkPageID {
                    NetworkGlancePage(host: host, vpnRunning: vpnRunning)
                        .id(frames[current].id)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity.combined(with: .offset(y: -8))))
                } else {
                    glance(frames[current])
                        .id(frames[current].id)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity.combined(with: .offset(y: -8))))
                }
            }
        }
        .frame(width: IslandStyle.glanceCardSize.width,
               height: IslandStyle.glanceCardSize.height,
               alignment: .top)
        .padding(IslandStyle.glanceCardPadding)
        .frame(width: IslandStyle.glanceReelWidth,
               height: IslandStyle.glanceReelHeight,
               alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // The pager is pinned from the outer box, so it holds one line while
        // the reel turns and no page can move it.
        .overlay(alignment: .bottom) {
            pager(frames: frames, current: current)
                .padding(.bottom, IslandStyle.pagerInset)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Edge-triggered: `.active` re-fires on every pointer move, and the
        // write is unconditional, so hovering across the reel used to
        // invalidate it (and rebuild all ~9 glance pages) at pointer rate.
        .onContinuousHover { phase in
            switch phase {
            case .active: if !paused { paused = true }
            case .ended: if paused { paused = false }
            }
        }
        .onTapGesture {
            guard frames.count > 1 else { return }
            let next = (current + 1) % frames.count
            if reduceMotion { index = next } else { withAnimation(.easeInOut(duration: 0.45)) { index = next } }
        }
        .onAppear {
            // The reel is the only island surface that shows host stats, so it
            // is what tells the sampler its numbers are on screen.
            ProcessSampler.shared.setScope(.island, active: true)
            ProcessSampler.shared.start()
            FanMonitor.shared.start()
        }
        .onDisappear {
            ProcessSampler.shared.setScope(.island, active: false)
            FanMonitor.shared.stop()
        }
        .task(id: frames.map(\.id).joined(separator: "|")) {
            await play(count: frames.count)
        }
        .help("自动切换额度、余额、算力、内存、网络、外设、会话和用量，点击看下一张")
    }

    /// Pager dots: one fixed strip pinned to the card's bottom edge. Never
    /// measured out of the current card's content, so the dots hold their
    /// line while the reel turns.
    private func pager(frames: [IslandGlance], current: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(frames.indices, id: \.self) { item in
                Capsule()
                    .fill(Color.white.opacity(item == current ? 0.85 : 0.22))
                    .frame(width: item == current ? 12 : 4, height: 4)
            }
        }
        .frame(height: IslandStyle.pagerDotHeight)
    }

    private func glance(_ frame: IslandGlance) -> some View {
        IslandGlanceCard(frame: frame)
    }

    private func play(count: Int) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4.2))
            if Task.isCancelled { return }
            let fresh = ProcessSampler.shared.host
            if fresh != host { host = fresh }
            let rpms = FanMonitor.shared.fans.prefix(2).map(\.rpm)
            if rpms != fanRPM { fanRPM = rpms }
            guard !paused, count > 1 else { continue }
            let next = (index + 1) % count
            if reduceMotion {
                index = next
            } else {
                withAnimation(.easeInOut(duration: 0.45)) { index = next }
            }
        }
    }
}

/// The fixed grid every glance page is drawn on: a section band over a
/// `frame.columns`-wide grid of fixed-height modules. Shared by the reel and by
/// the network page, which is rendered on its own so only it observes the
/// traffic stream.
private struct IslandGlanceCard: View {
    let frame: IslandGlance

    var body: some View {
        VStack(alignment: .leading, spacing: IslandStyle.cardTitleGap) {
            Text(frame.title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(IslandStyle.textTertiary)
                .lineLimit(1)
                .frame(height: IslandStyle.cardTitleHeight, alignment: .leading)
            Group {
                if frame.marks.count >= 4 {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4),
                                             count: frame.columns),
                              spacing: IslandStyle.markRowSpacing) {
                        ForEach(frame.marks.prefix(4)) { markCell($0) }
                    }
                } else {
                    HStack(spacing: 4) {
                        ForEach(frame.marks) { markCell($0) }
                    }
                }
            }
            .frame(maxWidth: 160)
            .frame(maxWidth: .infinity)
        }
        // The card body is a fixed box: title band + two module rows. A reel of
        // cards can then never disagree about height.
        .frame(height: IslandStyle.cardBodyHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One fixed-height module: the well, a value and a caption always occupy
    /// the same box, so a card never resizes the lane while the reel turns.
    private func markCell(_ mark: IslandMark) -> some View {
        VStack(spacing: IslandStyle.markCellSpacing) {
            if let agent = mark.mark {
                IslandMarkWell(mark: agent, tint: mark.tint)
            } else {
                IslandMarkWell(kind: mark.kind, tint: mark.tint)
            }
            RollingNumberText(mark.value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(IslandStyle.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(height: IslandStyle.markValueHeight)
            Text(mark.caption)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(IslandStyle.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: IslandStyle.markCaptionHeight)
        }
        .frame(maxWidth: .infinity)
        .frame(height: IslandStyle.markCellHeight, alignment: .top)
    }
}

/// The island's network page. Split out of `IslandGlanceReel` so that the
/// 4 Hz `VpnLiveRates` stream invalidates only this card, instead of the reel
/// and every page it holds.
private struct NetworkGlancePage: View {
    let host: ProcessSampler.HostStats
    let vpnRunning: Bool
    /// The 4 Hz traffic stream, observed *here* rather than on the reel — that
    /// is the whole point of this view existing.
    @ObservedObject private var rates = VpnLiveRates.shared

    var body: some View {
        IslandGlanceCard(frame: IslandGlance(id: IslandGlanceReel.networkPageID,
                                            title: "网络",
                                            marks: marks))
    }

    private var marks: [IslandMark] {
        let rssi = host.wifiRSSI
        let quality: String = {
            guard host.wifiOn, rssi < 0 else { return host.wifiOn ? "开" : "关" }
            if rssi >= -55 { return "强" }
            if rssi >= -70 { return "中" }
            return "弱"
        }()
        let address = host.wifiName.isEmpty ? (host.wiredOn ? "有线" : "Wi-Fi") : host.wifiName
        var marks = [
            IslandMark(id: "wifi", kind: .link,
                       tint: host.wifiOn ? IslandStyle.cobalt : IslandStyle.textSecondary,
                       value: quality, caption: address),
            IslandMark(id: "vpn", kind: .vpn,
                       tint: vpnRunning ? IslandStyle.mint : IslandStyle.textSecondary,
                       value: vpnRunning ? "已连接" : "关闭", caption: "VPN 代理"),
        ]
        // Throughput only once the proxy has actually seen traffic; an idle
        // VPN that has never carried a byte would otherwise claim "0.0 KB/s"
        // as if it were a reading.
        let speedDown = rates.speedDown
        let speedUp = rates.speedUp
        if speedDown > 0 || speedUp > 0 {
            marks.append(IslandMark(id: "down", kind: .traffic, tint: IslandStyle.mint,
                                    value: VpnFormat.bytes(speedDown).trimmingCharacters(in: .whitespaces),
                                    caption: "下载 /s"))
            marks.append(IslandMark(id: "up", kind: .traffic, tint: IslandStyle.cobalt,
                                    value: VpnFormat.bytes(speedUp).trimmingCharacters(in: .whitespaces),
                                    caption: "上传 /s"))
        }
        return marks
    }
}

// MARK: - Usage card

/// Today's number, a 30-day histogram you can scrub by hovering, and the
/// month's pace with its source split underneath.
struct IslandUsageCard: View {
    let usage: IslandUsage
    @State private var scrubIndex: Int?
    @State private var histogramWidth: CGFloat = 1
    /// Re-identifies this card's figures when the token unit style changes —
    /// see `TokenStyleGenerationKey`.
    @Environment(\.tokenStyleGeneration) private var tokenStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                hero
                    .frame(maxWidth: .infinity, alignment: .leading)
                costHero
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 64, alignment: .top)
            IslandHistogram(days: usage.days, highlighted: scrubIndex)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let next = index(at: point.x)
                        if next != scrubIndex { scrubIndex = next }
                    case .ended: if scrubIndex != nil { scrubIndex = nil }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { histogramWidth = $0 }
            monthLine
                .frame(height: 14)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        // Scoped to this card's own figures: the identity change that re-renders
        // them must not reach the session strip or the header beside it.
        .id(tokenStyle)
    }

    private func index(at x: CGFloat) -> Int? {
        guard !usage.days.isEmpty, histogramWidth > 0 else { return nil }
        let slot = histogramWidth / CGFloat(usage.days.count)
        return max(0, min(usage.days.count - 1, Int(x / slot)))
    }

    private var scrubbed: IslandDay? {
        guard let scrubIndex, usage.days.indices.contains(scrubIndex) else { return nil }
        return usage.days[scrubIndex]
    }

    private var hero: some View {
        let day = scrubbed
        let value = day?.tokens ?? usage.today
        return VStack(alignment: .leading, spacing: 2) {
            Text(day.map { IslandFormat.dayLabel($0.date) } ?? "今日 Token")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(IslandStyle.textTertiary)
                .contentTransition(.opacity)
            RollingNumberText(UsageStats.formatTokens(value))
                .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(day == nil ? IslandStyle.mint : IslandStyle.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            RollingNumberText(heroCaption(day))
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(IslandStyle.textSecondary)
                .lineLimit(1)
        }
        .animation(.snappy(duration: 0.18), value: value)
    }

    private var costHero: some View {
        let day = scrubbed
        let estimate = day?.cost ?? usage.todayCost
        return VStack(alignment: .leading, spacing: 2) {
            Text(day.map { IslandFormat.dayLabel($0.date) + " 花费" } ?? "今日花费")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(IslandStyle.textTertiary)
            RollingNumberText(estimate.cost.dominant.map { ModelPricing.format($0.amount, currency: $0.currency) } ?? "—")
                .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(IslandStyle.amber)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if !costCaption(estimate).isEmpty {
                RollingNumberText(costCaption(estimate))
                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(IslandStyle.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func costCaption(_ estimate: ModelPricing.Estimate) -> String {
        if let secondary = estimate.cost.secondary {
            return "另有 " + ModelPricing.format(secondary.amount, currency: secondary.currency)
        }
        if estimate.unpricedModels > 0 { return "\(estimate.unpricedModels) 个模型未计价" }
        return estimate.isEmpty ? "暂无用量" : ""
    }

    private func heroCaption(_ day: IslandDay?) -> String {
        if let day {
            let peak = usage.days.map(\.tokens).max() ?? 0
            guard peak > 0, day.tokens > 0 else { return "无用量" }
            return "峰值的 \(Int((Double(day.tokens) / Double(peak) * 100).rounded()))%"
        }
        let calls = "\(usage.todayCalls.formatted()) 次"
        guard let pace = IslandUsage.pace(usage.today, usage.yesterday) else { return calls }
        return "昨日的 \(Int((pace * 100).rounded()))% · " + calls
    }

    private var monthLine: some View {
        HStack(spacing: 10) {
            Text("本月")
                .foregroundStyle(IslandStyle.textTertiary)
            RollingNumberText(UsageStats.formatTokens(usage.month))
                .foregroundStyle(IslandStyle.textPrimary)
            if let pace = IslandUsage.pace(usage.month, usage.lastMonthSameSpan) {
                Text("上月同期 \(Int((pace * 100).rounded()))%")
                    .foregroundStyle(pace >= 1 ? IslandStyle.amber : IslandStyle.textSecondary)
            }
            Spacer(minLength: 8)
            IslandSourceSplit(values: usage.monthBySource)
                .frame(width: 100, height: 6)
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
        .lineLimit(1)
    }
}

/// 30 bars in one `Canvas` pass: one view, one draw, regardless of count.
struct IslandHistogram: View {
    let days: [IslandDay]
    let highlighted: Int?

    var body: some View {
        Canvas { context, size in
            guard !days.isEmpty else { return }
            let peak = CGFloat(max(days.map(\.tokens).max() ?? 0, 1))
            let slot = size.width / CGFloat(days.count)
            let barWidth = max(2, slot * 0.62)
            for (index, day) in days.enumerated() {
                let fraction = CGFloat(day.tokens) / peak
                let height = day.tokens > 0 ? max(3, size.height * fraction) : 2
                let rect = CGRect(x: CGFloat(index) * slot + (slot - barWidth) / 2,
                                  y: size.height - height, width: barWidth, height: height)
                let isToday = index == days.count - 1
                let color: Color
                if index == highlighted {
                    color = .white
                } else if isToday {
                    color = IslandStyle.mint
                } else {
                    color = Color.white.opacity(day.tokens > 0 ? 0.24 : 0.08)
                }
                context.fill(Path(roundedRect: rect, cornerRadius: min(barWidth / 2, 2)), with: .color(color))
            }
        }
        .accessibilityLabel("近 30 天用量")
    }
}

/// Month-to-date share per source as one segmented capsule.
struct IslandSourceSplit: View {
    let values: [Int]

    var body: some View {
        let total = max(values.reduce(0, +), 1)
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(Array(UsageSource.allCases.enumerated()), id: \.element) { index, source in
                    let value = index < values.count ? values[index] : 0
                    if value > 0 {
                        Capsule()
                            .fill(IslandStyle.color(source))
                            .frame(width: max(3, (proxy.size.width - 4) * CGFloat(value) / CGFloat(total)))
                    }
                }
            }
        }
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .clipShape(Capsule())
        .help(helpText(total: total))
    }

    private func helpText(total: Int) -> String {
        UsageSource.allCases.enumerated().map { index, source in
            let value = index < values.count ? values[index] : 0
            return "\(source.label) \(UsageStats.formatTokens(value)) · \(Int((Double(value) / Double(total) * 100).rounded()))%"
        }.joined(separator: "\n")
    }
}

// MARK: - Formatting

enum IslandFormat {
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86400)) 天前"
    }

    static func dayLabel(_ date: Date) -> String {
        UsageStats.formatter("M月d日 EEE").string(from: date)
    }
}
