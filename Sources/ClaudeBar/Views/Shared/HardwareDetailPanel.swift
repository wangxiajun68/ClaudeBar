import SwiftUI
import Darwin
import Metal

/// Machine identity is immutable for this process; never launch a profiler from a view body.
enum HardwareIdentity {
    static let gpuName = MTLCreateSystemDefaultDevice()?.name ?? "GPU"
    static let name: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        return String(cString: buffer)
    }()
    static var shortName: String { name.replacingOccurrences(of: "Apple ", with: "") }
}

struct HardwareSiliconMark: View {
    var gpu = false
    var load: Double
    var tint: Color
    /// The mark's per-unit reading, straight from the sampler: one cell per
    /// logical core, or one per GPU sub-unit. The mark is the same drawing
    /// everywhere it appears, so the breakdown is handed in rather than looked
    /// up — a caller with only a single number still draws the single die.
    var cells: [Double] = []
    /// The size the tile gives the mark. Passed in so the popover's hero copy and
    /// the tile's copy are the *same drawing at the same proportions* — the
    /// drawing fills whatever box it is handed on its own 120×92 grid.
    var markHeight: CGFloat = 76
    var body: some View {
        VStack(spacing: 3) {
            HardwareIllustration(kind: gpu ? .gpu : .cpu, load: load, tint: tint, cells: cells)
                .frame(height: markHeight)
            Text(gpu ? HardwareIdentity.gpuName.replacingOccurrences(of: "Apple ", with: "") : HardwareIdentity.shortName).font(.system(size: 11, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 2)
        .accessibilityLabel("\(gpu ? HardwareIdentity.gpuName : HardwareIdentity.name) · \(gpu ? "GPU" : "CPU") 总负载 \(Int(min(1, max(0, load.isFinite ? load : 0)) * 100))%")
    }
}

struct LoadHistoryChart: View {
    let values: [Double]
    let tint: Color
    var body: some View {
        VStack(spacing: 6) {
            Canvas { context, size in
                for step in 0...4 {
                    let y = size.height * CGFloat(step) / 4
                    var grid = Path(); grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(grid, with: .color(Theme.hairline), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                    context.draw(Text("\(100 - step * 25)").font(.system(size: 9)).foregroundColor(Theme.textSecondary), at: CGPoint(x: 2, y: y + 6), anchor: .leading)
                }
                guard values.count > 1 else { return }
                var line = Path()
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: 28 + (size.width - 28) * CGFloat(index) / CGFloat(values.count - 1),
                                        y: size.height * (1 - CGFloat(min(1, max(0, value)))))
                    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 28, y: size.height)); area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.28), tint.opacity(0.015)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }.frame(height: 140)
            HStack { Text("较早采样"); Spacer(); Text("当前 · %") }.font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
        }
        .accessibilityLabel("最近 \(values.count) 次采样，当前 \(Int((values.last ?? 0) * 100))%")
    }
}

struct HardwareDetailPanel: View {
    let gpu: Bool
    private let sampler = ProcessSampler.shared
    private var tint: Color { gpu ? Theme.chartBlue : Theme.chartGreen }

    /// What the mark is actually showing. The previous copy promised the
    /// opposite ("不代表单个核心的独立读数") of what the drawing now does, which
    /// is exactly the kind of caption that turns a measurement back into an
    /// ornament.
    private var caption: String {
        if gpu {
            let units = sampler.host.gpuRenderers.count
            return units > 0
                ? "每一格是一组图形子单元，按各自的实时占用点亮。"
                : "芯片亮度表示整体负载。"
        }
        let cores = sampler.host.coreLoad.count
        return cores > 0
            ? "每一个方块是一个逻辑核心（共 \(cores) 个），按各自的实时占用点亮。"
            : "芯片亮度表示整体负载。"
    }

