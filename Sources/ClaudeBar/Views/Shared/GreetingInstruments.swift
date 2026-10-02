import SwiftUI

// The greeting card's instruments: small drawings that carry a reading so the
// words around them can stay few. All of them are drawn in the sky's ink —
// white on a deep sky, navy on a pale one — and none owns a timer; they redraw
// when the card hands them a new value.

// MARK: - Weather glyphs

/// An SF weather symbol in the card's voice: multicolour on a deep sky, where
/// the yellow sun and blue rain read; hierarchical ink on a pale one, where
/// multicolour's white cloud would vanish.
struct WeatherGlyph: View {
    var symbol: String
    var size: CGFloat
    var ink: Color
    var vivid: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .regular))
            .symbolRenderingMode(vivid ? .multicolor : .hierarchical)
            .foregroundStyle(ink)
            .contentTransition(.symbolEffect(.replace))
            .shadow(color: .black.opacity(vivid ? 0.2 : 0), radius: size * 0.2, y: size * 0.06)
            .accessibilityHidden(true)
    }
}

/// A raindrop filled to the relative humidity.
struct HumidityDrop: View {
    var level: Double
    var ink: Color

    var body: some View {
        let fill = min(1, max(0, level))
        ZStack {
            DropShape().fill(ink.opacity(0.14))
            DropShape().fill(ink.opacity(0.78))
                .mask(alignment: .bottom) { Rectangle().frame(height: 12 * fill) }
            DropShape().stroke(ink.opacity(0.78), lineWidth: 1)
        }
        .frame(width: 9, height: 12)
        .accessibilityHidden(true)
    }
}

private struct DropShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addCurve(to: CGPoint(x: r.midX, y: r.maxY),
                   control1: CGPoint(x: r.midX + w * 0.8, y: r.minY + h * 0.58),
                   control2: CGPoint(x: r.midX + w * 0.5, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.midX, y: r.minY),
                   control1: CGPoint(x: r.midX - w * 0.5, y: r.maxY),
                   control2: CGPoint(x: r.midX - w * 0.8, y: r.minY + h * 0.58))
        return p
    }
}

/// A compass ring with the arrow pointing where the wind is *going* — the way
/// a weather map draws it. Calm air is a still dot.
struct WindDial: View {
    /// Where the wind comes from, degrees clockwise from north.
    var from: Double?
    var calm: Bool
    var ink: Color

