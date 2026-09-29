import SwiftUI

extension WeatherReading.Sky {
    func symbol(night: Bool = false) -> String {
        switch self {
        case .clear: return night ? "moon.stars.fill" : "sun.max.fill"
        case .partly: return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case .cloudy: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case .rain: return "cloud.rain.fill"
        case .snow: return "cloud.snow.fill"
        case .thunder: return "cloud.bolt.rain.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .sleet: return "cloud.sleet.fill"
        case .hail: return "cloud.hail.fill"
        }
    }
    var caption: String {
        switch self {
        case .clear: return "晴"
        case .partly: return "晴间多云"
        case .cloudy: return "多云"
        case .fog: return "雾"
        case .rain: return "雨"
        case .snow: return "雪"
        case .thunder: return "雷雨"
        case .drizzle: return "毛毛雨"
        case .sleet: return "雨夹雪"
        case .hail: return "冰雹"
        }
    }
}

/// One open weather instrument: a magnetic date rail, comparable temperature
/// ranges, then a horizon plot and readings. No nested panel backgrounds.
struct WeatherExplorer: View {
    var reading: WeatherReading
    @Binding var selection: Date?
    var palette: SkyPalette
    var now: Date
    var compact = true
    var showDetails: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var pointer: CGFloat?
    @Namespace private var marker

    private var selected: WeatherDay? { reading.forecast.first { $0.date == selection } }
    private var ink: Color { palette.ink }
    private var soft: Color { palette.inkSoft }
    private var accent: Color { palette.accent }
    private var zone: TimeZone { TimeZone(identifier: reading.timezone) ?? .current }
    private func isToday(_ day: WeatherDay) -> Bool {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.isDate(day.date, inSameDayAs: now)
    }
    private var dayLabel: String {
        selected.map { label($0.date, format: "M月d日") + " · 日间预报" } ?? "此刻 · 当地天空"
    }
    /// The forecast horizon in words. The domestic sources serve four or five
    /// days rather than six, so the span is counted, never assumed.
    private var forecastHorizon: String {
        let days = reading.forecast.count
        return days > 1 ? "今天及未来 \(days - 1) 天" : "预报"
    }
    private var sourceURL: String {
        switch reading.source {
        case "高德": return "https://lbs.amap.com/"
        case "中国天气网": return "http://www.weather.com.cn/"
        case "Open-Meteo": return "https://open-meteo.com/"
        default: return "https://wttr.in/"
        }
    }
    private func label(_ date: Date, format: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = zone; f.dateFormat = format
        return f.string(from: date)
    }

    var body: some View {
        if compact { compactRail } else { detailedBody }
    }

