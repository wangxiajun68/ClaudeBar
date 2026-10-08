import Foundation

@MainActor
enum CLIControlClient {
    static func response(_ request: CLIControl.Request) throws -> CLIControl.Response {
        do {
            try CLIControlPolicy.validate(request)
            let result = try CLIControl.send(request, to: CLIControl.socketURL(
                home: FileManager.default.homeDirectoryForCurrentUser, appName: BuildChannel.appName))
            guard result.ok else { throw CLIError(result.message, code: result.code) }
            return result
        } catch let error as CLIControlFailure { throw CLIError(error.message, code: error.code) }
    }
    static func execute(_ request: CLIControl.Request, options: CLIOptions) throws {
        let reply = try response(request)
        let result = try reply.result.map { try JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) }
        if options.json {
            try ClaudeBarCLI.printJSON(["ok": true, "message": reply.message, "channel": reply.channel,
                                       "command": request.command, "result": result ?? NSNull()])
            return
        }
        let terminal = CLITerminal.current(options)
        let body = result as? [String: Any] ?? [:]
        var rows: [String] = []
        if let providers = body["providers"] as? [[String: Any]] {
            for provider in providers {
                rows.append(terminal.heading("\(string(provider["agent"]).uppercased()) / \(string(provider["name"]))"))
                rows.append("ID \(string(provider["id"])) · active \(string(provider["active"])) · capture \(string(provider["capture"]))")
                rows += terminal.table(headers: ["MODEL", "ID", "ACTIVE"],
                    rows: (provider["models"] as? [[String: Any]] ?? []).map {
                        [string($0["name"]), string($0["id"]), string($0["active"])]
                    }, weights: [45, 45, 10])
            }
            if providers.isEmpty { rows.append("No configured providers") }
        } else if let connectors = body["connectors"] as? [[String: Any]] {
            rows.append(terminal.heading("CONNECTOR CONTROL INVENTORY"))
            rows += terminal.table(headers: ["NAME", "KIND", "STATE", "CONTROL", "ID"], rows: connectors.map {
                [string($0["name"]), string($0["kind"]), string($0["enabled"]), string($0["controllable"]), string($0["id"])]
            }, weights: [25, 10, 10, 10, 45])
            rows.append("Use --json for complete IDs; native-only items cannot be toggled")
        } else if let nodes = body["nodes"] as? [[String: Any]] {
            rows.append(terminal.heading("VPN NODES / \(string(body["source"]).uppercased())"))
            rows += terminal.table(headers: ["NODE", "SELECTED", "DELAY ms"], rows: nodes.map {
                [string($0["name"]), string($0["selected"]), string($0["delayMs"])]
            }, weights: [65, 15, 20])
            for group in body["groups"] as? [[String: Any]] ?? [] {
                rows.append(terminal.heading("GROUP / \(string(group["name"]))"))
                rows.append("TYPE \(string(group["type"])) · selected \(string(group["selected"]))")
                rows += (group["nodes"] as? [String] ?? []).map { "  " + CLITerminal.clean($0) }
            }
        } else {
            rows.append(terminal.paint(CLITerminal.clean(reply.message + " [" + reply.channel + "]"), "38;5;82"))
            rows += body.keys.sorted().map { "\(CLITerminal.clean($0)): \(string(body[$0]))" }
        }
        print(rows.map { $0.contains("\u{1B}[") ? $0 : CLITerminal.fit($0, terminal.width, pad: false) }.joined(separator: "\n"))
    }
    private static func string(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "N/A" }
        return CLITerminal.clean(String(describing: value))
    }
}