    var body: some View {
        ZStack {
            Circle().stroke(ink.opacity(0.42), lineWidth: 1)
            if calm || from == nil {
                Circle().fill(ink.opacity(0.8)).frame(width: 3, height: 3)
            } else if let from {
                Image(systemName: "arrow.up")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(ink.opacity(0.9))
                    .rotationEffect(.degrees(from + 180))
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }

    /// All three spellings the sources use: Open-Meteo's eight bare Chinese
    /// points, wttr.in's sixteen English ones, and 中国天气网's `"北风"` —
    /// which is the form the app actually receives whenever AMap has no key
    /// (the default), so it is the common case, not an edge case. The trailing
    /// 风 is part of the *word*, not of the direction, and leaving it on made
    /// the bearing unresolvable (dial fell back to a dot) and the tooltip read
    /// "北风风 3 级".
    static func bearing(_ direction: String) -> Double? {
        var text = direction.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("风") { text.removeLast() }
        let chinese: [String: Double] = ["北": 0, "东北": 45, "东": 90, "东南": 135,
                                         "南": 180, "西南": 225, "西": 270, "西北": 315]
        if let degrees = chinese[text] { return degrees }
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        return points.firstIndex(of: text.uppercased()).map { Double($0) * 22.5 }
    }

    /// The direction as a word, or `nil` when the source's string names no
    /// point — the caller must not append 风 to a string it did not resolve.
    static func name(_ direction: String) -> String? {
        guard let bearing = bearing(direction) else { return nil }
        let names = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        return names[(Int(bearing / 45 + 0.5) % 8 + 8) % 8]
    }
}

/// One icon-led reading: the glyph carries the meaning, the figure the value,
/// the tooltip and VoiceOver the words.
struct InstrumentMetric<Icon: View>: View {
    var value: String
    var help: String
    var ink: Color
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(spacing: 4) {
            icon.frame(width: 12, height: 12)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(ink.opacity(0.82))
                .lineLimit(1)
                .fixedSize()
        }
        .contentShape(Rectangle())
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }
}

// MARK: - Forecast ribbon

/// The coming days as one picture: a glyph per day, the high/low band as a
/// smooth ribbon, rain chance as faint bars behind it. Only the highs carry
/// figures; the focused day adds its low and a guide line.
///
/// Hover focuses a day, a click pins it, ←/→ walk the pin, Esc lets go. The
/// ribbon reports focus up; the card decides what the rest of the sky says.
struct ForecastRibbon: View {
    var days: [WeatherDay]
    var zone: TimeZone
    var ink: Color
    var vivid: Bool
    var focus: Date?
    var pinned: Date?
    var arrived: Bool
    var hover: (Date?) -> Void
    var toggle: (Date) -> Void
    var move: (Int) -> Void
    var clear: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let glyphRow: CGFloat = 8
    private static let chartTop: CGFloat = 28
    private static let chartBottom: CGFloat = 58
    private static let labelRow: CGFloat = 72

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let column = width / CGFloat(max(1, days.count))
            let points = plot(width: width)
            let focusIndex = days.firstIndex { $0.date == focus }
            ZStack(alignment: .topLeading) {
                chart(points: points, column: column, focusIndex: focusIndex)
                    .mask(alignment: .leading) {
                        Rectangle().scaleEffect(x: arrived || reduceMotion ? 1 : 0, anchor: .leading)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).delay(1.35), value: arrived)
                    }
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    let x = column * (CGFloat(index) + 0.5)
                    let focused = index == focusIndex
                    WeatherGlyph(symbol: day.sky.symbol(), size: focused ? 15 : 13, ink: ink, vivid: vivid)
                        .frame(width: column, height: 16)
                        .position(x: x, y: Self.glyphRow)
                    Text("\(Int(day.high.rounded()))°")
                        .font(.system(size: focused ? 10 : 9, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(ink.opacity(focused ? 1 : 0.86))
                        .fixedSize()
                        .position(x: x, y: points[index].high.y - 8)
                    if focused {
                        Text("\(Int(day.low.rounded()))°")
                            .font(.system(size: 9, weight: .medium)).monospacedDigit()
                            .foregroundStyle(ink.opacity(0.86))
                            .fixedSize()
                            .position(x: x, y: points[index].low.y + 8)
                            .transition(.opacity)
                    }
                    HStack(spacing: 3) {
                        if day.date == pinned {
                            Circle().fill(ink.opacity(0.9)).frame(width: 3, height: 3)
                        }
                        Text(weekday(day.date, index: index))
                            .font(.system(size: 9, weight: focused ? .semibold : .medium))
                            .foregroundStyle(ink.opacity(focused ? 1 : 0.86))
                    }
                    .fixedSize()
                    .position(x: x, y: Self.labelRow)
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: focus)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location): hover(day(at: location.x, column: column)?.date)
                case .ended: hover(nil)
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                if let day = day(at: location.x, column: column) { toggle(day.date) }
            }
        }
        .shadow(color: .black.opacity(vivid ? 0.24 : 0), radius: 4, y: 1)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.escape) { clear(); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("未来 \(days.count) 天预报")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(1)
            case .decrement: move(-1)
            @unknown default: break
            }
        }
        .help("悬停查看某天 · 点击固定 · ←/→ 切换 · Esc 回到现在")
    }

    private struct Plot { var high: CGPoint; var low: CGPoint; var rain: Double }

    private func plot(width: CGFloat) -> [Plot] {
        guard !days.isEmpty else { return [] }
        let column = width / CGFloat(days.count)
        let floor = days.map(\.low).min() ?? 0
        let ceiling = days.map(\.high).max() ?? 1
        let span = max(4, ceiling - floor)
        let base = floor - (span - (ceiling - floor)) / 2
        func y(_ t: Double) -> CGFloat {
            Self.chartBottom - CGFloat((t - base) / span) * (Self.chartBottom - Self.chartTop)
        }
        return days.enumerated().map { index, day in
            let x = column * (CGFloat(index) + 0.5)
            return Plot(high: CGPoint(x: x, y: y(day.high)), low: CGPoint(x: x, y: y(day.low)),
                        rain: Double(day.rainChance ?? 0) / 100)
        }
    }

    private func chart(points: [Plot], column: CGFloat, focusIndex: Int?) -> some View {
        let warm = vivid ? Color(hex: 0xFFC47A) : Color(hex: 0xD9803A)
        let cool = vivid ? Color(hex: 0x8CC8FF) : Color(hex: 0x3F7FCF)
        return Canvas { context, _ in
            guard !points.isEmpty else { return }
            let bar = min(12, column * 0.3)
            for point in points where point.rain > 0.05 {
                let height = CGFloat(point.rain) * 22
                let rect = CGRect(x: point.high.x - bar / 2, y: Self.chartBottom + 2 - height, width: bar, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .color(cool.opacity(0.12 + point.rain * 0.22)))
            }
            let highs = Self.smooth(points.map(\.high))
            let lows = Self.smooth(points.map(\.low))
            var band = highs
            Self.appendSmooth(points.map(\.low).reversed(), to: &band)
            band.closeSubpath()
            context.fill(band, with: .linearGradient(
                Gradient(colors: [warm.opacity(0.55), cool.opacity(0.36)]),
                startPoint: CGPoint(x: 0, y: Self.chartTop), endPoint: CGPoint(x: 0, y: Self.chartBottom)))
            context.stroke(highs, with: .color(ink.opacity(0.82)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            context.stroke(lows, with: .color(ink.opacity(0.4)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            if let focusIndex {
                let x = points[focusIndex].high.x
                var guide = Path()
                guide.move(to: CGPoint(x: x, y: Self.chartTop - 6))
                guide.addLine(to: CGPoint(x: x, y: Self.chartBottom + 4))
                context.stroke(guide, with: .color(ink.opacity(0.22)), lineWidth: 0.5)
            }
            for (index, point) in points.enumerated() {
                let focused = index == focusIndex
                let r: CGFloat = focused ? 3 : 1.8
                if focused {
                    context.fill(Path(ellipseIn: CGRect(x: point.high.x - 6, y: point.high.y - 6, width: 12, height: 12)),
                                 with: .color(warm.opacity(0.3)))
                }
                context.fill(Path(ellipseIn: CGRect(x: point.high.x - r, y: point.high.y - r, width: r * 2, height: r * 2)),
                             with: .color(ink))
                let lr = r * 0.85
                context.fill(Path(ellipseIn: CGRect(x: point.low.x - lr, y: point.low.y - lr, width: lr * 2, height: lr * 2)),
                             with: .color(ink.opacity(focused ? 0.9 : 0.55)))
            }
        }
        .accessibilityHidden(true)
    }

    /// Catmull-Rom through the day points as cubic Béziers; with six points a
    /// monotone spline and this are indistinguishable, and this never
    /// overshoots enough to cross the other curve at the ribbon's spacing.
    private static func smooth(_ points: [CGPoint]) -> Path {
        var path = Path()
        appendSmooth(points, to: &path)
        return path
    }

    /// Continues the current subpath with a line to the first point when there
    /// is one (so the band closes as one region), otherwise starts it there.
    private static func appendSmooth(_ points: [CGPoint], to path: inout Path) {
        guard let first = points.first else { return }
        if path.isEmpty { path.move(to: first) } else { path.addLine(to: first) }
        guard points.count > 1 else { return }
        for i in 0..<(points.count - 1) {
            let p0 = points[max(0, i - 1)], p1 = points[i], p2 = points[i + 1], p3 = points[min(points.count - 1, i + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
    }

    private func day(at x: CGFloat, column: CGFloat) -> WeatherDay? {
        guard !days.isEmpty, column > 0 else { return nil }
        return days[min(days.count - 1, max(0, Int(x / column)))]
    }

    private func weekday(_ date: Date, index: Int) -> String {
        if index == 0 { return "今天" }
        var style = Date.FormatStyle(timeZone: zone).weekday(.abbreviated)
        style.locale = Locale(identifier: "zh_CN")
        return date.formatted(style)
    }

    private var accessibilityValue: String {
        guard let day = days.first(where: { $0.date == focus }) ?? days.first else { return "" }
        let index = days.firstIndex(of: day) ?? 0
        return "\(weekday(day.date, index: index))，\(day.sky.caption)，\(Int(day.low.rounded()))到\(Int(day.high.rounded()))度"
            + (day.rainChance.map { "，降水概率 \($0)%" } ?? "")
    }
}

// MARK: - Sun path

/// The day as an arc: sunrise on the left, sunset on the right, the sun where
/// it is now (or at the scrubbed time), the travelled part drawn solid. At
/// night the moon walks a shallow arc under the horizon towards sunrise.
struct SunPath: View {
    var sunrise: Date?
    var sunset: Date?
    var now: Date
    var zone: TimeZone
    var ink: Color
    var vivid: Bool
    var caption: String?
    var captionAccent: Bool

    private static let horizon: CGFloat = 34

    var body: some View {
        VStack(spacing: 3) {
            Canvas { context, size in draw(in: &context, size: size) }
                .frame(height: Self.horizon + 8)
            HStack(spacing: 6) {
                time(sunrise, symbol: "sunrise.fill")
                Spacer(minLength: 4)
                if let caption {
                    Text(caption)
                        .font(.system(size: 9, weight: .medium))
                        .italic(!captionAccent)
                        .foregroundStyle(captionAccent ? Color(hex: 0xFFD27A) : ink.opacity(0.86))
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Spacer(minLength: 4)
                time(sunset, symbol: "sunset.fill")
            }
        }
        .shadow(color: .black.opacity(vivid ? 0.28 : 0), radius: 4, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("日出 \(sunrise == nil ? "暂无时间" : clock(sunrise))，日落 \(sunset == nil ? "暂无时间" : clock(sunset))" + (caption.map { "，\($0)" } ?? ""))
    }

    private func time(_ date: Date?, symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8))
                .symbolRenderingMode(vivid ? .multicolor : .hierarchical)
            Text(clock(date)).font(.system(size: 9, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(ink.opacity(0.8))
        .fixedSize()
    }

    private func clock(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "en_GB"), timeZone: zone))
    }

    /// Where the body is along its arc, 0…1, and whether it is the sun's.
    private var progress: (fraction: Double, day: Bool)? {
        guard let sunrise, let sunset else { return nil }
        let length = sunset.timeIntervalSince(sunrise)
        guard length > 0 else { return nil }
        if now >= sunrise && now <= sunset { return (now.timeIntervalSince(sunrise) / length, true) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: sunset),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: sunrise) else { return nil }
        let dusk = now > sunset ? sunset : yesterday
        let dawn = now > sunset ? tomorrow : sunrise
        let night = max(1, dawn.timeIntervalSince(dusk))
        return (min(1, max(0, now.timeIntervalSince(dusk) / night)), false)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let cx = size.width / 2, rx = size.width / 2 - 8, ry = Self.horizon - 6
        func dayPoint(_ f: Double) -> CGPoint {
            CGPoint(x: cx - rx * cos(.pi * f), y: Self.horizon - ry * sin(.pi * f))
        }
        func nightPoint(_ f: Double) -> CGPoint {
            CGPoint(x: cx + rx * cos(.pi * f), y: Self.horizon + 6 * sin(.pi * f))
        }
        func arc(_ point: (Double) -> CGPoint, to end: Double) -> Path {
            var path = Path()
            path.move(to: point(0))
            for step in 1...48 { path.addLine(to: point(end * Double(step) / 48)) }
            return path
        }

        var horizon = Path()
        horizon.move(to: CGPoint(x: 0, y: Self.horizon))
        horizon.addLine(to: CGPoint(x: size.width, y: Self.horizon))
        context.stroke(horizon, with: .color(ink.opacity(0.34)), lineWidth: 0.5)

        guard let (f, isDay) = progress else { return }
        context.stroke(arc(dayPoint, to: 1), with: .color(ink.opacity(0.42)),
                       style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1.5, 3]))
        let sunColor = vivid ? Color(hex: 0xFFD27A) : Color(hex: 0xE08A2E)
        if isDay {
            context.stroke(arc(dayPoint, to: f), with: .linearGradient(
                Gradient(colors: [ink.opacity(0.35), sunColor]),
                startPoint: dayPoint(0), endPoint: dayPoint(f)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            let sun = dayPoint(f)
            context.fill(Path(ellipseIn: CGRect(x: sun.x - 9, y: sun.y - 9, width: 18, height: 18)),
                         with: .radialGradient(Gradient(colors: [sunColor.opacity(0.5), sunColor.opacity(0)]),
                                               center: sun, startRadius: 0, endRadius: 9))
            context.fill(Path(ellipseIn: CGRect(x: sun.x - 3.5, y: sun.y - 3.5, width: 7, height: 7)), with: .color(sunColor))
        } else {
            context.stroke(arc(nightPoint, to: 1), with: .color(ink.opacity(0.2)),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1.5, 3]))
            let moon = nightPoint(f)
            var crescent = Path(ellipseIn: CGRect(x: moon.x - 3.5, y: moon.y - 3.5, width: 7, height: 7))
            crescent.addPath(Path(ellipseIn: CGRect(x: moon.x - 1.5, y: moon.y - 4.5, width: 7, height: 7)))
            context.fill(crescent, with: .color(ink.opacity(0.92)), style: FillStyle(eoFill: true))
        }
    }

    /// Resolve events for the selected civil day, without fixed-hour placeholders.
    static func times(on date: Date, reading: WeatherReading?, zone: TimeZone) -> (rise: Date?, set: Date?) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let forecast = reading?.forecast.first { calendar.isDate($0.date, inSameDayAs: date) }
        func parse(_ text: String?) -> Date? {
            guard let text else { return nil }
            let pattern = #"^\s*(\d{1,2}):(\d{2})(?:\s*(AM|PM))?\s*$"#
            guard let match = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
            let value = String(text[match]).trimmingCharacters(in: .whitespaces).uppercased()
            let digits = value.split { !$0.isNumber }.compactMap { Int($0) }
            guard digits.count == 2, (0...59).contains(digits[1]) else { return nil }
            var hour = digits[0]
            let meridiem = value.hasSuffix("AM") || value.hasSuffix("PM")
            guard (meridiem ? 1...12 : 0...23).contains(hour) else { return nil }
            if meridiem { hour = hour % 12 + (value.hasSuffix("PM") ? 12 : 0) }
            return calendar.date(bySettingHour: hour, minute: digits[1], second: 0, of: date)
        }
        let currentDay = reading.map { calendar.isDate($0.observedAt, inSameDayAs: date) } ?? false
        // Strings have no date. Never reuse today's clocks for another forecast day.
        var rise = forecast?.sunrise ?? (forecast == nil && currentDay ? parse(reading?.sunrise) : nil)
        var set = forecast?.sunset ?? (forecast == nil && currentDay ? parse(reading?.sunset) : nil)
        if (rise == nil || set == nil), let latitude = reading?.latitude, let longitude = reading?.longitude {
            let events = SkyAstronomy.solarEvents(on: date, latitude: latitude, longitude: longitude, zone: zone)
            rise = rise ?? events.sunrise
            set = set ?? events.sunset
        }
        return (rise, set)
    }
}

// MARK: - Sill gauges

/// One allowance on the sill, read the way the popup's `QuotaSwayGauge` reads
/// it: the **remaining** share, the arc filling with what is left, the name
/// over the figure. The tint keys off the remainder, so only a window close to
/// empty is flagged.
struct SillGauge: View {
    struct Metric: Equatable, Identifiable {
        var label: String
        var usedPercent: Double
        var id: String { label }
        var remaining: Double { min(100, max(0, 100 - usedPercent)) }
    }

    var metric: Metric

    static func tint(remaining: Double) -> Color {
        Color(hex: remaining <= 10 ? 0xFF8A75 : remaining <= 25 ? 0xFFD37A : 0x7CE7B8)
    }

    var body: some View {
        let remaining = metric.remaining
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(.white.opacity(0.16), lineWidth: 2)
                Circle().trim(from: 0, to: remaining / 100)
                    .stroke(Self.tint(remaining: remaining), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            VStack(alignment: .leading, spacing: 0) {
                Text(metric.label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                Text("\(Int(remaining.rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .lineLimit(1)
            .fixedSize()
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Sky mode

/// 天气渲染关掉后，天空停在一种天气上；这一层天气在天空里叫 `SkyScene.Weather`，
/// 在卡片右上、控制台和日轨里则要用 `WeatherReading.Sky` 的说法（图标 / 名称）。
/// 两张表本来各自成立，这里只是搭一座桥——不是第三张口径。
///
/// **The bridge is the only copy.** `WeatherReading.Sky.symbol(night:)` owns the
/// glyphs; the card's pinned-sky icon and the manual console's weather table
/// both go through here, so a weather cannot end up with one name on the header
/// and another in the picker (it did: pinned heavy rain drew `cloud.rain.fill`
/// on the header and `cloud.heavyrain.fill` in the console).
enum PinnedSky {
    static func sky(for weather: SkyScene.Weather?) -> WeatherReading.Sky {
        switch weather {
        case .none, .clear: return .clear
        case .cloudy: return .partly
        case .overcast: return .cloudy
        case .lightRain: return .drizzle
        case .heavyRain: return .rain
        case .thunder: return .thunder
        case .snow: return .snow
        case .fog: return .fog
        }
    }
}

/// 实时 / 手动 / 贴图：天空跟着实时天气与钟点、跟着自选的天气与时刻，还是关掉
/// 天气、只留一张天空贴图。一个胶囊，选中项在两三格之间滑动。
///
/// 第三格是「预演」：天气渲染开着时它替换掉「贴图」那一格的位置，选中它
/// 只换天气图层、时刻留在原地。实时天气关掉（`rendering == false`）之后
/// 天空停在一种天气上，"贴图"这一格才是把它重新打开的开关。
struct SkyModeToggle: View {
    /// "auto" / "manual" / "preview"
    var skyMode: String
    /// 偏好里「实时天气（天气渲染）」那一项。关掉意思是天空现在停在某一层，
    /// 也正是这一格出现的原因。
    var rendering: Bool
    var ink: Color
    var setManual: (Bool) -> Void
    /// 开 / 关「预演」（只在实时天气开着时有意义）。
    var setPreview: (Bool) -> Void
    /// 「贴图」那一段：把实时天气关掉的那一项再打开。
    var setRendering: (Bool) -> Void

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var previewing: Bool { skyMode == "preview" }
    private var manual: Bool { skyMode == "manual" }
    private var none: Bool { !rendering && !manual && !previewing }

    private var selection: Int { manual ? 1 : (previewing ? 2 : 0) }

    var body: some View {
        HStack(spacing: 0) {
            if none {
                segment(0, title: "贴图", symbol: "photo",
                        help: "天气渲染已关闭：天空停在一种天气上，点一下重新打开")
            } else {
                segment(0, title: "自动", symbol: "sparkles", help: "天空跟随实时天气与时间")
                segment(1, title: "手动", symbol: "slider.horizontal.3", help: "自选天气与时段，拖动时间轴预览")
                if rendering {
                    segment(2, title: "预演", symbol: "wand.and.stars",
                            help: "只换这一层天气，时刻留在此刻")
                }
            }
        }
        .padding(2)
        .background(ink.opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(ink.opacity(0.16), lineWidth: 0.5))
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: skyMode)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: rendering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("天空模式")
    }

    private func segment(_ index: Int, title: String, symbol: String, help: String) -> some View {
        let selected = selection == index
        return Button { tap(index) } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .foregroundStyle(ink.opacity(selected ? 1 : 0.86))
            .background {
                if selected {
                    Capsule().fill(ink.opacity(0.2)).matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(InstrumentPressStyle())
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tap(_ index: Int) {
        switch index {
        case 0:
            if none { setRendering(true) } else { setManual(false) }
        case 1:
            // 手动换自动，或预演换手动；同一个动作——真正的手动。
            //
            // Re-tapping 手动 while already manual must be a no-op: the pair
            // below leaves manual by the *other* door first (`setPreview(false)`
            // writes `skyMode = "auto"` unconditionally), which makes
            // `setManual`'s own `on != manual` guard pass and re-seeds the hour
            // from now — silently throwing away the time the user just scrubbed
            // and persisting it. Case 0 does not have the problem because
            // `setManual(false)` finds `manual == false` and returns.
            if previewing {
                setPreview(false)
            } else if manual {
                return
            }
            setManual(true)
        default:
            setPreview(!previewing)
        }
    }
}

// MARK: - Manual sky console

/// The manual sky, set in place where the sun path sits in automatic mode:
/// eight weathers, eight parts of the day, and a 24-hour timeline painted in
/// that day's own sky colours. Picking a part of the day glides the hour there;
/// the timeline (or a drag across the sky itself) scrubs it directly.
struct SkyConsole: View {
    var weather: SkyScene.Weather
    var band: SkyScene.Band
    var minutes: Double
    var night: Bool
    /// Minutes after local midnight.
    var sunrise: Double?
    var sunset: Double?
    /// The sky's colour at each hour, 00:00…24:00.
    var track: [Color]
    var ink: Color
    var vivid: Bool
    var pickWeather: (SkyScene.Weather) -> Void
    var pickBand: (SkyScene.Band) -> Void
    var scrub: (Double) -> Void
    var commit: () -> Void

    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One column per choice, shared by both rows, so each weather sits over
    /// a part of the day and the console reads as a grid.
    static let cell: CGFloat = 34

    /// The eight weathers, with the console's own short titles. The **glyphs
    /// come from `WeatherReading.Sky.symbol(night:)` through `PinnedSky`** —
    /// spelling them out here made this a third weather→icon table, and it had
    /// already drifted: 大雨 drew `cloud.heavyrain.fill` in this row while the
    /// card header drew `cloud.rain.fill` for the same weather.
    static let weathers: [(weather: SkyScene.Weather, title: String)] = [
        (.clear, "晴"), (.cloudy, "少云"), (.overcast, "阴"), (.lightRain, "小雨"),
        (.heavyRain, "大雨"), (.thunder, "雷雨"), (.snow, "雪"), (.fog, "雾"),
    ]

    static let bands: [(band: SkyScene.Band, title: String)] = [
        (.dawn, "黎明"), (.sunrise, "日出"), (.morning, "上午"), (.noon, "正午"),
        (.afternoon, "下午"), (.sunset, "日落"), (.dusk, "黄昏"), (.night, "夜晚"),
    ]

    var body: some View {
        // Each weather carries its own name. With icons alone, the part-of-day
        // row directly beneath (same columns) read as their captions.
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                ForEach(Self.weathers, id: \.weather) { item in
                    let selected = item.weather == weather
                    Button { pickWeather(item.weather) } label: {
                        VStack(spacing: 2) {
                            WeatherGlyph(symbol: PinnedSky.sky(for: item.weather).symbol(night: night),
                                         size: 12, ink: ink, vivid: vivid)
                                .frame(height: 14)
                            Text(item.title)
                                .font(.system(size: 9, weight: selected ? .semibold : .medium))
                                .foregroundStyle(ink.opacity(selected ? 1 : 0.86))
                                .lineLimit(1)
                        }
                        .frame(width: Self.cell, height: 32)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ink.opacity(0.2))
                                    .matchedGeometryEffect(id: "weather", in: selection)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(InstrumentPressStyle())
                    .opacity(selected ? 1 : 0.78)
                    .help("天气：" + item.title)
                    .accessibilityLabel("天气，" + item.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            // A segmented track, so the time of day reads as its own control.
            HStack(spacing: 2) {
                ForEach(Self.bands, id: \.band) { item in
                    let selected = item.band == band
                    Button { pickBand(item.band) } label: {
                        Text(item.title)
                            .font(.system(size: 9.5, weight: selected ? .semibold : .medium))
                            .foregroundStyle(ink.opacity(selected ? 1 : 0.86))
                            .frame(width: Self.cell, height: 16)
                            .background {
                                if selected {
                                    Capsule().fill(ink.opacity(0.2)).matchedGeometryEffect(id: "band", in: selection)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(InstrumentPressStyle())
                    .disabled(sunrise == nil || sunset == nil)
                    .help(sunrise == nil || sunset == nil ? "暂无该地点当天的日出日落时间，可拖动时间轴" : "时段：" + item.title)
                    .accessibilityLabel("时段，" + item.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .background(Capsule().fill(ink.opacity(0.07)))
            SkyTimeline(minutes: minutes, sunrise: sunrise, sunset: sunset, track: track, ink: ink,
                        night: night, scrub: scrub, commit: commit)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: weather)
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: band)
        .shadow(color: .black.opacity(vivid ? 0.18 : 0), radius: 4, y: 1)
    }
}

/// The day as a slider: the track is the sky's own colour hour by hour, ticks
/// mark sunrise and sunset, the thumb carries the sun or the moon and the time
/// rides above it. Snaps to five minutes; ←/→ step a quarter hour.
struct SkyTimeline: View {
    var minutes: Double
    var sunrise: Double?
    var sunset: Double?
    var track: [Color]
    var ink: Color
    var night: Bool
    var scrub: (Double) -> Void
    var commit: () -> Void

    private static let day: Double = 1440

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let x = CGFloat(minutes / Self.day) * width
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(LinearGradient(colors: track.isEmpty ? [ink.opacity(0.3)] : track,
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(ink.opacity(0.28), lineWidth: 0.5))
                    .frame(width: width, height: 8)
                    .offset(y: 17)
                ForEach([sunrise, sunset].compactMap { $0 }, id: \.self) { mark in
                    Capsule().fill(ink.opacity(0.55))
                        .frame(width: 1.5, height: 12)
                        .offset(x: CGFloat(mark / Self.day) * width - 0.75, y: 15)
                }
                Text(Self.clock(minutes))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.92))
                    .fixedSize()
                    .position(x: min(width - 18, max(18, x)), y: 6)
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .overlay {
                        Image(systemName: night ? "moon.fill" : "sun.max.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(night ? Color(hex: 0x3A4A78) : Color(hex: 0xF29A2E))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .position(x: x, y: 21)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in scrub(Self.snap(Double(value.location.x / width) * Self.day)) }
                .onEnded { _ in commit() })
        }
        .frame(height: 30)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-15); return .handled }
        .onKeyPress(.rightArrow) { step(15); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("天空时间")
        .accessibilityValue(Self.clock(minutes))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(30)
            case .decrement: step(-30)
            @unknown default: break
            }
        }
        .help("拖动选择时间 · ←/→ 每次 15 分钟")
    }

    private func step(_ delta: Double) {
        scrub(Self.wrap(minutes + delta))
        commit()
    }

    static func snap(_ value: Double) -> Double { min(day - 5, max(0, (value / 5).rounded() * 5)) }
    static func wrap(_ value: Double) -> Double { (value.truncatingRemainder(dividingBy: day) + day).truncatingRemainder(dividingBy: day) }
    static func clock(_ minutes: Double) -> String {
        let total = Int(minutes.rounded()) % Int(day)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct InstrumentPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Six source-provided hour buckets. Rain uses an honest zero baseline; gaps
/// remain gaps, and unavailable precipitation never becomes a zero-height bar.
struct HourlyWeatherInstrument: View {
    var reading: WeatherReading
    var date: Date
    var ink: Color
    var darkInk = false

    var body: some View {
        let hours = reading.upcomingHours(at: date)
        // `hourMetric` only names a metric off a non-empty hour set, so an
        // empty one already lands in the else.
        if abs(date.timeIntervalSince(reading.observedAt)) < 7200,
           let metric = reading.hourMetric(at: date) {
            let help = details(hours: hours, metric: metric)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(metric.title + " · " + metric.unit)
                    Spacer(minLength: 4)
                    Text(summary(hours: hours, metric: metric))
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(ink.opacity(0.9))
                GeometryReader { geometry in
                    let values = hours.compactMap { metric.value($0) }
                    let low = metric == .temperature ? (values.min() ?? 0) - 1 : 0
                    let high = metric == .probability ? 100 : max(low + 1, values.max() ?? 1)
                    let span = max(3600, hours.last!.date.timeIntervalSince(hours.first!.date))
                    let width = max(0, geometry.size.width - 20)
                    let tint = metric == .precipitation || metric == .probability ? Color(hex: darkInk ? 0x175A80 : 0x77CFF3)
                        : metric == .temperature ? Color(hex: darkInk ? 0x874416 : 0xFFD18A) : ink
                    Canvas { context, size in
                        let baseline: CGFloat = 20
                        var axis = Path()
                        axis.move(to: CGPoint(x: 0, y: baseline))
                        axis.addLine(to: CGPoint(x: size.width, y: baseline))
                        context.stroke(axis, with: .color(ink.opacity(0.25)), lineWidth: 0.5)
                        var line = Path()
                        var previous: Date?
                        for hour in hours {
                            let x = 10 + width * hour.date.timeIntervalSince(hours.first!.date) / span
                            guard let value = metric.value(hour) else { previous = nil; continue }
                            let y = baseline - 18 * (value - low) / (high - low)
                            if metric == .precipitation || metric == .probability {
                                if value > 0 {
                                    let bar = CGRect(x: x - 5, y: y, width: 10, height: max(1, baseline - y))
                                    context.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(tint))
                                } else {
                                    context.fill(Path(ellipseIn: CGRect(x: x - 1, y: baseline - 1, width: 2, height: 2)), with: .color(ink.opacity(0.6)))
                                }
                            } else {
                                if let previous, hour.date.timeIntervalSince(previous) <= 3600 {
                                    line.addLine(to: CGPoint(x: x, y: y))
                                } else { line.move(to: CGPoint(x: x, y: y)) }
                                context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)), with: .color(tint))
                            }
                            previous = hour.date
                        }
                        context.stroke(line, with: .color(tint), lineWidth: 1.5)
                    }
                    ForEach(hours) { hour in
                        let x = 10 + width * hour.date.timeIntervalSince(hours.first!.date) / span
                        Text(clock(hour.date) + "时")
                            .font(.system(size: 8, weight: .medium).monospacedDigit())
                            .foregroundStyle(ink.opacity(0.86))
                            .position(x: x, y: 29)
                        if metric.value(hour) == nil {
                            Text("—").font(.system(size: 9)).foregroundStyle(ink.opacity(0.8))
                                .position(x: x, y: 10)
                        }
                    }
                }
            }
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(help)
        } else {
            Text("小时预报暂不可用")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(ink.opacity(0.86))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private func clock(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: reading.timezone) ?? .current
        return String(format: "%02d", calendar.component(.hour, from: date))
    }

    private func summary(hours: [WeatherReading.Hour], metric: WeatherReading.HourMetric) -> String {
        let values = hours.compactMap { metric.value($0) }
        guard let low = values.min(), let high = values.max() else { return "未来 6 小时" }
        if metric == .temperature { return String(format: "%.0f–%.0f° · 6小时", low, high) }
        return String(format: "峰值 %.1f %@ · 6小时", high, metric.unit)
    }

    private func details(hours: [WeatherReading.Hour], metric: WeatherReading.HourMetric) -> String {
        let readings = hours.map { hour in
            clock(hour.date) + "时 " + (metric.value(hour).map { String(format: "%.1f", $0) + " " + metric.unit } ?? "暂无数据")
        }.joined(separator: "；")
        let interval = metric == .precipitation ? " · 各时刻前一小时累计降水" : ""
        return metric.title + interval + " · " + (reading.hourlySource ?? reading.source) + "\n" + readings
    }
}
