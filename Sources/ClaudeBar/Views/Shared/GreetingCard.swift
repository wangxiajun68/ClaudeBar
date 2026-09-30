import SwiftUI
import simd

/// A window onto the live sky: the greeting written into it by hand, the clock,
/// weather, forecast and sun path as instruments at its edges, the tool
/// readings on one glass sill. The sky is the Metal atmosphere
/// (`AtmosphereSurface`); motion is visibility-gated and the clock owns its
/// one-second ticker.
struct GreetingCard: View {
    @ProviderState([.usage, .configuration]) private var providerStore
    @EnvironmentObject private var codexStore: CodexProviderStore
    @State private var weather = WeatherStore.shared
    @State private var city = AppPreferences.shared.weatherCity
    @State private var costDisplay = AppPreferences.shared.costDisplay
    @State private var typeface = AppPreferences.shared.greetingTypeface
    /// 设置 → 天气与问候 → 天气渲染。关掉之后天空不再画天气图层，这张卡也不再
    /// 联网取天气（见 `GreetingCard` 自己的 `.task`）。
    @State private var weatherRendering = AppPreferences.shared.greetingWeatherRendering
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
            // The build gate is part of the answer, not just the switch: a card
            // that claims to be "locating" in a build that will not ask would
            // spin forever instead of falling back to the city.
            locating: BuildChannel.promptsForSystemPermissions && PermissionGate.allows(.currentLocation),
            typeface: typeface,
            weatherRendering: weatherRendering,
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
        .onReceive(AppPreferences.shared.$greetingTypeface.removeDuplicates()) { typeface = $0 }
        .onReceive(AppPreferences.shared.$greetingWeatherRendering.removeDuplicates()) { weatherRendering = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            codexStore.refreshConfiguredModel()
        }
        .onAppear { codexStore.refreshConfiguredModel(); cursor.refresh() }
        .task(id: surfaceVisible) {
            guard surfaceVisible, AppPreferences.shared.greetingWeatherRendering else { return }
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
///
/// THESIS: a window that breathes — the live sky is the canvas, the greeting is
/// written into it by hand, everything else is an instrument on the frame.
/// HIERARCHY: primary — the greeting (up to 15 % of the width, monoline script,
/// GPU-drawn); secondary — the weather "now" and the clock; tertiary — the
/// forecast ribbon, the sun path and the glass sill. Nothing floats over the
/// sky: every detail opens *in place* (a focused day re-reads the "now"
/// instrument, a hovered chip widens), so the greeting is never covered.
struct GreetingStatusSheet: View {
    var name: String
    var ccModel: String
    var ccProvider: String
    var codexModel: String
    var codexProvider: String
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
    /// Cursor's own monthly allowance, the third client the card reads.
    var cursorPlan: CursorUsageFetcher.PlanUsage?
    var cursorLoading: Bool
    var cursorNote: String?
    var reading: WeatherReading?
    var city: String
    var weatherLoading: Bool
    var weatherNote: String?
    /// The reading follows the Mac's position rather than a typed city.
    var locating: Bool = false
    /// The face the greeting is written in (设置 → 问候字体).
    var typeface: GreetingTypeface = .standard
    /// 设置 → 天气与问候 → 天气渲染。关掉之后天空不再画云、雨雪、雾、闪电与
    /// 玻璃雨滴；右上不再是实时天气，而是一张贴图说明。
    var weatherRendering = true
    /// 预览工具用它一次渲染两种取值（见 Tools/render-greeting-preview.py）。
    var manualWeatherFetch = false
    var refreshWeather: () -> Void
    var refreshQuota: () -> Void
    var refreshCursor: () -> Void
    var showModels: () -> Void
    var showUsage: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.surfaceIsVisible) private var visible
    @State private var arrived = false
    @State private var skyDate = Date()
    @State private var timeOffset: Double = 0
    /// Display-synced drivers for the eased return to now and the manual
    /// glide: a sleeping task steps at its own pace and beats against the
    /// display, which reads as judder in a moving sky.
    @State private var rewinder = FrameTicker()
    @State private var cardWidth: CGFloat = 1100
    @State private var metalReady = AtmosphereGPU.shared != nil
    @State private var controller = AtmosphereController()
    @State private var rainbowUntil: Date?
    @State private var skyHovered = false
    @State private var hoveredDay: Date?
    @State private var pinnedDay: Date?
    @State private var rewrites = 0
    /// Manual sky: persisted so the chosen sky survives a relaunch. The hour
    /// is live `@State` while it moves and is written back when it settles,
    /// so a drag or a glide does not write defaults sixty times a second.
    @AppStorage("greeting.skyMode") private var skyMode = "auto"
    /// 天气渲染关掉后，天空停在这一种天气上（`none` 即跟随实时读数）。
    @AppStorage("greeting.pinnedWeather") private var pinnedWeatherRaw = "none"
    @AppStorage("greeting.manualWeather") private var manualWeatherRaw = SkyScene.Weather.clear.rawValue
    @AppStorage("greeting.manualMinutes") private var storedMinutes: Double = 17 * 60 + 40
    @State private var manualMinutes: Double?
    @State private var glider = FrameTicker()
    @State private var dragBase: Double?

    // MARK: - Scene

    /// "Here and now": the sky clock plus any drag offset — or, in manual
    /// mode, today at the chosen hour. The weather reading never moves with
    /// either; only the sky does.
    private var sceneDate: Date {
        if manual { return manualDate }
        if pinnedWeather != nil { return skyDate }
        return skyDate.addingTimeInterval(timeOffset)
    }
    private var zone: TimeZone { TimeZone(identifier: reading?.timezone ?? "") ?? .current }

    private var manual: Bool { skyMode == "manual" }
    private var manualWeather: SkyScene.Weather { SkyScene.Weather(rawValue: manualWeatherRaw) ?? .clear }
    /// 是否在画实时天气：偏好关掉就画贴图，或天空正停在某一层固定天气上
    /// （「预演」里选的），也都不再按实时读数取数。
    private var liveWeather: Bool { Self.liveWeatherShown(rendering: manualWeatherFetch ? false : weatherRendering,
                                                         pinned: pinnedWeatherRaw) }
    private var pinnedWeather: SkyScene.Weather? { SkyScene.Weather(rawValue: pinnedWeatherRaw) }

    /// 纯函数：preview 工具、测试和卡片读同一段逻辑。
    static func liveWeatherShown(rendering: Bool, pinned: String) -> Bool {
        rendering && pinned == "none"
    }
    private var minutes: Double { manualMinutes ?? storedMinutes }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
    private var manualDate: Date { calendar.startOfDay(for: skyDate).addingTimeInterval(minutes * 60) }
    private func minutesOfDay(_ date: Date) -> Double { date.timeIntervalSince(calendar.startOfDay(for: date)) / 60 }
    /// With no coordinates (or no reading at all) the sky is estimated from the
    /// time zone, so a failed fetch still shows *about now* rather than grey.
    private var astronomy: SkyAstronomy.Snapshot {
        reading?.astronomy(at: sceneDate) ?? SkyScene.estimatedAstronomy(date: sceneDate, timezone: zone)
    }
    /// 「预演」里挑了一层天气时，天空用这一层，但时刻仍是此刻——调色板照一天走。
    private var pinnedScene: SkyScene {
        guard let weather = pinnedWeather else { return SkyScene.pinned }
        let sample = Self.sample(weather)
        return SkyScene.make(sky: sample.sky, rainChance: sample.rain, windKph: max(8, reading?.windKph ?? 10),
                             windDirection: reading?.windDirection ?? "", astronomy: astronomy)
    }

    private func makeScene() -> SkyScene {
        if manual {
            let sample = Self.sample(manualWeather)
            return SkyScene.make(sky: sample.sky, rainChance: sample.rain, windKph: max(8, reading?.windKph ?? 10),
                                 windDirection: reading?.windDirection ?? "", astronomy: astronomy)
        }
        if pinnedWeather != nil {
            // The palette is what is on trial here, so the reading survives the
            // fetch going stale — a stale calm sky would show the wrong state.
            return pinnedScene
        }
        return SkyScene.make(sky: reading?.sky, rainChance: reading?.rainChance ?? 0, windKph: reading?.windKph ?? 6,
                             windDirection: reading?.windDirection ?? "", astronomy: astronomy)
    }

    /// A reading that `SkyScene.make` turns into exactly `weather`.
    private static func sample(_ weather: SkyScene.Weather) -> (sky: WeatherReading.Sky, rain: Int) {
        switch weather {
        case .clear: return (.clear, 0)
        case .cloudy: return (.partly, 0)
        case .overcast: return (.cloudy, 0)
        case .lightRain: return (.drizzle, 40)
        case .heavyRain: return (.rain, 85)
        case .thunder: return (.thunder, 90)
        case .snow: return (.snow, 60)
        case .fog: return (.fog, 0)
        }
    }
    private var phrase: GreetingPhrase.Phrase { GreetingPhrase.forDate(skyDate) }
    private var previewTime: String {
        sceneDate.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
    }

    /// The card's grid. The sky is tall enough that the greeting has a free
    /// band between the top instruments (clock, weather) and the bottom ones
    /// (sun path, forecast); `GreetingTypesetter` centres the ink in it.
    private struct Metrics {
        var width: CGFloat
        var margin: CGFloat { width >= 900 ? 32 : 24 }
        var narrow: Bool { width < 700 }
        var sky: CGFloat { min(430, max(330, width * 0.38)).rounded() }
        var sill: CGFloat { 56 }
        var total: CGFloat { sky + sill }
        var top: CGFloat { margin - 8 }
        var nowHeight: CGFloat { 88 }
        var chartWidth: CGFloat { narrow ? 236 : 300 }
        var chartHeight: CGFloat { 80 }
        var sunWidth: CGFloat { narrow ? 196 : 212 }
        var chartTop: CGFloat { sky - 14 - chartHeight }
        /// The manual console takes the sun path's corner and, when the card
        /// is too narrow for both, the forecast's too.
        var consoleWidth: CGFloat { narrow ? width - margin * 2 : min(440, width - margin * 2 - chartWidth - 32) }
        /// 时钟下方「自动 / 手动 / 预演」那枚分段控件：多一段就多一格。
        func skyToggleWidth(threeWay: Bool) -> CGFloat { threeWay ? 148 : 104 }
        var topClear: CGFloat { top + nowHeight + 6 }
        var bottomClear: CGFloat { chartTop - 6 }
    }

    // MARK: - Unchanged subtrees

    /// What each time-independent part of the sheet reads. A drag or a glide
    /// moves only the sky's time; these parts keep their last body and layout
    /// through it instead of being rebuilt every frame. Each key must cover
    /// everything its part reads, or the part shows stale values.
    private struct NowKey: Equatable {
        var reading: WeatherReading?
        var hoveredDay: Date?
        var pinnedDay: Date?
        var night: Bool
        var darkInk: Bool
        var city: String
        var weatherLoading: Bool
        var weatherNote: String?
        var locating: Bool
        /// 天气渲染关掉时，右上读的是天空自己的天气（固定的一种），所以天气层
        /// 也是这份读数的输入。
        var sky: SkyScene.Weather
        var visible: Bool
        var reduceMotion: Bool
        var width: CGFloat
    }

    private struct ForecastKey: Equatable {
        var days: [WeatherDay]
        var zone: TimeZone
        var darkInk: Bool
        var hoveredDay: Date?
        var pinnedDay: Date?
        var arrived: Bool
        var reduceMotion: Bool
        var width: CGFloat
    }

    private struct SillKey: Equatable {
        var ccModel: String
        var ccProvider: String
        var codexModel: String
        var codexProvider: String
        var tokens: Int
        var yesterdayTokens: Int
        var calls: Int
        var spend: String
        var windows: [CodexQuotaWindow]
        var quotaLoading: Bool
        var quotaNote: String?
        var cursorPlan: CursorUsageFetcher.PlanUsage?
        var cursorLoading: Bool
        var cursorNote: String?
        /// Reset countdowns are counted from the sky clock's minute.
        var skyDate: Date
        var arrived: Bool
        var visible: Bool
        var reduceMotion: Bool
        var width: CGFloat
    }

    // MARK: - Body

    var body: some View {
        let m = Metrics(width: cardWidth)
        let scene = makeScene()
        let layout = GreetingTypesetter.layout(phrase.script + ",", name: name, typeface: typeface, cardWidth: m.width,
                                               skyHeight: m.sky, margin: m.margin,
                                               topClear: m.topClear, bottomClear: m.bottomClear)
        // 天空没有天气时（关掉实时天气、也没挑过哪一层）用的是一张固定调色板，
        // 那片灰不是"光线弱"，不该据此点亮白字：`prefersDarkInk` 说的是问候语
        // 背后的地面有多亮，这张贴图量它自己。挑了天气或跟着实时读数时，就量
        // 画出来的那片天。
        let inkGround = (liveWeather || pinnedWeather != nil) ? scene.prefersDarkInk : SkyScene.pinned.prefersDarkInk
        let ink = inkGround ? Color(hex: 0x141E33) : Color.white
        let vivid = !inkGround
        ZStack(alignment: .topLeading) {
            sky(scene: scene, layout: layout, metrics: m)
            skyGestures(layout: layout, metrics: m)
            greetingAccessibility(layout: layout)
            let clockZone: String? = liveWeather ? reading?.timezone : nil
            let clockPreview: Date? = manual ? manualDate : (timeOffset == 0 || !liveWeather ? nil : sceneDate)
            VStack(alignment: .leading, spacing: 8) {
                GreetingClock(ink: ink, timezone: clockZone, preview: clockPreview)
                SkyModeToggle(skyMode: skyMode, rendering: self.weatherRendering, ink: ink,
                              setManual: { setManual($0, scene: scene) },
                              setPreview: { setPreview($0) },
                              setRendering: { AppPreferences.shared.greetingWeatherRendering = $0 })
                    .frame(width: m.skyToggleWidth(threeWay: self.weatherRendering || manual), alignment: .leading)
            }
            .padding(.leading, m.margin)
            .padding(.top, m.top)
            .modifier(StatusArrival(arrived: arrived, delay: 1.1, reduceMotion: reduceMotion))
            let nowNight = manual ? reading?.isDay == false : scene.nightness > 0.5
            let shownReading = liveWeather ? reading : nil
            let shownCity = liveWeather ? city : "贴图"
            Unchanged(key: NowKey(reading: shownReading, hoveredDay: liveWeather ? hoveredDay : nil,
                                  pinnedDay: pinnedDay, night: nowNight,
                                  darkInk: scene.prefersDarkInk, city: shownCity, weatherLoading: weatherLoading,
                                  weatherNote: liveWeather ? weatherNote : nil, locating: locating,
                                  sky: scene.weather, visible: visible,
                                  reduceMotion: reduceMotion, width: m.width)) {
                weatherNow(night: nowNight, ink: ink, vivid: vivid, metrics: m)
            }
            .equatable()
                .padding(.trailing, m.margin)
                .padding(.top, m.top)
                .frame(width: m.width, alignment: .topTrailing)
                .modifier(StatusArrival(arrived: arrived, delay: 1.2, reduceMotion: reduceMotion))
            Group {
                if manual {
                    skyConsole(scene: scene, ink: ink, vivid: vivid)
                        .frame(width: m.consoleWidth, alignment: .leading)
                        .offset(x: m.margin, y: m.chartTop)
                        .transition(.opacity.combined(with: .offset(y: 10)))
                } else {
                    sunPath(scene: scene, ink: ink, vivid: vivid, times: dayTimes)
                        .frame(width: m.sunWidth)
                        .offset(x: m.margin, y: m.sky - 14 - 57)
                        .transition(.opacity)
                }
            }
            .modifier(StatusArrival(arrived: arrived, delay: 1.3, reduceMotion: reduceMotion))
            if liveWeather, !(manual && m.narrow) {
                Unchanged(key: ForecastKey(days: forecastDays, zone: zone, darkInk: scene.prefersDarkInk,
                                           hoveredDay: hoveredDay, pinnedDay: pinnedDay, arrived: arrived,
                                           reduceMotion: reduceMotion, width: m.width)) {
                    forecast(ink: ink, vivid: vivid, metrics: m)
                }
                .equatable()
                .transition(.opacity)
            }
            Unchanged(key: SillKey(ccModel: ccModel, ccProvider: ccProvider, codexModel: codexModel,
                                   codexProvider: codexProvider, tokens: tokens,
                                   yesterdayTokens: yesterdayTokens, calls: calls, spend: spend, windows: windows,
                                   quotaLoading: quotaLoading, quotaNote: quotaNote, cursorPlan: cursorPlan,
                                   cursorLoading: cursorLoading, cursorNote: cursorNote, skyDate: skyDate,
                                   arrived: arrived, visible: visible, reduceMotion: reduceMotion, width: m.width)) {
                sill(metrics: m)
            }
            .equatable()
                .offset(y: m.sky)
                .modifier(StatusArrival(arrived: arrived, delay: 1.5, reduceMotion: reduceMotion))
        }
        .frame(width: m.width, height: m.total, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            if abs(width - cardWidth) > 0.5 { cardWidth = width }
        }
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.22 : 0.5),
                                                      .white.opacity(colorScheme == .dark ? 0.04 : 0.08)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
        .background {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color.black.opacity(0.001))
                .shadow(color: colorScheme == .dark ? .black.opacity(0.45) : Color(hex: 0x1B2A4A).opacity(0.14),
                        radius: colorScheme == .dark ? 48 : 40, y: colorScheme == .dark ? 20 : 18)
                .shadow(color: Color(hex: 0x1B2A4A).opacity(colorScheme == .dark ? 0 : 0.08), radius: 8, y: 2)
        }
        .onAppear {
            arrived = true
            AtmosphereGPU.whenReady { metalReady = true }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.88), value: manual)
        .onDisappear {
            rewinder.stop(); timeOffset = 0; hoveredDay = nil; pinnedDay = nil
            glider.stop(); commitMinutes()
        }
        .task(id: visible) {
            guard visible else { return }
            while !Task.isCancelled {
                skyDate = Date()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .onChange(of: reading?.sky) { old, new in
            // A rainbow is earned: rain that has just cleared, with the sun low
            // enough (below 42°) for the bow to stand above the horizon.
            if let old, [.rain, .drizzle, .thunder].contains(old), let new, [.clear, .partly].contains(new) {
                rainbowUntil = Date().addingTimeInterval(1800)
            }
        }
        .onChange(of: typeface) {
            // A new face is written in, not swapped in.
            guard !reduceMotion, metalReady else { return }
            controller.rewrite()
        }
        .onChange(of: reading?.forecast.map(\.date)) { _, dates in
            if let pinnedDay, dates?.contains(pinnedDay) != true { self.pinnedDay = nil }
        }
        .sensoryFeedback(.levelChange, trigger: Int(timeOffset / 3600))
        .sensoryFeedback(.levelChange, trigger: manual && dragBase != nil ? Int(minutes / 60) : -1)
        .sensoryFeedback(.selection, trigger: pinnedDay)
        .sensoryFeedback(.alignment, trigger: rewrites)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Sky

    @ViewBuilder
    private func sky(scene: SkyScene, layout: GreetingTypesetter.Layout, metrics m: Metrics) -> some View {
        if metalReady {
            AtmosphereSurface(input: .init(scene: scene, layout: layout, skyHeight: m.sky,
                                           darkInk: scene.prefersDarkInk, darkAppearance: colorScheme == .dark,
                                           reduceMotion: reduceMotion, rainbow: rainbowVisible(scene),
                                           meteorShower: SkyEvents.meteorShower(on: sceneDate, in: zone),
                                           previewing: timeOffset != 0),
                              controller: controller, active: visible)
                .frame(width: m.width, height: m.total)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            FallbackSky(scene: scene, reading: reading, astronomy: astronomy, layout: layout)
                .frame(width: m.width, height: m.total)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func rainbowVisible(_ scene: SkyScene) -> Bool {
        guard let rainbowUntil, rainbowUntil > skyDate else { return false }
        return scene.sunAltitude > 3 && scene.sunAltitude < 42 && scene.rain == 0
    }

    /// Drag or arrow keys scrub the sky ±12 h (the clock and the sun path
    /// follow); a click on the greeting writes it again, anywhere else sends a
    /// ripple through the sky.
    private func skyGestures(layout: GreetingTypesetter.Layout, metrics m: Metrics) -> some View {
        let writing = layout.phraseFrame.union(layout.nameFrame).insetBy(dx: -8, dy: -8)
        // 关掉天气渲染后这条手势只剩"点问候语重写一遍"：漫游一天是在挑时刻，
        // 而固定的天空被有意钉在此刻。
        let scrub = liveWeather
        return Color.clear
            .contentShape(Rectangle())
            .frame(width: m.width, height: m.sky)
            .gesture(DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard scrub else { return }
                    if manual {
                        // In manual mode the drag *sets* the hour and stays.
                        glider.stop()
                        let base = dragBase ?? minutes
                        dragBase = base
                        manualMinutes = SkyTimeline.wrap(base + value.translation.width / max(1, m.width) * 1440)
                    } else {
                        rewinder.stop()
                        timeOffset = max(-43200, min(43200, value.translation.width / max(1, m.width) * 86400))
                    }
                }
                .onEnded { _ in
                    guard scrub else { return }
                    if manual { dragBase = nil; commitMinutes() } else { returnToNow() }
                })
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                if writing.contains(value.location) {
                    guard !reduceMotion, metalReady else { return }
                    controller.rewrite()
                    rewrites += 1
                } else {
                    guard !reduceMotion else { return }
                    controller.ripple(at: value.location)
                }
            })
            .onHover { inside in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { skyHovered = inside }
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) {
                guard scrub else { return .ignored }
                manual ? nudgeManual(-60) : adjustSky(by: -3600); return .handled
            }
            .onKeyPress(.rightArrow) {
                guard scrub else { return .ignored }
                manual ? nudgeManual(60) : adjustSky(by: 3600); return .handled
            }
            .onKeyPress(.escape) {
                guard scrub else { pinnedDay = nil; return .handled }
                returnToNow(); pinnedDay = nil; return .handled
            }
            .onKeyPress(.space) {
                guard !reduceMotion, metalReady else { return .ignored }
                controller.rewrite()
                rewrites += 1
                return .handled
            }
            .accessibilityLabel("天空时间预览")
            .accessibilityValue(liveWeather ? (manual ? "手动 \(previewTime)" : timeOffset == 0 ? "现在" : previewTime)
                                                 : "贴图")
            .accessibilityAction(named: Text("前一小时")) { if scrub { adjustSky(by: -3600) } }
            .accessibilityAction(named: Text("后一小时")) { if scrub { adjustSky(by: 3600) } }
            .accessibilityAction(named: Text("回到现在")) { if scrub { returnToNow() } }
            .help(skyHint)
    }

    private var skyHint: String {
        if !liveWeather { return "点击问候语重写一遍 · 设置里可重新打开天气渲染" }
        if manual { return "拖动天空调整时间 · 点击问候语重写一遍" }
        return "拖动或按 ←/→ 漫游一天 · 点击问候语重写一遍 · 松手或 Esc 回到现在"
    }

    /// The GPU draws the words; VoiceOver still reads them as one sentence.
    private func greetingAccessibility(layout: GreetingTypesetter.Layout) -> some View {
        Color.clear
            .frame(width: layout.phraseFrame.width, height: layout.phraseFrame.height)
            .offset(x: layout.phraseFrame.minX, y: layout.phraseFrame.minY)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("\(phrase.script)，\(name)")
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Weather now

    private var forecastDays: [WeatherDay] { liveWeather ? Array((reading?.forecast ?? []).prefix(6)) : [] }

    /// The day the forecast ribbon is pointing at, if it is not today: hover
    /// wins over the pin so the pin can be compared against other days.
    private var focusedDay: WeatherDay? {
        guard let id = hoveredDay ?? pinnedDay,
              let index = forecastDays.firstIndex(where: { $0.date == id }), index > 0 else { return nil }
        return forecastDays[index]
    }

    private var placeParts: (city: String, district: String?) {
        if let place = reading?.place, !place.isEmpty {
            let parts = place.components(separatedBy: " · ")
            return (parts[0], parts.count > 1 ? parts[1] : nil)
        }
        return (city.isEmpty ? "请设置城市" : city, nil)
    }

    private var coordinates: String? {
        guard let lat = reading?.latitude, let lon = reading?.longitude else { return nil }
        return String(format: "%.2f°%@ %.2f°%@", abs(lat), lat >= 0 ? "N" : "S", abs(lon), lon >= 0 ? "E" : "W")
    }

    /// Top right: where, what the sky is doing, and how the air feels — or,
    /// while the ribbon points at a day, that day, in the same places.
    private func weatherNow(night: Bool, ink: Color, vivid: Bool, metrics m: Metrics) -> some View {
        VStack(alignment: .trailing, spacing: 7) {
            locationRow(ink: ink, metrics: m)
            conditionRow(night: night, ink: ink, vivid: vivid)
            metricRow(ink: ink, vivid: vivid)
        }
        .frame(height: m.nowHeight, alignment: .topTrailing)
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: focusedDay?.date)
    }

    @ViewBuilder
    private func locationRow(ink: Color, metrics m: Metrics) -> some View {
        if liveWeather {
            liveLocationRow(ink: ink, metrics: m)
        } else {
            // 关掉天气渲染后这里不再是一个"到某地的实时天气"按钮，它只是一个
            // 标题，没有可刷新的东西。
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "photo")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.7))
                Text(city)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.88))
                Text("贴图")
                    .font(.system(size: 11))
                    .foregroundStyle(ink.opacity(0.55))
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("天气渲染关闭，\(city) 只作贴图")
        }
    }

    private func liveLocationRow(ink: Color, metrics m: Metrics) -> some View {
        Button(action: refreshWeather) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if weatherNote != nil {
                    Circle().fill(Color(hex: 0xFFB35C)).frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
                }
                Image(systemName: locating ? "location.fill" : "mappin.and.ellipse")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.7))
                    .symbolEffect(.pulse, options: .repeating, isActive: weatherLoading && visible && !reduceMotion)
                Text(placeParts.city)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.88))
                if let district = placeParts.district {
                    Text(district).font(.system(size: 11)).foregroundStyle(ink.opacity(0.6))
                }
                if let focusedDay {
                    Text("· " + dayName(focusedDay.date))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ink.opacity(0.78))
                        .transition(.opacity)
                } else if !m.narrow, let coordinates {
                    Text(coordinates)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(ink.opacity(0.42))
                        .transition(.opacity)
                }
            }
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(SillPressStyle())
        .disabled(weatherLoading)
        .help(weatherHelp)
        .accessibilityLabel(weatherAccessibility)
        .accessibilityHint("刷新天气")
    }

    @ViewBuilder
    /// `night` is the live reading's own day/night in manual mode: a manual
    /// sky must not turn today's real sun into a moon.
    private func conditionRow(night: Bool, ink: Color, vivid: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if let day = focusedDay {
                WeatherGlyph(symbol: day.sky.symbol(), size: 28, ink: ink, vivid: vivid)
                bigTemperature(day.high, ink: ink)
                caption(day.sky.caption, high: nil, low: day.low, ink: ink)
            } else if let reading {
                WeatherGlyph(symbol: reading.sky.symbol(night: night), size: 28, ink: ink, vivid: vivid)
                bigTemperature(reading.temperatureC, ink: ink)
                caption(reading.skyLabel, high: reading.highC, low: reading.lowC, ink: ink)
            } else if !liveWeather {
                // The pinned sky: no reading, so name the sky itself. The
                // glyph is the sky's own weather, at the same size as the
                // reading it stands in for.
                WeatherGlyph(symbol: pinnedSkySymbol(night: night), size: 28, ink: ink, vivid: vivid)
                caption(PinnedSky.sky(for: pinnedWeather).caption, high: nil, low: nil, ink: ink)
            } else {
                WeatherGlyph(symbol: weatherLoading ? "cloud" : "icloud.slash", size: 24, ink: ink, vivid: false)
                    .opacity(0.8)
                caption(weatherLoading ? "获取中" : "离线", high: nil, low: nil, ink: ink)
            }
        }
    }

    /// 固定天空时的天气图标：挑过的一层用它的 SVG 图标，没挑过就是一片晴空。
    private func pinnedSkySymbol(night: Bool) -> String {
        switch pinnedWeather {
        case .none, .clear: return night ? "moon.stars.fill" : "sun.max.fill"
        case .cloudy: return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case .overcast: return "cloud.fill"
        case .lightRain: return "cloud.drizzle.fill"
        case .heavyRain: return "cloud.rain.fill"
        case .thunder: return "cloud.bolt.rain.fill"
        case .snow: return "cloud.snow.fill"
        case .fog: return "cloud.fog.fill"
        }
    }

    private func bigTemperature(_ value: Double, ink: Color) -> some View {
        Text("\(Int(value.rounded()))°")
            .font(.system(size: 40, weight: .thin))
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(value: value))
            .foregroundStyle(ink.opacity(0.95))
            .fixedSize()
    }

    private func caption(_ text: String, high: Double?, low: Double?, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ink.opacity(0.86))
                .lineLimit(1)
            HStack(spacing: 6) {
                if let high {
                    Label { Text("\(Int(high.rounded()))°") } icon: { Image(systemName: "arrow.up") }
                }
                if let low {
                    Label { Text("\(Int(low.rounded()))°") } icon: { Image(systemName: "arrow.down") }
                }
            }
            .labelStyle(CompactLabelStyle())
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(ink.opacity(0.62))
        }
        .fixedSize()
    }

    @ViewBuilder
    private func metricRow(ink: Color, vivid: Bool) -> some View {
        // 固定天空的体感 / 湿度 / 风读的是实时读数，关掉之后没有依据，这一行
        // 就空着——空着比印一串已经不对的数好。
        if liveWeather { liveMetricRow(ink: ink, vivid: vivid) }
    }

    private func liveMetricRow(ink: Color, vivid: Bool) -> some View {
        HStack(spacing: 12) {
            if let day = focusedDay {
                if let rain = day.rainChance {
                    InstrumentMetric(value: "\(rain)%", help: "降水概率 \(rain)%", ink: ink) {
                        umbrella(rain, ink: ink)
                    }
                }
                if let wind = day.wind {
                    let level = Self.beaufort(wind)
                    InstrumentMetric(value: "\(level)级", help: "最大风力 \(level) 级", ink: ink) {
                        WindDial(from: nil, calm: level == 0, ink: ink)
                    }
                }
                if let rise = day.sunrise {
                    InstrumentMetric(value: clock(rise), help: "日出 \(clock(rise))", ink: ink) {
                        solarIcon("sunrise.fill", ink: ink, vivid: vivid)
                    }
                }
                if let set = day.sunset {
                    InstrumentMetric(value: clock(set), help: "日落 \(clock(set))", ink: ink) {
                        solarIcon("sunset.fill", ink: ink, vivid: vivid)
                    }
                }
            } else if let reading {
                let feels = Int(reading.feelsLikeC.rounded())
                InstrumentMetric(value: "\(feels)°", help: "体感 \(feels)°", ink: ink) {
                    Image(systemName: feels >= 30 ? "thermometer.high" : feels <= 5 ? "thermometer.low" : "thermometer.medium")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ink.opacity(0.8))
                }
                InstrumentMetric(value: "\(reading.humidity)%", help: "湿度 \(reading.humidity)%", ink: ink) {
                    HumidityDrop(level: Double(reading.humidity) / 100, ink: ink)
                }
                let level = Self.beaufort(reading.windKph)
                InstrumentMetric(value: level == 0 ? "无风" : "\(level)级", help: windHelp(reading, level: level), ink: ink) {
                    WindDial(from: WindDial.bearing(reading.windDirection), calm: level == 0, ink: ink)
                }
                InstrumentMetric(value: "\(reading.rainChance)%", help: "未来几小时降水概率 \(reading.rainChance)%", ink: ink) {
                    umbrella(reading.rainChance, ink: ink)
                }
            } else {
                Text(weatherNote != nil ? "点击地点重试 · 天空按时区推算" : "天空按时区推算")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ink.opacity(0.55))
            }
        }
    }

    private func umbrella(_ chance: Int, ink: Color) -> some View {
        Image(systemName: chance >= 50 ? "umbrella.fill" : "umbrella")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(ink.opacity(chance >= 50 ? 0.92 : 0.72))
    }

    private func solarIcon(_ symbol: String, ink: Color, vivid: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10))
            .symbolRenderingMode(vivid ? .multicolor : .hierarchical)
            .foregroundStyle(ink)
    }

    private func windHelp(_ reading: WeatherReading, level: Int) -> String {
        guard level > 0 else { return "无风" }
        let direction = reading.windDirection.isEmpty ? "" : WindDial.name(reading.windDirection) + "风 "
        return "\(direction)\(level) 级 · \(Int(reading.windKph.rounded())) km/h"
    }

    private func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "en_GB"), timeZone: zone))
    }

    private func dayName(_ date: Date) -> String {
        var style = Date.FormatStyle(timeZone: zone).month(.defaultDigits).day().weekday(.abbreviated)
        style.locale = Locale(identifier: "zh_CN")
        return date.formatted(style)
    }

    private var weatherHelp: String {
        if let weatherNote { return weatherNote + " · 点击重试" }
        guard let reading else { return "刷新天气" }
        var parts = ["点击刷新", "更新于 \(reading.observedAt.formatted(date: .omitted, time: .shortened))"]
        if reading.conditionText != reading.skyLabel, !reading.conditionText.isEmpty { parts.append(reading.conditionText) }
        parts.append(locating ? "按当前位置" : "按设置的城市")
        return parts.joined(separator: " · ")
    }

    private var weatherAccessibility: String {
        let place = [placeParts.city, placeParts.district].compactMap { $0 }.joined(separator: "，")
        guard let reading else { return "\(place)，暂无天气，\(weatherLoading ? "正在更新" : weatherNote ?? "")" }
        let level = Self.beaufort(reading.windKph)
        return "\(place)，\(Int(reading.temperatureC.rounded()))度，\(reading.skyLabel)，体感 \(Int(reading.feelsLikeC.rounded()))度，湿度 \(reading.humidity)%，\(windHelp(reading, level: level))"
    }

    static func beaufort(_ kph: Double) -> Int {
        let limits: [Double] = [1, 6, 12, 20, 29, 39, 50, 62, 75, 89, 103, 118]
        return limits.firstIndex { kph < $0 } ?? 12
    }

    // MARK: - Forecast and sun path

    @ViewBuilder
    private func forecast(ink: Color, vivid: Bool, metrics m: Metrics) -> some View {
        if forecastDays.count > 1 {
            ForecastRibbon(days: forecastDays, zone: zone, ink: ink, vivid: vivid,
                           focus: hoveredDay ?? pinnedDay, pinned: pinnedDay, arrived: arrived,
                           hover: { hoveredDay = $0 },
                           toggle: { date in pinnedDay = pinnedDay == date ? nil : date },
                           move: movePin, clear: { pinnedDay = nil })
                .frame(width: m.chartWidth, height: m.chartHeight)
                .offset(x: m.width - m.margin - m.chartWidth, y: m.chartTop)
                .modifier(StatusArrival(arrived: arrived, delay: 1.35, reduceMotion: reduceMotion))
        }
    }

    private func movePin(_ step: Int) {
        guard !forecastDays.isEmpty else { return }
        let current = forecastDays.firstIndex { $0.date == pinnedDay } ?? (step > 0 ? 0 : forecastDays.count)
        let next = min(forecastDays.count - 1, max(0, current + step))
        pinnedDay = next == 0 ? nil : forecastDays[next].date
    }

    /// 日轨的日出日落。天气渲染关掉时不再按实时读数（那是屏幕上一个不是所在
    /// 地的坐标）推算，改用本机时区与纬度约 30° 走一遍同一个星历——这是
    /// `SkyScene.estimatedAstronomy` 已经在做的事，一处实现两处用。
    private var dayTimes: (rise: Date, set: Date) {
        SunPath.times(on: sceneDate, reading: liveWeather ? reading : nil, zone: zone)
    }

    private func sunPath(scene: SkyScene, ink: Color, vivid: Bool, times: (rise: Date, set: Date)) -> some View {
        let caption: String?
        if timeOffset != 0 { caption = "预览 \(previewTime)" }
        else if skyHovered, liveWeather { caption = "拖动天空 · 漫游一天" }
        else { caption = aside(scene: scene) }
        return SunPath(sunrise: times.rise, sunset: times.set, now: sceneDate, zone: zone, ink: ink, vivid: vivid,
                       caption: caption, captionAccent: timeOffset != 0)
            .allowsHitTesting(false)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: caption)
    }

    /// The phrase's own aside (late night, festivals) wins; otherwise the sky
    /// gets one line — an umbrella, a full moon, the golden hour.
    private func aside(scene: SkyScene) -> String? {
        if let aside = phrase.aside { return aside }
        let night = scene.nightness > 0.5
        if scene.rain > 0 { return night ? "listen to the rain" : "take an umbrella" }
        if scene.snow > 0 { return "it's snowing" }
        if scene.weather == .fog { return "soft light today" }
        if night, abs(scene.moonPhase - 0.5) < 0.03, scene.moonVisibility > 0.2 { return "full moon tonight" }
        if !night, scene.sunAltitude < 8, scene.sunAltitude > -2, scene.band == .sunset { return "golden hour" }
        if let t = reading?.temperatureC, t >= 33, !night { return "stay in the shade" }
        return nil
    }

    // MARK: - Manual sky

    private func skyConsole(scene: SkyScene, ink: Color, vivid: Bool) -> some View {
        let times = SunPath.times(on: skyDate, reading: reading, zone: zone)
        let picked = pinnedWeather ?? manualWeather
        return SkyConsole(weather: picked, band: scene.band, minutes: minutes, night: scene.nightness > 0.5,
                          sunrise: minutesOfDay(times.rise), sunset: minutesOfDay(times.set),
                          track: trackColors(weather: picked), ink: ink, vivid: vivid,
                          pickWeather: { weather in
                              if skyMode == "preview" {
                                  pinnedWeatherRaw = weather.rawValue
                              } else {
                                  manualWeatherRaw = weather.rawValue
                              }
                          },
                          pickBand: { glide(to: representativeMinutes($0)) },
                          scrub: { glider.stop(); manualMinutes = $0 },
                          commit: commitMinutes)
    }

    /// 「预演」只换天气图层，不换场景：时刻、日月、窗台、科目都留在原地，
    /// 所以切换本身不闪；点一下取消就回到实时天空。
    private func setPreview(_ on: Bool) {
        if on {
            guard weatherRendering else { return }
            pinnedWeatherRaw = pinnedWeatherRaw == "none" ? SkyScene.Weather.clear.rawValue : pinnedWeatherRaw
            skyMode = "preview"
        } else {
            pinnedWeatherRaw = "none"
            skyMode = "auto"
        }
    }

    /// Entering manual starts from the sky as it is now, so the switch itself
    /// changes nothing; leaving glides the hour back to now first, and the
    /// renderer cross-fades the weather.
    private func setManual(_ on: Bool, scene: SkyScene) {
        guard on != manual else { return }
        rewinder.stop()
        if on {
            timeOffset = 0
            manualWeatherRaw = scene.weather.rawValue
            manualMinutes = minutesOfDay(skyDate)
            commitMinutes()
            skyMode = "manual"
        } else {
            glide(to: minutesOfDay(Date())) { skyMode = "auto" }
        }
    }

    /// Where each part of the day is at its most itself, from today's sunrise
    /// and sunset — so "日落" is the sunset here, not 18:00 everywhere.
    private func representativeMinutes(_ band: SkyScene.Band) -> Double {
        let times = SunPath.times(on: skyDate, reading: reading, zone: zone)
        let rise = minutesOfDay(times.rise), set = minutesOfDay(times.set), noon = (rise + set) / 2
        switch band {
        case .dawn: return rise - 35
        case .sunrise: return rise + 12
        case .morning: return (rise + noon) / 2 + 20
        case .noon: return noon
        case .afternoon: return noon + (set - noon) * 0.55
        case .sunset: return set - 8
        case .dusk: return set + 32
        case .night: return SkyTimeline.wrap(set + 200)
        }
    }

    /// Moves the hour the short way round the clock with an ease-in-out, fast
    /// for a short hop and never longer than 1.4 s.
    private func glide(to target: Double, then finish: (() -> Void)? = nil) {
        glider.stop()
        let origin = minutes
        var delta = SkyTimeline.wrap(target) - origin
        if delta > 720 { delta -= 1440 } else if delta < -720 { delta += 1440 }
        guard !reduceMotion, abs(delta) > 1 else {
            manualMinutes = SkyTimeline.wrap(target)
            commitMinutes()
            finish?()
            return
        }
        let duration = min(1.4, 0.45 + abs(delta) / 720 * 0.95)
        let start = CACurrentMediaTime()
        glider.run { now in
            let p = min(1, max(0, (now - start) / duration))
            let eased = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
            manualMinutes = SkyTimeline.wrap(origin + delta * eased)
            guard p >= 1 else { return true }
            commitMinutes()
            finish?()
            return false
        }
    }

    private func nudgeManual(_ delta: Double) {
        glider.stop()
        manualMinutes = SkyTimeline.wrap(minutes + delta)
        commitMinutes()
    }

    private func commitMinutes() {
        if let manualMinutes, manualMinutes != storedMinutes { storedMinutes = manualMinutes }
    }

    /// The chosen weather's sky at every hour of today, for the timeline's
    /// track. Twenty-five scenes are cheap once but not per frame of a drag,
    /// so they are kept until the weather, the day or the place changes.
    @MainActor private static var trackCache: (key: String, colors: [Color])?

    private func trackColors(weather: SkyScene.Weather) -> [Color] {
        let day = calendar.startOfDay(for: skyDate)
        let key = "\(weather.rawValue)|\(day.timeIntervalSince1970)|\(reading?.latitude ?? 0),\(reading?.longitude ?? 0)"
        if let cached = Self.trackCache, cached.key == key { return cached.colors }
        let sample = Self.sample(weather)
        let colors: [Color] = (0...24).map { hour in
            let date = day.addingTimeInterval(Double(hour) * 3600)
            let astronomy = reading?.astronomy(at: date) ?? SkyScene.estimatedAstronomy(date: date, timezone: zone)
            let scene = SkyScene.make(sky: sample.sky, rainChance: sample.rain, windKph: 10, windDirection: "",
                                      astronomy: astronomy)
            let c = simd_mix(scene.mid, scene.horizon, SIMD3(repeating: 0.45))
            return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
        }
        Self.trackCache = (key, colors)
        return colors
    }

    private func adjustSky(by seconds: Double) {
        rewinder.stop()
        timeOffset = min(43200, max(-43200, timeOffset + seconds))
    }

    private func returnToNow() {
        rewinder.stop()
        guard !reduceMotion else { timeOffset = 0; return }
        let origin = timeOffset, start = CACurrentMediaTime()
        guard origin != 0 else { return }
        rewinder.run { now in
            let progress = min(1, max(0, (now - start) / 0.75))
            timeOffset = progress >= 1 ? 0 : origin * pow(1 - progress, 3)
            return progress < 1
        }
    }

    // MARK: - Sill

    /// One glass sill of icon-and-gauge readings. Each chip says the minimum
    /// at rest and widens in place on hover with the one line behind it.
    private func sill(metrics m: Metrics) -> some View {
        HStack(spacing: 8) {
            SillChip(action: showModels, help: "Claude Code · \(ccModel) · \(ccProvider) · 打开模型管理",
                     detail: m.narrow ? nil : ccProvider) {
                ProductBrandMark(codex: false, well: false, page: true).frame(width: 15, height: 15)
                    .modifier(MarkNudge(motion: arrived && !reduceMotion && visible))
                Text(ccModel).font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: m.narrow ? 64 : 150, alignment: .leading)
            }
            .accessibilityLabel("Claude Code，\(ccModel)，\(ccProvider)，打开模型管理")
            SillChip(action: showModels, help: "Codex · \(codexModel) · \(codexProvider) · 打开模型管理",
                     detail: m.narrow ? nil : codexProvider) {
                ProductBrandMark(codex: true, well: false, page: true).frame(width: 15, height: 15)
                Text(codexModel).font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: m.narrow ? 64 : 150, alignment: .leading)
            }
            .accessibilityLabel("Codex，\(codexModel)，\(codexProvider)，打开模型管理")
            Rectangle().fill(.white.opacity(0.16)).frame(width: 0.5, height: 18)
            SillChip(action: refreshCursor, help: cursorHelp, detail: cursorDetail) {
                allowance(brand: .cursor, metrics: cursorMetrics, loading: cursorLoading, narrow: m.narrow)
            }
            .disabled(cursorLoading)
            .accessibilityLabel("刷新 Cursor 额度，" + cursorSummary)
            SillChip(action: refreshQuota, help: "点击刷新 Codex 额度 · " + quotaHelp, detail: quotaDetail) {
                allowance(brand: .codex, metrics: codexMetrics, loading: quotaLoading, narrow: m.narrow)
            }
            .disabled(quotaLoading)
            .accessibilityLabel("刷新 Codex 额度，" + quotaHelp)
            Spacer(minLength: 8)
            SillChip(action: showUsage, help: "今日 \(tokens.formatted()) Token · 昨日 \(yesterdayTokens.formatted()) · 预估 \(spend) · \(calls.formatted()) 次 · 点击查看用量",
                     detail: "\(spend) · \(calls.formatted()) 次") {
                if tokens > 0 || yesterdayTokens > 0 {
                    TokenComparison(today: tokens, yesterday: yesterdayTokens,
                                    tint: Color(hex: 0x7FD6FF), secondary: .white)
                        .frame(width: 22, height: 9)
                }
                Text(UsageStats.formatTokens(tokens))
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    .rollingNumber(valueKey: String(tokens))
                    .fixedSize()
                if yesterdayTokens > 0 {
                    Text(changeText).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Color(hex: tokens >= yesterdayTokens ? 0x7CE7B8 : 0xFFB38A))
                }
            }
            .layoutPriority(1)
            .accessibilityLabel("今日 \(tokens) Token，昨日 \(yesterdayTokens) Token，预估费用 \(spend)，\(calls) 次调用，查看用量")
        }
        .foregroundStyle(Color.white.opacity(0.9))
        .padding(.horizontal, 12)
        .frame(width: m.width, height: m.sill)
        .modifier(SillGlass(corner: 0))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.22)).frame(height: 0.5) }
    }

    private var changeText: String {
        let change = (Double(tokens) / Double(max(1, yesterdayTokens)) - 1) * 100
        return String(format: "%@%.0f%%", change >= 0 ? "↑" : "↓", abs(change))
    }

    /// An allowance chip's face, matching the popup's switcher row: the
    /// family's mark, then one remaining-share gauge per window or pool. A
    /// narrow card keeps the first (the one that runs out soonest).
    @ViewBuilder
    private func allowance(brand: ProductBrandMark.Brand, metrics: [SillGauge.Metric],
                           loading: Bool, narrow: Bool) -> some View {
        ProductBrandMark(brand: brand, well: false, page: true).frame(width: 13, height: 13)
        if metrics.isEmpty {
            if loading && !reduceMotion && visible {
                Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold))
                    .symbolEffect(.rotate, options: .repeating, isActive: true)
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                Text("—").font(.system(size: 11, weight: .semibold))
            }
        } else {
            ForEach(narrow ? Array(metrics.prefix(1)) : metrics) { SillGauge(metric: $0) }
        }
    }

    /// Reset time counted from the sky clock's minute, so a scrubbed or
    /// rendered sky agrees with itself.
    private func resetCountdown(_ reset: Date?) -> String? {
        guard let reset else { return nil }
        let minutes = max(0, Int(reset.timeIntervalSince(skyDate) / 60))
        if minutes == 0 { return "待重置" }
        if minutes >= 1440 { return "\(minutes / 1440)天后重置" }
        return String(format: "%d:%02d 后重置", minutes / 60, minutes % 60)
    }

    // MARK: Codex allowance — the popup's two rate-limit windows ("5 小时" / "7 天")

    private var codexMetrics: [SillGauge.Metric] {
        windows.map { SillGauge.Metric(label: $0.label, usedPercent: $0.usedPercent) }
    }

    /// Hover line: when each window comes back.
    private var quotaDetail: String? {
        guard !windows.isEmpty else {
            if quotaLoading { return "读取中" }
            if let quotaNote, !quotaNote.isEmpty { return quotaNote }
            return "暂无额度"
        }
        let resets = windows.compactMap { window in resetCountdown(window.resetsAt).map { "\(window.label) \($0)" } }
        return resets.isEmpty ? nil : resets.joined(separator: " · ")
    }

    private var quotaHelp: String {
        guard !windows.isEmpty else { return quotaNote ?? "暂无额度数据" }
        return windows.map {
            let used = Int(min(100, max(0, $0.usedPercent)).rounded())
            let wait = $0.resetWait.isEmpty ? "" : "（\($0.resetWait)）"
            return "\($0.label)剩余 \(100 - used)%（已用 \(used)%），\($0.resetClock)\(wait)"
        }
        .joined(separator: " · ")
    }

    // MARK: Cursor allowance — the popup's two named pools ("Cursor" / "Other")

    /// Cursor Models and Other Models, as the popup's chip draws them. A plan
    /// that names neither (legacy / team shapes) falls back to the one monthly
    /// share it does report.
    private var cursorMetrics: [SillGauge.Metric] {
        guard let plan = cursorPlan else { return [] }
        var metrics: [SillGauge.Metric] = []
        if let pool = plan.cursorModelsFraction { metrics.append(.init(label: "Cursor", usedPercent: pool * 100)) }
        if let pool = plan.otherModelsFraction { metrics.append(.init(label: "Other", usedPercent: pool * 100)) }
        if metrics.isEmpty { metrics.append(.init(label: "本月", usedPercent: plan.usedFraction * 100)) }
        return metrics
    }

    private var cursorSummary: String {
        guard cursorPlan != nil else { return cursorNote ?? "暂无读数" }
        return cursorMetrics.map { "\($0.label) 剩余 \(Int($0.remaining.rounded()))%" }.joined(separator: "，")
    }

    private var cursorHelp: String {
        var parts = ["点击刷新 Cursor 额度"]
        if cursorPlan != nil { parts.append(cursorSummary) }
        if let detail = cursorPlan.map(cursorPlanDetail) { parts.append(detail) }
        if let cursorNote { parts.append(cursorNote) }
        return parts.joined(separator: " · ")
    }

    private var cursorDetail: String? {
        guard let plan = cursorPlan else { return cursorLoading ? "读取中" : cursorNote.map { _ in "Cursor 无读数" } }
        return cursorPlanDetail(plan)
    }

    /// The popup's footer — the shared monthly spend — and when the month turns.
    private func cursorPlanDetail(_ plan: CursorUsageFetcher.PlanUsage) -> String {
        var parts: [String] = []
        if let spend = plan.spendText { parts.append(spend) }
        if let reset = plan.resetsAt {
            let days = max(0, Int(reset.timeIntervalSince(skyDate) / 86400))
            parts.append(days <= 0 ? "待重置" : "\(days)天后重置")
        }
        return parts.isEmpty ? "月度额度" : parts.joined(separator: " · ")
    }
}

