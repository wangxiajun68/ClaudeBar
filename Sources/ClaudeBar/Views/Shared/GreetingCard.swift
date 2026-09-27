import SwiftUI

/// The 概览 page's one wide band: **the sky, the date, the clock, and Hello**.
///
/// This replaces the four 1×4 glance tiles the page used to open with. Those four
/// figures (额度 / 模型 / 花费 / Token) all had a deeper home already — 用量页的
/// 模型瓦片、资源条的读数、模型页的当前连接 — so the row was a second,
/// shallower copy of numbers a person scrolls past anyway, and it spent the one
/// strip on the page that everybody sees first. What the band says instead is
/// what nothing else in the app can: what time it is, what day it is, what the
/// weather is doing, and which machine this is.
///
/// **The card is the sky.** There is one continuous weather gradient across the
/// full width and one set of weather motions running over the whole band, behind
/// all three readings — the weather, the clock and the greeting do not draw
/// backgrounds of their own, so there is no seam between them. The gradient and
/// its ink come from `SkyPalette` (a night card is dark with light type, a clear
/// day is the ice canvas warmed a few degrees), and the motion from
/// `WeatherBackdrop`, which is a `TimelineView`-driven `Canvas` paused by
/// reduce-motion and visibility exactly like the machine marks.
///
/// The surface itself is still the app's: `WeatherBackdrop` is handed to
/// `.tile(base:)`, so the depth lens, the inner frame ring, the hairline edge and
/// the Core Animation layer shadow are the same four parts every other card in
/// the app wears.
struct GreetingCard: View {
    // No store subscription here, deliberately. The four glance tiles this
    // replaces read two stores to draw their figures; every one of those figures
    // now lives on the page it belongs to, so a `@ProviderState` on this band
    // would be a subscription with no reader (and `.configuration` publishes on
    // every balance fetch).

    @State private var weather = WeatherStore.shared
    @State private var now = Date()
    @State private var city = AppPreferences.shared.weatherCity

    /// Read once — a host name cannot change under us.
    private let machine = MachineIdentity.displayName

    private var reading: WeatherReading? { weather.reading }

