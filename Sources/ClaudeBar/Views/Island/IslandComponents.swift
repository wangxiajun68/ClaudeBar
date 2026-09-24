import SwiftUI

// MARK: - Agent mark

/// An agent family's mark in a tinted well. While busy, a short arc orbits
/// it — a single `rotationEffect` driven by a repeating animation, so the
/// render server interpolates it without re-running any view body.
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
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                IslandAgentBadge(agent: session.agent, busy: session.isBusy)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.project.isEmpty ? session.agent.label : session.project)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(IslandStyle.textPrimary)
                        .lineLimit(1)
                    subtitle
                }
                Spacer(minLength: 10)
                if hovered {
                    HStack(spacing: 3) {
                        Text(session.agent == .cursor ? "打开" : "继续")
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(IslandStyle.color(session.agent))
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else if session.contextRatio > 0 {
                    IslandContextGauge(ratio: session.contextRatio)
                        .transition(.opacity)
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
        .onHover { hovered = $0 }
        .animation(IslandStyle.hoverSpring, value: hovered)
        .help(session.cwd)
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

    private var color: Color {
        if ratio < 0.6 { return IslandStyle.mint }
        if ratio < 0.85 { return IslandStyle.amber }
        return IslandStyle.coral
    }

    var body: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(Color.white.opacity(0.1))
                .frame(width: 36, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(color).frame(width: max(4, 36 * min(1, ratio)), height: 4)
                }
            Text("\(Int((ratio * 100).rounded()))%")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(IslandStyle.textSecondary)
                .frame(width: 30, alignment: .trailing)
        }
        .help("上下文窗口占用")
    }
}

/// One mark's icon well. Its geometry is a constant so a `Canvas`-drawn
/// glyph and an SF Symbol reserve the same square.
struct IslandMarkWell: View {
    let symbol: String?
    let mark: IslandAgent?

    init(symbol: String, tint: Color) {
        self.symbol = symbol
        self.mark = nil
        self.tint = tint
    }

    init(mark: IslandAgent, tint: Color) {
        self.symbol = nil
        self.mark = mark
        self.tint = tint
    }

    let tint: Color

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.16))
            if let mark {
                IslandAgentMark(agent: mark)
                    .frame(width: IslandStyle.markWellSize * 0.62, height: IslandStyle.markWellSize * 0.62)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: IslandStyle.markWellSize, height: IslandStyle.markWellSize)
        .accessibilityHidden(true)
    }
}

// MARK: - Rotating glance

/// One icon on a glance card. Several marks of the same kind share a card.
private struct IslandMark: Identifiable {
    let id: String
    let symbol: String
    let tint: Color
    let value: String
    let caption: String
    /// Set when the mark has a real product glyph (the route cards).
    var mark: IslandAgent? = nil
}

/// One frame of the island's right-hand reel. Identity stays stable so a
/// host-stat refresh does not restart the playback task.
private struct IslandGlance: Identifiable {
    let id: String
    let title: String
    let marks: [IslandMark]
}

