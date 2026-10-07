import SwiftUI

/// Network, power and accessory status, with a connection-details popover.
struct LinkCard: View {
    @State private var showConnections = false
    var host: ProcessSampler.HostStats
    var accessory: AudioAccessoryMonitor.Accessory?
    var accessoryCount: Int
    var unavailableReason: String?
    /// `dense` tightens the vertical gaps for the popup's denser track. Its
    /// only caller is the dashboard's `ResourceStrip`, which passes `false`;
    /// the popup's machine readout is `MachineKpiStrip`, not this card — so the
    /// compact spacing this describes is currently unreachable.
    var dense: Bool
    /// Which interface the card's mark draws. Defaults to 以太网 so an existing
    /// call site is unchanged; `ResourceStrip` passes the interface actually in
    /// use, which is what made this mark a *reading of the connection* rather
    /// than a second copy of the Wi-Fi glyph already in the header badge.
    var interface: ConnectInterface = .ethernet

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    // The hero, in the same slot and the same type as the five
                    // meters beside it: the card's *figure* is the connected
                    // network's name, because that is the one thing this card is
                    // about that a number cannot say. See the `heroTint` note in
                    // `ResourceStrip.meter`; the shared hero font is
                    // `Theme.Font.displayMetric` — a name is not a metric, so it
                    // takes the same rounded weight at the same size rather than
                    // the metric font's digits.
                    RollingNumberText(status.title, rolls: false)
                        .font(Theme.Font.displayMetric)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .truncationMode(.middle)
                    // Two lines, left to wrap, exactly like the meters' caption
                    // band — the grade and the dBm are this card's reading, and
                    // splitting them (grade on the hero's line, dBm below) is how
                    // the old layout spent its height to say one thing.
                    Text(caption)
                        .rollingNumber(caption)
                        .font(Theme.Font.tileLabel)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                        .allowsTightening(true)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
                Spacer(minLength: 4)
                // The mark slot — the same 176×130 the meters reserve, holding
                // the one drawing this card had been missing. The card used to
                // put its reading in a 30-tick ruler that stretched the full
                // width, leaving the right half of the tile empty and making it
                // the only card in the grid with nothing where every sibling
                // draws its mark.
                ConnectInterfaceMark(interface: interface,
                                     accessory: accessory,
                                     strength: signalFraction,
                                     state: markState)
                    .frame(width: ResourceStrip.markSlot.width, height: ResourceStrip.markSlot.height)
                    .clipped()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 168, maxHeight: .infinity, alignment: .topLeading)
        // The card speaks the same surface language as the five meters it sits
        // among: the tile's own wash, the white inner frame ring it implies, and
        // a hover edge in the same hue the header badge already carries. It used
        // to be the one *plain* tile on the strip (`hoverTile()` with no tint),
        // which read as a card from a different grid dropped into this one — the
        // wash is how a row of tiles scans, and this card was opting out of it.
        //
        // The hue is the badge's own blue (`Theme.chartBlue`, the Wi-Fi mark),
        // not a new colour: the card has no single reading to tint by, so it
        // tints by the instrument it is named for, exactly as every other tile
        // does. Its own marks keep their signal hues.
        .hoverTile(tint: Theme.chartBlue, dense: dense)
        .help(helpText())
        // The whole card opens the map, like every other tile on the strip —
        // only the title was clickable before, which made this the one card whose
        // obvious target did nothing. `contentShape` is what extends the hit area
        // over the gaps between the marks.
        .contentShape(Rectangle())
        .onTapGesture { showConnections = true }
        .accessibilityAction(named: "查看连接详情") { showConnections = true }
        .popover(isPresented: $showConnections) { ConnectionDetailPanel() }
    }

    private var status: ConnectionStatus { ConnectionStatus(host: host) }

    /// The grade-and-dBm line, or the reason there is none — the tile's version
    /// of the meters' caption band.
    private var caption: String {
        if let rssi = status.rssi {
            let grade = WiFiBars.label(for: rssi) + " · "
            return "\(grade)\(rssi) dBm"
        }
        return status.subtitle
    }

    /// 0…1 across the shared −100…−40 dBm ruler (`WiFiBars.fraction`), so the
    /// mark's lit cells and the popover's scale cannot disagree about one
    /// reading. `nil` (no reading) is 0 — an unattached radio lights nothing.
    private var signalFraction: Double {
        guard let rssi = status.rssi else { return 0 }
        return WiFiBars.fraction(for: rssi)
    }

    /// Whole-card state, as one value, so the mark is tinted from the same
    /// decision the header pill is: attached / on-but-not-attached / off.
    private var markState: ConnectMarkState {
        if status.attached { return .attached }
        return host.wifiOn ? .idle : .off
    }

    private var header: some View {
        HStack(spacing: 6) {
            // A plain badge, not a ringed one: the ring around a small glyph is
            // read as a spinner (see `ResourceStrip.meter`). Its size is stated
            // for the same reason the other five meters state it: unstated, this
            // badge alone took `InstrumentBadge`'s 24pt default and the header
            // glyphs on one strip came out two different sizes.
            InstrumentBadge(kind: .link, tint: Theme.chartBlue)
                .frame(width: 26, height: 26)
            Text("连接")
                .font(Theme.Font.chrome)
                .foregroundColor(Theme.textSecondary)
            Spacer(minLength: 4)
            StatusPill(label: linkState.0, tint: linkState.1)
            // The chevron the header used to carry is gone: at the family's own
            // density the meters state this with their trailing arrow, and the
            // card's whole body is the target, so a second "this opens" mark on
            // the title line was saying what the header already says.
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .accessibilityHidden(true)
        }
    }

    /// Whole-card state: is this Mac on a network at all? Independent of the
    /// headset, which is a mark with its own state.
    private var linkState: (String, Color) {
        if status.attached { return ("已接入", Theme.Ink.success) }
        if host.wifiOn { return ("Wi-Fi 已开启", Theme.textSecondary) }
        if host.bluetoothOn { return ("本机", Theme.textSecondary) }
        return ("离线", Theme.Ink.idle)
    }

    private func helpText() -> String {
        var lines: [String] = []
        lines.append(host.wifiOn ? "Wi-Fi 开" : "Wi-Fi 关")
        if !host.wifiName.isEmpty { lines.append(host.wifiName) }
        if host.wifiOn, host.wifiRSSI < 0 { lines.append("\(host.wifiRSSI) dBm \(WiFiBars.label(for: host.wifiRSSI))") }
        if host.wiredOn { lines.append("以太网 已接入") }
        if let accessory {
            // `accessoryValue` already ends with the connection word
            // (已连接 / 未连接 / 已离开) in every branch; appending
            // `connection.label` again printed it twice (finding 550).
            lines.append("\(accessory.name) \(accessoryValue(accessory, count: accessoryCount))")
        } else if let unavailableReason {
            lines.append(unavailableReason)
        }
        return lines.joined(separator: "  ·  ")
    }
}

