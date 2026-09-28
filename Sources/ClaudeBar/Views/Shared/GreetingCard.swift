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
            reading: weather.reading,
            city: city,
            weatherLoading: weather.loading,
            weatherNote: weather.note,
            refreshWeather: { weather.refresh() },
            refreshQuota: { codexStore.refreshQuota(manual: true) },
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
        .onAppear { codexStore.refreshConfiguredModel() }
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
    var reading: WeatherReading?
    var city: String
    var weatherLoading: Bool
    var weatherNote: String?
    var refreshWeather: () -> Void
    var refreshQuota: () -> Void
    var showModels: () -> Void
    var showUsage: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false
    @State private var selectedDate: Date?
    @State private var weatherDetails = false
    @State private var skyDate = Date()
    @State private var timeOffset: Double = 0
    @State private var pointer = CGSize.zero
    @Environment(\.surfaceIsVisible) private var visible

    private var selectedDay: WeatherDay? { reading?.forecast.first { $0.date == selectedDate } }
    private var sceneDate: Date {
        guard let selectedDay else { return skyDate.addingTimeInterval(timeOffset) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: reading?.timezone ?? "") ?? .current
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: selectedDay.date) ?? selectedDay.date
    }
    private var astronomy: SkyAstronomy.Snapshot? { reading?.astronomy(at: sceneDate) }
    private var sceneSky: WeatherReading.Sky { selectedDay?.sky ?? reading?.sky ?? .cloudy }
    private var sceneNight: Bool { astronomy?.night ?? (selectedDay == nil && reading?.isDay == false) }


    private var palette: SkyPalette {
        if reading != nil { return SkyPalette(sky: sceneSky, night: sceneNight).daybreak(elevation: sceneSky == .clear || sceneSky == .partly ? astronomy?.sun.altitude : nil) }
        return .neutral
    }
    private var border: Color { palette.ink.opacity(0.16) }

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
                                timeOffset = max(-43200, min(43200, value.translation.width / max(1, geo.size.width) * 86400))
                            }
                            .onEnded { _ in
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.8)) { timeOffset = 0 }
                            })
                        .help("横向拖动天空预览一天，松手回到现在")
                    HStack(alignment: .top) {
                        GreetingClock(ink: palette.ink, secondary: palette.inkSoft, timezone: reading?.timezone)
                        Spacer(minLength: 24)
                        weatherBlock.frame(width: geo.size.width < 650 ? 190 : 218)
                    }
                    .padding(geo.size.width < 650 ? 24 : 32)
                    SkyGreeting(name: name, palette: palette, phrase: GreetingPhrase.forDate(skyDate),
                                lightX: astronomy.map { $0.sun.azimuth / 360 } ?? 0.5)
                        .frame(width: geo.size.width - 64, height: geo.size.width < 650 ? 190 : 232)
                        .offset(x: 32 + pointer.width * 0.4, y: geo.size.width < 650 ? 160 : 136)
                        .allowsHitTesting(false)
                    if reading != nil {
                        SkyVeil(sky: sceneSky, night: sceneNight)
                            .offset(x: pointer.width * 0.8, y: pointer.height * 0.5)
                            .allowsHitTesting(false)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: timeOffset == 0 ? "sun.horizon" : "clock.arrow.circlepath")
                        if timeOffset != 0 {
                            Text("天空预览 · \(sceneDate.formatted(.dateTime.hour().minute())) · 松手回到现在")
                        } else if let reading, !reading.sunset.isEmpty {
                            Text("日落 \(reading.sunset)")
                            Text("·").opacity(0.5)
                            Text("拖动天空，漫游一天").opacity(0.8)
                        }
                    }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(palette.ink.opacity(0.72))
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
            }.frame(height: 400)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    forecastDock.frame(maxWidth: .infinity)
                    dockDivider
                    modelCell.frame(maxWidth: .infinity)
                    dockDivider
                    todayCell.frame(width: 240)
                }.frame(minWidth: 920)
                VStack(spacing: 16) {
                    forecastDock
                    Rectangle().fill(border).frame(height: 0.5)
                    HStack(spacing: 20) {
                        modelCell.frame(maxWidth: .infinity)
                        dockDivider
                        todayCell.frame(maxWidth: .infinity)
                    }
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
                                    intensity: selectedDay?.rainChance ?? reading.rainChance,
                                    astronomy: astronomy, windKph: selectedDay?.wind ?? reading.windKph)
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
        .popover(isPresented: $weatherDetails, attachmentAnchor: .point(.topTrailing), arrowEdge: .trailing) {
            if let reading {
                WeatherDetails(reading: reading, selectedDate: $selectedDate, palette: palette, skyDate: skyDate,
                               weatherLoading: weatherLoading, weatherNote: weatherNote, close: { weatherDetails = false })
            } else {
                VStack(spacing: 12) {
                    Label(weatherNote ?? "天气暂不可用", systemImage: "cloud.slash")
                    Button("重新获取", action: refreshWeather).disabled(weatherLoading)
                }.padding(24)
            }
        }
        .onAppear { arrived = true }
        .onChange(of: weatherDetails) { _, open in if !open { selectedDate = nil } }
        .onChange(of: reading?.place) { _, _ in selectedDate = nil }
        .onChange(of: reading?.forecast) { _, days in
            if let selectedDate, days?.contains(where: { $0.date == selectedDate }) != true { self.selectedDate = nil }
        }
        .task(id: visible) {
            guard visible else { return }
            while !Task.isCancelled {
                skyDate = Date()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var dockDivider: some View {
        Rectangle().fill(border).frame(width: 0.5, height: 96).padding(.horizontal, 20)
    }

    private var forecastDock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("天气展望").font(.system(size: 11, weight: .medium))
                Spacer()
                Button { weatherDetails = true } label: {
                    Image(systemName: "arrow.up.right").frame(width: 22, height: 22)
                }.buttonStyle(.plain).help("查看完整预报").accessibilityLabel("查看完整预报")
            }.foregroundStyle(palette.ink.opacity(0.72))
            if let reading, !reading.forecast.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(reading.forecast.prefix(5).enumerated()), id: \.element.id) { index, day in
                        Button { selectedDate = day.date; weatherDetails = true } label: {
                            VStack(spacing: 10) {
                                Text(index == 0 ? "今天" : day.date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "zh_CN"))))
                                    .font(.system(size: 10, weight: .medium)).foregroundStyle(palette.ink.opacity(0.72))
                                Image(systemName: (index == 0 ? reading.sky : day.sky).symbol(night: index == 0 && sceneNight))
                                    .symbolRenderingMode(.palette).foregroundStyle(palette.accent, palette.ink)
                                    .font(.system(size: 21)).frame(height: 23)
                                HStack(spacing: 3) {
                                    Text("\(Int(day.high.rounded()))°")
                                    Text("\(Int(day.low.rounded()))°").foregroundStyle(palette.ink.opacity(0.6))
                                }.font(.system(size: 10, weight: .medium, design: .monospaced))
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(palette.ink.opacity(index == 0 ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .help("\(day.date.formatted(date: .abbreviated, time: .omitted)) · \(day.sky.caption) · 点击查看详情")
                    }
                }
            } else {
                Button(action: refreshWeather) {
                    Label(weatherLoading ? "正在获取预报…" : reading?.forecastNote ?? "预报暂不可用 · 重试", systemImage: "cloud.slash")
                        .font(.system(size: 11)).frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
                }.buttonStyle(.plain).disabled(weatherLoading)
            }
        }.foregroundStyle(palette.ink)
    }

    private var modelCell: some View {
        VStack(alignment: .leading, spacing: 14) {
            modelIdentity(codex: false, model: ccModel, provider: ccProvider)
            modelIdentity(codex: true, model: codexModel, provider: codexProvider)
            HStack(spacing: 10) {
                Button(action: refreshQuota) {
                    HStack(spacing: 8) {
                        QuotaOrbit(windows: windows, ink: palette.ink).frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            if let window = windows.first {
                                Text("已用 \(Int(min(100, max(0, window.usedPercent)).rounded()))%")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                Text(window.resetWait.isEmpty ? window.resetClock : window.resetWait)
                                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(palette.ink.opacity(0.68))
                                    .lineLimit(1)
                            } else {
                                Text(quotaPlacard).font(.system(size: 10)).lineLimit(2)
                            }
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(quotaLoading).opacity(quotaLoading ? 0.5 : 1)
                    .help("点击刷新 · " + quotaHelp).accessibilityLabel("刷新 Codex 额度，" + quotaHelp)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    if balanceWarning { Circle().fill(Color(hex: 0xFFB84D)).frame(width: 4, height: 4) }
                    Text(balance).lineLimit(1).minimumScaleFactor(0.8)
                }.font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(balanceWarning ? Color(hex: 0xFFCC80) : palette.ink.opacity(0.7))
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .background(palette.ink.opacity(0.07), in: Capsule()).help("账户余额：" + balance)
            }
        }.foregroundStyle(palette.ink)
    }

    private func modelIdentity(codex: Bool, model: String, provider: String) -> some View {
        Button(action: showModels) {
            HStack(spacing: 9) {
                ProductBrandMark(codex: codex, well: false, page: !palette.isLightGround).frame(width: 20, height: 20)
                Text(model).font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text(provider).font(.system(size: 9)).lineLimit(1)
                    .foregroundStyle(palette.ink.opacity(0.76))
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
                    Text("今日用量").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.ink.opacity(0.72))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 10))
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(UsageStats.formatTokens(tokens))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit().rollingNumber(valueKey: String(tokens))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    if yesterdayTokens > 0 {
                        let change = (Double(tokens) / Double(yesterdayTokens) - 1) * 100
                        Text(String(format: "%@%.0f%%", change >= 0 ? "↑" : "↓", abs(change)))
                            .font(.system(size: 10, weight: .medium)).monospacedDigit()
                            .foregroundStyle(palette.isLightGround ? palette.accent : Color(hex: 0x7CE7B8))
                    }
                }
                TokenComparison(today: tokens, yesterday: yesterdayTokens, tint: palette.accent, secondary: palette.inkSoft)
                    .frame(height: 12)
                HStack {
                    Text("昨日 \(UsageStats.formatTokens(yesterdayTokens))")
                    Spacer()
                    Text("Token")
                }.font(.system(size: 9)).foregroundStyle(palette.ink.opacity(0.68))
                Text("\(spend) · \(calls.formatted()) 次")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.ink.opacity(0.76))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }.foregroundStyle(palette.ink).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help("今日与昨日总量对比 · 费用按模型价格估算 · 点击查看用量")
            .accessibilityLabel("今日 \(tokens) Token，预估费用 \(spend)，昨日 \(yesterdayTokens) Token，\(calls) 次调用，查看用量")
    }

    private var weatherAccessibility: String {
        let value = selectedDay.map { "最高 \(Int($0.high.rounded()))度，\($0.sky.caption)" }
            ?? reading.map { "\(Int($0.temperatureC.rounded()))度，\($0.skyLabel)" } ?? "暂无天气"
        return "\(reading?.place ?? city)，\(value)，\(weatherLoading ? "正在更新" : weatherNote ?? "")"
    }

    private var weatherBlock: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "location.fill").font(.system(size: 8))
                Text(reading?.place.isEmpty == false ? reading!.place : (city.isEmpty ? "请设置城市" : city))
                    .font(.system(size: 10, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Button(action: refreshWeather) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                        .symbolEffect(.rotate, options: .repeating, isActive: weatherLoading && !reduceMotion && visible)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(weatherLoading)
                    .help(weatherNote ?? reading.map { "刷新天气 · 更新于 \($0.observedAt.formatted(date: .omitted, time: .shortened))" } ?? "刷新天气")
                    .accessibilityLabel("刷新天气")
            }.foregroundStyle(palette.ink.opacity(0.75))
            Button { weatherDetails = true } label: {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: (reading?.sky ?? .cloudy).symbol(night: reading?.isDay == false))
                            .symbolRenderingMode(.palette).foregroundStyle(palette.accent, palette.ink)
                            .font(.system(size: 27, weight: .light))
                        Text(reading?.temperatureText ?? "—°")
                            .font(.system(size: 43, weight: .thin)).monospacedDigit().contentTransition(.numericText())
                        VStack(alignment: .leading, spacing: 6) {
                            Text(reading?.skyLabel ?? (weatherLoading ? "获取中" : "暂无天气"))
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }.font(.system(size: 10)).foregroundStyle(palette.ink.opacity(0.75))
                        Spacer(minLength: 0)
                    }
                    if let reading {
                        HStack(spacing: 8) {
                            Text("\(Int(reading.lowC.rounded()))°")
                            DaybreakTemperatureRange(low: reading.lowC, high: reading.highC, current: reading.temperatureC).frame(height: 8)
                            Text("\(Int(reading.highC.rounded()))°")
                        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.ink.opacity(0.8))
                    }
                    if weatherNote != nil {
                        Label("更新失败 · 显示上次读数", systemImage: "exclamationmark.circle")
                            .font(.system(size: 9)).foregroundStyle(palette.ink.opacity(0.8))
                    }
                }.padding(.bottom, 4).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(weatherAccessibility).accessibilityHint("打开天气详情")
        }
        .foregroundStyle(palette.ink).padding(.horizontal, 16).padding(.vertical, 10)
        .modifier(DaybreakGlass(dark: false))
    }

}

