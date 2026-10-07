import Foundation
import Darwin

struct CLITerminal {
    var width: Int
    var height: Int
    var color: Bool
    var ascii: Bool
    var plain: Bool

    static func current(_ options: CLIOptions) -> Self {
        var size = winsize()
        let tty = isatty(STDOUT_FILENO) != 0
        let measured = tty && ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0
        let env = ProcessInfo.processInfo.environment
        return .init(width: measured && size.ws_col > 0 ? Int(size.ws_col) : 100,
            height: measured && size.ws_row > 0 ? Int(size.ws_row) : 40,
            color: tty && !options.noColor && env["NO_COLOR"] == nil && env["TERM"] != "dumb",
            ascii: options.ascii || env["TERM"] == "dumb", plain: options.plain)
    }

    /// Untrusted session names must never inject OSC, cursor moves or new rows.
    static func clean(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
                && ![0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].contains($0.value)
        })).replacingOccurrences(of: "\t", with: " ")
    }

    static func cells(_ value: String) -> Int {
        value.reduce(0) { total, character in
            let widths = character.unicodeScalars.map { max(0, Int(wcwidth(wchar_t($0.value)))) }
            // A joined emoji is one glyph; flags consist of two narrow regional indicators.
            let width = character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation })
                ? max(2, widths.max() ?? 0) : (widths.max() ?? 0)
            return total + width
        }
    }

    static func fit(_ text: String, _ width: Int, pad: Bool = true) -> String {
        let safe = clean(text)
        let width = max(0, width)
        var result = "", used = 0
        let clipped = cells(safe) > width
        let budget = clipped ? max(0, width - 1) : width
        for character in safe {
            let count = cells(String(character))
            guard used + count <= budget else { break }
            result.append(character); used += count
        }
        if clipped && width > 0 { result += "~"; used += 1 }
        if pad && used < width { result += String(repeating: " ", count: width - used) }
        return result
    }

    func paint(_ text: String, _ code: String = "38;5;46") -> String {
        color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    func heading(_ title: String, _ code: String = "38;5;117") -> String {
        let line = "\(ascii ? "+" : "┌") \(title) "
        return paint(Self.fit(line + String(repeating: ascii ? "-" : "─", count: max(0, width - Self.cells(line))), width, pad: false), code)
    }

    func bar(_ label: String, percent: Double?, detail: String = "") -> String {
        let value = percent.flatMap { $0.isFinite ? max(0, min(100, $0)) : nil }
        let number = value.map { String(format: "%5.1f%%", $0) } ?? "   N/A"
        let size = max(4, min(24, width - 30 - Self.cells(detail)))
        let filled = value.map { Int($0 / 100 * Double(size)) } ?? 0
        let graph = String(repeating: ascii ? "#" : "█", count: filled)
            + String(repeating: ascii ? "." : "░", count: size - filled)
        let palette = ["CPU": "38;5;75", "GPU": "38;5;177", "MEM": "38;5;116", "DISK": "38;5;215", "YEAR": "38;5;221"]
        let code = (value ?? 0) >= 90 && label != "YEAR" ? "38;5;203" : (palette[label] ?? "38;5;82")
        return Self.fit(label, 7) + " " + paint(String(graph.prefix(filled)), code) + paint(String(graph.dropFirst(filled)), "38;5;238") + " " + number + (detail.isEmpty ? "" : "  " + Self.fit(detail, max(0, width - size - 17), pad: false))
    }

    func table(headers: [String], rows: [[String]], weights: [Int]) -> [String] {
        guard !rows.isEmpty else { return [paint("  NO RECORDS", "38;5;244")] }
        if width < 64 {
            return rows.flatMap { row in
                [paint(Self.fit(row.first ?? "", width, pad: false))]
                    + zip(headers.dropFirst(), row.dropFirst()).map { Self.fit("  \($0): \($1)", width, pad: false) }
            }
        }
        let room = width - (headers.count - 1) * 2
        let total = weights.reduce(0, +)
        var widths = weights.map { max(1, room * $0 / total) }
        widths[widths.count - 1] += room - widths.reduce(0, +)
        func row(_ values: [String]) -> String {
            zip(values, widths).map { value, width in
                let code: String? = ["BUSY": "38;5;82", "WAITING": "38;5;221", "IDLE": "38;5;244", "CLAUDE": "38;5;215", "CODEX": "38;5;117", "CURSOR": "38;5;183"][value.uppercased()]
                let text = Self.fit(value, width)
                return code.map { paint(text, $0) } ?? text
            }.joined(separator: "  ")
        }
        return [paint(row(headers), "1;38;5;110")]
            + rows.map(row)
    }

    static func bytes(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "N/A" }
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var number = bytes, index = 0
        while number >= 1024 && index < units.count - 1 { number /= 1024; index += 1 }
        return String(format: index == 0 ? "%.0f %@" : "%.1f %@", number, units[index])
    }

    static func number(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1000 { return String(format: "%.1fK", Double(value) / 1000) }
        return String(value)
    }
}