/// Meteor-shower peak nights (local dates), when the clear-sky meteor rate rises.
/// Evaluates `content` again only when `key` changes (used with
/// `.equatable()`). The sheet's parts take closures, which SwiftUI cannot
/// compare, so without this every change of the sheet's state — sixty or a
/// hundred and twenty a second during a drag — rebuilds all of them.
private struct Unchanged<Key: Equatable, Content: View>: View, Equatable {
    let key: Key
    @ViewBuilder let content: () -> Content

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    var body: some View { content() }
}

/// Calls `tick` once per display refresh (up to 120 Hz on ProMotion) with the
/// frame's target presentation time, until it returns `false` or `stop()`.
/// Runs in the common modes, so it keeps going while a drag is tracking.
@MainActor final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private var tick: ((CFTimeInterval) -> Bool)?

    func run(_ tick: @escaping (CFTimeInterval) -> Bool) {
        stop()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        self.tick = tick
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        tick = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let tick else { return }
        if !tick(link.targetTimestamp) { stop() }
    }
}

enum SkyEvents {
    static func meteorShower(on date: Date, in zone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.month, .day], from: date)
        switch (parts.month ?? 0, parts.day ?? 0) {
        case (1, 3), (1, 4), (8, 11), (8, 12), (8, 13), (12, 13), (12, 14): return true
        default: return false
        }
    }
}