    private var compactRail: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "calendar").font(.system(size: 16))
                Text(reading.forecast.count == 6 ? "六日预报" : "天气预报")
                    .font(.system(size: 11, weight: .semibold))
            }.foregroundStyle(soft).frame(width: 64, alignment: .leading)
            ForEach(reading.forecast) { day in
                Button {
                    selection = isToday(day) ? nil : day.date
                    showDetails()
                } label: {
                    VStack(spacing: 7) {
                        Text(isToday(day) ? "今天" : label(day.date, format: "EEE"))
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(ink.opacity(isToday(day) ? 0.18 : 0), in: Capsule())
                        HStack(spacing: 5) {
                            Image(systemName: day.sky.symbol())
                                .symbolRenderingMode(.multicolor).font(.system(size: 22))
                            if let chance = day.rainChance, chance > 20 {
                                Text("\(chance)%").font(.system(size: 9)).foregroundStyle(Color(hex: 0xA8DDFF))
                            }
                        }.frame(height: 24)
                        HStack(spacing: 4) {
                            Text("\(Int(day.low.rounded()))°").foregroundStyle(soft.opacity(0.75)).fixedSize()
                            GeometryReader { geo in
                                let low = reading.forecast.map(\.low).min() ?? day.low
                                let high = reading.forecast.map(\.high).max() ?? day.high
                                let span = max(1, high - low)
                                Capsule().fill(ink.opacity(0.12))
                                Capsule().fill(LinearGradient(colors: [Color(hex: 0x7FC8FF), Color(hex: 0xFFD98A)], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(2, geo.size.width * (day.high - day.low) / span))
                                    .offset(x: geo.size.width * (day.low - low) / span)
                            }.frame(height: 4)
                            Text("\(Int(day.high.rounded()))°").fontWeight(.semibold).fixedSize()
                        }.font(.system(size: 12)).monospacedDigit()
                    }.frame(maxWidth: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(WeatherIconStyle())
                .help("\(label(day.date, format: "M月d日")) · \(day.sky.caption) · 点击详情")
                .accessibilityLabel("\(label(day.date, format: "M月d日"))，\(day.sky.caption)，最低 \(Int(day.low)) 度，最高 \(Int(day.high)) 度，查看预报详情")
            }
            if reading.forecast.isEmpty {
                Button("预报暂不可用 · 查看详情", action: showDetails)
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(soft)
                Spacer()
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var detailedBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "calendar").foregroundStyle(accent)
                Text("天气展望").fontWeight(.semibold)
                Text(forecastHorizon).foregroundStyle(soft)
                Spacer()
                Text(reading.place).foregroundStyle(soft)

            }.font(.system(size: 11, weight: .medium))

            if !reading.forecast.isEmpty {
                GeometryReader { geometry in
                    let cellWidth = geometry.size.width / CGFloat(reading.forecast.count)
                    HStack(spacing: 0) {
                        ForEach(Array(reading.forecast.enumerated()), id: \.element.id) { index, day in
                            dayButton(day, index: index, width: cellWidth)
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): pointer = p.x
                        case .ended: pointer = nil
                        }
                    }
                }.frame(height: 116)
            } else {
                Label(reading.forecastNote ?? "预报暂不可用 · 点击右上方刷新", systemImage: "cloud.slash")
                    .font(.system(size: 12)).foregroundStyle(soft).padding(.vertical, 8)
            }
            Group {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 30) {
                        horizon.frame(width: 260)
                        metrics.frame(maxWidth: .infinity)
                    }.frame(minWidth: 670)
                    VStack(alignment: .leading, spacing: 20) {
                        metrics
                        horizon
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack {
                Text(reading.forecastNote ?? "")
                Spacer(minLength: 0)
                Button("天气数据 · \(reading.source) ↗") { openURL(URL(string: sourceURL)!) }.buttonStyle(.plain)
                    .help("天气数据来源与许可")
            }.font(.system(size: 9)).foregroundStyle(soft)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 14)
    }

    private func dayButton(_ day: WeatherDay, index: Int, width: CGFloat) -> some View {
        let active = isToday(day) ? selection == nil : selection == day.date
        let distance = pointer.map { abs($0 - (CGFloat(index) + 0.5) * width) } ?? 1000
        let influence = max(0, 1 - distance / max(1, width * 1.35))
        let low = reading.forecast.map(\.low).min() ?? day.low
        let high = reading.forecast.map(\.high).max() ?? day.high
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86)) {
                selection = isToday(day) ? nil : day.date
            }
        } label: {
            VStack(spacing: 10) {
                HStack(spacing: 4) {
                    Text(isToday(day) ? "今天" : label(day.date, format: "EEE"))
                    if !isToday(day) { Text(label(day.date, format: "M/d")).foregroundStyle(soft) }
                }.font(.system(size: 11, weight: active ? .bold : .medium))
                Image(systemName: day.sky.symbol())
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(accent, ink, soft)
                    .font(.system(size: 25, weight: .regular))
                    .frame(height: 30)
                    .scaleEffect(reduceMotion ? 1 : 1 + influence * 0.22)
                    .offset(y: reduceMotion ? 0 : -influence * 4)
                    .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.68), value: influence)
                HStack(spacing: 6) {
                    Text("\(Int(day.low.rounded()))°").foregroundStyle(soft).fixedSize()
                    GeometryReader { geo in
                        let span = max(1, high - low)
                        Capsule().fill(ink.opacity(0.12))
                        Capsule().fill(LinearGradient(colors: [Color(hex: 0x98D7EE), Color(hex: 0xFFE1A4)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, geo.size.width * (day.high - day.low) / span))
                            .offset(x: geo.size.width * (day.low - low) / span)
                    }.frame(height: 4)
                    Text("\(Int(day.high.rounded()))°").fixedSize()
                }.font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                ZStack {
                    Capsule().fill(.clear)
                    if active { Capsule().fill(accent).matchedGeometryEffect(id: "selected-date", in: marker) }
                }.frame(height: 2)
            }
            .padding(.horizontal, width < 100 ? 5 : 10).padding(.top, 4).padding(.bottom, 6)
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label(day.date, format: "M月d日 EEEE"))，\(day.sky.caption)，\(Int(day.low))至\(Int(day.high))度，降水概率\(day.rainChance.map { "\($0)%" } ?? "未知")")
        .accessibilityAddTraits(active ? .isSelected : [])
        .help("\(day.sky.caption) · 点击查看当天日照、降水和风速")
    }

    private var metrics: some View {
        HStack(alignment: .top, spacing: 0) {
            metric("降水概率", value: (selected?.rainChance ?? (selection == nil ? reading.rainChance : nil)).map { "\($0)%" } ?? "—", symbol: "drop.fill") {
                GeometryReader { geo in
                    let chance = Double(selected?.rainChance ?? (selection == nil ? reading.rainChance : 0)) / 100
                    Capsule().fill(ink.opacity(0.14))
                    Capsule().fill(accent).frame(width: max(0, geo.size.width * chance))
                }.frame(width: 58, height: 4)
            }
            metric(selected == nil ? "\(reading.windDirection)风" : "最大风速", value: (selected?.wind ?? (selection == nil ? reading.windKph : nil)).map { "\(Int($0.rounded())) km/h" } ?? "—", symbol: "wind") {
                Image(systemName: "location.north.line").font(.system(size: 13)).foregroundStyle(accent)
            }
            if selected == nil {
                metric("相对湿度", value: "\(reading.humidity)%", symbol: "humidity.fill") {
                    HStack(spacing: 2) {
                        ForEach(0..<10) { i in
                            Capsule().fill(i < reading.humidity / 10 ? accent : ink.opacity(0.14)).frame(width: 3, height: CGFloat(4 + i))
                        }
                    }
                }
                metric("体感", value: "\(Int(reading.feelsLikeC.rounded()))°", symbol: "thermometer.medium") {
                    Text(reading.feelsLikeC > reading.temperatureC + 2 ? "比实测更暖" : reading.feelsLikeC < reading.temperatureC - 2 ? "比实测更凉" : "接近实测").font(.system(size: 9)).foregroundStyle(soft)
                }
            } else {
                metric("日照时长", value: daylight, symbol: "sun.max") {
                    Text("日出至日落").font(.system(size: 9)).foregroundStyle(soft)
                }
            }
        }
    }
    private var daylight: String {
        guard let rise = selected?.sunrise, let set = selected?.sunset else { return "—" }
        let minutes = Int(set.timeIntervalSince(rise) / 60)
        return "\(minutes / 60)h \(minutes % 60)m"
    }
    private func metric<Graphic: View>(_ label: String, value: String, symbol: String, @ViewBuilder graphic: () -> Graphic) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(label, systemImage: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(soft)
            Text(value).font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.8)
            graphic().frame(height: 14)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var horizon: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(dayLabel)
                Spacer()
                if selection == nil, let astro = reading.astronomy(at: now) {
                    Text("太阳 \(Int(astro.sun.altitude.rounded()))°").monospacedDigit()
                }
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(soft)
            SolarHorizon(reading: reading, date: selected?.date ?? now, now: selection == nil ? now : nil, tint: accent, ink: ink)
                .frame(height: 45)
            HStack {
                Label(selected?.sunrise.map { label($0, format: "HH:mm") } ?? (selection == nil ? reading.sunrise : "—"), systemImage: "sunrise")
                Spacer()
                Label(selected?.sunset.map { label($0, format: "HH:mm") } ?? (selection == nil ? reading.sunset : "—"), systemImage: "sunset")
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(soft)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SolarHorizon: View {
    var reading: WeatherReading
    var date: Date
    var now: Date?
    var tint: Color
    var ink: Color
    var body: some View {
        Canvas { ctx, size in
            guard let lat = reading.latitude, let lon = reading.longitude else { return }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: reading.timezone) ?? .current
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            let duration = end.timeIntervalSince(start)
            func point(_ date: Date) -> CGPoint {
                let altitude = SkyAstronomy.snapshot(date: date, latitude: lat, longitude: lon).sun.altitude
                return CGPoint(x: date.timeIntervalSince(start) / duration * size.width, y: size.height * (0.65 - altitude / 90 * 0.6))
            }
            var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: size.height * 0.65)); baseline.addLine(to: CGPoint(x: size.width, y: size.height * 0.65))
            ctx.stroke(baseline, with: .color(ink.opacity(0.28)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            var curve = Path()
            for i in 0...96 {
                let p = point(start.addingTimeInterval(duration * Double(i) / 96))
                if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            ctx.stroke(curve, with: .color(tint.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            if let now {
                let p = point(now)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x-3, y: p.y-3, width: 6, height: 6)), with: .color(tint))
            }
        }.clipped().accessibilityHidden(true)
    }
}