private struct DaybreakGlass: ViewModifier {
    var dark: Bool
    func body(content: Content) -> some View {
        content
            .background((dark ? Color(hex: 0x07182F).opacity(0.70) : Color.white.opacity(0.04)), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .background(.ultraThinMaterial.opacity(dark ? 0.2 : 0.35), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
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
                        .font(.system(size: 44, weight: .ultraLight)).monospacedDigit()
                    VStack(spacing: 5) {
                        Text(String(format: "%02d", Calendar.current.component(.second, from: context.date)))
                            .font(.system(size: 12, design: .monospaced)).contentTransition(reduceMotion ? .identity : .numericText())
                        ZStack(alignment: .leading) {
                            Rectangle().fill(ink.opacity(0.2))
                            Rectangle().fill(ink.opacity(0.7)).frame(width: 20 * Double(Calendar.current.component(.second, from: context.date)) / 60)
                        }.frame(width: 20, height: 1)
                    }.foregroundStyle(ink.opacity(0.65))
                }
                Text(context.date.formatted(.dateTime.month().day().weekday(.abbreviated).locale(Locale(identifier: "zh_CN"))))
                    .font(.system(size: 11, weight: .medium)).tracking(0.4).foregroundStyle(ink.opacity(0.76))
                if let timezone, let zone = TimeZone(identifier: timezone), zone.secondsFromGMT(for: context.date) != TimeZone.current.secondsFromGMT(for: context.date) {
                    Text("天气当地 \(context.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)))")
                        .font(.system(size: 10)).foregroundStyle(secondary)
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

/// One day's figure. `tint` is the accent the comparison bar above is drawn
/// in, so the chip and the bar it belongs to read as one thing rather than as
/// two numbers that happen to sit next to each other.
private struct DayChip: View {
    var label: String
    var value: Int
    var tint: Color
    /// The 昨日 chip passes the muted ink — the same tone the bar under 今日 is
    /// drawn in — so "pale" means the comparison row both times.
    var muted = false
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
                .opacity(muted ? 0.45 : 1)
            Text(label)
            Text(UsageStats.formatTokens(value))
                .monospacedDigit()
                .rollingNumber(valueKey: String(value))
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(tint)
        .opacity(muted ? 0.72 : 1)
        .lineLimit(1)
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

/// Magnification follows proximity inside a stable hit region. Transform only
/// the label so the pointer cannot chase the moving edge and oscillate.
private struct StatusMagneticStyle: ButtonStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        StatusMagneticLabel(label: configuration.label, pressed: configuration.isPressed, tint: tint)
    }
}

private struct StatusMagneticLabel<Label: View>: View {
    let label: Label
    let pressed: Bool
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var pointer: CGPoint?
    var body: some View {
        label
            .background {
                Rectangle().fill(tint.opacity(pointer == nil || !enabled ? 0 : 0.5))
                    .frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
            }
            .scaleEffect(reduceMotion ? 1 : pressed ? 0.98 : pointer == nil ? 1 : 1.015)
            .offset(x: reduceMotion ? 0 : (pointer?.x ?? 0), y: reduceMotion ? 0 : (pointer?.y ?? 0))
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.75), value: pointer)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: pressed)
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { geo in
                    Color.clear.contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard enabled else { pointer = nil; return }
                            switch phase {
                            case .active(let location):
                                pointer = CGPoint(x: (location.x / max(1, geo.size.width) - 0.5) * 4,
                                                  y: (location.y / max(1, geo.size.height) - 0.5) * 4)
                            case .ended: pointer = nil
                            }
                        }
                }
            }
    }
}
