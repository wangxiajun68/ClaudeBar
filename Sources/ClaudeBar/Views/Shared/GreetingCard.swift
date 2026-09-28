import SwiftUI

/// A sky window: handwritten greeting, quiet instruments, one glass sill.
/// Weather motion is visibility-gated; the clock owns its one-second ticker.
struct GreetingCard: View {
    @ProviderState([.usage, .configuration]) private var providerStore
    @EnvironmentObject private var codexStore: CodexProviderStore
    @State private var weather = WeatherStore.shared
    @State private var city = AppPreferences.shared.weatherCity
    @State private var costDisplay = AppPreferences.shared.costDisplay
    @ObservedObject private var fx = ExchangeRate.shared
    @ObservedObject private var cursor = CursorUsageStore.shared
    @Environment(\.surfaceIsVisible) private var surfaceVisible
    var onNavigate: (AppPage) -> Void = { _ in }

    private var ccModel: String {
        let live = providerStore.currentEnv?.ANTHROPIC_MODEL ?? ""
        return live.isEmpty ? (providerStore.activeModel?.name ?? "未配置") : live
    }

    private var codexModel: String {
        codexStore.configuredModel ?? "默认模型"
    }

    private var balance: String {
        if let providerID = codexStore.configuredProviderID,
           let amount = providerStore.balanceAmounts[providerID] { return amount }
        if codexStore.usesOfficialAccount, let credits = codexStore.creditBalance { return credits }
        return providerStore.balanceLoading || codexStore.quotaLoading ? "查询中" : "未提供余额"
    }

    private var spend: String {
        let shown = ModelPricing.present(providerStore.todayUsage.cost.cost,
                                         display: costDisplay, rate: fx.effectiveRate)
        guard let primary = shown.primary else { return "暂无报价" }
        return ModelPricing.format(primary.amount, currency: primary.currency)
    }

    var body: some View {
        GreetingStatusSheet(
            name: MachineIdentity.greetingName,
            ccModel: ccModel,
            ccProvider: providerStore.activeProvider?.name ?? "Claude Code",
            codexModel: codexModel,
            codexProvider: codexStore.usesOfficialAccount ? "ChatGPT" : (codexStore.providers.first { $0.id == codexStore.configuredProviderID }?.name ?? "Codex"),
            balance: balance,
            tokens: providerStore.todayUsage.tokens,
            yesterdayTokens: providerStore.todayUsage.yesterdayTokens,
            calls: providerStore.todayUsage.calls,
            spend: spend,
            windows: codexStore.quotaWindows,
            quotaLoading: codexStore.quotaLoading,
            quotaNote: codexStore.quotaNote,
            cursorPlan: cursor.plan,
            cursorLoading: cursor.loading,
            cursorNote: cursor.note,
            reading: weather.reading,
            city: city,
            weatherLoading: weather.loading,
            weatherNote: weather.note,
            refreshWeather: { weather.refresh() },
            refreshQuota: { codexStore.refreshQuota(manual: true) },
            refreshCursor: { cursor.refresh(manual: true) },
            showModels: { onNavigate(.providers) },
            showUsage: { onNavigate(.usage) }
        )
        .onReceive(AppPreferences.shared.$weatherCity.removeDuplicates()) { value in
            guard city != value else { return }
            city = value
            weather.refresh()
        }
        .onReceive(AppPreferences.shared.$costDisplay.removeDuplicates()) { costDisplay = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            codexStore.refreshConfiguredModel()
        }
        .onAppear { codexStore.refreshConfiguredModel(); cursor.refresh() }
        .task(id: surfaceVisible) {
            guard surfaceVisible else { return }
            while !Task.isCancelled {
                weather.refreshIfStale()
                do { try await Task.sleep(for: .seconds(WeatherStore.staleAfter + 15)) }
                catch { return }
            }
        }
    }
}

