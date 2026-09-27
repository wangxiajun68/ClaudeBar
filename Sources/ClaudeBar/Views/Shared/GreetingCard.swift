import SwiftUI

/// One living sky across the entire card. The handwritten greeting leads;
/// model, wallet and usage readings sit in the same atmosphere below it.
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
            refreshQuota: { codexStore.refreshQuota() },
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
    @Environment(\.surfaceIsVisible) private var visible

    private var selectedDay: WeatherDay? { reading?.forecast.first { $0.date == selectedDate } }
    private var sceneDate: Date {
        guard let selectedDay else { return skyDate }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: reading?.timezone ?? "") ?? .current
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: selectedDay.date) ?? selectedDay.date
    }
    private var astronomy: SkyAstronomy.Snapshot? { reading?.astronomy(at: sceneDate) }
    private var sceneSky: WeatherReading.Sky { selectedDay?.sky ?? reading?.sky ?? .cloudy }
    private var sceneNight: Bool { astronomy?.night ?? (selectedDay == nil && reading?.isDay == false) }


    private var palette: SkyPalette {
        if reading != nil { return SkyPalette(sky: sceneSky, night: sceneNight) }
        return .neutral
    }
    private var accent: Color { palette.accent }
    private var border: Color { palette.ink.opacity(0.16) }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 24) {
                    greeting.frame(maxWidth: .infinity, alignment: .leading)
                    weatherBlock.frame(width: 230)
                }
                .frame(minWidth: 860)
                VStack(alignment: .leading, spacing: 14) {
                    greeting
                    compactWeather
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 28)
            .modifier(StatusArrival(arrived: arrived, delay: 0, reduceMotion: reduceMotion))

            Rectangle().fill(border).frame(height: 1)
            if let reading {
                WeatherExplorer(reading: reading, selection: $selectedDate, palette: palette, now: skyDate, showDetails: { weatherDetails = true })
                Rectangle().fill(border).frame(height: 1)
            }
            // Two readings, not four. The two clients used to be two identical
            // cells differing only by a small SF Symbol, and the allowance sat a
            // section further down repeating the Codex half of the same fact.
            // They are now one mark (`CodexModelMark`: both brand glyphs over
            // one allowance lane) and one 今日 cell (token figure, cost figure,
            // and the day-over-day bar between them).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    modelCell.frame(maxWidth: .infinity)
                    Rectangle().fill(border).frame(width: 1, height: 106).padding(.vertical, 20)
                    todayCell.frame(maxWidth: .infinity)
                }.frame(minWidth: 860)
                VStack(spacing: 0) {
                    modelCell
                    Rectangle().fill(border).frame(height: 1).padding(.horizontal, 20)
                    todayCell
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .modifier(StatusArrival(arrived: arrived, delay: 0.14, reduceMotion: reduceMotion))
        }
        .background {
            ZStack {
                palette.gradient
                if let reading {
                    WeatherBackdrop(sky: sceneSky, isDay: !sceneNight, intensity: selectedDay?.rainChance ?? reading.rainChance, astronomy: astronomy, windKph: selectedDay?.wind ?? reading.windKph)
                        .frame(height: 280)
                        .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.7), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                        .frame(maxHeight: .infinity, alignment: .top)
                        .mask(LinearGradient(colors: [.white.opacity(0.32), .white],
                                             startPoint: .leading, endPoint: .trailing))
                    // A continuous scrim keeps the typography legible while
                    // the same animated atmosphere flows behind every row.
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.23), location: 0),
                        .init(color: .black.opacity(0.04), location: 0.65),
                        .init(color: .clear, location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.16), location: 0.45),
                        .init(color: .black.opacity(0.42), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: sceneSky)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.2), value: sceneNight)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
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

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(context.date.formatted(.dateTime.month(.wide).day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(palette.inkSoft)
            }
            SkyGreeting(name: name, palette: palette)
            GreetingClock(ink: palette.ink, secondary: palette.inkSoft)
        }
    }

    /// Flat instrument row. Model navigation and allowance refresh are siblings,
    /// so keyboard activation and pointer clicks never trigger a parent button.
    private var modelCell: some View {
        HStack(alignment: .top, spacing: 24) {
            modelIdentity(codex: false, model: ccModel, provider: ccProvider)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                modelIdentity(codex: true, model: codexModel, provider: "余额 \(balance)")
                Button(action: refreshQuota) {
                    VStack(alignment: .leading, spacing: 7) {
                        if windows.isEmpty {
                            Label(quotaPlacard, systemImage: "arrow.clockwise")
                                .font(.system(size: 10)).foregroundStyle(palette.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ForEach(windows) { window in
                                quotaRow(window)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(quotaLoading)
                .help("点击刷新额度 · " + quotaHelp)
                .accessibilityLabel("刷新 Codex 额度，" + quotaHelp)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .foregroundStyle(palette.ink)
    }

    private func modelIdentity(codex: Bool, model: String, provider: String) -> some View {
        Button(action: showModels) {
            HStack(alignment: .top, spacing: 11) {
                ProductBrandMark(codex: codex).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Text(codex ? "Codex" : "Claude Code").font(.system(size: 10, weight: .semibold))
                        Image(systemName: "arrow.up.right").font(.system(size: 7, weight: .medium))
                    }.foregroundStyle(palette.inkSoft)
                    Text(model).font(.system(size: 16, weight: .semibold, design: .rounded))
                        .lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.8)
                    Text(provider).font(.system(size: 10)).foregroundStyle(palette.inkSoft)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }
        .buttonStyle(StatusMagneticStyle(tint: palette.ink))
        .help("打开模型管理 · \(model)")
        .accessibilityLabel("\(codex ? "Codex" : "Claude Code")，\(model)，\(provider)，打开模型管理")
    }

    private func quotaRow(_ window: CodexQuotaWindow) -> some View {
        let remaining = max(0, min(100, 100 - window.usedPercent))
        return HStack(spacing: 8) {
            Text(window.label).frame(width: 32, alignment: .leading)
            GeometryReader { geo in
                Capsule().fill(palette.ink.opacity(0.15))
                Capsule().fill(remaining < 15 ? Color(hex: 0xFFBC9C) : palette.accent)
                    .frame(width: geo.size.width * remaining / 100)
                    .opacity(quotaLoading ? 0.5 : 1)
            }.frame(minWidth: 32, maxWidth: 90).frame(height: 4)
            Text("\(Int(remaining.rounded()))%").monospacedDigit().frame(width: 28, alignment: .trailing)
            Spacer(minLength: 0)
            Image(systemName: "arrow.clockwise").font(.system(size: 8))
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(palette.inkSoft)
        .help("\(window.label)剩余 \(Int(remaining))%，\(window.resetClock) 重置")
    }

    /// What the Codex mark's lane says when there are no windows to draw: the
    /// reason, in the card's own two words — a live "正在读取额度…" while the call
    /// is out, the failure note from the store otherwise. This is the *empty*
    /// lane's copy; a lane that has rows keeps them and marks the refresh by
    /// lighting up instead, which is why `quotaLoading` goes to the mark too.
    private var quotaPlacard: String {
        if quotaLoading { return "正在读取额度…" }
        if let quotaNote, !quotaNote.isEmpty { return quotaNote }
        return "暂无额度数据"
    }

    private var quotaHelp: String {
        guard !windows.isEmpty else { return quotaNote ?? "暂无额度数据" }
        return windows.map { "\($0.label)剩余 \(Int((100 - $0.usedPercent).rounded()))%，\($0.resetClock)" }
            .joined(separator: " · ")
    }

    /// Today's volume and today's money in one cell.
    ///
    /// They were two cells whose captions differed and whose figures did not:
    /// both are "how much of my work today", and splitting them cost a whole
    /// column of the row. The token figure leads (it is the primary reading),
    /// the cost rides in a pill beside it (it is an estimate, and the pill says
    /// so), and the day-over-day pair sits underneath as two chips — the today
    /// chip carries the accent the comparison bar is drawn in, so the bar and
    /// the figure it compares are visibly the same reading.
    private var todayCell: some View {
        Button(action: showUsage) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    InstrumentGlyph(kind: .tokens, tint: palette.ink, detailed: true)
                        .frame(width: 15, height: 15)
                    Text("今日用量")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.inkSoft)
                }
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    Text(UsageStats.formatTokens(tokens))
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                        .monospacedDigit().rollingNumber(valueKey: String(tokens))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(spend).font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("预估费用").font(.system(size: 9)).foregroundStyle(palette.inkSoft)
                    }
                }
                HStack(spacing: 8) {
                    TokenComparison(today: tokens, yesterday: yesterdayTokens,
                                    tint: palette.accent, secondary: palette.inkSoft)
                        .frame(width: 54, height: 15)
                    DayChip(label: "今日", value: tokens, tint: palette.accent)
                    DayChip(label: "昨日", value: yesterdayTokens, tint: palette.inkSoft, muted: true)
                    Spacer(minLength: 0)
                    Text("\(calls) 次调用")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.inkSoft)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(palette.ink)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .padding(20).contentShape(Rectangle())
        }
        .buttonStyle(StatusMagneticStyle(tint: palette.accent))
        .help("今天 \(tokens.formatted()) Token（\(spend)，按模型价格估算），昨天 \(yesterdayTokens.formatted()) Token，共 \(calls) 次调用。点击查看用量。")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日 \(tokens) Token，花费 \(spend)，昨日 \(yesterdayTokens) Token，\(calls) 次调用")
    }

    private var weatherAccessibility: String {
        let value = selectedDay.map { "最高 \(Int($0.high.rounded()))度，\($0.sky.caption)" }
            ?? reading.map { "\(Int($0.temperatureC.rounded()))度，\($0.skyLabel)" } ?? "暂无天气"
        return "\(reading?.place ?? city)，\(value)，\(weatherLoading ? "正在更新" : weatherNote ?? "")"
    }

    private var compactWeather: some View {
        HStack(spacing: 12) {
            Button { selectedDate = nil; weatherDetails = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: sceneSky.symbol(night: sceneNight))
                        .symbolRenderingMode(.hierarchical).font(.system(size: 28)).foregroundStyle(palette.accent)
                    Text(selectedDay.map { "\(Int($0.high.rounded()))°" } ?? reading?.temperatureText ?? "—°")
                        .font(.system(size: 34, weight: .light, design: .rounded)).monospacedDigit()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(reading?.place ?? city).font(.system(size: 11, weight: .semibold))
                        Text(weatherLoading ? "正在更新…" : weatherNote ?? "查看天气详情 ›")
                            .font(.system(size: 10)).foregroundStyle(palette.inkSoft).lineLimit(2)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(weatherAccessibility).accessibilityHint("打开天气详情")
            Spacer()
            Button(action: refreshWeather) {
                Image(systemName: "arrow.clockwise").frame(width: 32, height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(weatherLoading).accessibilityLabel("刷新天气")
        }.foregroundStyle(palette.ink)
    }

    private var weatherBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "location.fill").font(.system(size: 9))
                Text(reading?.place.isEmpty == false ? reading!.place : (city.isEmpty ? "请设置城市" : city))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: refreshWeather) {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, options: .repeating, isActive: weatherLoading && !reduceMotion && visible)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(weatherLoading)
                    .help("刷新天气").accessibilityLabel("刷新天气")
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(palette.inkSoft)
            Button { weatherDetails = true } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: sceneSky.symbol(night: sceneNight))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(palette.accent, palette.ink, palette.inkSoft)
                    .font(.system(size: 36, weight: .light))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(selectedDay.map { "\(Int($0.high.rounded()))°" } ?? reading?.temperatureText ?? "—°")
                        .font(.system(size: 58, weight: .light, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText())
                    Text(selectedDay.map { "\($0.sky.caption) · 当日最高" } ?? (sceneNight && reading?.sky == .clear ? "晴夜" : reading?.skyLabel) ?? (weatherLoading ? "正在获取实况" : "暂无天气"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.inkSoft)
                }
            }
            }.buttonStyle(.plain).help("点击查看天气详情与未来五天预报")
                .accessibilityLabel(weatherAccessibility).accessibilityHint("打开天气详情与未来五天预报")
            if let reading {
                HStack(spacing: 12) {
                    Label("\(Int((selectedDay?.high ?? reading.highC).rounded()))°", systemImage: "arrow.up")
                    Label("\(Int((selectedDay?.low ?? reading.lowC).rounded()))°", systemImage: "arrow.down")
                    Spacer()
                    if selectedDay != nil {
                        Button("回到现在") {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { selectedDate = nil }
                        }.buttonStyle(.plain).foregroundStyle(palette.accent)
                    } else { Text("详情 ›").foregroundStyle(palette.inkSoft) }
                }.font(.system(size: 11, weight: .medium))
                if selectedDay == nil {
                    Text("更新于 " + reading.observedAt.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 9)).foregroundStyle(palette.inkSoft)
                }
            }
            if let weatherNote {
                Text(weatherNote).font(.system(size: 10)).foregroundStyle(palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(palette.ink)
        .accessibilityElement(children: .contain)
    }

}