/// Before the Metal pipeline is ready (or where Metal is unavailable): the
/// same palette and layout in SwiftUI, over the Canvas weather, the phrase in
/// the same face and weight (fully written — there is no write-on without the
/// GPU's progress channel).
private struct FallbackSky: View {
    var scene: SkyScene
    var reading: WeatherReading?
    var astronomy: SkyAstronomy.Snapshot
    var layout: GreetingTypesetter.Layout

    private func color(_ c: SIMD3<Float>) -> Color { Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(stops: [.init(color: color(scene.zenith), location: 0),
                                   .init(color: color(scene.mid), location: 0.47),
                                   .init(color: color(scene.horizon), location: 0.86)],
                           startPoint: .top, endPoint: .bottom)
            if let reading {
                WeatherBackdrop(sky: reading.sky, isDay: scene.nightness < 0.5, intensity: reading.rainChance,
                                astronomy: astronomy, windKph: reading.windKph)
            }
            let ink = scene.prefersDarkInk ? Color(hex: 0x141E33) : Color.white
            let outline = Path(GreetingTypesetter.phrasePath(layout))
            ZStack {
                outline.fill(ink)
                if layout.outlineWidth > 0 {
                    outline.stroke(ink, style: StrokeStyle(lineWidth: layout.outlineWidth, lineCap: .round, lineJoin: .round))
                }
            }
            .compositingGroup()
            .opacity(0.95)
            .shadow(color: .black.opacity(scene.prefersDarkInk ? 0 : 0.22), radius: 24, y: 10)
            if !layout.name.isEmpty {
                Text(layout.name)
                    .font(Font(GreetingTypesetter.nameFont(size: layout.nameSize)))
                    .tracking(layout.nameSize * 0.16)
                    .foregroundStyle(ink.opacity(0.82))
                    .fixedSize()
                    .alignmentGuide(.top) { $0[.firstTextBaseline] }
                    .offset(x: layout.nameOrigin.x, y: layout.nameOrigin.y)
            }
        }
    }
}