/// Pure presentation also used by the native rendering fixture. Sample data
/// never enters the stores or live dashboard.
struct GreetingStatusSheet: View {
    var name: String
    var ccModel: String
    var ccProvider: String
    var codexModel: String
    var codexProvider: String
    var balance: String
    var tokens: Int
    var yesterdayTokens: Int
    var calls: Int
    var spend: String
    var windows: [CodexQuotaWindow]
    /// The allowance's live state. `quotaLoading` is what the lane shows while
    /// the reading is being re-taken; `quotaNote` is what it says when there is
    /// no reading to draw at all.
    var quotaLoading: Bool
    var quotaNote: String?
    /// Cursor's own monthly allowance. Cursor is a client family the app
    /// watches (see `ProductBrandMark`), and its plan is the third allowance the
    /// card can read — so the model/sill zone names it beside CC and Codex
    /// rather than leaving it to the popup's chip.
    var cursorPlan: CursorUsageFetcher.PlanUsage?
    var cursorLoading: Bool
    var cursorNote: String?
    var reading: WeatherReading?
    var city: String
    var weatherLoading: Bool
    var weatherNote: String?
    var refreshWeather: () -> Void
    var refreshQuota: () -> Void
    var refreshCursor: () -> Void
    var showModels: () -> Void
    var showUsage: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false
    @State private var skyDate = Date()
    @State private var timeOffset: Double = 0
    @State private var pointer = CGSize.zero
    @State private var rewindTask: Task<Void, Never>?
    @Environment(\.surfaceIsVisible) private var visible

    // The scene is "here and now": the sky clock plus any drag offset. The
    // forecast card is a separate, self-contained reading, so it never mutates
    // this — one glance at a future day must not repaint the whole window.
    private var sceneDate: Date { skyDate.addingTimeInterval(timeOffset) }
    private var astronomy: SkyAstronomy.Snapshot? { reading?.astronomy(at: sceneDate) }
    private var sceneSky: WeatherReading.Sky { reading?.sky ?? .cloudy }
    private var sceneNight: Bool { astronomy?.night ?? (reading?.isDay == false) }


    private var palette: SkyPalette {
        if reading != nil { return SkyPalette(sky: sceneSky, night: sceneNight).daybreak(elevation: sceneSky == .clear || sceneSky == .partly ? astronomy?.sun.altitude : nil) }
        return .neutral
    }
    private var previewTime: String {
        sceneDate.formatted(Date.FormatStyle(date: .omitted, time: .shortened,
            timeZone: TimeZone(identifier: reading?.timezone ?? "") ?? .current))
    }
    private var border: Color { palette.ink.opacity(0.16) }
    /// The height of the sky band. It came down from a fixed 400pt when the
    /// dock's forecast zone was folded into the weather HUD: the whole card was
    /// too tall, and the sky was carrying the slack. The greeting is still
    /// framed with room to breathe, and the window now reads as a *band* rather
    /// than a poster.
    ///
    /// The height is the `GeometryReader`'s own frame, so it cannot be read from
    /// `geo` inside; `_windowWidth` is written on that reader's first pass (and
    /// on any resize) so the height and the HUD's width agree on "narrow".
    private var windowNarrow: Bool { _windowWidth < 700 }
    private var skyHeight: CGFloat { windowNarrow ? 272 : 300 }
    @State private var _windowWidth: CGFloat = 1100

