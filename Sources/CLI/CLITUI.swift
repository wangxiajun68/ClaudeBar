import Foundation

enum CLITUIEvent: Equatable {
    case text(String), paste(String), up, down, left, right, pageUp, pageDown, home, end, enter, tab, backspace, escape
    case mouse(Int, Int, Int, Bool)
}

/// Incremental UTF-8 / CSI decoder. Escape sequences can arrive across multiple reads.
struct CLITUIInput {
    private var bytes: [UInt8] = []
    private var paste = false
    mutating func feed(_ data: [UInt8], flushEscape: Bool = false) -> [CLITUIEvent] {
        bytes += data
        var events: [CLITUIEvent] = []
        while !bytes.isEmpty {
            if bytes.starts(with: [27, 91, 50, 48, 48, 126]) { bytes.removeFirst(6); paste = true; continue }
            if bytes.starts(with: [27, 91, 50, 48, 49, 126]) { bytes.removeFirst(6); paste = false; continue }
            // A terminal that ignores SGR mode may still emit legacy X10 reports.
            // Consume the whole report so coordinates never turn into keyboard shortcuts.
            if bytes.starts(with: [27, 91, 77]) {
                guard bytes.count >= 6 else { if flushEscape { bytes.removeAll() }; break }
                let code = Int(bytes[3]) - 32, x = Int(bytes[4]) - 32, y = Int(bytes[5]) - 32
                bytes.removeFirst(6)
                if !paste && code >= 0 && x > 0 && y > 0 { events.append(.mouse(code, x, y, code & 3 == 3)) }
                continue
            }
            if bytes[0] == 27 {
                if bytes.count == 1 {
                    if flushEscape { bytes.removeFirst(); events.append(.escape) }
                    break
                }
                guard bytes[1] == 91 || bytes[1] == 79 else {
                    bytes.removeFirst(); if !paste { events.append(.escape) }; continue
                }
                guard let finish = bytes.indices.dropFirst(2).first(where: { (64...126).contains(bytes[$0]) }) else {
                    if bytes.count > 128 || flushEscape { bytes.removeAll() }
                    break
                }
                let sequence = String(decoding: bytes[2...finish], as: UTF8.self)
                bytes.removeFirst(finish + 1)
                if paste { continue }
                let keys: [String: CLITUIEvent] = ["A": .up, "B": .down, "C": .right, "D": .left,
                    "H": .home, "F": .end, "1~": .home, "4~": .end, "7~": .home, "8~": .end,
                    "5~": .pageUp, "6~": .pageDown, "Z": .tab]
                if let key = keys[sequence] { events.append(key) }
                else if sequence.hasPrefix("<"), sequence.last == "M" || sequence.last == "m" {
                    let parts = sequence.dropFirst().dropLast().split(separator: ";").compactMap { Int($0) }
                    if parts.count == 3 { events.append(.mouse(parts[0], parts[1], parts[2], sequence.last == "m")) }
                }
                continue
            }
            let first = bytes[0]
            if first < 32 || first == 127 {
                bytes.removeFirst()
                if paste {
                    if [9, 10, 13].contains(first) { events.append(.paste(" ")) }; continue
                }
                switch first {
                case 9: events.append(.tab)
                case 10, 13: events.append(.enter)
                case 8, 127: events.append(.backspace)
                default: break
                }
                continue
            }
            if first >= 128 && (first < 194 || first > 244) { bytes.removeFirst(); continue }
            let length = first < 128 ? 1 : first < 224 ? 2 : first < 240 ? 3 : 4
            guard bytes.count >= length else { break }
            let text = String(bytes: bytes.prefix(length), encoding: .utf8)
            bytes.removeFirst(text == nil ? 1 : length)
            if let text { events.append(paste ? .paste(text) : .text(text)) }
        }
        return events
    }
}

struct CLITUIRow {
    var id: String
    var text: String
    var detail: [String] = []
}

struct CLITUIViewport {
    var selected: String?
    var top: String?
    var offset = 0
    var query = ""

    mutating func reconcile(_ rows: [CLITUIRow], height: Int) {
        if let top, let index = rows.firstIndex(where: { $0.id == top }) { offset = index }
        offset = min(max(0, offset), max(0, rows.count - max(1, height)))
        if selected == nil || !rows.contains(where: { $0.id == selected }) { selected = rows.indices.contains(offset) ? rows[offset].id : nil }
        top = rows.indices.contains(offset) ? rows[offset].id : nil
    }