struct CLIFrame {
    var snapshot: CLISnapshot?
    var snapshotError: String?
    var running: Bool
    var archived: Bool
    var system: CLISystem?
    var capturedAt = Date()
    var snapshotProcessMatches = true

    var age: Double? { snapshot.map { max(0, capturedAt.timeIntervalSince($0.updatedAt)) } }
    var freshness: String {
        guard let snapshot else { return "unavailable" }
        if snapshot.updatedAt.timeIntervalSince(capturedAt) > 5 { return "invalid-clock" }
        if archived { return "archived" }
        return running && snapshotProcessMatches && (age ?? .infinity) <= 15 ? "fresh" : "stale"
    }
}

struct CLIRenderer {
    var terminal: CLITerminal
    var options: CLIOptions

    func weatherLines(_ frame: CLIFrame, detailed: Bool) -> [String] {
        let t = terminal
        guard let w = frame.snapshot?.weather else {
            return [t.paint(CLITerminal.fit(frame.snapshot?.weatherLoading == true ? "WEATHER  FETCHING..." : "WEATHER  N/A · use weather refresh", t.width, pad: false), "38;5;244")]
        }
        let stale = frame.capturedAt.timeIntervalSince(w.fetchedAt ?? w.observedAt) > 900
        let temperature = String(format: "%.0f", w.temperatureC)
        var rows = ["\(w.place) · \(w.condition) · \(temperature)°C" + (stale ? " · STALE" : ""),
                    String(format: "Feels %.0f° · H %.0f° / L %.0f° · rain %d%%", w.feelsLikeC, w.highC, w.lowC, w.rainChance)]
        if detailed {
            rows += [String(format: "HUMIDITY %d%% · WIND %@ %.1f km/h", w.humidity, w.windDirection, w.windKph),
                     "SUNRISE \(w.sunrise) · SUNSET \(w.sunset) · \(w.timezone)",
                     "OBSERVED " + ISO8601DateFormatter().string(from: w.observedAt) + " · " + w.source]
            if let note = frame.snapshot?.weatherNote { rows.append(note) }
        }
        if frame.snapshot?.weatherLoading == true { rows.append("UPDATING · showing last observation") }
        return rows.map { t.paint(CLITerminal.fit($0, t.width, pad: false), "38;5;221") }
    }

