import SwiftUI

/// The 概览 band: one sky. HELLO and the name open across it, the weather
/// sits on the sky with no plate of its own, and a thin row along the top
/// carries Codex quota, the CC balance, the Codex model, and today's spend.
struct GreetingCard: View {
    /// Today's spend lives on `.usage`; the CC balance on `.configuration`.
    /// Scoped so a session poll does not rebuild the sky.
    @ProviderState([.usage, .configuration]) private var providerStore
    @EnvironmentObject private var codexStore: CodexProviderStore
    @State private var weather = WeatherStore.shared
    @State private var now = Date()
    @State private var city = AppPreferences.shared.weatherCity
    @State private var costDisplay = AppPreferences.shared.costDisplay
    @ObservedObject private var fx = ExchangeRate.shared

    private let name = MachineIdentity.greetingName

    private var reading: WeatherReading? { weather.reading }

    private var palette: SkyPalette {
        guard let reading else { return .neutral }
        return SkyPalette(sky: reading.sky, night: reading.isDay == false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            statusRow
            HStack(alignment: .bottom, spacing: Theme.Space.s24) {
                greetingColumn
                weatherColumn
            }
        }
        .padding(.horizontal, Theme.Space.s24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: 228, alignment: .leading)
        .tile(tint: palette.accent, hovered: false,
              lens: nil, framed: false,
              wash: 0, lift: false,
              ground: AnyView(SkyGround(palette: palette,
                                        sky: reading?.sky,
                                        isDay: reading?.isDay,
                                        intensity: reading?.rainChance ?? 0)))
        .onReceive(Self.ticker) { now = $0 }
        .onReceive(AppPreferences.shared.$weatherCity.removeDuplicates()) { newCity in
            city = newCity
            weather.refresh()
        }
        .onReceive(AppPreferences.shared.$costDisplay.removeDuplicates()) { costDisplay = $0 }
        .onAppear { weather.refreshIfStale() }
        .accessibilityElement(children: .contain)
    }

    private static let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // MARK: - Status

    /// Codex allowance, the CC balance, the model Codex is pointed at, and
    /// what today has cost. Type on the sky — no chips, no second card.
    private var statusRow: some View {
        HStack(spacing: 14) {
            glance("CODEX", codexQuotaLine)
            glanceRule
            glance("CC", providerStore.balanceText ?? "—")
            glanceRule
            glance("模型", codexModel)
                .frame(maxWidth: 220, alignment: .leading)
            Spacer(minLength: 12)
            glance("今日", todaySpend)
        }
    }

    private func glance(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(palette.inkSoft)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }

    private var glanceRule: some View {
        Rectangle()
            .fill(palette.inkSoft.opacity(0.35))
            .frame(width: 1, height: 22)
    }

    private var codexQuotaLine: String {
        let windows = codexStore.quotaWindows
        if windows.isEmpty {
            if codexStore.quotaLoading { return "…" }
            return codexStore.quotaNote ?? "—"
        }
        return windows.prefix(2).map { window in
            let remain = Int((100 - window.usedPercent).rounded())
            let label = window.label
                .replacingOccurrences(of: " 小时", with: "h")
                .replacingOccurrences(of: " 天", with: "d")
            return "\(label) \(remain)%"
        }.joined(separator: " · ")
    }

    private var codexModel: String {
        codexStore.activeProvider?.activeModel?.name ?? "未配置"
    }

    private var todaySpend: String {
        let shown = ModelPricing.present(providerStore.todayUsage.cost.cost,
                                         display: costDisplay, rate: fx.effectiveRate)
        guard let primary = shown.primary else { return "—" }
        return ModelPricing.format(primary.amount, currency: primary.currency)
    }

    // MARK: - Greeting

    private var greetingColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(dateLine)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(palette.inkSoft)
                .padding(.bottom, 8)

            SkyGreeting(name: name, palette: palette, animated: true)

            Text(Self.clock.string(from: now))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.ink)
                .contentTransition(.identity)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hello，\(name)，\(dateLine)，\(Self.clock.string(from: now))")
    }

    private var dateLine: String {
        "\(Self.date.string(from: now))  ·  \(Self.weekday.string(from: now))"
    }

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

    // MARK: - Weather

    /// Temperature and condition, set directly on the sky. No plate: a frame
    /// around the reading turned the weather into a second card.
    private var weatherColumn: some View {
        Button {
            weather.refresh()
        } label: {
            VStack(alignment: .trailing, spacing: 2) {
                temperature
                HStack(spacing: 5) {
                    Text(reading?.skyLabel ?? (weather.loading ? "查询中" : "无读数"))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .symbolEffect(.rotate, options: .repeating, isActive: weather.loading)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(palette.inkSoft)

                Text(placeLine)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.inkSoft)
                    .lineLimit(1)

                if let reading {
                    HStack(spacing: 10) {
                        extreme("最高", reading.highC)
                        extreme("最低", reading.lowC)
                    }
                    .padding(.top, 4)
                    Text("体感 \(Int(reading.feelsLikeC.rounded()))°  ·  湿度 \(reading.humidity)%")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(palette.inkSoft)
                        .lineLimit(1)
                } else if let note = weather.note {
                    Text(note)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.inkSoft)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.985))
        .help(weatherHelp)
        .accessibilityLabel(weatherAccessibility)
    }

    private var temperature: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(temperatureNumber)
                .font(.system(size: 52, weight: .light, design: .rounded))
                .monospacedDigit()
            if reading != nil {
                Text("°")
                    .font(.system(size: 22, weight: .light, design: .rounded))
                    .padding(.top, 6)
            }
        }
        .foregroundStyle(palette.ink)
    }

    private var temperatureNumber: String {
        guard let reading else { return "—" }
        return "\(Int(reading.temperatureC.rounded()))"
    }

    private func extreme(_ label: String, _ celsius: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(palette.inkSoft)
            Text("\(Int(celsius.rounded()))°")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.ink)
        }
    }

    private var placeLine: String {
        guard let reading, !reading.place.isEmpty else {
            return city.isEmpty ? "未设置天气城市" : city
        }
        return reading.place
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
        return "\(reading.place) \(reading.skyLabel) \(Int(reading.temperatureC.rounded())) 度，最高 \(Int(reading.highC.rounded())) 度，最低 \(Int(reading.lowC.rounded())) 度，体感 \(Int(reading.feelsLikeC.rounded())) 度，湿度 \(reading.humidity)%"
    }
}

/// The band's ground: the sky's gradient, the sky's motion, and — on a real
/// sky — a static veil so the type stays readable without a per-frame blur.
struct SkyGround: View {
    var palette: SkyPalette
    var sky: WeatherReading.Sky?
    var isDay: Bool?
    var intensity: Int

    var body: some View {
        ZStack {
            palette.gradient
            if let sky {
                WeatherBackdrop(sky: sky, isDay: isDay, intensity: intensity)
            }
            if !palette.isLightGround {
                LinearGradient(stops: [
                    .init(color: Color.black.opacity(0.22), location: 0),
                    .init(color: Color.black.opacity(0.06), location: 0.38),
                    .init(color: Color.black.opacity(0), location: 0.70),
                ], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.20)],
                               startPoint: .center, endPoint: .bottom)
                VStack(spacing: 0) {
                    LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 52)
                    Spacer(minLength: 0)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
