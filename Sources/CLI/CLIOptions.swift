import Foundation

struct CLIError: Error, CustomStringConvertible {
    var description: String
    var code: Int32 = 2
    init(_ message: String, code: Int32 = 2) { description = message; self.code = code }
}

struct CLIOptions {
    static let commands = ["status", "dashboard", "watch", "sessions", "count", "system", "cpu", "gpu", "memory", "disk", "battery", "network", "uptime", "date", "calendar", "greet", "weather", "agents", "models", "alerts", "commands", "usage", "providers", "quota", "vpn", "proxy", "connectors", "config", "paths", "doctor", "start", "stop", "restart", "launch", "quit", "mode", "provider", "model", "connector", "open", "refresh", "completion", "version", "help"]
    /// Explicit aliases keep status/start/stop and model/mode unambiguous.
    static let aliases = [
        "st": "status", "db": "dashboard", "w": "watch", "s": "sessions", "sess": "sessions", "c": "count",
        "sys": "system", "mem": "memory", "dsk": "disk", "bat": "battery", "net": "network", "up": "uptime",
        "dt": "date", "cal": "calendar", "gr": "greet", "wx": "weather", "ag": "agents", "md": "models",
        "al": "alerts", "cmd": "commands", "u": "usage", "pv": "providers", "q": "quota", "px": "proxy",
        "cn": "connectors", "cfg": "config", "p": "paths", "dr": "doctor", "on": "start", "off": "stop",
        "rs": "restart", "mo": "mode", "o": "open", "r": "refresh", "cmp": "completion", "v": "version", "h": "help",
        "launch": "start", "quit": "stop", "provider": "providers", "model": "models", "connector": "connectors"
    ]
    static let subcommandAliases = [
        "sessions": ["ls": "list", "c": "count"], "weather": ["r": "refresh"],
        "providers": ["ls": "list", "cat": "catalog", "u": "use", "of": "official", "cap": "capture"],
        "models": ["ls": "list", "cat": "catalog", "u": "use", "us": "usage"],
        "vpn": ["st": "status", "on": "start", "off": "stop", "rs": "restart", "n": "nodes", "g": "groups",
                "pv": "preview", "s": "select", "t": "test", "r": "reload", "px": "proxy"],
        "proxy": ["st": "status"],
        "connectors": ["ls": "list", "r": "refresh", "s": "show", "on": "enable", "off": "disable", "rm": "remove"],
        "config": ["s": "set"], "mode": ["st": "status", "p": "performance", "d": "desktop"]
    ]
    var command = "status"
    var argument: String?
    var arguments: [String] = []
    var provider: String?
    var model: String?
    var group: String?
    var project: String?
    var launchMode: String?
    var yes = false
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
        func interval(_ text: String) throws -> Double {
            guard let number = Double(text), number.isFinite, (0.5...3600).contains(number) else {
                throw CLIError("Refresh interval must be 0.5...3600 seconds")
            }
            return number
        }
        while index < args.count {
            let flag = args[index]
            switch flag {
            case "--help", "-h": options.command = "help"; return options
            case "--version", "-V": options.command = "version"; return options
            case "--json", "-j": options.json = true
            case "--watch", "-w":
                options.watch = true
                if index + 1 < args.count, Double(args[index + 1]) != nil {
                    index += 1; options.interval = try interval(args[index])
                }
            case "--no-color": options.noColor = true
            case "--compact", "-c": options.compact = true
            case "--ascii": options.ascii = true
            case "--plain", "-p": options.plain = true; options.noColor = true
            case "--include-subagents": options.includeSubagents = true
            case "--count": options.count = true
            case "--yes", "-y": options.yes = true
            case "--provider": options.provider = try value(flag)
            case "--model": options.model = try value(flag)
            case "--group": options.group = try value(flag)
            case "--project": options.project = try value(flag)
            case "--mode": options.launchMode = try value(flag)
            case "--agent", "-a": options.agent = try value(flag)
            case "--status", "-s": options.status = try value(flag)
            case "--snapshot": options.snapshotPath = try value(flag)
            case "--app": options.appPath = try value(flag)
            case "--interval", "-i": options.interval = try interval(value(flag))
            case "--samples", "--limit", "-n", "-l":
                guard let number = Int(try value(flag)), (1...100000).contains(number) else {
                    throw CLIError("\(flag) must be 1...100000")
                }
                if flag == "--samples" || flag == "-n" { options.samples = number } else { options.limit = number }
            default:
                guard !flag.hasPrefix("-") else { throw CLIError("Unknown option: \(flag)") }
                let firstCommand = positional.isEmpty
                positional.append(flag)
                if firstCommand, (aliases[flag] ?? flag) == "watch", index + 1 < args.count, Double(args[index + 1]) != nil {
                    index += 1; options.interval = try interval(args[index])
                }
            }
            index += 1
        }
        if let command = positional.first { options.command = command }
        options.command = aliases[options.command] ?? options.command
        guard commands.contains(options.command) else { throw CLIError("Unknown command: \(options.command). Use help.") }
        if options.command == "watch" { options.command = "dashboard"; options.watch = true }
        options.arguments = Array(positional.dropFirst())
        if let first = options.arguments.first, let expanded = subcommandAliases[options.command]?[first] {
            options.arguments[0] = expanded
        }
        options.argument = options.arguments.first
        let grammar: [String: [String: ClosedRange<Int>]] = [
            "sessions": ["list": 1...1, "count": 1...1], "weather": ["refresh": 1...1],
            "providers": ["list": 1...1, "catalog": 1...1, "use": 2...2, "official": 1...1, "capture": 3...3],
            "models": ["list": 1...1, "catalog": 1...1, "use": 2...2, "usage": 1...1],
            "vpn": ["status": 1...1, "start": 1...1, "stop": 1...1, "restart": 1...1, "nodes": 1...1, "groups": 1...1,
                    "preview": 1...1, "select": 2...2, "test": 2...2, "reload": 1...1, "proxy": 2...2, "tun": 2...2],
            "proxy": ["status": 1...1, "start": 1...1, "stop": 1...1, "on": 1...1, "off": 1...1],
            "connectors": ["list": 1...1, "refresh": 1...1, "show": 2...2, "enable": 2...2, "disable": 2...2, "remove": 2...2],
            "config": ["set": 3...3], "mode": ["status": 1...1, "desktop": 1...1, "performance": 1...1]
        ]
        if let first = options.argument {
            if let choices = grammar[options.command] {
                guard choices[first]?.contains(options.arguments.count) == true else { throw CLIError("Invalid arguments for \(options.command); use help") }
            } else if ["open", "completion"].contains(options.command) {
                guard options.arguments.count == 1 else { throw CLIError("Unexpected arguments") }
            } else { throw CLIError("Unexpected arguments") }
        }
        if options.command == "sessions" { options.count = options.argument == "count" || options.count }
        if let mode = options.launchMode, !["performance", "desktop"].contains(mode) { throw CLIError("--mode: desktop or performance") }
        if options.launchMode != nil && !["start", "restart"].contains(options.command) { throw CLIError("--mode requires start or restart") }
        if options.provider != nil && !(options.command == "models" && options.argument == "use") { throw CLIError("--provider requires models use") }
        if options.model != nil && !(options.command == "providers" && options.argument == "use") { throw CLIError("--model requires providers use") }
        if options.group != nil && !(options.command == "vpn" && options.argument == "select") { throw CLIError("--group requires vpn select") }
        if options.project != nil && options.command != "connectors" { throw CLIError("--project requires connectors") }
        if options.yes && !(options.command == "connectors" && options.argument == "remove") { throw CLIError("--yes requires connectors remove") }
        if options.command == "connectors", options.argument == "remove", !options.yes { throw CLIError("Connector removal requires --yes") }
        if let agent = options.agent, !["claude", "codex", "cursor"].contains(agent) { throw CLIError("--agent: claude, codex or cursor") }
        if let status = options.status, !["busy", "waiting", "idle"].contains(status) { throw CLIError("--status: busy, waiting or idle") }
        if options.command == "open", let page = options.argument, !CLISnapshot.pages.contains(page) { throw CLIError("Unknown page: \(page)") }
        if options.command == "completion", let shell = options.argument, !["zsh", "bash", "fish"].contains(shell) { throw CLIError("completion: zsh, bash or fish") }
        let queries = ["status", "dashboard", "sessions", "count", "system", "cpu", "gpu", "memory", "disk", "battery", "network", "uptime", "date", "calendar", "greet", "weather", "agents", "models", "alerts", "commands", "usage", "providers", "quota", "vpn", "proxy", "connectors", "config", "doctor"]
        if options.watch && (options.command == "commands" || options.controlRequest != nil || options.argument == "refresh" || !queries.contains(options.command)) { throw CLIError("--watch is only valid for queries") }
        if options.samples != nil && !options.watch { throw CLIError("--samples requires --watch") }
        if (options.agent != nil || options.status != nil || options.includeSubagents || options.limit != nil),
           !["status", "dashboard", "sessions", "count", "providers", "models"].contains(options.command) { throw CLIError("Filters do not apply to this command") }
        if (options.status != nil || options.includeSubagents || options.limit != nil), !["status", "dashboard", "sessions", "count"].contains(options.command) { throw CLIError("Session-only filter") }
        if options.count && options.command != "sessions" { throw CLIError("--count requires sessions; or use count") }
        if options.appPath != nil && !["start", "restart", "open", "doctor"].contains(options.command) { throw CLIError("--app requires start, open or doctor") }
        if options.snapshotPath != nil && (options.controlRequest != nil || ["start", "stop", "restart", "open", "refresh"].contains(options.command)) { throw CLIError("--snapshot is only for offline queries") }
        return options
    }

    var controlRequest: CLIControl.Request? {
        let controlled: Bool
        switch command {
        case "mode": controlled = true
        case "connectors": controlled = !arguments.isEmpty || project != nil
        case "providers", "config": controlled = !arguments.isEmpty
        case "models": controlled = !arguments.isEmpty && argument != "usage"
        case "vpn", "proxy": controlled = !arguments.isEmpty && argument != "status"
        default: controlled = false
        }
        guard controlled else { return nil }
        return .init(command: command, arguments: arguments.isEmpty ? [command == "connectors" ? "list" : "status"] : arguments,
                     agent: agent, provider: provider, model: model, group: group, project: project, confirmed: yes)
    }

    func sessions(in snapshot: CLISnapshot) -> [CLISnapshot.Session] {
        snapshot.sessions.filter {
            (includeSubagents || !$0.isSubagent) && (agent == nil || $0.agent == agent) && (status == nil || $0.status == status)
        }
    }
}