    func hero(_ frame: CLIFrame, lifestyle: CLILifestyle) -> [String] {
        let t = terminal
        var rows = [t.paint(CLITerminal.fit("GOOD " + lifestyle.word + "  /  FOLLOW THE SIGNAL", t.width, pad: false), "38;5;244")]
        let banner = lifestyle.banner(t)
        if t.width >= 100 {
            let leftWidth = lifestyle.word.count * 6 + 3
            var right = [t.paint(CLITerminal.fit(lifestyle.format("yyyy.MM.dd  EEEE"), t.width - leftWidth, pad: false), "1;38;5;221"),
                         t.paint(CLITerminal.fit(lifestyle.format("HH:mm:ss") + "  " + lifestyle.zone.identifier, t.width - leftWidth, pad: false), "38;5;117")]
            var rightTerminal = t; rightTerminal.width = t.width - leftWidth
            let sidebar = CLIRenderer(terminal: rightTerminal, options: options)
            right += sidebar.weatherLines(frame, detailed: false)
            right.append(t.paint(CLITerminal.fit("DAY \(lifestyle.dayOfYear) / \(lifestyle.daysInYear) · \(Int(lifestyle.yearPercent))% OF YEAR", rightTerminal.width, pad: false), "38;5;244"))
            for (index, line) in banner.enumerated() {
                rows.append(line + String(repeating: " ", count: leftWidth - (lifestyle.word.count * 6 - 1)) + (index < right.count ? right[index] : ""))
            }
        } else {
            rows += banner
            rows.append(t.paint(CLITerminal.fit(lifestyle.summary, t.width, pad: false), "38;5;221"))
            rows += weatherLines(frame, detailed: false)
        }
        rows.append(t.paint(CLITerminal.fit(frame.snapshot?.greeting ?? lifestyle.greeting, t.width, pad: false), "38;5;183"))
        return rows
    }

