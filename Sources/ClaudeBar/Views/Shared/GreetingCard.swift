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

    private var palette: SkyPalette {
        if let reading { return SkyPalette(sky: reading.sky, night: reading.isDay == false) }
        return .neutral
    }
    private var accent: Color { palette.accent }
    private var border: Color { palette.ink.opacity(0.16) }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 24) {
                    greeting.frame(maxWidth: .infinity, alignment: .leading)
                    weatherBlock.frame(width: 200)
                }
                .frame(minWidth: 860)
                VStack(alignment: .leading, spacing: 14) {
                    greeting
                    weatherBlock
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 28)
            .modifier(StatusArrival(arrived: arrived, delay: 0, reduceMotion: reduceMotion))

            Rectangle().fill(border).frame(height: 1)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    modelCell(isCodex: false)
                    modelCell(isCodex: true)
                    tokenCell
                    spendCell
                }.frame(minWidth: 760)
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        modelCell(isCodex: false)
                        modelCell(isCodex: true)
                    }
                    HStack(alignment: .top, spacing: 0) { tokenCell; spendCell }
                }
            }
            .padding(10)
            .modifier(StatusArrival(arrived: arrived, delay: 0.07, reduceMotion: reduceMotion))

            Rectangle().fill(border).frame(height: 1).padding(.horizontal, 28)
            quotaFooter
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .modifier(StatusArrival(arrived: arrived, delay: 0.14, reduceMotion: reduceMotion))
        }
        .background {
            ZStack {
                palette.gradient
                if let reading {
                    WeatherBackdrop(sky: reading.sky, isDay: reading.isDay, intensity: reading.rainChance)
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
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.2), value: reading?.sky)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        }
        .onAppear { arrived = true }
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

    private func modelCell(isCodex: Bool) -> some View {
        let model = isCodex ? codexModel : ccModel
        let provider = isCodex ? codexProvider : ccProvider
        let ink = palette.ink
        return Button(action: showModels) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: isCodex ? "terminal" : "command")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ink)
                    Text(isCodex ? "Codex" : "CC")
                        .font(.system(size: 12, weight: .semibold))
                    Text("当前模型")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.inkSoft)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.inkSoft)
                }
                Text(model)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .lineLimit(1).truncationMode(.middle)
                if isCodex {
                    HStack(spacing: 5) {
                        Text("余额").foregroundStyle(palette.inkSoft)
                        Text(balance).foregroundStyle(palette.ink).monospacedDigit()
                    }.font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                } else {
                    Text(provider).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.inkSoft).lineLimit(1)
                }
            }
            .foregroundStyle(palette.ink)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(StatusMagneticStyle(tint: ink))
        .help("\(isCodex ? "Codex" : "CC") · \(provider) · \(model)\(isCodex ? " · 余额 " + balance : "")\n打开模型管理")
        .accessibilityElement(children: .combine)
    }

    private var tokenCell: some View {
        Button(action: showUsage) {
            VStack(alignment: .leading, spacing: 8) {
                caption("今日 Token", icon: "chart.bar.xaxis")
                Text(UsageStats.formatTokens(tokens))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit().rollingNumber(valueKey: String(tokens))
                HStack(spacing: 8) {
                    TokenComparison(today: tokens, yesterday: yesterdayTokens, tint: palette.accent, secondary: palette.inkSoft)
                        .frame(width: 42, height: 13)
                    Text(yesterdayTokens > 0 ? "昨日 \(UsageStats.formatTokens(yesterdayTokens))" : "\(calls) 次调用")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.inkSoft).lineLimit(1)
                }
            }
            .foregroundStyle(palette.ink)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .padding(16).contentShape(Rectangle())
        }
        .buttonStyle(StatusMagneticStyle(tint: palette.ink))
        .help("今天 \(tokens.formatted()) Token，昨天 \(yesterdayTokens.formatted()) Token。上条为今天，下条为昨天。点击查看用量。")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日 \(tokens) Token，昨日 \(yesterdayTokens) Token，打开用量")
    }

    private var spendCell: some View {
        Button(action: showUsage) {
            VStack(alignment: .leading, spacing: 8) {
                caption("今日花费", icon: "yensign.circle")
                Text(spend)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit().rollingNumber(valueKey: spend)
                    .lineLimit(1).minimumScaleFactor(0.65)
                Text("按模型价格估算 · \(calls) 次调用")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.inkSoft).lineLimit(1)
            }
            .foregroundStyle(palette.ink)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .padding(16).contentShape(Rectangle())
        }
        .buttonStyle(StatusMagneticStyle(tint: accent))
        .help("今日花费为 API 标价估算，不代表实际账单。点击查看用量明细。")
        .accessibilityElement(children: .combine)
    }

    private func caption(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.inkSoft)
    }

    private var quotaFooter: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Codex 额度")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: refreshQuota) {
                    Label(quotaLoading ? "更新中" : "刷新额度", systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.inkSoft)
                .disabled(quotaLoading)
            }
            .foregroundStyle(palette.ink)
            if windows.isEmpty {
                Text(quotaLoading ? "正在读取账户额度…" : (quotaNote ?? "暂无额度数据，点击刷新重试"))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.inkSoft)
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 32) {
                        ForEach(windows.prefix(2)) { window in StatusQuotaMeter(window: window, palette: palette) }
                    }.frame(minWidth: 650)
                    VStack(spacing: 20) {
                        ForEach(windows.prefix(2)) { window in StatusQuotaMeter(window: window, palette: palette) }
                    }
                }
            }
        }
    }

    private var weatherBlock: some View {
        Button(action: refreshWeather) {
            HStack(spacing: 14) {
                Image(systemName: weatherSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(palette.inkSoft)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(reading.map { "\(Int($0.temperatureC.rounded()))°" } ?? "--°")
                            .font(.system(size: 56, weight: .light, design: .rounded))
                            .monospacedDigit()
                        Text(reading?.skyLabel ?? (weatherLoading ? "查询中" : "暂无天气"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.inkSoft)
                    }
                    Text(reading?.place.isEmpty == false ? reading!.place : (city.isEmpty ? "请设置城市" : city))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.inkSoft)
                    if let reading {
                        Text("↑\(Int(reading.highC.rounded()))°  ↓\(Int(reading.lowC.rounded()))°  ·  湿度 \(reading.humidity)%")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(palette.inkSoft)
                    } else {
                        Text(weatherLoading ? "正在获取实况" : "点击重试")
                            .font(.system(size: 10)).foregroundStyle(palette.inkSoft)
                    }
                }.lineLimit(1)
            }
            .foregroundStyle(palette.ink)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(StatusMagneticStyle(tint: palette.ink))
        .disabled(weatherLoading)
        .help(weatherNote ?? "点击刷新天气")
        .accessibilityElement(children: .combine)
    }

    private var weatherSymbol: String {
        guard let reading else { return "cloud" }
        switch reading.sky {
        case .clear: return reading.isDay == false ? "moon.stars.fill" : "sun.max.fill"
        case .partly: return reading.isDay == false ? "cloud.moon.fill" : "cloud.sun.fill"
        case .cloudy: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case .rain: return "cloud.rain.fill"
        case .snow: return "cloud.snow.fill"
        case .thunder: return "cloud.bolt.rain.fill"
        }
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

private struct StatusQuotaMeter: View {
    let window: CodexQuotaWindow
    var palette: SkyPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var remaining: Double { max(0, min(100, 100 - window.usedPercent)) }
    private var tint: Color {
        remaining <= 10 ? Color(hex: 0xFFA7A0) : remaining <= 25 ? Color(hex: 0xFFE1A6) : palette.accent
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 11, weight: .medium))
                Text("\(Int(remaining.rounded()))%")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit().rollingNumber(valueKey: String(remaining))
                Text("剩余").font(.system(size: 10)).foregroundStyle(palette.inkSoft)
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(waitText(at: context.date))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.inkSoft)
                }
            }.foregroundStyle(palette.ink)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.ink.opacity(0.13))
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * remaining / 100)
                }
                .mask {
                    HStack(spacing: 3) {
                        ForEach(0..<40, id: \.self) { _ in Rectangle() }
                    }
                }
            }.frame(height: 6)
                .animation(reduceMotion ? nil : .spring(response: 0.65, dampingFraction: 0.86), value: remaining)
            Text(window.resetClock)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex \(window.label)，剩余 \(Int(remaining))%，\(window.resetClock)")
    }

    private func waitText(at now: Date) -> String {
        guard let reset = window.resetsAt else { return "刷新时间未知" }
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return "等待额度更新" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return "\(minutes / 1440)天 \(minutes % 1440 / 60)小时后刷新" }
        if minutes >= 60 { return "\(minutes / 60)小时 \(minutes % 60)分后刷新" }
        return "\(minutes)分钟后刷新"
    }
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
                RoundedRectangle(cornerRadius: 14)
                    .fill(tint.opacity(pointer == nil || !enabled ? 0 : 0.055))
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