    /// No reading yet (first launch, offline, or 城市 left blank): the band
    /// paints the ice canvas's own step and says nothing about weather. It is not
    /// an error state — the clock and the greeting are complete on their own.
    private var palette: SkyPalette {
        guard let reading else { return .neutral }
        return SkyPalette(sky: reading.sky, night: reading.isDay == false)
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s24) {
            weatherBlock
            Spacer(minLength: Theme.Space.s16)
            clockBlock
            Spacer(minLength: Theme.Space.s16)
            greetingBlock
        }
        .padding(.horizontal, Theme.Space.s24)
        .padding(.vertical, Theme.Space.s16)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
        // One surface. `base:` is the sky, `WeatherBackdrop` is its motion, and
        // both sit *behind* every reading on the card — which is what keeps the
        // gradient continuous across the three modules instead of three blocks
        // with a seam. `lift: false` because this is a page band (see
        // `TileSurface.lift`), and no wash because the base already *is* colour.
        .tile(tint: nil, hovered: false,
              lens: DepthLensSpec(tint: palette.accent, size: 150, overflow: 0.28),
              wash: 0, lift: false,
              base: AnyShapeStyle(AnyGradientBackground(palette: palette,
                                                        sky: reading?.sky,
                                                        isDay: reading?.isDay,
                                                        intensity: reading?.rainChance ?? 0)))
        .onReceive(Self.ticker) { now = $0 }
        .onReceive(AppPreferences.shared.$weatherCity.removeDuplicates()) { newCity in
            city = newCity
            weather.refresh()
        }
        .onAppear { weather.refreshIfStale() }
        .help(weatherHelp)
        .accessibilityElement(children: .contain)
    }

    /// A 1 Hz publisher that exists for the clock alone. `.common` mode keeps it
    /// ticking through a scroll or a resize — a `.default`-mode timer freezes
    /// mid-drag and the seconds visibly stop.
    private static let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // MARK: - Weather

    /// The weather's own column: the figure, the words, and where it is. It has
    /// no panel behind it — the card is the sky.
    private var weatherBlock: some View {
        Button {
            weather.refresh()
        } label: {
            HStack(alignment: .center, spacing: Theme.Space.s14) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(reading?.temperatureText ?? "—")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(palette.ink)
                        Text(reading?.skyLabel ?? (weather.loading ? "查询中" : "无读数"))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(palette.accent)
                    }
                    Text(placeLine)
                        .font(Theme.Font.tileDetail)
                        .foregroundStyle(palette.inkSoft)
                        .lineLimit(1)
                    if let reading {
                        RollingNumberText("最高 \(Int(reading.highC.rounded()))° · 最低 \(Int(reading.lowC.rounded()))°")
                            .font(Theme.Font.tileDetail)
                            .foregroundStyle(palette.inkSoft)
                            .lineLimit(1)
                    } else if let note = weather.note {
                        Text(note)
                            .font(Theme.Font.tileDetail)
                            .foregroundStyle(palette.inkSoft)
                            .lineLimit(1)
                    }
                }
                .frame(minWidth: 168, alignment: .leading)

                // The retry affordance, and the only control on the band: a
                // quiet glyph in the palette's own ink so it reads on any sky.
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.inkSoft)
                    .opacity(weather.loading ? 0.35 : 0.8)
                    .rotationEffect(.degrees(weather.loading ? 360 : 0))
                    .animation(.linear(duration: 0.9), value: weather.loading)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help(weatherHelp)
        .accessibilityLabel(weatherAccessibility)
    }

    private var placeLine: String {
        guard let reading, !reading.place.isEmpty else {
            return city.isEmpty ? "未设置天气城市" : city
        }
        return reading.place
    }

    // MARK: - Clock

    private var clockBlock: some View {
        VStack(spacing: 2) {
            Text(Self.clock.string(from: now))
                .font(.system(size: 46, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.identity)
            HStack(spacing: 7) {
                Text(Self.weekday.string(from: now))
                    .font(Theme.Font.tileLabel)
                    .foregroundStyle(palette.accent)
                Rectangle()
                    .fill(palette.inkSoft.opacity(0.35))
                    .frame(width: 1, height: 10)
                Text(Self.date.string(from: now))
                    .font(Theme.Font.tileLabel)
                    .foregroundStyle(palette.inkSoft)
            }
            .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.weekday.string(from: now)) \(Self.date.string(from: now)) \(Self.clock.string(from: now))")
    }

    /// `HH:mm:ss`. Seconds included, because the band's whole point is that it is
    /// alive, and a clock that moves once a minute reads as a screenshot.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEEE"
        return f
    }()

    // MARK: - Greeting

    private var greetingBlock: some View {
        SkyGreeting(name: machine, palette: palette, animated: reading != nil)
            .frame(maxWidth: 460, alignment: .trailing)
    }

    // MARK: - Copy

    private var weatherHelp: String {
        guard let reading else {
            return weather.note ?? (city.isEmpty
                ? "没有设置天气城市（设置 → 界面 → 天气城市）"
                : "天气暂不可用，点一下重试")
        }
        var lines = [
            "\(reading.place.isEmpty ? city : reading.place) · \(reading.conditionText.isEmpty ? reading.skyLabel : reading.conditionText)",
            "体感 \(Int(reading.feelsLikeC.rounded()))° · 湿度 \(reading.humidity)% · 风 \(reading.windDirection) \(Int(reading.windKph.rounded())) km/h",
            "日出 \(reading.sunrise) · 日落 \(reading.sunset)",
        ]
        if reading.rainChance > 0 { lines.append("未来数小时降水概率 \(reading.rainChance)%") }
        if let note = weather.note { lines.append(note) }
        lines.append("数据：wttr.in · 点一下刷新")
        return lines.joined(separator: "\n")
    }

    private var weatherAccessibility: String {
        guard let reading else { return "天气 \(weather.note ?? "不可用")" }
        return "\(reading.place) \(reading.skyLabel) \(Int(reading.temperatureC.rounded())) 度，最高 \(Int(reading.highC.rounded())) 度，最低 \(Int(reading.lowC.rounded())) 度"
    }
}

/// The band's ground: the sky's gradient with the sky's motion running over it.
///
/// It is a `ShapeStyle` rather than a `View` because the tile's base has to be a
/// style (that is what `.fill(_:)` takes). `resolve(in:)` draws the gradient and
/// hands the animated backdrop to `LayerView`, so the canvas is a layer inside
/// the tile's own background stack — above the fill, below the content, clipped
/// by the tile's corner shape along with everything else.
struct AnyGradientBackground: ShapeStyle {
    var palette: SkyPalette
    var sky: WeatherReading.Sky?
    var isDay: Bool?
    var intensity: Int

    func resolve(in environment: EnvironmentValues) -> some View {
        ZStack {
            palette.gradient
            if let sky {
                WeatherBackdrop(sky: sky, isDay: isDay, intensity: intensity)
            }
        }
    }
}