    var body: some View {
        let load = gpu ? sampler.host.gpu : sampler.host.cpu
        let values = sampler.trail.map { gpu ? $0.gpu : $0.cpu }
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                HardwareSiliconMark(gpu: gpu, load: load / 100, tint: tint,
                                    cells: gpu ? sampler.host.gpuRenderers.map { $0 / 100 }
                                               : sampler.host.coreLoad,
                                    markHeight: 62)
                    .frame(width: 104)
                VStack(alignment: .leading, spacing: 4) {
                    Text(gpu ? HardwareIdentity.gpuName : HardwareIdentity.name).font(Theme.Font.chromeEmph)
                    Text(gpu ? "图形处理器 · 整体负载" : "\(sampler.host.coreCount) 个逻辑核心 · 整体负载").rollingNumber().font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    RollingNumberText(String(format: "%.1f%%", load)).font(Theme.Font.displayMetric).monospacedDigit()
                }
                Spacer()
            }
            LoadHistoryChart(values: values, tint: tint)
            HStack {
                Label(sampler.host.temperatureLabel(celsius: gpu ? sampler.host.gpuTemperatureCelsius : sampler.host.cpuTemperatureCelsius) ?? "温度暂无读数", systemImage: "thermometer.medium")
                Spacer()
                Text("峰值 \(Int((values.max() ?? 0) * 100))%").rollingNumber()
            }.font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            Text(caption)
                .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
        }.padding(22).frame(width: 420).background(Theme.cardSurface)
    }
}

/// The connection tile's popover.
///
/// **What a connection card's click should open**, decided here because the card
/// is four different claims in one tile (Wi-Fi, AirDrop, Ethernet, a headset) and
/// "show me more" has to mean one thing for all of them.
///
/// The previous version was five stacked blocks — a route diagram, an RSSI bar,
/// a proxy card, an accessory grid, a caption row — which is a *form*, and a form
/// is what you draw when the readings have nothing to say to each other. They do:
/// every one of them is either **this Mac**, the **name it goes by**, a **gate
/// this traffic passes through**, or a **device sitting on it**. So the panel is
/// one hub with four rings, and it opens on **one number** instead of a title.
///
/// 1. **The answer, not the title.** "连接" named the panel; it did not say what
///    the connection *is*. The hero is the link's own quality — 很强 · −46 dBm
///    when the Mac is on Wi-Fi, 已接入 when it is on Ethernet — and a second line
///    says which radio is carrying it. One glance, no reading.
/// 2. **Four rings, four state words.** MAC + IP + 两个 DNS 地址 in a mono column
///    said nothing to anyone who is not debugging, and said it four times. What a
///    person wants from "show me the connection" is *which way out, under what
///    name, through what door, with what attached*. Each ring is one of those, and
///    each carries a word in colour (蓝色是走的路、紫色是代理自己) rather than a
///    grey paragraph. The one exception is deliberate: a ring with **nothing
///    attached states why** ("未检测到耳机"), because an empty grid reads as a
///    loading state.
/// 3. **The door is the only live thing.** The 本机代理 ring is the one
///    connection in this machine the app itself owns, so it is the one ring with
///    an action in it; its 8pt dot fills and breathes white while the endpoint is
///    listening, which makes it worth keeping in the corner of an eye.
/// 4. **Export, then hand off.** 复制诊断 copies one buffer with the numbers the
///    rings now only summarise — that is where MAC, IP and the resolvers went — and
///    the two system steps stay one click away instead of being re-derived here.
///
/// Motion is **one** gesture, and it is hover state rather than a loop: the four
/// rings animate a shared rotation to `−3°` when the pointer enters the cluster,
/// so the assembly reads as one hinged panel being turned toward you. One shared
/// value rather than four staggered entrances is deliberate — it is the same
/// argument as the card's own hover, which was reworked from a per-frame shiver
/// into a single state change (`TileSurface.lift`). Reduce Motion pins the angle
/// at rest. The only thing that keeps moving on its own is the proxy ring's live
/// dot, which reports a real state (a listener that is up) and stops the moment it
/// is not.
struct ConnectionDetailPanel: View {
    private let sampler = ProcessSampler.shared
    private let audio = AudioAccessoryMonitor.shared
    @ObservedObject private var prefs = AppPreferences.shared
    /// Injected, not a singleton: this panel is presented from the 概览 strip,
    /// and the window already owns the one `CodexProviderStore` it hands to
    /// every page through the environment. Reaching for a `shared` here would
    /// mean the popup and the 设置 page could hold two stores describing one
    /// listener.
    @EnvironmentObject private var codexStore: CodexProviderStore
    @ObservedObject private var tests = ConnectivityTestCenter.shared
    @Environment(\.openURL) private var openURL