    mutating func move(_ delta: Int, rows: [CLITUIRow], height: Int) {
        guard !rows.isEmpty else { return }
        let index = min(rows.count - 1, max(0, (rows.firstIndex { $0.id == selected } ?? offset) + delta))
        selected = rows[index].id
        if index < offset { offset = index }
        if index >= offset + height { offset = index - max(1, height) + 1 }
        top = rows[min(offset, rows.count - 1)].id
    }

    mutating func scroll(_ delta: Int, rows: [CLITUIRow], height: Int) {
        offset = min(max(0, rows.count - max(1, height)), max(0, offset + delta))
        top = rows.indices.contains(offset) ? rows[offset].id : nil
    }
}

struct CLITUIState {
    static let pages = ["dashboard", "sessions", "models", "vpn", "connectors", "system", "usage"]
    var page: String
    var viewports: [String: CLITUIViewport] = [:]
    var frame: CLIFrame?
    var paused = false
    var mouse = true
    var editing: String? // "/" search, ":" control command
    var draft = ""
    var modal: [String]?
    var modalOffset = 0
    var notice = "Ready · ? help · : commands"
    private(set) var catalogs: [String: [CLITUIRow]] = [:]
    private(set) var history: [Double] = []
    private var frozenHistory: [Double] = []

    init(command: String) { page = command == "status" ? "dashboard" : command }

    mutating func receive(_ newFrame: CLIFrame) {
        if let cpu = newFrame.system?.cpuPercent, cpu.isFinite {
            history.append(max(0, min(100, cpu)))
            if history.count > 60 { history.removeFirst(history.count - 60) }
        }
        if !paused { frame = newFrame }
    }

    mutating func togglePause(latest: CLIFrame?) {
        paused.toggle()
        if paused { frozenHistory = history }
        else { frame = latest }
    }

    func sparkline(ascii: Bool) -> String {
        let glyphs = Array(ascii ? ".:-=+*#@" : "▁▂▃▄▅▆▇█")
        return String((paused ? frozenHistory : history).suffix(24).map { glyphs[min(7, Int($0 / 100 * 7))] })
    }

