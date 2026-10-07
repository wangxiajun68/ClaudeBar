import Foundation

/// Local calendar and greeting work even without a running application.
struct CLILifestyle {
    var date: Date
    var calendar = Calendar.current
    var zone: TimeZone { calendar.timeZone }
    var hour: Int { calendar.component(.hour, from: date) }
    var word: String {
        switch hour { case 5..<12: return "MORNING"; case 12..<18: return "AFTERNOON"; case 18..<23: return "EVENING"; default: return "NIGHT" }
    }
    var greeting: String {
        switch hour { case 5..<12: return "早上好，准备进入矩阵"; case 12..<18: return "下午好，保持专注，也记得休息"; case 18..<23: return "晚上好，欢迎回到矩阵"; default: return "夜深了，愿灵感与你同在" }
    }
    func format(_ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar; formatter.timeZone = zone; formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
    var summary: String { format("yyyy.MM.dd  EEEE  HH:mm:ss") + "  " + zone.identifier }
    var dayOfYear: Int { calendar.ordinality(of: .day, in: .year, for: date) ?? 1 }
    var daysInYear: Int { calendar.range(of: .day, in: .year, for: date)?.count ?? 365 }
    var yearPercent: Double { Double(dayOfYear - 1) / Double(daysInYear) * 100 }
    var info: [String: Any] {
        ["local": format("yyyy-MM-dd HH:mm:ss"), "timezone": zone.identifier,
         "utc": ISO8601DateFormatter().string(from: date), "epoch": date.timeIntervalSince1970,
         "week": calendar.component(.weekOfYear, from: date), "dayOfYear": dayOfYear,
         "daysInYear": daysInYear, "yearPercent": yearPercent, "greeting": greeting, "banner": word]
    }
    func month(_ terminal: CLITerminal) -> [String] {
        guard let range = calendar.range(of: .day, in: .month, for: date),
              let start = calendar.dateInterval(of: .month, for: date)?.start else { return [] }
        let today = calendar.component(.day, from: date)
        // Fixed Monday-first columns, independent of the person's locale.
        let offset = (calendar.component(.weekday, from: start) + 5) % 7
        var cells = Array(repeating: "    ", count: offset)
        cells += range.map { day in day == today ? String(format: "[%2d]", day) : String(format: " %2d ", day) }
        while cells.count % 7 != 0 { cells.append("    ") }
        var rows = [terminal.paint(format("yyyy年 M月"), "1;38;5;221"), terminal.paint(" Mo  Tu  We  Th  Fr  Sa  Su ", "38;5;110")]
        for index in stride(from: 0, to: cells.count, by: 7) {
            rows.append(terminal.paint(cells[index..<index + 7].joined(), index <= offset + today - 1 && offset + today - 1 < index + 7 ? "38;5;221" : "38;5;250"))
        }
        return rows
    }
    /// Five-row bitmap lettering: actual terminal glyphs, no fonts or runtime dependencies.
    func banner(_ terminal: CLITerminal) -> [String] {
        let glyphs: [Character: [String]] = [
            "A": ["01110", "10001", "11111", "10001", "10001"],
            "E": ["11111", "10000", "11110", "10000", "11111"],
            "F": ["11111", "10000", "11110", "10000", "10000"],
            "G": ["01111", "10000", "10111", "10001", "01110"],
            "H": ["10001", "10001", "11111", "10001", "10001"],
            "I": ["11111", "00100", "00100", "00100", "11111"],
            "M": ["10001", "11011", "10101", "10001", "10001"],
            "N": ["10001", "11001", "10101", "10011", "10001"],
            "O": ["01110", "10001", "10001", "10001", "01110"],
            "R": ["11110", "10001", "11110", "10100", "10010"],
            "T": ["11111", "00100", "00100", "00100", "00100"],
            "V": ["10001", "10001", "10001", "01010", "00100"]
        ]
        guard terminal.width >= word.count * 6 else { return [terminal.paint(word, "1;38;5;183")] }
        return (0..<5).map { row in
            let text = word.map { glyphs[$0]?[row] ?? "00000" }.joined(separator: "0")
                .map { $0 == "1" ? (terminal.ascii ? "#" : "█") : " " }.joined()
            return terminal.paint(text, row < 2 ? "38;5;183" : "38;5;141")
        }
    }
}

struct CLIAlert: Codable {
    var level: String
    var message: String
    static func collect(_ frame: CLIFrame) -> [Self] {
        var rows: [Self] = []
        if frame.freshness != "fresh" { rows.append(.init(level: "notice", message: "Application data is \(frame.freshness)")) }
        if let s = frame.snapshot {
            let main = s.sessions.filter { !$0.isSubagent }
            let waiting = main.filter { $0.status == "waiting" }.count
            if waiting > 0 { rows.append(.init(level: "attention", message: "\(waiting) sessions awaiting confirmation")) }
            for session in main where (session.contextPercent ?? 0) >= 90 {
                rows.append(.init(level: "warning", message: "\(session.agent) / \(session.project): context \(Int(session.contextPercent ?? 0))%"))
            }
            for quota in s.quota where quota.usedPercent >= 90 {
                rows.append(.init(level: "warning", message: "\(quota.label): quota \(Int(quota.usedPercent))% used"))
            }
        }
        if let host = frame.system {
            if let cpu = host.cpuPercent, cpu >= 90 { rows.append(.init(level: "warning", message: "CPU utilization above 90%")) }
            if let free = host.diskAvailableBytes, let total = host.diskTotalBytes, total > 0, Double(free) / Double(total) < 0.1 {
                rows.append(.init(level: "warning", message: "Disk has less than 10% available"))
            }
            if let battery = host.batteryPercent, battery <= 20, host.externalPower != true {
                rows.append(.init(level: "attention", message: "Battery low: \(battery)%"))
            }
        }
        return rows
    }
}