/// Which interface the connection card's own mark draws.
///
/// Chosen once per card from the state, not by the reader: the mark's job is to
/// say *how this Mac is attached* — the one fact the header badge (always the
/// Wi-Fi glyph) and the title (a network name) between them cannot state, and the
/// reason this tile is "连接" and not "Wi-Fi". Ethernet wins when both are up,
/// because a wired link is what the machine is actually routed through.
enum ConnectInterface {
    case wifi
    case ethernet
    /// Wi-Fi is on but nothing is attached — the mark is an open arc, not a
    /// filled one, so "connected" is never drawn by a powered radio.
    case wifiDown
    case offline
}

/// The whole-card connection state, read by the mark's *tint* — one value so the
/// mark and the header pill cannot disagree.
enum ConnectMarkState {
    case attached
    case idle
    case off

    var tint: Color {
        switch self {
        case .attached: return Theme.chartBlue
        case .idle: return Theme.textSecondary
        case .off: return Theme.statusIdle
        }
    }
}

/// The connection tile's mark: the machine's own attachment, drawn as a filled
/// signal meter over the interface's Lucide outline.
///
/// This is the tile's *reading*, in the place every other card on the strip
/// draws one. It draws `ConnectionSignalScale`'s ruler in mark form — a cell
/// row over the same −100…−40 dBm fraction (`WiFiBars.fraction`), reduced to
/// the mark slot — rather than the full-width 30-cell row it replaced: a mark
/// that measures the signal belongs in the mark slot, and that row stretched
/// across the tile with nothing on its right.
///
/// It is also honest about which interface it is. Ethernet is a socket, Wi-Fi an
/// arc — the two are not the same object and a strip that drew only the Wi-Fi
/// glyph for both would be naming the radio where the question is the link.
struct ConnectInterfaceMark: View {
    var interface: ConnectInterface
    var accessory: AudioAccessoryMonitor.Accessory?
    /// 0…1, the signal reading. `nil`-free: no reading is 0.
    var strength: Double
    var state: ConnectMarkState

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: glyph)
                .font(.system(size: 46, weight: .medium))
                .foregroundColor(state.tint)
                .frame(width: 64, height: 52)
            SignalCellRow(strength: strength)
                .frame(height: 16)
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    /// The interface's own glyph — never the header badge's, which is always the
    /// Wi-Fi mark.
    private var glyph: String {
        switch interface {
        case .ethernet: return "cable.connector"
        case .wifi: return "wifi"
        case .wifiDown: return "wifi.slash"
        case .offline: return "wifi.slash"
        }
    }

    /// The mark's caption band, the same job the meters' captions do: the
    /// interface (when there is more than one thing to name) and the headset,
    /// which is the one other device this card is responsible for.
    private var label: String {
        var parts: [String] = []
        switch interface {
        case .ethernet: parts.append("以太网")
        case .wifi, .wifiDown: parts.append("Wi-Fi")
        case .offline: parts.append("未接入")
        }
        if let accessory, accessory.connection == .inUse {
            parts.append("\u{1F3A7}")  // headphones
        }
        return parts.joined(separator: " · ")
    }
}