private struct WeatherIconStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.94 : hover ? 1.1 : 1)
            .offset(y: reduceMotion || !hover ? 0 : -2)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: hover)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}

/// A compact per-day forecast strip: one slim column per day, meant to live
/// **inside the weather HUD**, not in the dock.
///
/// This replaced a full-width "天气展望" timeline in the dock. That timeline was
/// the old popover's content flattened into the card, and it made the greeting
/// band very tall — a six-column instrument under a 400pt sky and above two more
/// dock zones. The reading it carried (a six-day trend) is genuinely wanted, but
/// it does not need a third of the card to say it: the same glyphs beside the
/// current temperature answer "what is the week doing" at a glance, and the card
/// loses the whole dock row.
///
/// Columns are *slim*: a weekday (or 今天), the day's glyph, and the low/high.
/// The place name, the condition caption and the big single-day number all stay
/// with the HUD above — this strip is the trend, the HUD is now.
///
/// Motion is one-shot and Core Animation backed: each glyph runs
/// `symbolEffect(.variableColor…)` gated on `!reduceMotion && visible`, so an
/// idle, always-open card costs an idle card's worth of CPU. There is no timer,
/// no `TimelineView`, and no hover-driven rasterization here.
struct ForecastStrip: View {
    var reading: WeatherReading?
    var palette: SkyPalette
    var now: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.surfaceIsVisible) private var visible
    private var motionOn: Bool { !reduceMotion && visible }

    private var ink: Color { palette.ink }
    private var soft: Color { palette.inkSoft }
    private var accent: Color { palette.accent }
    private var zone: TimeZone { TimeZone(identifier: reading?.timezone ?? "") ?? .current }
    private var days: [WeatherDay] { Array((reading?.forecast ?? []).prefix(6)) }
    /// With nothing to draw the strip is not rendered at all — the HUD's own
    /// "no weather" line already says why, and a second empty box under it would
    /// be the dock row creeping back in.
    private var isEmpty: Bool { days.isEmpty }

    private func isToday(_ day: WeatherDay) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.isDate(day.date, inSameDayAs: now)
    }
    /// The weekday, short: `周二`. One character shorter than `星期二`, which is
    /// what keeps six columns readable inside the HUD's width.
    private func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = zone
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }
    /// The day's sky in the same alphabet the HUD draws: the live sky for today,
    /// the forecast code for the others.
    private func sky(_ day: WeatherDay) -> WeatherReading.Sky {
        isToday(day) ? (reading?.sky ?? day.sky) : day.sky
    }

    var body: some View {
        if !isEmpty {
            GeometryReader { geo in
                // Six columns in the HUD's 236–292pt is tight, so the type and
                // the gutters step down with the space rather than wrapping: a
                // wrapped "32°" reads as a bug, and the HUD cannot grow.
                let compact = geo.size.width < 268
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                        if index > 0 {
                            Rectangle().fill(ink.opacity(0.12))
                                .frame(width: 0.5, height: compact ? 36 : 40)
                        }
                        column(day, compact: compact)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
            .frame(height: 62)
            .accessibilityElement(children: .contain)
        }
    }

    private func column(_ day: WeatherDay, compact: Bool) -> some View {
        let today = isToday(day)
        return VStack(spacing: compact ? 2 : 3) {
            Text(today ? "今天" : weekday(day.date))
                .font(.system(size: compact ? 9 : 10, weight: today ? .bold : .semibold))
                .foregroundStyle(ink.opacity(today ? 0.95 : 0.8))
                .lineLimit(1).minimumScaleFactor(0.75)
            Image(systemName: sky(day).symbol(night: today && reading?.isDay == false))
                .symbolRenderingMode(.palette)
                .foregroundStyle(accent, ink)
                .font(.system(size: compact ? 15 : 16, weight: .medium))
                .frame(height: compact ? 17 : 19)
                // A slow colour wash reads as "alive sky" without moving pixels
                // off their centres, so the columns never jitter.
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: motionOn)
            HStack(spacing: compact ? 2 : 3) {
                Text("\(Int(day.high.rounded()))°").font(.system(size: compact ? 10 : 11, weight: .bold, design: .rounded)).monospacedDigit()
                Text("\(Int(day.low.rounded()))°").font(.system(size: compact ? 9 : 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(soft.opacity(0.82)).monospacedDigit()
            }
            .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(today ? "今天" : weekday(day.date))，\(sky(day).caption)，最高 \(Int(day.high.rounded())) 度，最低 \(Int(day.low.rounded())) 度")
    }
}