/// A reading on the sill: capsule, hover lift, press dip — and, when it has
/// one, a detail line that slides out beside the reading while hovered, so
/// the sill never needs a panel over the sky.
private struct SillChip<Label: View>: View {
    var action: () -> Void
    var help: String
    var detail: String? = nil
    @ViewBuilder var label: Label
    @State private var hovered = false
    @State private var expanded = false
    @State private var hoverTask: Task<Void, Never>?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                label
                if expanded, let detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .offset(x: -6)))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.white.opacity(hovered ? 0.14 : 0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(SillPressStyle())
        .opacity(enabled ? 1 : 0.55)
        .onHover { inside in
            hovered = inside
            hoverTask?.cancel()
            // A short dwell, so sweeping the pointer along the sill does not
            // ripple every chip open and shut.
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(inside ? 140 : 60))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) { expanded = inside }
            }
        }
        .onDisappear { hoverTask?.cancel() }
        .help(help)
    }
}

private struct SillPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// `↑ 32°`: the arrow set small and tight against its figure.
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 1) {
            configuration.icon.font(.system(size: 8, weight: .bold)).opacity(0.8)
            configuration.title
        }
    }
}

/// Smoked glass on the sky: native glass on macOS 26, a material stack on 15,
/// an opaque fill under Reduce Transparency.
private struct SillGlass: ViewModifier {
    var corner: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        if reduceTransparency {
            content.background(Color(hex: 0x141B28), in: shape)
        } else if #available(macOS 26.0, *) {
            content.background {
                shape.fill(Color(hex: 0x0A1426).opacity(0.28))
                    .glassEffect(.regular.tint(Color(hex: 0x0A1426).opacity(0.35)), in: shape)
            }
        } else {
            content
                .background(Color(hex: 0x0A1426).opacity(0.42), in: shape)
                .background(.ultraThinMaterial.opacity(0.6), in: shape)
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: corner > 0 ? 0.5 : 0))
                .environment(\.colorScheme, .dark)
        }
    }
}