    /// Wide enough for the grid to stay a grid: two cards, a 10pt gutter and two
    /// 22pt margins inside 420 — the popover width the app's detail panels already
    /// use, so this and `HardwareDetailPanel` do not disagree.
    private let panelWidth: CGFloat = 420

    /// The gauge's slot. Stated once because `ring`'s frame, its own doc comment
    /// and the live dot's offset all assume it, and a slot that drifts from the
    /// drawing is how the old panel would have put a dot outside its ring.
    static let deviceGauge: CGFloat = 72

    /// `nil` for no link at all, `.some(nil)` for a link with no grade to name
    /// (Ethernet, or Wi-Fi that has not published an RSSI yet).
    private var linkGrade: String? {
        let host = sampler.host
        guard host.wiredOn || (host.wifiOn && host.wifiRSSI < 0) else { return nil }
        return WiFiBars.label(for: host.wifiRSSI)
    }

    private var heroValue: String {
        let host = sampler.host
        if host.wiredOn, host.wifiOn, host.wifiRSSI < 0 { return "\(linkGrade ?? "已接入") · 以太网" }
        if host.wiredOn { return "已接入" }
        if host.wifiOn, host.wifiRSSI < 0 { return linkGrade ?? "—" }
        return linkStateWord
    }

    private var heroUnit: String {
        let host = sampler.host
        if host.wiredOn, !host.wifiName.isEmpty { return "以太网 \(host.wifiName)" }
        if host.wiredOn { return "以太网" }
        if !host.wifiName.isEmpty { return host.wifiName }
        if host.wifiOn { return "Wi-Fi 已开启" }
        if host.bluetoothOn { return "仅蓝牙" }
        return "没有网络出口"
    }

    /// −100…−40 is the band macOS itself treats as usable, and the same range the
    /// tile's grade comes from, so the tick and the word cannot disagree.
    private var linkPosition: Double? {
        let host = sampler.host
        guard host.wifiOn, host.wifiRSSI < 0, !host.wiredOn else { return nil }
        return min(1, max(0, Double(host.wifiRSSI + 100) / 60))
    }

    /// The one sentence the whole panel is about: which way this Mac is going out.
    private var linkStateWord: String {
        let host = sampler.host
        if host.wifiOn { return "Wi-Fi 已开启" }
        if host.bluetoothOn { return "仅蓝牙" }
        return "离线"
    }

    var body: some View {
        let host = sampler.host
        VStack(alignment: .leading, spacing: 18) {
            // No "连接" heading. The hero is the answer, and a panel that has to
            // name itself above its own reading is a panel with nothing to say.
            hero(host)
            rings(host)
            tools(host)
        }
        .padding(22)
        .frame(width: panelWidth)
        .background(Theme.cardSurface)
    }

    // MARK: Hero

    @State private var clusterHovered = false
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The one-shot flag behind the copy acknowledgement. See `tools`.
    private struct Track: Identifiable { var id: String { "copied" } }

    private func hero(_ host: ProcessSampler.HostStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(heroValue)
                    .font(Theme.Font.displayHero)
                    .foregroundColor(linkGrade != nil ? Theme.Ink.success : Theme.textPrimary)
                Text(heroUnit)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            // A hairline scale with one tick on it, not a bar against a track: the
            // tick *is* the reading, and a bar that fills would be read as a ratio,
            // which RSSI is not. On Ethernet (or a radio with no figure yet) the
            // track is empty and the words carry it alone.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.hairline)
                        .frame(height: 2)
                    if let position = linkPosition {
                        Capsule()
                            .fill(Theme.chartBlue)
                            .frame(width: max(3, proxy.size.width * CGFloat(position)), height: 2)
                        Capsule()
                            .fill(Theme.chartBlue)
                            .frame(width: 4, height: 12)
                            .offset(x: proxy.size.width * CGFloat(position) - 2)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 12)
            HStack(spacing: 6) {
                Image(systemName: host.wiredOn ? "cable.connector" : (host.wifiOn ? "wifi" : "wifi.slash"))
                    .font(.system(size: 10, weight: .medium))
                Text(trendNote(host))
                    .rollingNumber()
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(Theme.Font.caption)
            .foregroundColor(Theme.textSecondary)
        }
    }