/// Twelve equal cells across the −100…−40 dBm ruler (~5 dB per cell), filled
/// from the left: a filled cell is a step of signal, so the *count* is the
/// reading. Twelve, not the panel ruler's thirty — the mark is a *reduction*
/// of the same ruler to the mark slot's width, so the shared thing is the
/// fraction (`WiFiBars.fraction`; the panel keeps the same rule in
/// `ConnectionSignalScale.position`), not the number of cells.
///
/// Drawing it here (rather than reusing the wide view) is what keeps the mark
/// inside the 176×130 slot every sibling reserves; the shared things are the
/// fraction and the unfilled-cell ink (`ConnectionSignalScale.emptyCell`).
private struct SignalCellRow: View {
    var strength: Double

    private static let count = 12

    var body: some View {
        // No reading lights nothing: `strength` is 0 for an unattached radio, and
        // the `index / (count - 1)` formula would still light cell 0 at 0.0 (0/11
        // <= 0), i.e. draw one filled cell for "no signal". The floor is what
        // stops an offline card from claiming a bar's worth of signal.
        let lit = strength > 0.001 ? max(1, Int((strength * Double(Self.count - 1)).rounded()) + 1) : 0
        return HStack(spacing: 2) {
            ForEach(0..<Self.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index < lit ? Theme.chartBlue : ConnectionSignalScale.emptyCell)
                    .frame(maxWidth: .infinity)
                    .frame(height: 14)
            }
        }
    }
}

/// RSSI is represented by a textual grade beside the connection glyph.
/// The one place a Wi-Fi RSSI becomes words. Shared, not `private`, because the
/// connection panel names the same grade the tile does — two vocabularies for one
/// reading is how a tile and its popover end up disagreeing.
enum WiFiBars {
    /// 0…1 across the −100…−40 dBm ruler — the one place a reading becomes a
    /// position, so the tile's mark and the panel's ruler cannot put the same
    /// dBm at two lengths. Clamped at both ends: an RSSI outside the ruler pins
    /// to the nearest end instead of overflowing its view.
    static func fraction(for rssi: Int) -> Double {
        min(1, max(0, Double(rssi + 100) / 60))
    }

    /// The grade word for an RSSI reading. Non-optional: the switch is
    /// exhaustive over the Int range, so the three call sites' `??` fallbacks
    /// were unreachable (finding 553).
    static func label(for rssi: Int) -> String {
        switch rssi {
        case ..<(-75): return "弱"
        case ..<(-62): return "一般"
        case ..<(-50): return "好"
        default: return "很强"
        }
    }
}

/// Charge and connection are separate claims; both are stated when both are
/// true, so 充电中 is never read as 已连接. Shared by the card's help text, the
/// headset cell and `ConnectionDetailPanel` — the three must not describe one
/// headset differently.
func accessoryValue(_ accessory: AudioAccessoryMonitor.Accessory, count: Int) -> String {
    var parts: [String] = []
    if let left = accessory.left?.percent { parts.append("左 \(left)%") }
    if let right = accessory.right?.percent { parts.append("右 \(right)%") }
    if let level = accessory.caseLevel?.percent { parts.append("盒 \(level)%") }
    if parts.isEmpty, let combined = accessory.combined?.percent { parts.append("\(combined)%") }
    if count > 1 { parts.append("等 \(count) 台") }
    let level = parts.isEmpty ? "—" : parts.joined(separator: " ")
    switch accessory.connection {
    case .inUse: return accessory.isCharging == true ? "\(level) · 充电中" : "\(level) · 已连接"
    case .nearby: return accessory.isCharging == true ? "\(level) · 充电中" : "\(level) · 未连接"
    case .absent: return "\(level) · 已离开"
    }
}

/// Shared state vocabulary for the overview and its inspector. A powered radio
/// alone is not an association; Ethernet does not establish the default route.
struct ConnectionStatus {
    let host: ProcessSampler.HostStats
    var rssi: Int? { host.wifiOn && host.wifiRSSI < 0 ? host.wifiRSSI : nil }
    var wifiAttached: Bool { host.wifiOn && (!host.wifiName.isEmpty || rssi != nil) }
    var attached: Bool { host.wiredOn || wifiAttached }
    var symbol: String { host.wiredOn ? "cable.connector" : (wifiAttached ? "wifi" : "wifi.slash") }
    var title: String {
        if host.wiredOn { return wifiAttached ? "以太网 + Wi-Fi" : "以太网" }
        if wifiAttached { return host.wifiName.isEmpty ? "Wi-Fi 已接入" : host.wifiName }
        return host.wifiOn ? "Wi-Fi 等待连接" : "未接入网络"
    }
    var subtitle: String {
        if host.wiredOn { return wifiAttached ? "两个网络接口已接入" : "有线网络已接入" }
        if wifiAttached { return "无线网络已接入" }
        return host.wifiOn ? "无线已开启，尚无接入信息" : "Wi-Fi 已关闭"
    }
}