    func render(_ frame: CLIFrame) -> String {
        if options.command == "count" || options.count {
            return frame.snapshot.map { String(options.sessions(in: $0).count) } ?? "N/A"
        }
        let t = terminal
        var lines: [String] = []
        let command = options.command
        let lifestyle = CLILifestyle(date: frame.capturedAt)
        let overview = ["status", "dashboard"].contains(command)
        if !t.plain {
            lines += [t.paint(CLITerminal.fit("M T X  /  CLAUDEBAR     SYSTEM OBSERVATORY   [\(BuildChannel.name.uppercased())]", t.width, pad: false), "1;38;5;117")]
        }
        if overview || command == "greet" {
            if !t.plain && !options.compact && (t.height >= 35 || !options.watch || command == "greet") {
                lines += hero(frame, lifestyle: lifestyle)
            } else {
                lines.append(t.paint(CLITerminal.fit(frame.snapshot?.greeting ?? lifestyle.greeting, t.width, pad: false), "1;38;5;183"))
                lines.append(t.paint(CLITerminal.fit(lifestyle.summary, t.width, pad: false), "38;5;221"))
                lines.append(contentsOf: weatherLines(frame, detailed: false))
            }
        }
        let local = ["system", "cpu", "gpu", "memory", "disk", "battery", "network", "uptime", "date", "calendar", "greet", "commands"].contains(command)
        if !local {
            lines.append(t.paint(CLITerminal.fit("APP \(frame.running ? "ONLINE" : "OFFLINE")  |  DATA \(frame.freshness.uppercased())"
                + (frame.age.map { "  \(Int($0))s ago" } ?? ""), t.width, pad: false), frame.freshness == "fresh" ? "38;5;82" : "38;5;214"))
            if let error = frame.snapshotError { lines.append(CLITerminal.fit("\(error) · use \(BuildChannel.cliShortExecutable) start", t.width, pad: false)) }
        }
        if command == "date" || command == "calendar" {
            lines.append(t.heading("LOCAL CLOCK / CALENDAR", "38;5;221"))
            lines.append(lifestyle.summary)
            lines.append("UTC " + ISO8601DateFormatter().string(from: frame.capturedAt))
            lines.append("WEEK \(lifestyle.calendar.component(.weekOfYear, from: frame.capturedAt)) · DAY \(lifestyle.dayOfYear)/\(lifestyle.daysInYear)")
            lines.append(t.bar("YEAR", percent: lifestyle.yearPercent))
            if command == "calendar" { lines += lifestyle.month(t) }
        }
        if command == "weather" {
            lines.append(t.heading("WEATHER / CACHED OBSERVATION", "38;5;221"))
            lines += weatherLines(frame, detailed: true)
            if let weather = frame.snapshot?.weather, !weather.forecast.isEmpty {
                lines += t.table(headers: ["DATE", "LOW / HIGH", "RAIN"], rows: weather.forecast.map { day in
                    var localDay = CLILifestyle(date: day.date)
                    if let zone = TimeZone(identifier: weather.timezone) { localDay.calendar.timeZone = zone }
                    return [localDay.format("MM-dd EEE"), String(format: "%.0f / %.0f C", day.lowC, day.highC), day.rainChance.map { "\($0)%" } ?? "N/A"]
                }, weights: [40, 35, 25])
            }
        }
        if command == "alerts" {
            lines.append(t.heading("ATTENTION / HEALTH SIGNALS", "38;5;215"))
            let alerts = CLIAlert.collect(frame)
            lines += alerts.isEmpty ? [t.paint("All available readings within thresholds", "38;5;82")] : alerts.map {
                t.paint(CLITerminal.fit("[\($0.level.uppercased())] \($0.message)", t.width, pad: false), $0.level == "warning" ? "38;5;203" : "38;5;221")
            }
        }
        if command == "commands" {
            lines.append(t.heading("COMMAND DIRECTORY"))
            lines += t.table(headers: ["AREA", "COMMANDS"], rows: [
                ["Observatory", "status dashboard watch alerts"], ["Local machine", "system cpu gpu memory disk battery network uptime"],
                ["Your day", "greet date calendar weather [refresh]"], ["Agents", "sessions count agents usage models quota providers"],
                ["Services", "vpn proxy connectors config"], ["Application", "start stop open refresh paths doctor"],
                ["Shell", "completion version help"]], weights: [22, 78])
        }
        if let host = frame.system, command != "alerts" {
            lines.append(t.heading("MACHINE / LOCAL TELEMETRY"))
            lines.append(CLITerminal.fit("\(host.hostname) · \(host.chip) · \(host.cores) cores", t.width, pad: false))
            lines.append(CLITerminal.fit("\(host.os) · uptime \(Int(host.uptimeSeconds / 3600))h \(Int(host.uptimeSeconds / 60) % 60)m", t.width, pad: false))
            if overview || ["system", "cpu"].contains(command) { lines.append(t.bar("CPU", percent: host.cpuPercent, detail: "load " + host.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " "))) }
            if overview || ["system", "gpu"].contains(command) { lines.append(t.bar("GPU", percent: host.gpuPercent)) }
            if overview || ["system", "memory"].contains(command) { lines.append(t.bar("MEM", percent: host.memoryUsedBytes.map { Double($0) / Double(host.memoryTotalBytes) * 100 },
                               detail: CLITerminal.bytes(host.memoryUsedBytes.map { Double($0) }) + " / " + CLITerminal.bytes(Double(host.memoryTotalBytes)))) }
            let diskPercent = host.diskTotalBytes.flatMap { total in host.diskAvailableBytes.map { total > 0 ? (1 - Double($0) / Double(total)) * 100 : 0 } }
            if overview || ["system", "disk"].contains(command) { lines.append(t.bar("DISK", percent: diskPercent, detail: CLITerminal.bytes(host.diskAvailableBytes.map { Double($0) }) + " free")) }
            if overview || ["system", "network"].contains(command) { lines.append(t.paint(CLITerminal.fit("NET  DOWN \(CLITerminal.bytes(host.networkDownBytesPerSecond))/s  UP \(CLITerminal.bytes(host.networkUpBytesPerSecond))/s", t.width, pad: false), "38;5;117")) }
            if overview || ["system", "battery"].contains(command) { lines.append(t.paint(CLITerminal.fit("POWER  " + (host.batteryPercent.map { "\($0)% · \(host.batteryCharging == true ? "charging" : "not charging") · \(host.externalPower == true ? "AC" : "battery")" } ?? "No battery / N/A"), t.width, pad: false), "38;5;215")) }
        }
        if let snapshot = frame.snapshot {
            if command == "agents" {
                lines.append(t.heading("AGENT FLEET"))
                lines += t.table(headers: ["AGENT", "MAIN", "BUSY", "WAITING", "IDLE", "HELPERS"], rows: ["claude", "codex", "cursor"].map { agent in
                    let all = snapshot.sessions.filter { $0.agent == agent }
                    let main = all.filter { !$0.isSubagent }
                    return [agent.uppercased(), String(main.count), String(main.filter { $0.status == "busy" }.count), String(main.filter { $0.status == "waiting" }.count), String(main.filter { $0.status == "idle" }.count), String(all.filter(\.isSubagent).count)]
                }, weights: [25, 15, 15, 15, 15, 15])
            }
            if ["status", "dashboard", "sessions"].contains(command) {
                let rows = options.sessions(in: snapshot)
                let counts = Dictionary(grouping: rows, by: \.status).mapValues(\.count)
                lines.append(t.heading("AGENT SESSIONS", "38;5;183"))
                lines.append(CLITerminal.fit("TOTAL \(rows.count)   BUSY \(counts["busy"] ?? 0)   WAITING \(counts["waiting"] ?? 0)   IDLE \(counts["idle"] ?? 0)", t.width, pad: false))
                let defaultLimit = command == "sessions" ? rows.count : max(1, min(6, t.height - (options.compact || t.height < 35 ? 26 : 33)))
                let visible = Array(rows.prefix(options.limit ?? defaultLimit))
                lines += t.table(headers: ["AGENT / ID", "STATE", "CTX", "PROJECT", "MODEL / ACTIVITY"], rows: visible.map { s in
                    [s.agent.uppercased() + "/" + (s.pid.map(String.init) ?? String(s.id.prefix(8))) + (s.isSubagent ? "*" : ""),
                     s.status.uppercased(), s.contextPercent.map { String(format: "%.0f%%", $0) } ?? "N/A", s.project,
                     [s.model, s.activity].filter { !$0.isEmpty }.joined(separator: " · ")]
                }, weights: [18, 10, 6, 25, 35])
                if visible.count < rows.count { lines.append("  +\(rows.count - visible.count) more · use sessions or --limit") }
                if command == "sessions" { lines.append("* sub-agent; default counts contain main sessions only") }
            }
            if ["status", "dashboard", "usage", "models"].contains(command) {
                lines.append(t.heading("TOKEN TELEMETRY", "38;5;215"))
                lines.append(CLITerminal.fit("TODAY \(CLITerminal.number(snapshot.usage.todayTokens)) tokens / \(snapshot.usage.todayCalls) calls   PERIOD [\(snapshot.usage.period)] \(CLITerminal.number(snapshot.usage.tokens))" + (snapshot.usage.loading ? " · LOADING" : ""), t.width, pad: false))
                if overview {
                    let leaders = snapshot.usage.models.sorted { $0.tokens > $1.tokens }.prefix(2)
                    if !leaders.isEmpty { lines.append(t.paint(CLITerminal.fit("TOP MODELS  " + leaders.map { "\($0.model) \(CLITerminal.number($0.tokens))" }.joined(separator: "  /  "), t.width, pad: false), "38;5;215")) }
                }
                if command == "usage" || command == "models" {
                    lines += t.table(headers: ["MODEL", "TOKENS"], rows: snapshot.usage.models.sorted { $0.tokens > $1.tokens }.map { [$0.model, String($0.tokens)] }, weights: [70, 30])
                }
            }
            if ["status", "dashboard"].contains(command) {
                lines.append(t.heading("SERVICES", "38;5;82"))
                if !snapshot.quota.isEmpty { lines.append(CLITerminal.fit("QUOTA  " + snapshot.quota.map { String(format: "%@ %.0f%% used", $0.label, $0.usedPercent) }.joined(separator: "  /  "), t.width, pad: false)) }
                lines.append(CLITerminal.fit("VPN \(snapshot.vpn.state) · \(snapshot.vpn.node ?? "no node")   PROXY \(snapshot.proxy.running ? "ON" : "OFF") :\(snapshot.proxy.port)", t.width, pad: false))
                lines.append(CLITerminal.fit("PROVIDERS \(snapshot.providers.count)   CONNECTORS \(snapshot.connectorsScanned ? String(snapshot.connectors.count) : "NOT SCANNED")   CHARGE \(snapshot.charge.mode)", t.width, pad: false))
            }
            if command == "providers" {
                lines.append(t.heading("PROVIDERS / NO CREDENTIALS"))
                lines += t.table(headers: ["AGENT", "NAME", "ACTIVE", "MODEL"], rows: snapshot.providers.map { [$0.agent, $0.name, $0.active ? "YES" : "-", $0.model] }, weights: [15, 40, 10, 35])
            }
            if command == "quota" {
                lines.append(t.heading("CODEX ACCOUNT QUOTA"))
                if snapshot.quota.isEmpty { lines.append(snapshot.quotaLoading ? "LOADING" : "N/A · no account reading available") }
                for quota in snapshot.quota {
                    lines.append(t.bar(quota.label, percent: quota.usedPercent, detail: "used"))
                    if let reset = quota.resetsAt { lines.append("  reset " + ISO8601DateFormatter().string(from: reset)) }
                }
            }
            if command == "vpn" || command == "config" {
                lines.append(t.heading("VPN"))
                lines += ["STATE \(snapshot.vpn.state) · enabled \(snapshot.vpn.enabled)",
                          "NODE \(snapshot.vpn.node ?? "N/A") · core \(snapshot.vpn.coreVersion ?? "N/A")",
                          "PORT \(snapshot.vpn.mixedPort) · system proxy \(snapshot.vpn.systemProxy) · TUN \(snapshot.vpn.tun)"].map { CLITerminal.fit($0, t.width, pad: false) }
            }
            if command == "proxy" || command == "config" {
                lines.append(t.heading("LOCAL LLM PROXY"))
                lines.append("\(snapshot.proxy.running ? "RUNNING" : "STOPPED") · 127.0.0.1:\(snapshot.proxy.port)")
            }
            if command == "connectors" {
                lines.append(t.heading("CONNECTOR INVENTORY"))
                if !snapshot.connectorsScanned { lines.append("NOT SCANNED · use refresh to read the inventory") }
                if snapshot.connectorsLoading { lines.append("SCANNING") }
                lines += t.table(headers: ["NAME", "KIND", "PLATFORM", "ENABLED"], rows: snapshot.connectors.map {
                    [$0.name, $0.kind, $0.platforms.joined(separator: ","), $0.enabled.map { $0 ? "YES" : "NO" } ?? "N/A"]
                }, weights: [45, 15, 25, 15])
            }
            if command == "config" {
                lines.append(t.heading("BUILD / CHARGE POLICY"))
                lines += ["CHANNEL \(BuildChannel.name) · system integration \(BuildChannel.allowsSystemIntegration)",
                          "CHARGE \(snapshot.charge.mode) · limit \(snapshot.charge.limit)% · \(snapshot.charge.status)"].map { CLITerminal.fit($0, t.width, pad: false) }
            }
        }
        if overview && !t.plain { lines.append(t.paint(CLITerminal.fit("\(BuildChannel.cliShortExecutable) commands · weather · agents · alerts · Ctrl-C exits watch", t.width, pad: false), "38;5;244")) }
        if options.watch { lines.append(t.paint("LIVE · \(options.interval)s · Ctrl-C to disconnect", "38;5;244")) }
        return lines.map { line in
            // Uncolored service fields are also untrusted; colored rows were already fitted.
            line.contains("\u{1B}[") ? line : CLITerminal.fit(line, t.width, pad: false)
        }.joined(separator: "\n")
    }
}