    /// Catalogs are credential-free RPC results, fetched once on request rather than each tick.
    mutating func receiveCatalog(_ reply: CLIControl.Response) -> Bool {
        guard reply.ok, let json = reply.result,
              let body = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return false }
        func value(_ item: [String: Any], _ key: String) -> String {
            guard let value = item[key], !(value is NSNull) else { return "N/A" }
            return CLITerminal.clean(String(describing: value))
        }
        var entries: [CLITUIRow] = [], target: String
        if let providers = body["providers"] as? [[String: Any]] {
            target = "models"
            for p in providers {
                let id = value(p, "id"), agent = value(p, "agent")
                entries.append(.init(id: "provider:" + agent + ":" + id,
                    text: "\(value(p, "name")) · \(agent) · active \(value(p, "active"))",
                    detail: ["PROVIDER / \(value(p, "name"))", "ID: \(id)", "Agent: \(agent)", "Active: \(value(p, "active"))", ":pv u '\(id)' -a \(agent)"]))
                for m in p["models"] as? [[String: Any]] ?? [] {
                    let model = value(m, "id")
                    entries.append(.init(id: "model:\(agent):\(id):\(model)", text: "  \(value(m, "name")) · active \(value(m, "active"))",
                        detail: ["MODEL / \(value(m, "name"))", "ID: \(model)", "Provider: \(id)", "Agent: \(agent)", ":md u '\(model)' -a \(agent) --provider '\(id)'"]))
                }
            }
        } else if let connectors = body["connectors"] as? [[String: Any]] {
            target = "connectors"
            entries = connectors.map { c in
                let id = value(c, "id")
                return .init(id: "connector:" + id, text: "\(value(c, "name")) · \(value(c, "kind")) · enabled \(value(c, "enabled"))",
                    detail: ["CONNECTOR / \(value(c, "name"))", "ID: \(id)", "Kind: \(value(c, "kind"))", "Enabled: \(value(c, "enabled"))",
                        "Controllable: \(value(c, "controllable"))", "Removable: \(value(c, "removable"))", ":cn on '\(id)'", ":cn off '\(id)'"])
            }
        } else if let nodes = body["nodes"] as? [[String: Any]] {
            target = "vpn"
            entries = nodes.map { n in
                .init(id: "node:" + value(n, "name"), text: "NODE \(value(n, "name")) · selected \(value(n, "selected")) · \(value(n, "delayMs")) ms",
                    detail: ["NODE / \(value(n, "name"))", "Source: \(value(body, "source"))", "Selected: \(value(n, "selected"))", "Latency: \(value(n, "delayMs")) ms",
                        "Select: :vpn s '<node>' --group '<group>'", "Test: :vpn t '<node>'"])
            }
            entries += (body["groups"] as? [[String: Any]] ?? []).map { g in
                .init(id: "group:" + value(g, "name"), text: "GROUP \(value(g, "name")) · selected \(value(g, "selected"))",
                    detail: ["GROUP / \(value(g, "name"))", "Type: \(value(g, "type"))", "Selected: \(value(g, "selected"))"] + (g["nodes"] as? [String] ?? []))
            }
        } else { return false }
        let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"
        entries.insert(.init(id: "catalog-time", text: "CATALOG · read \(clock.string(from: Date())) · r reload · Enter details / IDs"), at: 0)
        catalogs[target] = entries; page = target
        return true
    }

    func rows(options: CLIOptions, terminal: CLITerminal) -> [CLITUIRow] {
        guard let frame else { return [.init(id: "loading", text: "Connecting to local telemetry…")] }
        let snapshot = frame.snapshot
        var result: [CLITUIRow]
        switch page {
        case "sessions":
            let sessions = snapshot.map { options.sessions(in: $0) } ?? []
            result = Array(sessions.prefix(options.limit ?? sessions.count)).map { s in
                .init(id: s.agent + ":" + s.id,
                    text: "\(s.agent.uppercased())/\(s.pid.map(String.init) ?? String(s.id.prefix(8)))  \(s.status.uppercased())  \(s.contextPercent.map { String(format: "%.0f%%", $0) } ?? "N/A")  \(s.project)  \(s.model) · \(s.activity)",
                    detail: ["SESSION \(s.id)", "Agent: \(s.agent) · PID: \(s.pid.map(String.init) ?? "N/A")",
                        "State: \(s.status) · Model: \(s.model)", "Project: \(s.project)", "Activity: \(s.activity)",
                        "Context: \(s.contextTokens.map(String.init) ?? "N/A") / \(s.contextLimit.map(String.init) ?? "N/A")",
                        "Subagent: \(s.isSubagent) · Parent: \(s.parentID ?? "N/A")"])
            }
        case "models":
            var occurrences: [String: Int] = [:]
            result = (snapshot?.providers ?? []).filter { options.agent == nil || $0.agent == options.agent }.map { p in
                let key = "provider:\(p.agent):\(p.name)"
                let ordinal = occurrences[key, default: 0]; occurrences[key] = ordinal + 1
                return .init(id: "\(key):\(ordinal)", text: "\(p.active ? (terminal.ascii ? "*" : "●") : (terminal.ascii ? "-" : "○")) \(p.agent.uppercased())  \(p.name)  \(p.model)",
                    detail: ["PROVIDER / \(p.name)", "Agent: \(p.agent)", "Active: \(p.active)", "Model: \(p.model)",
                        "Use :pv cat -a \(p.agent) to fetch provider / model IDs.", "Switch: :pv u <ID> -a \(p.agent)", "Model: :md u <model-ID> -a \(p.agent) --provider <ID>"])
            }
            result += (snapshot?.usage.models ?? []).sorted { $0.tokens > $1.tokens }.map {
                .init(id: "model:" + $0.model, text: "TOKENS  \($0.model)  \(CLITerminal.number($0.tokens))",
                      detail: ["MODEL / \($0.model)", "Period tokens: \($0.tokens)"])
            }
        case "connectors":
            var occurrences: [String: Int] = [:]
            result = (snapshot?.connectors ?? []).map { c in
                let key = "\(c.kind):\(c.name):\(c.platforms.sorted().joined(separator: ","))"
                let ordinal = occurrences[key, default: 0]; occurrences[key] = ordinal + 1
                return .init(id: "\(key):\(ordinal)", text: "\(c.enabled.map { $0 ? "ON " : "OFF" } ?? "N/A")  \(c.name)  \(c.kind)  \(c.platforms.joined(separator: ", "))",
                    detail: ["CONNECTOR / \(c.name)", "Kind: \(c.kind)", "Platforms: \(c.platforms.joined(separator: ", "))",
                        "Enabled: \(c.enabled.map(String.init) ?? "N/A")", "Inventory / IDs: :cn ls", "Enable: :cn on <ID>", "Disable: :cn off <ID>"])
            }
        default:
            var focused = options; focused.command = page; focused.watch = false
            focused.argument = nil; focused.arguments = []
            result = CLIRenderer(terminal: terminal, options: focused).render(frame).components(separatedBy: "\n").enumerated().map {
                .init(id: "line:\($0.offset)", text: $0.element)
            }
            if page == "vpn" {
                result += ["", ":vpn pv · preview nodes/groups (read-only)", ":vpn on / off · start / stop", ":vpn s <node> --group <group> · select", ":vpn t <node> · test latency"].enumerated().map { .init(id: "hint:\($0.offset)", text: $0.element) }
            }
        }
        if let catalog = catalogs[page] { result = page == "vpn" ? result + catalog : catalog }
        if result.isEmpty { result = [.init(id: "empty", text: snapshot == nil ? frame.snapshotError ?? "No application data" : "No records")] }
        let query = viewports[page]?.query ?? ""
        if !query.isEmpty { result = result.filter { Self.plain($0.text).localizedCaseInsensitiveContains(query) } }
        return result
    }

    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    static func wrap(_ text: String, width: Int) -> [String] {
        let safe = CLITerminal.clean(text), width = max(1, width)
        var result: [String] = [], line = "", used = 0
        for character in safe {
            let cells = CLITerminal.cells(String(character))
            if used + cells > width && !line.isEmpty { result.append(line); line = ""; used = 0 }
            line.append(character); used += cells
        }
        result.append(line); return result
    }

    static func bodyTerminal(_ terminal: CLITerminal) -> CLITerminal {
        var body = terminal; body.width = max(1, terminal.width - 3); return body
    }

    /// Clip trusted SGR only, preserving whole grapheme clusters at the right edge.
    static func clip(_ text: String, width: Int) -> String {
        var result = "", used = 0, index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\u{1B}", let end = text[index...].firstIndex(of: "m") {
                let escape = String(text[index...end])
                if escape.range(of: "^\u{1B}\\[[0-9;]*m$", options: .regularExpression) != nil {
                    result += escape; index = text.index(after: end); continue
                }
            }
            let char = text[index], cells = CLITerminal.cells(String(char))
            if used + cells > width { break }
            // Other controls, including OSC/cursor escapes, never pass through.
            result += CLITerminal.clean(String(char)); used += cells; index = text.index(after: index)
        }
        return result + "\u{1B}[0m"
    }

    mutating func screen(options: CLIOptions, terminal t: CLITerminal) -> [String] {
        let width = max(1, t.width - 1) // Never write the wrap column; terminals differ on delayed wrapping.
        let height = max(1, t.height)
        let bodyHeight = max(1, height - 7)
        let rows = rows(options: options, terminal: Self.bodyTerminal(t))
        var viewport = viewports[page] ?? .init()
        viewport.reconcile(rows, height: bodyHeight); viewports[page] = viewport
        let f = frame
        let summary = "\(paused ? "PAUSED" : "LIVE") · \(options.interval)s · \(f?.freshness.uppercased() ?? "LOADING") · \(f?.running == true ? "APP ONLINE" : "APP OFFLINE") · \(f?.snapshot?.runMode ?? "desktop")" + (f?.age.map { " · age \(Int(max(0, $0)))s" } ?? "")
        let date = f?.capturedAt ?? Date()
        let clock = DateFormatter(); clock.dateFormat = "yyyy-MM-dd EEE HH:mm:ss"
        let weather = f?.snapshot?.weather.map { "\($0.place) \(Int($0.temperatureC.rounded()))°C \($0.condition)" } ?? "Weather N/A"
        var lines = [t.paint("MTX // MATRIX CONTROL [\(BuildChannel.name.uppercased())]", "1;38;5;82") + "  " + t.paint(summary, "38;5;117"),
            t.paint(CLITerminal.clean("\(f?.snapshot?.greeting ?? CLILifestyle(date: date).greeting) · \(clock.string(from: date)) · \(weather)"), "38;5;221"),
            Self.pages.enumerated().map { i, name in t.paint("\(i + 1) \(name)", name == page ? "1;38;5;16;48;5;117" : "38;5;244") }.joined(separator: "  "),
            t.heading("\(page == "sessions" ? "AGENT SESSIONS" : page.uppercased()) · \(rows.count) rows" + (viewport.query.isEmpty ? "" : " · /\(viewport.query)"), "38;5;183")]
        if let modal {
            let wrapped = modal.flatMap { Self.wrap($0, width: width) }
            modalOffset = min(max(0, modalOffset), max(0, wrapped.count - bodyHeight))
            lines += Array(wrapped.dropFirst(modalOffset).prefix(bodyHeight))
        } else {
            lines += rows.dropFirst(viewport.offset).prefix(bodyHeight).map { row in
                let marker = row.id == viewport.selected ? "> " : "  "
                let body = row.detail.isEmpty ? row.text : CLITerminal.clean(row.text)
                return t.paint(marker, "38;5;82") + body
            }
        }
        while lines.count < 4 + bodyHeight { lines.append("") }
        let range = rows.isEmpty ? "0/0" : "\(viewport.offset + 1)-\(min(rows.count, viewport.offset + bodyHeight))/\(rows.count)"
        lines += [t.paint("CPU " + sparkline(ascii: t.ascii) + "  " + range + " · mouse \(mouse ? "ON" : "OFF") · \(CLITerminal.clean(notice))", "38;5;110"),
            editing.map { Self.prompt($0, draft: draft, width: width) } ?? "↑↓/jk scroll · Tab/1–7 pages · / search · Enter details · Space pause · r reload · m mouse · : command · ? help · q quit",
            t.paint(modal == nil ? "Ctrl-C disconnects · m OFF lets the terminal select/copy text" : "DETAIL / RESULT · ↑↓ scroll · Esc/Enter close", "38;5;244")]
        // Tiny terminals still keep an exit hint visible.
        if height < 8 { lines = [lines[0]] + Array(lines.suffix(max(0, height - 1))) }
        return Array(lines.prefix(height)).map { Self.clip($0, width: width) }
    }

    static let help = ["MTX INTERACTIVE TERMINAL", "", "1–7 / Tab / ←→  switch pages (scroll/search retained per page)",
        "↑↓ / j k           select & scroll", "PgUp / PgDn / g G  page / first / last", "Mouse wheel        scroll; left click selects; m toggles mouse for copying",
        "/                  search this page; Enter apply; Esc cancel", "Enter              selected record details; Esc closes", "Space              freeze the view; backend and sampling continue",
        "r                  read model/VPN/connector catalog; otherwise resample local data",
        ":                  command prompt (existing aliases and quoted names supported)",
        ":pv cat -a claude   list provider/model IDs", ":md u <model-ID> -a claude --provider <provider-ID>",
        ":vpn pv            preview nodes/groups", ":vpn s 'node name' --group 'group name'", ":cn ls             connector inventory & IDs",
        ":cn on <ID> / :cn off <ID>", ":mo p / :mo d       performance / desktop mode", "",
        "Commands run once through the existing private control socket.", "Only control commands are accepted; watch never repeats writes.",
        "Archived --snapshot views cannot issue control commands.", "q / Ctrl-C          restore terminal and disconnect"]

    static func prompt(_ prefix: String, draft: String, width: Int) -> String {
        var tail = "", used = 2
        for char in CLITerminal.clean(draft).reversed() {
            let cells = CLITerminal.cells(String(char))
            if used + cells > max(2, width) { break }
            tail.insert(char, at: tail.startIndex); used += cells
        }
        return prefix + tail + "_"
    }

    /// Command prompt is an argv parser, never a shell. No interpolation or command substitution.
    static func arguments(_ text: String) throws -> [String] {
        var words: [String] = [], word = "", quote: Character?, escaped = false, started = false
        for char in text {
            if escaped { word.append(char); escaped = false; started = true; continue }
            if char == "\\", quote != "'" { escaped = true; started = true; continue }
            if let open = quote {
                if char == open { quote = nil } else { word.append(char) }; continue
            }
            if char == "'" || char == "\"" { quote = char; started = true }
            else if char.isWhitespace { if started { words.append(word); word = ""; started = false } }
            else { word.append(char); started = true }
        }
        guard quote == nil, !escaped else { throw CLIError("Unclosed quote or trailing escape") }
        if started { words.append(word) }; return words
    }
}

/// Diff whole lines rather than clearing the screen every tick. No terminal capability guessing.
struct CLITUIDiff {
    private var previous: [String] = []
    private var width = 0
    mutating func reset() { previous = []; width = 0 }
    mutating func draw(_ lines: [String], width: Int) -> String {
        let resized = self.width != width || previous.count != lines.count
        var result = resized ? "\u{1B}[2J" : ""
        for (index, line) in lines.enumerated() where resized || previous[index] != line {
            result += "\u{1B}[\(index + 1);1H\u{1B}[0m\u{1B}[2K" + line
        }
        previous = lines; self.width = width
        return result
    }
}