private struct GreetingClock: View {
    var ink: Color
    var secondary: Color
    @Environment(\.surfaceIsVisible) private var visible
    var body: some View {
        TimelineView(.periodic(from: .now, by: visible ? 1 : 3600)) { context in
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                    Text(context.date, format: .dateTime.second(.twoDigits))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(secondary)
                        .frame(width: 22, alignment: .leading)
                }.monospacedDigit()
                Text(TimeZone.current.identifier.replacingOccurrences(of: "_", with: " "))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondary)
            }.foregroundStyle(ink)
        }
        .accessibilityElement(children: .combine)
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
            Capsule()
                .fill(tint)
                .frame(width: 12, height: 3.5)
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

/// The cost figure as a pill on the token cell's caption row: it is money, it
/// is an estimate, and a pill is the app's word for "an aside about the number
/// beside me". A slash through its ¥ says the estimate part without a sentence.
private struct CostCapsule: View {
    var text: String
    var tint: Color
    var body: some View {
        HStack(spacing: 5) {
            // `yensign.circle`, not a slashed `yensign`.
            //
            // The slash was meant to say "estimate", and it said "crossed out":
            // a thin diagonal over an 11pt currency mark reads as a disabled or
            // struck-through item long before it reads as an approximation — it
            // is the glyph convention for *broken*. It also left the pill with
            // **two** ¥-like marks side by side (the slashed one and the plain
            // one the formatted amount carries), which is worse than either
            // alone. The circled mark labels the currency cleanly, and the
            // estimate is a word now, in `label`, where a reader gets it the
            // first time.
            Image(systemName: "yensign.circle")
                .font(.system(size: 11, weight: .medium))
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(tint.opacity(0.72))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 1))
        .help("按模型刊例价估算，不代表实际账单")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(text)，按模型价格估算，不代表实际账单")
    }

    /// "估" is the one character that says the figure is an estimate, and it is
    /// a character this pill can afford — the slash it replaces was trying to
    /// say the same thing with a mark that means "broken".
    private var label: String { "估" }
}

private struct TokenComparison: View {
    var today: Int
    var yesterday: Int
    var tint: Color
    var secondary: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            let maximum = Double(max(1, max(today, yesterday)))
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(tint)
                    .frame(width: geo.size.width * Double(max(0, today)) / maximum, height: 5)
                Capsule().fill(secondary.opacity(0.4))
                    .frame(width: geo.size.width * Double(max(0, yesterday)) / maximum, height: 5)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: today)
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