    // THESIS: a signature suspended in a real sky, with instruments on a glass sill.
    // WORLD: deep atmospheric blue, ivory calligraphy, serif signature, restrained gold.
    // STORY: read the greeting, glance at the weather, act on quota or usage.
    // COMPOSITION: corner HUDs, open central sky, one three-part dock; stacked on narrow windows.
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 12)
                            .onChanged { value in
                                guard reading?.latitude != nil, reading?.longitude != nil else { return }
                                rewindTask?.cancel()
                                timeOffset = max(-43200, min(43200, value.translation.width / max(1, geo.size.width) * 86400))
                            }
                            .onEnded { _ in
                                returnToNow()
                            })
                        .focusable()
                        .onKeyPress(.leftArrow) { adjustSky(by: -3600); return .handled }
                        .onKeyPress(.rightArrow) { adjustSky(by: 3600); return .handled }
                        .onKeyPress(.escape) { returnToNow(); return .handled }
                        .accessibilityLabel("天空时间预览")
                        .accessibilityValue(timeOffset == 0 ? "现在" : previewTime)
                        .accessibilityAction(named: Text("前一小时")) { adjustSky(by: -3600) }
                        .accessibilityAction(named: Text("后一小时")) { adjustSky(by: 3600) }
                        .accessibilityAction(named: Text("回到现在")) { returnToNow() }
                        .help("拖动或按左右方向键预览天空；松手或按 Esc 回到现在")
                    HStack(alignment: .top) {
                        GreetingClock(ink: palette.ink, secondary: palette.inkSoft, timezone: reading?.timezone)
                        Spacer(minLength: 24)
                        weatherBlock.frame(width: windowNarrow ? 236 : 292)
                    }
                    .padding(geo.size.width < 650 ? 24 : 32)
                    // The greeting stops before the HUD's column: the two are
                    // the only things on the top half of the band, and on the
                    // short band a full-width greeting ran under the forecast
                    // strip. `- 96` is the HUD's own width plus the gutter.
                    let hudWidth: CGFloat = windowNarrow ? 236 : 292
                    SkyGreeting(name: name, palette: palette, phrase: GreetingPhrase.forDate(skyDate),
                                lightX: astronomy.map { $0.sun.azimuth / 360 } ?? 0.5)
                        .frame(width: geo.size.width - hudWidth - 96, height: windowNarrow ? 148 : 170)
                        .offset(x: 32 + pointer.width * 0.4, y: windowNarrow ? 112 : 126)
                        .allowsHitTesting(false)
                    if reading != nil {
                        SkyVeil(sky: sceneSky, night: sceneNight)
                            .offset(x: pointer.width * 0.8, y: pointer.height * 0.5)
                            .allowsHitTesting(false)
                    }
                    HStack(spacing: 6) {
                        if reading != nil { Image(systemName: timeOffset == 0 ? "sun.horizon" : "clock.arrow.circlepath") }
                        if timeOffset != 0 {
                            Text("天空预览 · \(previewTime) · 松手回到现在")
                        } else if let reading, !reading.sunset.isEmpty {
                            Text("日落 \(reading.sunset)")
                            Text("·").opacity(0.5)
                            Text("拖动天空，漫游一天").opacity(0.8)
                        }
                    }
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.ink.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.horizontal, 36).padding(.bottom, 16)
                    .allowsHitTesting(false)
                }
                .onContinuousHover { phase in
                    guard !reduceMotion, visible else { pointer = .zero; return }
                    switch phase {
                    case .active(let point):
                        pointer = CGSize(width: (point.x / max(1, geo.size.width) - 0.5) * 20,
                                         height: (point.y / max(1, geo.size.height) - 0.5) * 12)
                    case .ended: pointer = .zero
                    }
                }
                .onAppear { _windowWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, width in _windowWidth = width }
            }
            .frame(height: skyHeight)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    modelCell.frame(maxWidth: .infinity)
                    dockDivider
                    todayCell.frame(width: 240)
                }.frame(minWidth: 640)
                HStack(spacing: 20) {
                    modelCell.frame(maxWidth: .infinity)
                    dockDivider
                    todayCell.frame(maxWidth: .infinity)
                }
            }
            .padding(20)
            .modifier(DaybreakGlass(dark: !palette.isLightGround))
            .padding(.horizontal, 24).padding(.bottom, 24)
            .modifier(StatusArrival(arrived: arrived, delay: 0.25, reduceMotion: reduceMotion))
        }
        .background {
            ZStack {
                palette.gradient
                if let reading {
                    WeatherBackdrop(sky: sceneSky, isDay: !sceneNight,
                                    intensity: reading.rainChance,
                                    astronomy: astronomy, windKph: reading.windKph)
                        .offset(x: pointer.width * 0.2, y: pointer.height * 0.2)
                    LinearGradient(stops: [
                        .init(color: Color(hex: 0x0A1530).opacity(0.08), location: 0),
                        .init(color: Color(hex: 0x0A1530).opacity(0.12), location: 0.40),
                        .init(color: Color(hex: 0x0A1530).opacity(0.78), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                    SkyGrain().opacity(0.035)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 2.4), value: sceneSky)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: sceneNight)
        }
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .strokeBorder(LinearGradient(colors: [palette.ink.opacity(0.32), palette.ink.opacity(0.06)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
        .onAppear { arrived = true }
        .onDisappear { rewindTask?.cancel(); timeOffset = 0 }
        .task(id: visible) {
            guard visible else { return }
            while !Task.isCancelled {
                skyDate = Date()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func adjustSky(by seconds: Double) {
        guard reading?.latitude != nil, reading?.longitude != nil else { return }
        rewindTask?.cancel()
        timeOffset = min(43200, max(-43200, timeOffset + seconds))
    }

    private func returnToNow() {
        rewindTask?.cancel()
        guard !reduceMotion else { timeOffset = 0; return }
        let origin = timeOffset
        rewindTask = Task { @MainActor in
            for frame in 1...30 {
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                guard !Task.isCancelled else { return }
                let progress = Double(frame) / 30
                timeOffset = origin * pow(1 - progress, 3)
            }
            timeOffset = 0
        }
    }

    private func resetCountdown(_ window: CodexQuotaWindow) -> String {
        guard let reset = window.resetsAt else { return "重置未知" }
        let minutes = max(0, Int(reset.timeIntervalSince(skyDate) / 60))
        if minutes == 0 { return "待重置" }
        if minutes >= 1440 { return "\(minutes / 1440)天后重置" }
        return String(format: "↻ %d:%02d", minutes / 60, minutes % 60)
    }

    private var dockDivider: some View {
        Rectangle().fill(border).frame(width: 0.5, height: 96).padding(.horizontal, 20)
    }

    /// Cursor's monthly plan, read the same way the Codex lane is: a ring, the
    /// used percentage, and the reset. It sits in the model zone because it is
    /// the third *client* the app watches, not because Cursor has a model to
    /// manage — the row is a **reading**, and clicking it re-reads the plan
    /// rather than opening anything.
    ///
    /// The ring's motion is a one-shot `.bounce` while the reading is being
    /// refreshed, gated on visibility and Reduce Motion. Like every other mark
    /// on the card it carries no repeating timer, so an idle card animates
    /// nothing.
    private var cursorRow: some View {
        Button(action: refreshCursor) {
            HStack(spacing: 8) {
                cursorRing
                cursorCaption
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(cursorLoading).opacity(cursorLoading ? 0.55 : 1)
        .help(cursorHelp)
        .accessibilityLabel(cursorAccessibility)
    }

    /// The ring, or a turning arrow while there is nothing to draw yet.
    @ViewBuilder private var cursorRing: some View {
        ZStack {
            Circle().stroke(palette.ink.opacity(0.14), lineWidth: 3)
            Circle()
                .trim(from: 0, to: cursorFraction)
                .stroke(cursorTint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if cursorPlan == nil {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .symbolEffect(.rotate, options: .repeating, isActive: cursorSpinning)
            }
        }
        .frame(width: 26, height: 26)
    }

    @ViewBuilder private var cursorCaption: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let plan = cursorPlan {
                Text("Cursor · 已用 \(cursorPercent)%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                Text(cursorPlanDetail(plan))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.ink.opacity(0.82))
                    .lineLimit(1).minimumScaleFactor(0.75)
            } else {
                Text(cursorLoading ? "正在读取 Cursor 额度…" : (cursorNote ?? "暂无 Cursor 额度"))
                    .font(.system(size: 10, weight: .medium)).lineLimit(2)
                    .foregroundStyle(palette.ink.opacity(0.86))
            }
        }
    }

    private var cursorFraction: Double { cursorPlan.map { min(1, max(0, $0.usedFraction)) } ?? 0 }
    private var cursorPercent: Int { Int((cursorFraction * 100).rounded()) }
    private var cursorSpinning: Bool { cursorLoading && !reduceMotion && visible }
    private var cursorHelp: String { "点击刷新 Cursor 额度" + (cursorNote.map { " · \($0)" } ?? "") }
    private var cursorAccessibility: String {
        "刷新 Cursor 额度，" + (cursorPlan == nil ? (cursorNote ?? "暂无读数") : "已用 \(cursorPercent)%")
    }

    private var cursorTint: Color {
        let used = cursorPlan?.usedFraction ?? 0
        if used >= 0.9 { return Color(hex: 0xFF8A75) }
        if used >= 0.75 { return Color(hex: 0xFFD37A) }
        return palette.accent
    }

    /// The line under the percentage: what the plan is and when it returns.
    private func cursorPlanDetail(_ plan: CursorUsageFetcher.PlanUsage) -> String {
        var parts: [String] = []
        if let spend = plan.spendText { parts.append(spend) }
        if let reset = plan.resetsAt {
            let days = max(0, Int(reset.timeIntervalSince(skyDate) / 86400))
            parts.append(days <= 0 ? "待重置" : "\(days) 天后重置")
        }
        return parts.isEmpty ? "月度额度" : parts.joined(separator: " · ")
    }

    private var modelCell: some View {
        VStack(alignment: .leading, spacing: 14) {
            modelIdentity(codex: false, model: ccModel, provider: ccProvider)
            modelIdentity(codex: true, model: codexModel, provider: codexProvider)
            cursorRow
            HStack(spacing: 10) {
                Button(action: refreshQuota) {
                    HStack(spacing: 8) {
                        QuotaOrbit(windows: windows, ink: palette.ink).frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            if let window = windows.first {
                                Text("已用 \(Int(min(100, max(0, window.usedPercent)).rounded()))%")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                Text("\(window.label) · \(resetCountdown(window))")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(palette.ink.opacity(0.82))
                                    .lineLimit(1).minimumScaleFactor(0.8)
                                if let second = windows.dropFirst().first {
                                    Text("\(second.label) · 已用 \(Int(min(100, max(0, second.usedPercent)).rounded()))%")
                                        .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(palette.ink.opacity(0.82))
                                        .lineLimit(1).minimumScaleFactor(0.8)
                                }
                            } else {
                                Text(quotaPlacard).font(.system(size: 10, weight: .medium)).lineLimit(2)
                            }
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(quotaLoading).opacity(quotaLoading ? 0.5 : 1)
                    .help("点击刷新 · " + quotaHelp).accessibilityLabel("刷新 Codex 额度，" + quotaHelp)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    if balanceWarning { Circle().fill(Color(hex: 0xFFB84D)).frame(width: 4, height: 4) }
                    Text(balance).lineLimit(1).minimumScaleFactor(0.8)
                }.font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(balanceWarning ? (palette.isLightGround ? Color(hex: 0x8C4B00) : Color(hex: 0xFFCC80)) : palette.ink.opacity(0.82))
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .background(palette.ink.opacity(0.07), in: Capsule()).help("账户余额：" + balance)
            }
        }.foregroundStyle(palette.ink)
    }

    private func modelIdentity(codex: Bool, model: String, provider: String) -> some View {
        Button(action: showModels) {
            HStack(spacing: 9) {
                ProductBrandMark(codex: codex, well: false, page: !palette.isLightGround)
                    .frame(width: 20, height: 20)
                    .modifier(MarkNudge(motion: arrived && !reduceMotion && visible))
                Text(model).font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text(provider).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(palette.ink.opacity(0.85))
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(palette.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).help("\(codex ? "Codex" : "Claude Code") · \(model) · 打开模型管理")
            .accessibilityLabel("\(codex ? "Codex" : "Claude Code")，\(model)，\(provider)，打开模型管理")
    }

    private var balanceWarning: Bool {
        let number = balance.split(separator: " ").first.map(String.init) ?? ""
        return Double(number).map { $0 <= 0 } ?? false
    }

    private var quotaPlacard: String {
        if quotaLoading { return "正在读取额度…" }
        if let quotaNote, !quotaNote.isEmpty { return quotaNote }
        return "暂无额度数据"
    }

    private var quotaHelp: String {
        guard !windows.isEmpty else { return quotaNote ?? "暂无额度数据" }
        return windows.map {
            let wait = $0.resetWait.isEmpty ? "" : "（\($0.resetWait)）"
            return "\($0.label)已用 \(Int($0.usedPercent.rounded()))%，\($0.resetClock)\(wait)"
        }
        .joined(separator: " · ")
    }

    private var todayCell: some View {
        Button(action: showUsage) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("今日用量").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.ink.opacity(0.82))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 10))
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(UsageStats.formatTokens(tokens))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit().rollingNumber(valueKey: String(tokens))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    if yesterdayTokens > 0 {
                        let change = (Double(tokens) / Double(yesterdayTokens) - 1) * 100
                        Text(String(format: "%@%.0f%%", change >= 0 ? "↑" : "↓", abs(change)))
                            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(palette.isLightGround ? palette.accent : Color(hex: 0x7CE7B8))
                    }
                }
                TokenComparison(today: tokens, yesterday: yesterdayTokens, tint: palette.accent, secondary: palette.inkSoft)
                    .frame(height: 12)
                HStack {
                    Text("昨日 \(UsageStats.formatTokens(yesterdayTokens))")
                    Spacer()
                    Text("Token")
                }.font(.system(size: 9, weight: .medium)).foregroundStyle(palette.ink.opacity(0.78))
                Text("\(spend) · \(calls.formatted()) 次")
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(palette.ink.opacity(0.84))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }.foregroundStyle(palette.ink).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help("今日与昨日总量对比 · 费用按模型价格估算 · 点击查看用量")
            .accessibilityLabel("今日 \(tokens) Token，预估费用 \(spend)，昨日 \(yesterdayTokens) Token，\(calls) 次调用，查看用量")
    }

    private var weatherAccessibility: String {
        let value = reading.map { "\(Int($0.temperatureC.rounded()))度，\($0.skyLabel)" } ?? "暂无天气"
        return "\(reading?.place ?? city)，\(value)，\(weatherLoading ? "正在更新" : weatherNote ?? "")"
    }

    private var weatherBlock: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "location.fill").font(.system(size: 8, weight: .bold))
                Text(reading?.place.isEmpty == false ? reading!.place : (city.isEmpty ? "请设置城市" : city))
                    .font(.system(size: 10, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Button(action: refreshWeather) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                        .symbolEffect(.rotate, options: .repeating, isActive: weatherLoading && !reduceMotion && visible)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(weatherLoading)
                    .help(weatherNote ?? reading.map { "刷新天气 · 更新于 \($0.observedAt.formatted(date: .omitted, time: .shortened))" } ?? "刷新天气")
                    .accessibilityLabel("刷新天气")
            }.foregroundStyle(palette.ink.opacity(0.82))
            Button(action: refreshWeather) {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: (reading?.sky ?? .cloudy).symbol(night: reading?.isDay == false))
                            .symbolRenderingMode(.palette).foregroundStyle(palette.accent, palette.ink)
                            .font(.system(size: 27, weight: .semibold))
                        Text(reading?.temperatureText ?? "—°")
                            .font(.system(size: 43, weight: .semibold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reading?.skyLabel ?? (weatherLoading ? "获取中" : "暂无天气"))
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1).minimumScaleFactor(0.7)
                            if let reading {
                                Text("\(Int(reading.lowC.rounded()))° – \(Int(reading.highC.rounded()))°")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(palette.ink.opacity(0.75))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    if let reading {
                        DaybreakTemperatureRange(low: reading.lowC, high: reading.highC, current: reading.temperatureC)
                            .frame(height: 8)
                    }
                    if weatherNote != nil {
                        Label(reading == nil ? "获取失败 · 点击重试" : "更新失败 · 显示上次读数", systemImage: "exclamationmark.circle")
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(palette.ink.opacity(0.85))
                    }
                    // The trend line: six slim days under the current reading.
                    // It is the piece the dock's forecast zone used to carry, at
                    // the scale a glance needs — see `ForecastStrip`.
                    if reading?.forecast.isEmpty == false {
                        Rectangle().fill(palette.ink.opacity(0.16)).frame(height: 0.5).padding(.vertical, 4)
                        ForecastStrip(reading: reading, palette: palette, now: skyDate)
                    }
                }.padding(.bottom, 4).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(weatherLoading)
                .accessibilityLabel(weatherAccessibility).accessibilityHint("刷新天气")
        }
        .foregroundStyle(palette.ink).padding(.horizontal, 16).padding(.vertical, 10)
        .modifier(DaybreakGlass(dark: !palette.isLightGround, hud: true))
    }

}

private struct DaybreakGlass: ViewModifier {
    var dark: Bool
    var hud = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(dark ? Color(hex: 0x12233D) : Color(hex: 0xD5DEEA), in: RoundedRectangle(cornerRadius: 24))
        } else if #available(macOS 26.0, *) {
            content.background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(dark ? Color(hex: 0x07182F).opacity(hud ? 0.16 : 0.55) : .white.opacity(0.04))
                    .glassEffect(.regular.tint(dark ? Color(hex: 0x07182F).opacity(hud ? 0.12 : 0.5) : .white.opacity(0.04)),
                                 in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        } else {
            content
                .background((dark ? Color(hex: 0x07182F).opacity(hud ? 0.16 : 0.70) : Color.white.opacity(0.04)), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .background(.ultraThinMaterial.opacity(dark ? 0.2 : 0.35), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5))
        }
    }
}

struct DaybreakTemperatureRange: View {
    var low: Double
    var high: Double
    var current: Double?
    var body: some View {
        GeometryReader { geo in
            Capsule().fill(LinearGradient(colors: [Color(hex: 0x7FC8FF), Color(hex: 0xFFB05C)], startPoint: .leading, endPoint: .trailing))
                .frame(height: 4).frame(maxHeight: .infinity)
            if let current {
                Circle().fill(.white).frame(width: 8, height: 8)
                    .offset(x: max(0, geo.size.width - 8) * min(1, max(0, (current - low) / max(1, high - low))))
            }
        }.accessibilityHidden(true)
    }
}

private struct GreetingClock: View {
    var ink: Color
    var secondary: Color
    var timezone: String?
    @Environment(\.surfaceIsVisible) private var visible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !visible)) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
                        .font(.system(size: 44, weight: .medium, design: .rounded)).monospacedDigit()
                    VStack(spacing: 5) {
                        Text(String(format: "%02d", Calendar.current.component(.second, from: context.date)))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced)).contentTransition(reduceMotion ? .identity : .numericText())
                        ZStack(alignment: .leading) {
                            Rectangle().fill(ink.opacity(0.2))
                            Rectangle().fill(ink.opacity(0.7)).frame(width: 20 * Double(Calendar.current.component(.second, from: context.date)) / 60)
                        }.frame(width: 20, height: 1)
                    }.foregroundStyle(ink.opacity(0.65))
                }
                Text(context.date.formatted(.dateTime.month().day().weekday(.abbreviated).locale(Locale(identifier: "zh_CN"))))
                    .font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(ink.opacity(0.82))
                if let timezone, let zone = TimeZone(identifier: timezone), zone.secondsFromGMT(for: context.date) != TimeZone.current.secondsFromGMT(for: context.date) {
                    Text("天气当地 \(context.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)))")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(secondary)
                }
            }.foregroundStyle(ink)
        }.accessibilityElement(children: .combine)
    }
}