/// Auto-advancing status, in the space the session filters used to occupy.
/// Playback lives on this view: the rest of the island does not tick with it.
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

    private var slides: [IslandGlance] {
        var frames: [IslandGlance] = []
        if !quota.isEmpty {
            frames.append(IslandGlance(id: "quota", title: "Codex 额度", marks: quota.prefix(2).map { window in
                let remaining = Int(max(0, min(100, 100 - window.usedPercent)).rounded())
                let when = (window.resetWait.isEmpty ? window.resetClock : window.resetWait)
                    .replacingOccurrences(of: "重置", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return IslandMark(id: window.label, symbol: "gauge.with.dots.needle.67percent",
                                  tint: remaining <= 10 ? IslandStyle.coral : IslandStyle.cobalt,
                                  value: "\(remaining)%", caption: when.isEmpty ? window.label : when)
            }))
        }
        if !balances.isEmpty {
            frames.append(IslandGlance(id: "balance", title: "供应商余额", marks: balances.prefix(4).map { balance in
                IslandMark(id: balance.id.uuidString, symbol: "creditcard", tint: IslandStyle.mint,
                           value: balance.amount, caption: balance.name)
            }))
        }
        frames.append(IslandGlance(id: "host", title: "本机", marks: hostMarks))
        frames.append(IslandGlance(id: "link", title: "网络与磁盘", marks: linkMarks))
        if !fanRPM.isEmpty {
            frames.append(IslandGlance(id: "fans", title: "风扇", marks: fanRPM.enumerated().map { offset, rpm in
                IslandMark(id: "fan-\(offset)", symbol: "fanblades", tint: IslandStyle.clay,
                           value: "\(rpm)", caption: fanRPM.count == 2 ? (offset == 0 ? "左" : "右") : "转速")
            }))
        }
        let sessionMarks = agentMarks
        if !sessionMarks.isEmpty {
            frames.append(IslandGlance(id: "sessions", title: "会话", marks: sessionMarks))
        }
        frames.append(IslandGlance(id: "usage", title: "用量", marks: usageMarks))
        let routes = Array(routeMarks.prefix(2))
        if !routes.isEmpty {
            frames.append(IslandGlance(id: "route", title: "当前模型", marks: routes))
        }
        return frames
    }

    private var hostMarks: [IslandMark] {
        let memory = host.memoryTotal > 0
            ? Int((Double(host.memoryUsed) / Double(host.memoryTotal) * 100).rounded()) : 0
        var marks = [
            IslandMark(id: "cpu", symbol: "cpu", tint: IslandStyle.mint,
                       value: "\(Int(host.cpu.rounded()))%", caption: "CPU"),
            IslandMark(id: "gpu", symbol: "square.3.layers.3d", tint: IslandStyle.cobalt,
                       value: "\(Int(host.gpu.rounded()))%", caption: "GPU"),
            IslandMark(id: "mem", symbol: "memorychip", tint: IslandStyle.amber,
                       value: "\(memory)%", caption: "内存"),
        ]
        if host.batteryInstalled {
            marks.append(IslandMark(id: "battery", symbol: host.batteryCharging ? "battery.100percent.bolt" : "battery.100percent",
                                    tint: IslandStyle.violet, value: "\(host.batteryPercent)%", caption: "电池"))
        }
        return marks
    }

    private var linkMarks: [IslandMark] {
        let signal: String = {
            guard host.wifiOn, host.wifiRSSI < 0 else { return host.wifiOn ? "开" : "关" }
            return "\(host.wifiRSSI)"
        }()
        var marks = [
            IslandMark(id: "disk", symbol: "internaldrive", tint: IslandStyle.violet,
                       value: "\(Int(host.diskPercent.rounded()))%", caption: "磁盘"),
            IslandMark(id: "wifi", symbol: host.wifiOn ? "wifi" : "wifi.slash", tint: IslandStyle.cobalt,
                       value: signal, caption: host.wifiName.isEmpty ? "Wi-Fi" : host.wifiName),
            IslandMark(id: "vpn", symbol: vpnRunning ? "lock.shield" : "lock.slash",
                       tint: vpnRunning ? IslandStyle.mint : IslandStyle.textSecondary,
                       value: vpnRunning ? "已连接" : "关闭", caption: "VPN"),
        ]
        if let watts = host.powerSystemWatts ?? host.powerBatteryWatts {
            marks.append(IslandMark(id: "power", symbol: "bolt.fill", tint: IslandStyle.amber,
                                    value: String(format: "%.0fW", abs(watts)), caption: "功耗"))
        }
        return marks
    }

    private var agentMarks: [IslandMark] {
        IslandAgent.allCases.compactMap { agent in
            let group = sessions.filter { $0.agent == agent }
            guard !group.isEmpty else { return nil }
            let busy = group.filter(\.isBusy).count
            return IslandMark(id: agent.rawValue, symbol: agent.glanceSymbol, tint: IslandStyle.color(agent),
                              value: "\(group.count)", caption: busy > 0 ? "\(busy) 忙" : "空闲")
        }
    }

    private var usageMarks: [IslandMark] {
        [
            IslandMark(id: "today", symbol: "sun.max", tint: IslandStyle.mint,
                       value: UsageStats.formatTokens(usage.today), caption: "今日"),
            IslandMark(id: "yesterday", symbol: "moon", tint: IslandStyle.textSecondary,
                       value: UsageStats.formatTokens(usage.yesterday), caption: "昨日"),
            IslandMark(id: "month", symbol: "calendar", tint: IslandStyle.cobalt,
                       value: UsageStats.formatTokens(usage.month), caption: "本月"),
            IslandMark(id: "calls", symbol: "arrow.left.arrow.right", tint: IslandStyle.amber,
                       value: "\(usage.todayCalls)", caption: "今日次数"),
        ]
    }

    private var routeMarks: [IslandMark] {
        var marks: [IslandMark] = []
        if !claudeRoute.isEmpty {
            marks.append(routeMark(id: "claude", symbol: "sparkle", tint: IslandStyle.clay,
                                   title: "Claude", route: claudeRoute))
        }
        if !codexRoute.isEmpty {
            marks.append(routeMark(id: "codex", symbol: "terminal", tint: IslandStyle.cobalt,
                                   title: "Codex", route: codexRoute))
        }
        return marks
    }

    private func routeMark(id: String, symbol: String, tint: Color, title: String, route: String) -> IslandMark {
        let parts = route.split(separator: "·", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let model = parts.count > 1 ? parts[1] : parts[0]
        return IslandMark(id: id, symbol: symbol, tint: tint, value: model, caption: title, mark: routeAgent(id))
    }

    /// The route cards reuse the agent's own glyph, so the 当前模型 slide reads
    /// the same as the header's route chip.
    private func routeAgent(_ id: String) -> IslandAgent? {
        id == "claude" ? .claude : (id == "codex" ? .codex : nil)
    }

    var body: some View {
        let frames = slides
        let current = frames.isEmpty ? 0 : min(index, frames.count - 1)
        ZStack(alignment: .top) {
            if frames.indices.contains(current) {
                glance(frames[current])
                    .id(frames[current].id)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 8)),
                        removal: .opacity.combined(with: .offset(y: -8))))
            }
        }
        .frame(width: IslandStyle.glanceCardSize.width,
               height: IslandStyle.glanceCardSize.height,
               alignment: .top)
        .padding(IslandStyle.glanceCardPadding)
        .overlay(alignment: .bottom) {
            if frames.count > 1 {
                pager(frames: frames, current: current)
                    .padding(.bottom, IslandStyle.pagerInset)
            }
        }
        // Outside the padding: the card's total box, independent of what any
        // card draws inside it.
        .frame(width: IslandStyle.glanceCardSize.width + 2 * IslandStyle.glanceCardPadding,
               height: IslandStyle.glanceReelHeight,
               alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.045)))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            guard frames.count > 1 else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                index = (current + 1) % frames.count
            }
        }
        .onHover { paused = $0 }
        .onAppear { FanMonitor.shared.start() }
        .onDisappear { FanMonitor.shared.stop() }
        .task(id: frames.map(\.id).joined(separator: "|")) {
            await play(count: frames.count)
        }
        .help("自动切换额度、余额、本机、网络、会话和用量，点击看下一张")
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
        VStack(alignment: .leading, spacing: IslandStyle.cardTitleGap) {
            Text(frame.title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(IslandStyle.textTertiary)
                .lineLimit(1)
                .frame(height: IslandStyle.cardTitleHeight, alignment: .leading)
            if frame.marks.count >= 4 {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 2),
                          spacing: IslandStyle.markRowSpacing) {
                    ForEach(frame.marks.prefix(4)) { markCell($0) }
                }
            } else {
                HStack(spacing: 4) {
                    ForEach(frame.marks) { markCell($0) }
                }
            }
        }
        // The card body is a fixed box: title band + two mark rows. A reel of
        // cards can then never disagree about height.
        .frame(height: IslandStyle.cardBodyHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One fixed-height cell: the well, a value and a caption always occupy
    /// the same box, so a card never resizes the lane while the reel turns.
    private func markCell(_ mark: IslandMark) -> some View {
        VStack(spacing: 3) {
            if let agent = mark.mark {
                IslandMarkWell(mark: agent, tint: mark.tint)
            } else {
                IslandMarkWell(symbol: mark.symbol, tint: mark.tint)
            }
            Text(mark.value)
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

// MARK: - Usage card

/// Today's number, a 30-day histogram you can scrub by hovering, and the
/// month's pace with its source split underneath.
struct IslandUsageCard: View {
    let usage: IslandUsage
    @State private var scrubIndex: Int?
    @State private var histogramWidth: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 14) {
                hero
                    .frame(width: 138, alignment: .leading)
                IslandHistogram(days: usage.days, highlighted: scrubIndex)
                    .frame(height: 46)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): scrubIndex = index(at: point.x)
                        case .ended: scrubIndex = nil
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { histogramWidth = $0 }
            }
            monthLine
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
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
            Text(day.map { IslandFormat.dayLabel($0.date) } ?? "今日")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(IslandStyle.textTertiary)
                .contentTransition(.opacity)
            Text(UsageStats.formatTokens(value))
                .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(day == nil ? IslandStyle.mint : IslandStyle.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(heroCaption(day))
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(IslandStyle.textSecondary)
                .lineLimit(1)
        }
        .animation(.snappy(duration: 0.18), value: value)
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
            Text(UsageStats.formatTokens(usage.month))
                .foregroundStyle(IslandStyle.textPrimary)
                .contentTransition(.numericText())
            if let pace = IslandUsage.pace(usage.month, usage.lastMonthSameSpan) {
                Text("上月同期 \(Int((pace * 100).rounded()))%")
                    .foregroundStyle(pace >= 1 ? IslandStyle.amber : IslandStyle.textSecondary)
            }
            Spacer(minLength: 8)
            IslandSourceSplit(values: usage.monthBySource)
                .frame(width: 150, height: 6)
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