/// The clock: minutes at 22pt light, a seconds point that breathes once a
/// second, the date beside it at 11pt. While the sky is scrubbed it shows the
/// previewed time instead, in amber, so the two never disagree.
///
/// The tick is `.periodic`, once a second. An `.animation` schedule — even one
/// whose `minimumInterval` is a whole second — keeps the hosting view in the
/// per-frame layout path for as long as it is unpaused (see the performance
/// note on `TimelineView`). The dot still flips with the second, and the
/// minute still rolls through `.numericText` when it changes. A scrubbed sky
/// or a hidden surface draws the face once and does not schedule anything.
private struct GreetingClock: View {
    var ink: Color
    var timezone: String?
    var preview: Date?
    @State private var onScreen = true
    @Environment(\.surfaceIsVisible) private var visible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let amber = Color(hex: 0xFFD27A)

    var body: some View {
        Group {
            if let preview {
                face(shown: preview, second: nil)
            } else if visible && onScreen {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    face(shown: context.date, second: Calendar.current.component(.second, from: context.date))
                }
            } else {
                face(shown: .now, second: nil)
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
        .accessibilityElement(children: .combine)
    }

    private func face(shown: Date, second: Int?) -> some View {
        let zone = preview == nil ? TimeZone.current : (timezone.flatMap(TimeZone.init(identifier:)) ?? .current)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(alignment: .top, spacing: 3) {
                    Text(shown, format: Date.FormatStyle(timeZone: zone).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
                        .font(.system(size: 22, weight: .light)).monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .foregroundStyle(preview == nil ? ink.opacity(0.92) : Self.amber)
                    if let second {
                        Circle().fill(ink)
                            .frame(width: 3, height: 3)
                            .opacity(second % 2 == 0 ? 0.8 : 0.35)
                            .padding(.top, 5)
                    } else if preview != nil {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Self.amber)
                            .padding(.top, 4)
                    }
                }
                Text(shown.formatted(Date.FormatStyle(timeZone: zone).month().day().weekday(.abbreviated).locale(Locale(identifier: "zh_CN"))))
                    .font(.system(size: 11, weight: .medium)).tracking(0.4).foregroundStyle(ink.opacity(0.6))
            }
            if preview == nil, let timezone, let zone = TimeZone(identifier: timezone),
               zone.secondsFromGMT(for: shown) != TimeZone.current.secondsFromGMT(for: shown) {
                Text("天气当地 \(shown.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)))")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(ink.opacity(0.5))
            }
        }
    }
}

/// Today against yesterday as two bars, today on top. Deliberately carries no
/// `value:`-keyed animation: `today` republishes several times a second during
/// a transcript burst, and `frame(width:)` would interpolate on every one.
private struct TokenComparison: View {
    var today: Int
    var yesterday: Int
    var tint: Color
    var secondary: Color
    var body: some View {
        GeometryReader { geo in
            let maximum = Double(max(1, max(today, yesterday)))
            VStack(alignment: .leading, spacing: 2) {
                Capsule().fill(tint)
                    .frame(width: max(2, geo.size.width * Double(max(0, today)) / maximum), height: 3.5)
                Capsule().fill(secondary.opacity(0.4))
                    .frame(width: max(2, geo.size.width * Double(max(0, yesterday)) / maximum), height: 2.5)
            }
            .frame(maxHeight: .infinity)
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
            .opacity(arrived || reduceMotion ? 1 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.86).delay(delay), value: arrived)
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