private struct QuotaOrbit: View {
    var windows: [CodexQuotaWindow]
    var ink: Color
    var body: some View {
        ZStack {
            ForEach(Array(windows.prefix(2).enumerated()), id: \.offset) { index, window in
                let used = min(100, max(0, window.usedPercent))
                let tint = Color(hex: used > 85 ? 0xFF8A75 : used >= 60 ? 0xFFD37A : 0x7FD6FF)
                Circle().stroke(ink.opacity(0.12), lineWidth: 3).padding(CGFloat(index) * 6)
                Circle().trim(from: 0, to: used / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(CGFloat(index) * 6)
            }
            if windows.isEmpty { Image(systemName: "arrow.clockwise").font(.system(size: 16)) }
        }.accessibilityHidden(true)
    }
}

private struct TokenComparison: View {
    var today: Int
    var yesterday: Int
    var tint: Color
    var secondary: Color
    var body: some View {
        GeometryReader { geo in
            let maximum = Double(max(1, max(today, yesterday)))
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(tint)
                    .frame(width: geo.size.width * Double(max(0, today)) / maximum, height: 4)
                Capsule().fill(secondary.opacity(0.4))
                    .frame(width: geo.size.width * Double(max(0, yesterday)) / maximum, height: 3)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct StatusArrival: ViewModifier {
    var arrived: Bool
    var delay: Double
    var reduceMotion: Bool
    func body(content: Content) -> some View {
        content
            .offset(y: arrived || reduceMotion ? 0 : 8)
            .opacity(arrived || reduceMotion ? 1 : 0.75)
            .animation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.88).delay(delay), value: arrived)
    }
}

/// One property change, applied in a single frame — so the brand mark's gentle
/// scale needs no `value:`-keyed animation (the inflight guard forbids one on
/// the per-poll figure components, and a hover/keyed animation here would
/// re-rasterise the mark on every pointer move for a change nothing sees).
///
/// `motion` is already gated on `!reduceMotion && visible` by the caller; when it
/// flips the mark settles at its resting size, so Reduce Motion keeps the card
/// still and an off-screen surface does no work.
private struct MarkNudge: ViewModifier {
    var motion: Bool
    @State private var settled = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(motion && !settled ? 1.12 : 1)
            .onAppear {
                guard motion else { return }
                settled = true
            }
            .transaction { $0.animation = nil }
    }
}
