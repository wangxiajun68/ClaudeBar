import Foundation
import AppKit
import Darwin

/// Errors are kept separate from stdout so JSON remains machine-readable.
@main struct ClaudeBarCLI {
    nonisolated(unsafe) static var interrupted = false

    @MainActor static func main() {
        _ = setlocale(LC_CTYPE, "")
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            let options = try CLIOptions.parse(args)
            try run(options)
        } catch {
            let failure = error as? CLIError ?? CLIError(String(describing: error), code: 1)
            if args.contains("--json") {
                let payload: [String: Any] = ["error": failure.description, "exitCode": failure.code]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                    FileHandle.standardError.write(data); FileHandle.standardError.write(Data("\n".utf8))
                }
            } else {
                FileHandle.standardError.write(Data(("\(BuildChannel.cliShortExecutable): \(CLITerminal.clean(failure.description))\n").utf8))
            }
            exit(failure.code)
        }
    }

    @MainActor static func run(_ options: CLIOptions) throws {
        if let control = options.controlRequest { try CLIControlClient.execute(control, options: options); return }
        if options.command == "restart" {
            let bundle = try applicationURL(explicit: options.appPath)
            _ = try normalQuit()
            var startup = options; startup.command = "start"; startup.appPath = bundle.path
            try run(startup)
            return
        }
        let weatherRefresh = options.command == "weather" && options.argument == "refresh"
        switch weatherRefresh ? "refresh" : options.command {
        case "help": print(help); return
        case "version":
            if options.json { try printJSON(["version": CLIVersion.value, "channel": BuildChannel.name, "schemaVersion": CLISnapshot.schemaVersion]) }
            else { print("\(BuildChannel.cliShortExecutable) \(CLIVersion.value) [\(BuildChannel.name)]") }
            return
        case "completion": print(completion(options.argument ?? "zsh")); return
        case "paths":
            let paths = pathInfo()
            if options.json { try printJSON(paths) }
            else { for key in paths.keys.sorted() { print("\(key): \(CLITerminal.clean(paths[key]!))") } }
            return
        case "start", "open":
            let bundle = try applicationURL(explicit: options.appPath)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = options.launchMode != "performance"
            if let mode = options.launchMode { configuration.arguments = [mode == "performance" ? "--performance" : "--desktop"] }
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: BuildChannel.bundleID)
            if let existing = running.first?.bundleURL {
                // Never launch a second checkout of the same channel beside the installed instance.
                if options.appPath != nil && existing.resolvingSymlinksInPath() != bundle.resolvingSymlinksInPath() {
                    throw CLIError("This channel is already running from another bundle; quit it normally first", code: 4)
                }
            }
            if options.command == "start", let mode = options.launchMode, !running.isEmpty {
                try CLIControlClient.execute(.init(command: "mode", arguments: [mode]), options: options)
                return
            }
            if options.command == "open" {
                let current = try? CLIControlClient.response(.init(command: "mode", arguments: ["status"]))
                let mode = current?.result.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["mode"] as? String
                if mode == "performance" || (mode == nil && readFrame(options).snapshot?.runMode == "performance") {
                    throw CLIError("Performance mode has no pages; use mode desktop first", code: 4)
                }
            }
            let target = running.first?.bundleURL ?? bundle
            var complete = false
            var launchError: Error?
            if options.command == "open" {
                var components = URLComponents()
                components.scheme = BuildChannel.urlScheme; components.host = "cli"; components.path = "/open"
                components.queryItems = [.init(name: "page", value: options.argument ?? "dashboard")]
                guard let url = components.url else { throw CLIError("Invalid page URL") }
                NSWorkspace.shared.open([url], withApplicationAt: target, configuration: configuration) { _, error in
                    launchError = error; complete = true
                }
            } else {
                NSWorkspace.shared.openApplication(at: target, configuration: configuration) { _, error in
                    launchError = error; complete = true
                }
            }
            let deadline = Date().addingTimeInterval(15)
            while !complete && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            guard complete else { throw CLIError("Launch timed out", code: 4) }
            if let launchError { throw CLIError("Launch failed: \(launchError.localizedDescription)", code: 4) }
            try actionOutput(options, "Application opened", extra: ["app": target.path]); return
        case "stop":
            let stopped = try normalQuit()
            try actionOutput(options, stopped ? "Application stopped normally" : "Already stopped"); return
        case "refresh":
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: BuildChannel.bundleID).first,
                  let bundle = app.bundleURL else { throw CLIError("Application is offline. Use start first", code: 3) }
            // Route to this exact running bundle, never through a globally registered scheme.
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
            let url = URL(string: "\(BuildChannel.urlScheme)://cli/\(weatherRefresh ? "weather-refresh" : "refresh")")!
            var complete = false
            var refreshError: Error?
            NSWorkspace.shared.open([url], withApplicationAt: bundle, configuration: configuration) { _, error in
                refreshError = error; complete = true
            }
            let deadline = Date().addingTimeInterval(10)
            while !complete && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            guard complete else { throw CLIError("Refresh delivery timed out", code: 4) }
            if let refreshError { throw CLIError("Refresh delivery failed: \(refreshError.localizedDescription)", code: 4) }
            try actionOutput(options, weatherRefresh ? "Weather refresh requested for the configured city" : "Refresh requested; read status after the next scan"); return
        default: break
        }
        let interactive = options.watch && !options.json && isatty(STDOUT_FILENO) != 0 && isatty(STDIN_FILENO) != 0
            && ProcessInfo.processInfo.environment["TERM"] != "dumb" && !options.plain
            && !options.count && !["count", "doctor"].contains(options.command)
        let previousINT = signal(SIGINT) { _ in ClaudeBarCLI.interrupted = true }
        let previousTERM = signal(SIGTERM) { _ in ClaudeBarCLI.interrupted = true }
        let previousHUP = signal(SIGHUP) { _ in ClaudeBarCLI.interrupted = true }
        let previousQUIT = signal(SIGQUIT) { _ in ClaudeBarCLI.interrupted = true }
        let previousPIPE = signal(SIGPIPE, SIG_DFL)
        defer { signal(SIGINT, previousINT); signal(SIGTERM, previousTERM); signal(SIGHUP, previousHUP); signal(SIGQUIT, previousQUIT); signal(SIGPIPE, previousPIPE) }
        if interactive { try CLITUIRuntime.run(options); return }
        var sample = 0
        repeat {
            let start = ProcessInfo.processInfo.systemUptime
            let frame = readFrame(options)
            if options.command == "doctor" {
                let report = doctor(options, frame: frame)
                if options.json { try printJSON(report, compact: options.watch) }
                else { for key in report.keys.sorted() { print("\(key): \(CLITerminal.clean(String(describing: report[key]!)))") } }
            } else {
                let needsSnapshot = ["sessions", "count", "usage", "providers", "quota", "vpn", "proxy", "connectors", "config", "agents", "models"].contains(options.command)
                if needsSnapshot && frame.snapshot == nil && !options.watch { throw CLIError(frame.snapshotError ?? "No snapshot", code: 3) }
                if options.json { try printJSON(jsonReport(options, frame: frame), compact: options.watch) }
                else {
                    if (options.command == "count" || options.count), frame.snapshot != nil, frame.freshness != "fresh" {
                        FileHandle.standardError.write(Data(("Notice: session count uses \(frame.freshness) data (\(Int(frame.age ?? 0))s old)\n").utf8))
                    }
                    let screen = CLITerminal.current(options)
                    let text = CLIRenderer(terminal: screen, options: options).render(frame)
                    print(text)
                }
            }
            sample += 1
            if !options.watch || (options.samples.map { sample >= $0 } ?? false) { break }
            while !interrupted && ProcessInfo.processInfo.systemUptime - start < options.interval { Thread.sleep(forTimeInterval: 0.05) }
        } while !interrupted
        if interrupted { throw CLIError("Interrupted", code: 130) }
    }

    @MainActor static func normalQuit() throws -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: BuildChannel.bundleID)
        guard apps.count <= 1 else { throw CLIError("Multiple instances of this channel are running; quit them from their menus", code: 4) }
        guard let app = apps.first else { return false }
        guard app.terminate() else { throw CLIError("Application declined normal termination", code: 4) }
        let deadline = Date().addingTimeInterval(10)
        while !app.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard app.isTerminated else { throw CLIError("Normal quit is still pending; check the application", code: 4) }
        return true
    }

    static func readFrame(_ options: CLIOptions, processIDs: [Int]? = nil) -> CLIFrame {
        let pids = processIDs ?? NSRunningApplication.runningApplications(withBundleIdentifier: BuildChannel.bundleID).map { Int($0.processIdentifier) }
        let running = !pids.isEmpty
        let file = options.snapshotPath.map { URL(fileURLWithPath: $0) }
            ?? CLISnapshot.fileURL(home: FileManager.default.homeDirectoryForCurrentUser, appName: BuildChannel.appName)
        var snapshot: CLISnapshot?
        var snapshotError: String?
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 16 * 1024 * 1024 else { throw CLIError("Snapshot exceeds 16 MiB") }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(CLISnapshot.self, from: Data(contentsOf: file))
            guard decoded.schemaVersion == CLISnapshot.schemaVersion else { throw CLIError("Unsupported snapshot schema; rebuild matching app and CLI") }
            guard decoded.channel == BuildChannel.name else { throw CLIError("Snapshot channel mismatch (expected \(BuildChannel.name))") }
            snapshot = decoded
        } catch let failure as CLIError { snapshotError = failure.description }
        catch {
            snapshotError = FileManager.default.fileExists(atPath: file.path) ? "Snapshot unreadable or malformed" : "No application snapshot available"
        }
        let host = ["status", "dashboard", "system", "cpu", "gpu", "memory", "disk", "battery", "network", "uptime", "alerts"].contains(options.command) ? CLISystem.read() : nil
        return .init(snapshot: snapshot, snapshotError: snapshotError, running: running, archived: options.snapshotPath != nil, system: host, snapshotProcessMatches: snapshot.map { pids.contains($0.pid) } ?? false)
    }

    static func object<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
    }

    static func jsonReport(_ options: CLIOptions, frame: CLIFrame) throws -> [String: Any] {
        var result: [String: Any] = ["schemaVersion": CLISnapshot.schemaVersion, "channel": BuildChannel.name,
            "command": options.command, "appRunning": frame.running, "freshness": frame.freshness,
            "capturedAt": ISO8601DateFormatter().string(from: frame.capturedAt)]
        if let age = frame.age { result["snapshotAgeSeconds"] = age }
        if let error = frame.snapshotError { result["snapshotError"] = error }
        if let host = frame.system { result["system"] = try object(host) }
        let lifestyle = CLILifestyle(date: frame.capturedAt)
        if ["status", "dashboard", "date", "calendar", "greet"].contains(options.command) {
            result["date"] = lifestyle.info
            result["greeting"] = frame.snapshot?.greeting ?? lifestyle.greeting
        }
        if options.command == "commands" {
            result["commands"] = CLIOptions.commands
            result["aliases"] = CLIOptions.aliases
            result["subcommandAliases"] = CLIOptions.subcommandAliases
        }
        if options.command == "alerts" { result["alerts"] = try object(CLIAlert.collect(frame)) }
        if ["status", "dashboard", "weather"].contains(options.command) {
            result["weatherAvailable"] = frame.snapshot?.weather != nil
            result["weatherLoading"] = frame.snapshot?.weatherLoading ?? false
            if let weather = frame.snapshot?.weather {
                result["weather"] = try object(weather)
                result["weatherStale"] = frame.capturedAt.timeIntervalSince(weather.fetchedAt ?? weather.observedAt) > 900
            }
            if let note = frame.snapshot?.weatherNote { result["weatherNote"] = note }
        }
        guard let snapshot = frame.snapshot else { return result }
        result["updatedAt"] = ISO8601DateFormatter().string(from: snapshot.updatedAt)
        result["appVersion"] = snapshot.appVersion
        result["runMode"] = snapshot.runMode ?? "desktop"
        switch options.command {
        case "sessions", "count", "status", "dashboard":
            let rows = options.sessions(in: snapshot)
            result["counts"] = ["total": rows.count,
                "busy": rows.filter { $0.status == "busy" }.count,
                "waiting": rows.filter { $0.status == "waiting" }.count,
                "idle": rows.filter { $0.status == "idle" }.count,
                "byAgent": Dictionary(grouping: rows, by: \.agent).mapValues(\.count)]
            if options.command != "count" && !options.count {
                result["sessions"] = try object(Array(rows.prefix(options.limit ?? rows.count)))
            }
        case "agents":
            result["agents"] = ["claude", "codex", "cursor"].map { agent -> [String: Any] in
                let all = snapshot.sessions.filter { $0.agent == agent }
                let main = all.filter { !$0.isSubagent }
                return ["agent": agent, "main": main.count, "subagents": all.filter(\.isSubagent).count,
                        "busy": main.filter { $0.status == "busy" }.count,
                        "waiting": main.filter { $0.status == "waiting" }.count,
                        "idle": main.filter { $0.status == "idle" }.count]
            }
        default: break
        }
        if options.command == "models" { result["models"] = try object(snapshot.usage.models.sorted { $0.tokens > $1.tokens }) }
        if ["status", "dashboard", "usage"].contains(options.command) { result["usage"] = try object(snapshot.usage) }
        if ["status", "dashboard", "providers"].contains(options.command) { result["providers"] = try object(snapshot.providers) }
        if ["status", "dashboard", "quota"].contains(options.command) { result["quota"] = try object(snapshot.quota); result["quotaLoading"] = snapshot.quotaLoading }
        if ["status", "dashboard", "vpn", "config"].contains(options.command) { result["vpn"] = try object(snapshot.vpn) }
        if ["status", "dashboard", "proxy", "config"].contains(options.command) { result["proxy"] = try object(snapshot.proxy) }
        if ["status", "dashboard", "connectors"].contains(options.command) {
            result["connectors"] = try object(snapshot.connectors); result["connectorsScanned"] = snapshot.connectorsScanned
            result["connectorsLoading"] = snapshot.connectorsLoading
        }
        if ["status", "dashboard", "config"].contains(options.command) {
            result["charge"] = try object(snapshot.charge); result["allowsSystemIntegration"] = BuildChannel.allowsSystemIntegration
        }
        return result
    }

    static func printJSON(_ value: Any, compact: Bool = false) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: compact ? [.sortedKeys, .fragmentsAllowed] : [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        FileHandle.standardOutput.write(data); write("\n")
    }
    static func write(_ value: String) { FileHandle.standardOutput.write(Data(value.utf8)) }
    static func actionOutput(_ options: CLIOptions, _ message: String, extra: [String: Any] = [:]) throws {
        if options.json { try printJSON(extra.merging(["ok": true, "message": message, "channel": BuildChannel.name]) { _, new in new }) }
        else { print("\(CLITerminal.clean(message)) [\(BuildChannel.name)]") }
    }

    static func pathInfo() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["channel": BuildChannel.name, "bundleID": BuildChannel.bundleID,
                "snapshot": CLISnapshot.fileURL(home: home, appName: BuildChannel.appName).path,
                "appSupport": home.appendingPathComponent("Library/Application Support").appendingPathComponent(BuildChannel.appName).path,
                "executable": URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path]
    }

    /// A CLI compiled for dev cannot select a release application, even with --app.
    static func validatedApplication(_ url: URL) -> Bool {
        guard let bundle = Bundle(url: url),
              bundle.bundleIdentifier == BuildChannel.bundleID,
              bundle.object(forInfoDictionaryKey: "ClaudeBarBuildChannel") as? String == BuildChannel.name,
              let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else { return false }
        return true
    }

    static func applicationURL(explicit: String?) throws -> URL {
        if let explicit {
            let url = URL(fileURLWithPath: explicit).resolvingSymlinksInPath()
            guard validatedApplication(url) else { throw CLIError("--app must be an executable \(BuildChannel.appName) bundle with the matching channel", code: 4) }
            return url
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: BuildChannel.bundleID).first?.bundleURL
        if let running, validatedApplication(running) { return running }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // Embedded in Foo.app/Contents/Helpers, or in .build/<channel>/bin.
        let embedded = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let built = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(BuildChannel.appName + ".app")
        let installed = BuildChannel.name == "release" ? URL(fileURLWithPath: "/Applications/ClaudeBar.app")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ClaudeBar Dev.app")
        for candidate in [embedded, built, installed] where validatedApplication(candidate) { return candidate }
        throw CLIError("Matching application not found. Build/install \(BuildChannel.appName), or use --app /path/to/app", code: 4)
    }

    static func doctor(_ options: CLIOptions, frame: CLIFrame) -> [String: Any] {
        var values: [String: Any] = pathInfo()
        values["version"] = CLIVersion.value
        values["controlSocket"] = CLIControl.socketURL(home: FileManager.default.homeDirectoryForCurrentUser, appName: BuildChannel.appName).path
        values["runMode"] = frame.snapshot?.runMode ?? "unknown"
        values["appRunning"] = frame.running; values["freshness"] = frame.freshness
        values["snapshotReadable"] = frame.snapshot != nil
        values["systemIntegration"] = BuildChannel.allowsSystemIntegration
        values["permissionPrompts"] = BuildChannel.promptsForSystemPermissions
        if let app = try? applicationURL(explicit: options.appPath) { values["application"] = app.path }
        else { values["application"] = "not found / channel mismatch" }
        if let error = frame.snapshotError { values["snapshotError"] = error }
        return values
    }

    static var help: String {
        """
        MTX // MATRIX SYSTEM OBSERVATORY [\(BuildChannel.name)]
        Usage: \(BuildChannel.cliShortExecutable) [command] [options]
        Alias: \(BuildChannel.cliExecutable) (same compiled channel)

        status / dashboard    Machine + agent sessions + usage + services (default)
        watch [SEC] / -w [SEC] Live Matrix dashboard; e.g. -w 1, Ctrl-C to leave
        sessions [list|count] All main Claude / Codex / Cursor sessions
        count                 Print only the matching session count
        system                Live CPU, GPU, memory, disk, battery, network, uptime
        cpu / gpu / memory    Focused live resource readings
        disk / battery        Available space / power and charging state
        network / uptime      Physical interface rates / machine uptime
        greet / date          Large greeting / local clock, timezone, year progress
        calendar              Current month; today in brackets
        weather [refresh]     Cached weather / request configured-city fetch
        agents / models       Fleet counts / model token ranking
        alerts                Waiting sessions, context/quota and host thresholds
        commands              Browse command groups
        usage                 Selected-period and today's tokens; model breakdown
        providers / quota     Provider inventory / Codex account allowance
        providers catalog     Full provider/model IDs (same-user live control)
        providers use TARGET  Activate provider; --agent claude|codex --model MODEL
        providers official    Restore official config for --agent claude|codex
        providers capture TARGET on|off  Toggle this provider's traffic recording
        models list           Configured models and IDs (models usage: token ranking)
        models use TARGET     Switch active provider's model; optional --provider
        vpn start|stop|restart|reload    Control the existing VPN lifecycle
        vpn nodes|groups      Runtime nodes/groups; vpn preview: saved subscription
        vpn select NODE       Switch node; optional --group NAME
        vpn test NODE         Measure node latency
        vpn proxy|tun on|off   System proxy / TUN policy
        proxy start|stop       Start or stop model routing proxy
        connectors list       Live inventory with control IDs and capabilities
        connectors refresh    Rescan; optional --project PATH
        connectors show TARGET        Credential-free item details
        connectors enable|disable TARGET   Toggle supported connector
        connectors remove TARGET --yes     Remove a removable connector
        config set KEY VALUE  appearance, token-units, weather-city, vpn-guard
        mode [status|performance|desktop]  Change presentation without stopping services
        vpn / proxy           VPN and local LLM proxy status
        connectors            Skills, MCP and plugin inventory
        config / paths        Credential-free policy / channel-specific paths
        doctor                Read-only CLI, application and snapshot diagnostics
        start / launch        Launch this channel's application; --mode performance
        restart               Normal quit and relaunch; optional --mode desktop
        stop / quit           Normal quit of this channel (allows app cleanup)
        open [page]           Open dashboard, sessions, providers, connectors,
                              usage, traffic, vpn, settings or help
        refresh               Request asynchronous usage/session/inventory scan
        completion [shell]    Generate zsh (default), bash or fish completion
        version / help        Build version / this guide

        -j, --json            Structured JSON; --watch emits NDJSON
        -w, --watch [SEC]      Repeat a query, optional seconds (never repeat actions)
        -i, --interval SEC    Refresh interval 0.5...3600 (default 2)
        -n, --samples N       Stop watching after N frames
        -a, --agent AGENT     claude | codex | cursor
        -s, --status STATE    busy | waiting | idle
        --include-subagents   Include Codex helpers in session list and count
        -l, --limit N         Limit displayed rows; counts still cover all matches
        --count               Numeric output for sessions
        -c, --compact         Compact greeting; more room for telemetry
        -p, --plain           Minimal uncolored output, no alternate screen
        --ascii               ASCII borders and meters
        --no-color            Disable ANSI colors (also honors NO_COLOR)
        --snapshot FILE       Read an archived snapshot, matching channel only
        --provider / --model / --group  Explicit selection for control commands
        --project PATH        Connector inventory project scope
        --mode MODE           Initial desktop/performance mode (start/restart)
        -y, --yes             Explicit connector removal
        --app BUNDLE          Explicit matching application for start/open/doctor

        Interactive watch (stdin + stdout TTY):
        ↑↓ / jk / PgUp / PgDn  Scroll; g/G first/last; mouse wheel supported
        Tab / ←→ / 1–7         Switch pages; / search; Enter details; Esc close
        Space                 Freeze view while backend sampling continues
        :                     Run one control command; quotes and aliases work
        r                     Reload model/VPN/connector catalogs or resample locally
        m / ? / q             Toggle mouse (copy text) / help / exit
        Plain, numeric, doctor, JSON and redirected watch stay streaming.

        Command abbreviations:
        \(CLIOptions.aliases.keys.sorted().map { "  " + $0 + " = " + CLIOptions.aliases[$0]! }.joined(separator: "\n"))
        Subcommand abbreviations (only the verb is expanded; target names stay exact):
        \(CLIOptions.subcommandAliases.keys.sorted().map { command in
            "  " + command + ": " + CLIOptions.subcommandAliases[command]!.keys.sorted().map {
                $0 + "=" + CLIOptions.subcommandAliases[command]![$0]!
            }.joined(separator: " ")
        }.joined(separator: "\n"))

        App data: private heartbeat snapshot (3s); stale after 15s or app exit.
        Host data: permission-free local sampling, even while app is offline.
        No snapshot: focused app queries exit 3; use start then retry.
        Exit codes: 0 success, 1 runtime error, 2 arguments, 3 no data,
                    4 app lifecycle failure, 5 control failure/restriction, 130 interrupted.
        """
    }

    static func completion(_ shell: String) -> String {
        let executable = BuildChannel.cliShortExecutable
        let aliases = executable + " " + BuildChannel.cliExecutable
        let commands = Set(CLIOptions.commands + Array(CLIOptions.aliases.keys)).sorted().joined(separator: " ")
        let flags = "-w -j -i -n -a -s -l -c -p -y -h -V --json --watch --interval --samples --agent --status --include-subagents --limit --count --provider --model --group --project --mode --yes --compact --plain --ascii --no-color --snapshot --app --help --version"
        func names(_ command: String) -> String {
            ([command] + CLIOptions.aliases.filter { $0.value == command }.map(\.key)).sorted().joined(separator: "|")
        }
        func verbs(_ command: String, _ full: String) -> String {
            full + " " + (CLIOptions.subcommandAliases[command]?.keys.sorted().joined(separator: " ") ?? "")
        }
        switch shell {
        case "bash":
            return """
            _claudebar_complete() {
              local previous="${COMP_WORDS[COMP_CWORD-1]}" choices="\(commands) \(flags)"
              case "$previous" in
                --agent|-a) choices="claude codex cursor" ;;
                --status|-s) choices="busy waiting idle" ;;
                -w|--watch|-i|--interval|watch|w) choices="0.5 1 2 5 10 30 60" ;;
                \(names("open"))) choices="\(CLISnapshot.pages.joined(separator: " "))" ;;
                \(names("weather"))) choices="\(verbs("weather", "refresh"))" ;;
                \(names("completion"))) choices="bash zsh fish" ;;
                --mode) choices="desktop performance" ;;
                \(names("providers"))) choices="\(verbs("providers", "list catalog use official capture"))" ;;
                \(names("models"))) choices="\(verbs("models", "list catalog use usage"))" ;;
                vpn) choices="\(verbs("vpn", "status start stop restart reload nodes groups preview select test proxy tun"))" ;;
                \(names("proxy"))) choices="\(verbs("proxy", "status start stop on off"))" ;;
                \(names("connectors"))) choices="\(verbs("connectors", "list refresh show enable disable remove"))" ;;
                \(names("mode"))) choices="\(verbs("mode", "status desktop performance"))" ;;
                \(names("config"))) choices="\(verbs("config", "set"))" ;;
                \(names("sessions"))) choices="\(verbs("sessions", "list count"))" ;;
                --app|--snapshot|--project) COMPREPLY=( $(compgen -f -- "${COMP_WORDS[COMP_CWORD]}") ); return ;;
              esac
              COMPREPLY=( $(compgen -W "$choices" -- "${COMP_WORDS[COMP_CWORD]}") )
            }
            complete -F _claudebar_complete \(aliases)
            """
        case "fish":
            let script = "complete -c \(executable) -f -a '\(commands)'\n"
                + "complete -c \(executable) -l agent -r -a 'claude codex cursor'\n"
                + "complete -c \(executable) -l status -r -a 'busy waiting idle'\n"
                + "complete -c \(executable) -n '__fish_seen_subcommand_from open' -a '\(CLISnapshot.pages.joined(separator: " "))'\n"
                + flags.split(separator: " ").filter { $0.hasPrefix("--") && !["--agent", "--status"].contains(String($0)) }.map { "complete -c \(executable) -l \($0.dropFirst(2))" }.joined(separator: "\n")
                + "\n" + flags.split(separator: " ").filter { !$0.hasPrefix("--") }.map { "complete -c \(executable) -s \($0.dropFirst())" }.joined(separator: "\n")
            return script + "\n" + script.replacingOccurrences(of: "-c " + executable, with: "-c " + BuildChannel.cliExecutable)
        default:
            return """
            #compdef \(aliases)
            _\(executable.replacingOccurrences(of: "-", with: "_"))() {
              local previous="$words[CURRENT-1]"
              case "$previous" in
                --agent|-a) compadd claude codex cursor; return ;;
                --status|-s) compadd busy waiting idle; return ;;
                -w|--watch|-i|--interval|watch|w) compadd 0.5 1 2 5 10 30 60; return ;;
                \(names("open"))) compadd \(CLISnapshot.pages.joined(separator: " ")); return ;;
                \(names("weather"))) compadd \(verbs("weather", "refresh")); return ;;
                \(names("completion"))) compadd zsh bash fish; return ;;
                --mode) compadd desktop performance; return ;;
                \(names("providers"))) compadd \(verbs("providers", "list catalog use official capture")); return ;;
                \(names("models"))) compadd \(verbs("models", "list catalog use usage")); return ;;
                vpn) compadd \(verbs("vpn", "status start stop restart reload nodes groups preview select test proxy tun")); return ;;
                \(names("proxy"))) compadd \(verbs("proxy", "status start stop on off")); return ;;
                \(names("connectors"))) compadd \(verbs("connectors", "list refresh show enable disable remove")); return ;;
                \(names("mode"))) compadd \(verbs("mode", "status desktop performance")); return ;;
                \(names("config"))) compadd \(verbs("config", "set")); return ;;
                \(names("sessions"))) compadd \(verbs("sessions", "list count")); return ;;
                --app|--snapshot|--project) _files; return ;;
              esac
              compadd -- \(commands) \(flags)
            }
            compdef _\(executable.replacingOccurrences(of: "-", with: "_")) \(aliases)
            """
        }
    }
}
