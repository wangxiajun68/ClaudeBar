import Foundation

struct CLIError: Error, CustomStringConvertible {
    var description: String
    var code: Int32 = 2
    init(_ message: String, code: Int32 = 2) { description = message; self.code = code }
}

struct CLIOptions {
    static let commands = ["status", "dashboard", "watch", "sessions", "count", "system", "cpu", "gpu", "memory", "disk", "battery", "network", "uptime", "date", "calendar", "greet", "weather", "agents", "models", "alerts", "commands", "usage", "providers", "quota", "vpn", "proxy", "connectors", "config", "paths", "doctor", "start", "stop", "open", "refresh", "completion", "version", "help"]
    var command = "status"
    var argument: String?
    var json = false
    var watch = false
    var interval = 2.0
    var samples: Int?
    var agent: String?
    var status: String?
    var limit: Int?
    var includeSubagents = false
    var count = false
    var noColor = false
    var ascii = false
    var plain = false
    var compact = false
    var snapshotPath: String?
    var appPath: String?

    static func parse(_ args: [String]) throws -> Self {
        var options = Self()
        var positional: [String] = []
        var index = 0
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < args.count, !args[index].hasPrefix("--") else { throw CLIError("Missing value for \(flag)") }
            return args[index]
        }
        while index < args.count {
            let flag = args[index]
            switch flag {
            case "--help", "-h": options.command = "help"; return options
            case "--version", "-V": options.command = "version"; return options
            case "--json": options.json = true
            case "--watch", "-w": options.watch = true
            case "--no-color": options.noColor = true
            case "--compact": options.compact = true
            case "--ascii": options.ascii = true
            case "--plain": options.plain = true; options.noColor = true
            case "--include-subagents": options.includeSubagents = true
            case "--count": options.count = true
            case "--agent": options.agent = try value(flag)
            case "--status": options.status = try value(flag)
            case "--snapshot": options.snapshotPath = try value(flag)
            case "--app": options.appPath = try value(flag)
            case "--interval":
                guard let number = Double(try value(flag)), number.isFinite, (0.5...3600).contains(number) else {
                    throw CLIError("--interval must be 0.5...3600 seconds")
                }
                options.interval = number
            case "--samples", "--limit":
                guard let number = Int(try value(flag)), (1...100000).contains(number) else {
                    throw CLIError("\(flag) must be 1...100000")
                }
                if flag == "--samples" { options.samples = number } else { options.limit = number }
            default:
                guard !flag.hasPrefix("-") else { throw CLIError("Unknown option: \(flag)") }
                positional.append(flag)
            }
            index += 1
        }
        if let command = positional.first { options.command = command }
        guard commands.contains(options.command) else { throw CLIError("Unknown command: \(options.command). Use help.") }
        if options.command == "watch" { options.command = "dashboard"; options.watch = true }
        let hasArgument = ["sessions", "open", "completion", "weather"].contains(options.command)
        guard positional.count <= (hasArgument ? 2 : 1) else { throw CLIError("Unexpected arguments") }
        options.argument = positional.dropFirst().first
        if options.command == "sessions", let argument = options.argument {
            guard argument == "count" || argument == "list" else { throw CLIError("Use sessions [list|count]") }
            options.count = argument == "count"
        }
        if options.command == "weather", let argument = options.argument, argument != "refresh" { throw CLIError("Use weather [refresh]") }
        if options.watch && options.argument == "refresh" { throw CLIError("weather refresh does not support --watch") }
        if let agent = options.agent, !["claude", "codex", "cursor"].contains(agent) { throw CLIError("--agent: claude, codex or cursor") }
        if let status = options.status, !["busy", "waiting", "idle"].contains(status) { throw CLIError("--status: busy, waiting or idle") }
        if options.command == "open", let page = options.argument, !CLISnapshot.pages.contains(page) { throw CLIError("Unknown page: \(page)") }
        if options.command == "completion", let shell = options.argument, !["zsh", "bash", "fish"].contains(shell) { throw CLIError("completion: zsh, bash or fish") }
        let queries = ["status", "dashboard", "sessions", "count", "system", "cpu", "gpu", "memory", "disk", "battery", "network", "uptime", "date", "calendar", "greet", "weather", "agents", "models", "alerts", "commands", "usage", "providers", "quota", "vpn", "proxy", "connectors", "config", "doctor"]
        if options.watch && (options.command == "commands" || !queries.contains(options.command)) { throw CLIError("--watch is only valid for queries") }
        if options.samples != nil && !options.watch { throw CLIError("--samples requires --watch") }
        if (options.agent != nil || options.status != nil || options.includeSubagents || options.limit != nil),
           !["status", "dashboard", "sessions", "count"].contains(options.command) { throw CLIError("Session filters require status, dashboard, sessions or count") }
        if options.count && options.command != "sessions" { throw CLIError("--count requires sessions; or use count") }
        if options.appPath != nil && !["start", "open", "doctor"].contains(options.command) { throw CLIError("--app requires start, open or doctor") }
        return options
    }

    func sessions(in snapshot: CLISnapshot) -> [CLISnapshot.Session] {
        snapshot.sessions.filter {
            (includeSubagents || !$0.isSubagent) && (agent == nil || $0.agent == agent) && (status == nil || $0.status == status)
        }
    }
}