    /// The figure tells you what it is *about*, so nobody has to guess that −46
    /// is a signal and not a temperature. Silent while the grade is already the
    /// answer.
    private func trendNote(_ host: ProcessSampler.HostStats) -> String {
        if host.wiredOn { return "以太网已接入" }
        if host.wifiOn, host.wifiRSSI < 0 { return "-100 弱 / -40 强（dBm）" }
        if host.wifiOn { return "Wi-Fi 已开启，暂无信号读数" }
        return "没有可用的网络出口"
    }

    // MARK: Rings

    /// Four rings, two columns by two.
    ///
    /// A `LazyVGrid` over a **fixed** column count, so four rings fill all four
    /// cells and the fourth never leaves a hole — the thing that made the old
    /// accessory grid look broken. Two columns rather than three: a 72pt gauge in
    /// a card is wider than it is tall, three columns squeezed the card to 120pt,
    /// and that both cropped the longest note ("未检测到耳机") and spent 284pt of
    /// glyph inside a 376pt field. Two columns give the card 176pt, the note a
    /// line it can use, and the gauge air enough to be the object it is.
    private func rings(_ host: ProcessSampler.HostStats) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                  spacing: 10) {
            ring(kind: .uplink,
                 title: host.wiredOn ? "以太网" : "Wi-Fi",
                 value: host.wiredOn ? "已接入"
                       : (host.wifiName.isEmpty ? (host.wifiOn ? "已开启" : "未开启") : host.wifiName),
                 note: host.wiredOn ? "外接网口" : "无线电",
                 level: linkPosition ?? (host.wiredOn ? 1 : nil),
                 active: host.wiredOn || host.wifiOn)
            ring(kind: .proxy,
                 title: "本机代理",
                 value: codexStore.proxyRunning ? "监听中" : "未监听",
                 note: "127.0.0.1:\(prefs.codexProxyPort)",
                 active: codexStore.proxyRunning)
            ring(kind: .airdrop,
                 title: "隔空投送",
                 value: "打开",
                 note: "Finder 近场",
                 active: true)
            ring(kind: .bluetooth,
                 title: "蓝牙",
                 value: host.bluetoothOn ? "已开启" : "未开启",
                 note: audio.accessories.isEmpty
                       ? "未检测到耳机"
                       : "\(audio.accessories.count) 个设备",
                 active: host.bluetoothOn)
        }
        // One deskew for the whole assembly, not four staggered entrances: the
        // rings are a hinged panel, and a panel turns as one piece.
        .rotationEffect(clusterAngle)
        .animation(reduceMotion ? nil : Theme.Motion.state, value: clusterHovered)
        .hoverState($clusterHovered)
    }

    private var clusterAngle: Angle {
        // Planar and single-axis on purpose: a two-axis `depthTilt` at a card's
        // 2.2° is a *card* being picked up, and this cluster is already four cards
        // in a grid, so `-3` about one axis reads as the panel turning rather than
        // as four tiles shivering.
        reduceMotion ? .degrees(0) : (clusterHovered ? .degrees(-3) : .degrees(0))
    }

    /// Not `private`: `ConnectionRing` below draws one, and the drawing *is* the
    /// only thing that differs between the four rings.
    enum RingKind { case uplink, proxy, airdrop, bluetooth }

    /// One instrument: a `deviceGauge`-tall gauge, a title, a **word**, and a note. The word
    /// is the reading's shape — a state is named, not implied — and the gauge is the
    /// same state drawn: filled at the tick for the uplink, lit for the live ones,
    /// dim for the rest. A ring that is off is drawn off, never merely smaller.
    private func ring(kind: RingKind, title: String, value: String, note: String,
                      level: Double? = nil, active: Bool) -> some View {
        let tint = ringTint(kind)
        return Button {
            switch kind {
            case .uplink:
                NotificationCenter.default.post(.showMainWindow(page: .traffic))
            case .proxy:
                tests.testProxy(port: prefs.codexProxyPort, running: codexStore.proxyRunning)
            case .airdrop:
                let app = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
                _ = NSWorkspace.shared.open(app)
            case .bluetooth:
                NotificationCenter.default.post(.showMainWindow(page: .settings))
            }
        } label: {
            VStack(spacing: 6) {
                ConnectionRing(kind: kind, level: level, tint: tint, active: active)
                    .frame(width: Self.deviceGauge, height: Self.deviceGauge)
                Text(title)
                    .font(Theme.Font.chromeEmph)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(value)
                    .rollingNumber()
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(active ? tint : Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(note)
                    .rollingNumber()
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help(ringHelp(kind, title: title, value: value, note: note))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(value)，\(note)")
    }

    /// Colour says which kind of thing the ring is: 蓝色是这一跳走的路（无线电 /
    /// 代理 / 近场），紫色是挂在蓝牙上的那台设备。The old panel tinted Sky and
    /// Earth links by direction (blue / purple) with nothing to justify either.
    private func ringTint(_ kind: RingKind) -> Color {
        switch kind {
        case .uplink: return Theme.chartBlue
        case .proxy: return Theme.chartPurple
        case .airdrop: return Theme.chartBlue
        case .bluetooth: return Theme.chartPurple
        }
    }

    private func ringHelp(_ kind: RingKind, title: String, value: String, note: String) -> String {
        switch kind {
        case .uplink: return "\(title) \(value) · 打开流量页看路由与吞吐"
        case .proxy: return "本地代理 \(note) · 点一下检测"
        case .airdrop: return "打开隔空投送，查看接收范围与附近设备"
        case .bluetooth: return "蓝牙 \(value) · \(note) · 打开设置看更多"
        }
    }

    // MARK: Tools

    /// The numbers the rings only summarise, in one copyable buffer, plus the two
    /// system steps this app will not re-derive. Rationale lives in the tooltips.
    ///
    /// The copy *answers*, for the same reason the popup's action bar toasts a
    /// refresh: a control whose whole job is invisible has to say it happened, and
    /// re-opening a popover to find out whether the clipboard changed is not a
    /// thing anyone does. `Track` is `nil` until the first copy — a local type, not
    /// another `VpnStatus`-shaped import, because a derived build's type identity
    /// cannot be relied on.
    private func tools(_ host: ProcessSampler.HostStats) -> some View {
        let track = copied ? Track() : nil
        return HStack(spacing: 12) {
            Button {
                copyDiagnostics(host)
            } label: {
                Label("复制诊断", systemImage: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .font(Theme.Font.caption)
            .foregroundColor(Theme.Ink.claude)
            .help("复制一份可粘贴的文本：出口、信号、代理端点与蓝牙设备")
            .popover(item: .constant(track)) { _ in
                Text("已复制连接诊断")
                    .font(Theme.Font.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            Spacer(minLength: 8)
            Button("流量明细") {
                NotificationCenter.default.post(.showMainWindow(page: .traffic))
            }
            .buttonStyle(.plain)
            .font(Theme.Font.caption)
            .foregroundColor(Theme.Ink.claude)
            .help("吞吐与路由明细")
            Button("打开网络设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
                    openURL(url)
                }
            }
            .buttonStyle(.plain)
            .font(Theme.Font.caption)
            .foregroundColor(Theme.textSecondary)
            .help("macOS 的接口列表")
        }
    }

    /// MAC, the proxy endpoint and the resolvers used to be four grey lines of the
    /// panel. They are not gone, they are *filed*: the one string that opens
    /// straight into an issue report or a chat.
    private func copyDiagnostics(_ host: ProcessSampler.HostStats) {
        var lines: [String] = ["ClaudeBar 连接诊断"]
        lines.append(host.wiredOn ? "出口：以太网" : "出口：\(host.wifiOn ? "Wi-Fi" : "无")")
        if !host.wifiName.isEmpty { lines.append("网络名：\(host.wifiName)") }
        if host.wifiOn, host.wifiRSSI < 0 {
            lines.append("信号：\(host.wifiRSSI) dBm \(WiFiBars.label(for: host.wifiRSSI) ?? "")")
        }
        lines.append("本机代理：\(codexStore.proxyRunning ? "监听中" : "未监听") · \(LocalProxyAddress.openaiRoot)")
        if audio.accessories.isEmpty {
            lines.append("蓝牙设备：无")
        } else {
            for accessory in audio.accessories {
                lines.append("蓝牙设备：\(accessory.name) \(accessoryValue(accessory, count: audio.accessories.count))")
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
    }
}

/// One ring gauge. Three kinds, three *different* drawings, because four
/// concentric arcs in four colours were read as four instances of one meter — and
/// the kind of door is exactly what differs between them.
///
/// * `.uplink` — an RSSI arc over a radio-wave interior, with the number's own
///   fraction filled in. The only ring that measures anything.
/// * `.proxy` — a full loop with a travelling bod, i.e. traffic going round: the
///   one endpoint here that is a *process*, so it is the one that moves.
/// * `.airdrop` — three broadcast arcs out of a receiver, the same drawing the
///   tile uses, at ring scale.
/// * `.bluetooth` — a radio mast with two lobes, the mark Bluetooth itself is
///   drawn from. The count of what is attached is a *word* under the ring rather
///   than pips on it: at 72pt a third pip would be 4pt of ink, i.e. countable in
///   the literal sense and unreadable in every other.
private struct ConnectionRing: View {
    var kind: ConnectionDetailPanel.RingKind
    var level: Double?
    var tint: Color
    var active: Bool
    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The 8pt dot that says "this endpoint is up". Filled and breathing white
    /// only while the proxy is actually listening — the one thing on the panel
    /// worth keeping in the corner of an eye.
    private var live: Bool { active && !reduceMotion }

    var body: some View {
        ZStack {
            Circle()
                .stroke(active ? tint.opacity(0.22) : Theme.hairline, lineWidth: 2)
            track
            core
            if kind == .proxy {
                Circle()
                    .fill(active ? Color.white : Theme.textTertiary(0.4))
                    .frame(width: 8, height: 8)
                    .opacity(live ? (phase.truncatingRemainder(dividingBy: 1) > 0.5 ? 1 : 0.45) : 1)
                    // Rides the gauge's own rim, so it cannot drift off it.
                    .offset(y: -ConnectionDetailPanel.deviceGauge / 2 + 10)
            }
        }
        .onAppear { if kind == .proxy, live { tick() } }
        .onDisappear { phase = 0 }
        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: phase)
    }

    /// The lit part of the ring: the uplink's own fraction, or a travelling arc
    /// for the one ring that stands for a running process. The other two have no
    /// ring to light — their state is the word under them — so they draw nothing
    /// here rather than a second decoration that says the same thing.
    @ViewBuilder private var track: some View {
        switch kind {
        case .uplink:
            if let level {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, level)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        case .proxy:
            Circle()
                .trim(from: 0, to: 0.34)
                .stroke(active ? tint.opacity(0.85) : Theme.textTertiary(0.3),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(Double(phase) * 360))
        case .airdrop, .bluetooth:
            EmptyView()
        }
    }

    /// Driven by the same 12-per-second cadence the old ES8 arrival-listener used
    /// (`setInterval(…, 1000 / 12)`), not by a `TimelineView`: the page already runs
    /// one clock, and a second one per ring is the kind of doubled work this file's
    /// header rules out.
    private func tick() {
        guard live else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { _ in
            Task { @MainActor in
                phase += 1.0 / 40.0
                if phase > 1 { phase -= 1 }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    @ViewBuilder private var core: some View {
        let ink = active ? tint : Theme.textSecondary.opacity(0.7)
        switch kind {
        case .uplink:
            WifiRingCore(tint: ink)
                .frame(width: 30, height: 30)
        case .proxy:
            ProxyRingCore(tint: ink)
                .frame(width: 26, height: 26)
        case .airdrop:
            AirDropCore(tint: ink)
                .frame(width: 30, height: 30)
        case .bluetooth:
            BluetoothRingCore(tint: ink)
                .frame(width: 28, height: 28)
        }
    }
}

private struct WifiRingCore: View {
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            context.translateBy(x: (size.width - 24 * scale) / 2, y: (size.height - 24 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            for (radius, alpha) in [(CGFloat(5), 0.45), (9, 0.75), (13, 1.0)] as [(CGFloat, Double)] {
                var arc = Path()
                arc.addArc(center: CGPoint(x: 12, y: 18), radius: radius,
                           startAngle: .degrees(-140), endAngle: .degrees(-40), clockwise: false)
                context.stroke(arc, with: .color(tint.opacity(alpha)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            context.fill(Path(ellipseIn: CGRect(x: 10, y: 17, width: 4, height: 4)), with: .color(tint))
        }
        .accessibilityHidden(true)
    }
}

private struct ProxyRingCore: View {
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            context.translateBy(x: (size.width - 24 * scale) / 2, y: (size.height - 24 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            // A rack unit: two slots and a bus, i.e. a service with a port.
            var slots = Path()
            slots.addRoundedRect(in: CGRect(x: 3, y: 8, width: 18, height: 5), cornerSize: CGSize(width: 1.5, height: 1.5))
            slots.addRoundedRect(in: CGRect(x: 3, y: 15, width: 18, height: 5), cornerSize: CGSize(width: 1.5, height: 1.5))
            context.stroke(slots, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: 5.2, y: 9.8, width: 1.8, height: 1.8)), with: .color(tint))
            context.fill(Path(ellipseIn: CGRect(x: 5.2, y: 16.8, width: 1.8, height: 1.8)), with: .color(tint))
            var bus = Path()
            bus.move(to: CGPoint(x: 9, y: 20.5)); bus.addLine(to: CGPoint(x: 15, y: 20.5))
            context.stroke(bus, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct AirDropCore: View {
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            context.translateBy(x: (size.width - 24 * scale) / 2, y: (size.height - 24 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            for radius in [CGFloat(4), 7, 10] {
                var arc = Path()
                arc.addArc(center: CGPoint(x: 12, y: 11), radius: radius,
                           startAngle: .degrees(135), endAngle: .degrees(405), clockwise: false)
                context.stroke(arc, with: .color(tint), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            }
            var receiver = Path()
            receiver.move(to: CGPoint(x: 12, y: 12))
            receiver.addLine(to: CGPoint(x: 7.5, y: 22))
            receiver.addQuadCurve(to: CGPoint(x: 16.5, y: 22), control: CGPoint(x: 12, y: 24))
            receiver.closeSubpath()
            context.fill(receiver, with: .color(tint))
        }
        .accessibilityHidden(true)
    }
}

private struct BluetoothRingCore: View {
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            context.translateBy(x: (size.width - 24 * scale) / 2, y: (size.height - 24 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            // The mast: a vertical spine with two lobes, and the two link lines
            // that meet it. Drawn from the mark's own geometry, not a font glyph.
            var mast = Path()
            mast.move(to: CGPoint(x: 12, y: 2.5))
            mast.addLine(to: CGPoint(x: 12, y: 21.5))
            mast.move(to: CGPoint(x: 12, y: 2.5))
            mast.addLine(to: CGPoint(x: 19, y: 7.5))
            mast.addLine(to: CGPoint(x: 6, y: 15))
            mast.move(to: CGPoint(x: 12, y: 21.5))
            mast.addLine(to: CGPoint(x: 19, y: 16.5))
            mast.addLine(to: CGPoint(x: 6, y: 9))
            context.stroke(mast, with: .color(tint),
                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: 10.6, y: 1.1, width: 2.8, height: 2.8)), with: .color(tint))
        }
        .accessibilityHidden(true)
    }
}

struct CapacityHardwareMark: View {
    var disk: Bool
    var load: Double
    var bytes: UInt64
    var tint: Color
    /// The mark's own reading, one entry per area. Empty falls back to the single
    /// `load` figure, which is what a caller without the breakdown gets.
    var wells: [Double] = []
    /// The size the tile gives the mark, so the byte label stays inside the slot.
    var markHeight: CGFloat = 76
    var body: some View {
        VStack(spacing: 0) {
            // Two different Lucide icons for two different things: 内存 is the
            // DIMM (`memory-stick`), 硬盘 the drive bay (`hard-drive`). Sharing
            // one drawing made the disk read as a second stick of memory, which
            // is the one thing a hardware mark must not do.
            HardwareIllustration(kind: disk ? .disk : .memory, load: load, tint: tint,
                                 wells: wells)
                .frame(height: markHeight - 12)
            Text(ProcessSampler.Snapshot(memoryBytes: bytes).memoryLabel)
                .rollingNumber()
                .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(Theme.textSecondary)
        }
        .accessibilityLabel("\(disk ? "硬盘" : "内存")容量 \(ProcessSampler.Snapshot(memoryBytes: bytes).memoryLabel)")
    }
}
