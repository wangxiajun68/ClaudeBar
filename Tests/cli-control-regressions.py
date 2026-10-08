#!/usr/bin/env python3
"""Run the production CLI router and Unix transport against isolated effect adapters."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
fixtures = r'''
import Foundation
import Darwin
func precondition(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL \(file):\(line) \(message())\n".utf8))
        exit(1)
    }
}
func preconditionFailure(_ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) -> Never {
    FileHandle.standardError.write(Data("FAIL \(file):\(line) \(message())\n".utf8))
    exit(1)
}

struct TestModel { var id = UUID(); var name: String }
struct TestProvider {
    var id = UUID(); var name: String; var models: [TestModel]
    var activeModelID: UUID?; var captureEnabled = false
    var apiKey = "SECRET-NEVER-EXPORT"; var baseURL = "SECRET-ENDPOINT"
    var activeModel: TestModel? { models.first { $0.id == activeModelID } ?? models.first }
}
@MainActor class ProviderStore {
    var providers = [TestProvider(name: "Alpha", models: [.init(name: "First"), .init(name: "Second")])]
    var activeProviderID: UUID?; var errorMessage: String?; var published = 0
    var activeProvider: TestProvider? { providers.first { $0.id == activeProviderID } }
    func activateModel(providerID: UUID, modelID: UUID) {
        activeProviderID = providerID; providers[0].activeModelID = modelID
    }
    func restoreOfficial() { activeProviderID = nil }
    func setCaptureEnabled(providerID: UUID, enabled: Bool) { providers[0].captureEnabled = enabled }
    func publishCLISnapshot() { published += 1 }
}
@MainActor final class CodexProviderStore: ProviderStore {
    var proxyRunning = false; var proxyIsRequiredByCaptureOrBridge = false; var delay = false
    var activationStarted = false
    private var activationWaiter: CheckedContinuation<Void, Never>?
    func activateForCLI(providerID: UUID, modelID: UUID) async throws {
        if delay {
            activationStarted = true
            await withCheckedContinuation { activationWaiter = $0 }
            activationStarted = false
        }
        try Task.checkCancellation(); activateModel(providerID: providerID, modelID: modelID)
    }
    func releaseActivation() { activationWaiter?.resume(); activationWaiter = nil }
    func startProxy() -> Bool { proxyRunning = true; return true }
    func stopProxy() { proxyRunning = false }
}
enum AppearanceMode: String { case light, dark }
enum TokenUnitStyle: String { case chinese, metric }
@MainActor final class AppPreferences {
    static let shared = AppPreferences()
    var performanceMode = false; var vpnEnabled = false; var vpnSystemProxyEnabled = false
    var vpnTunEnabled = false; var vpnMixedPort = 12345; var vpnGuardEnabled = false
    var codexRoutingEnabled = false; var appearance = AppearanceMode.dark
    var tokenUnitStyle = TokenUnitStyle.metric; var weatherCity = ""
}
@MainActor final class VpnManager {
    static let shared = VpnManager()
    enum State { case idle, running, failed(String), missingCore }
    struct Node { var name: String; var delay: Int? }
    struct Group { var name: String; var type: String; var current: String; var nodes: [String] }
    var state = State.idle; var isRunning = false; var effects = 0
    var proxies = [Node(name: "Tokyo", delay: 15), Node(name: "Paris", delay: 25)]
    var groups = [Group(name: "Main", type: "Selector", current: "Tokyo", nodes: ["Tokyo", "Paris"])]
    var liveLeafName = "Tokyo"; var primaryGroup: Group? { groups.first }
    func refreshProxies() async {}
    func selectNode(group: String, node: String) async -> Bool { effects += 1; liveLeafName = node; return true }
    func testDelay(node: String) async -> Int? { effects += 1; return 25 }
    func syncRuntime() { effects += 1; isRunning = AppPreferences.shared.vpnEnabled; state = isRunning ? .running : .idle }
    func reloadConfig() { effects += 1; isRunning = AppPreferences.shared.vpnEnabled; state = isRunning ? .running : .idle }
}
@MainActor final class VpnSubscriptionStore {
    static let shared = VpnSubscriptionStore(); var activeID: UUID? = UUID()
    struct Group { var name: String; var nodes: [String] }
    struct Preview { var proxyNames: [String]; var groups: [Group] }
    func previewAsync(for id: UUID) async -> Preview { .init(proxyNames: ["Tokyo"], groups: [.init(name: "Main", nodes: ["Tokyo"])]) }
}
@MainActor final class VpnProxyGuard {
    static let shared = VpnProxyGuard(); var effects = 0
    func start() { effects += 1 }; func stop() { effects += 1 }
}
@MainActor enum VpnSystemProxyController {
    static var effects = 0
    static func applySystemProxy(port: Int) { effects += 1 }
    static func clearSystemProxyAsync() { effects += 1 }
}
enum ConnectorBatchAction { case enable, disable, remove }
struct ConnectorRecord {
    enum Kind: String { case mcp }; enum Platform: String { case claude }
    enum Capability { case state, none }
    var id: String; var name: String; var kind = Kind.mcp; var platforms = [Platform.claude]
    var enabled: Bool? = true; var batchCapability = Capability.state; var canRemove = true
    var environment = "SECRET-ENVIRONMENT"
}
@MainActor final class ConnectorManager {
    static let shared = ConnectorManager(); var hasScanned = false; var effects = 0
    var records = [ConnectorRecord(id: "c-1", name: "Search"), ConnectorRecord(id: "c-2", name: "Native", batchCapability: .none)]
    struct Outcome { var failures: [String] = []; var hasWork = true; var cursorCommands = 0; var skipped = 0 }
    func refresh(projectPath: String?) async { hasScanned = true }
    func batch(_ action: ConnectorBatchAction, over: [ConnectorRecord], projectPath: String?) async -> Outcome {
        effects += 1; return .init()
    }
}
@MainActor final class WeatherStore { static let shared = WeatherStore(); var effects = 0; func refreshCityForCLI() { effects += 1 } }
@main struct Regression {
    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(condition(), "Control fixture did not reach the expected state")
    }
    @MainActor static func main() async throws {
        let store = ProviderStore(), codex = CodexProviderStore()
        let service = CLICommandService(store: store, codex: codex, presentation: {
            ["mode": AppPreferences.shared.performanceMode ? "performance" : "desktop"]
        })
        func request(_ command: String, _ arguments: [String], agent: String? = nil,
                     provider: String? = nil, model: String? = nil, group: String? = nil,
                     confirmed: Bool? = nil) -> CLIControl.Request {
            .init(command: command, arguments: arguments, agent: agent, provider: provider,
                  model: model, group: group, confirmed: confirmed)
        }
        func check(_ command: String, _ arguments: [String], ok: Bool = true, agent: String? = nil,
                   provider: String? = nil, model: String? = nil, group: String? = nil,
                   confirmed: Bool? = nil) async -> CLIControl.Response {
            let reply = await service.execute(request(command, arguments, agent: agent, provider: provider,
                                                      model: model, group: group, confirmed: confirmed))
            precondition(reply.ok == ok, "\(command) \(arguments) \(reply.message)")
            precondition(!(reply.result ?? "").contains("SECRET"))
            return reply
        }
        _ = await check("providers", ["catalog"])
        _ = await check("providers", ["use", "Alpha"], model: "Second")
        precondition(store.activeProviderID == store.providers[0].id && store.providers[0].activeModelID == store.providers[0].models[1].id)
        _ = await check("models", ["use", "First"])
        _ = await check("providers", ["capture", "Alpha", "on"])
        precondition(store.providers[0].captureEnabled)
        let before = store.providers[0].activeModelID
        store.providers[0].models.append(.init(name: "First"))
        _ = await check("models", ["use", "First"], ok: false)
        precondition(store.providers[0].activeModelID == before)
        _ = await check("models", ["use", store.providers[0].models[0].id.uuidString])
        _ = await check("providers", ["official"]); precondition(store.activeProviderID == nil)
        _ = await check("models", ["use", "First"], ok: false)
        _ = await check("providers", ["use", "Alpha"], agent: "codex", model: "Second")
        precondition(codex.activeProviderID == codex.providers[0].id)
        _ = await check("providers", ["use", "Alpha"], ok: false, agent: "cursor")
        codex.delay = true
        let pending = Task { await service.execute(request("models", ["use", "First"], agent: "codex")) }
        await waitUntil { codex.activationStarted }
        _ = await check("mode", ["status"])
        _ = await check("providers", ["official"], ok: false)
        codex.releaseActivation()
        let pendingReply = await pending.value; precondition(pendingReply.ok)
        codex.delay = false
        _ = await check("mode", ["performance"]); precondition(AppPreferences.shared.performanceMode)
        _ = await check("mode", ["desktop"]); precondition(!AppPreferences.shared.performanceMode)
        _ = await check("config", ["set", "appearance", "light"])
        _ = await check("config", ["set", "weather-city", "Shanghai"])
        _ = await check("config", ["set", "api-key", "SECRET"], ok: false)
        precondition(WeatherStore.shared.effects == 1 && AppPreferences.shared.appearance == .light)
        _ = await check("proxy", ["start"]); precondition(codex.proxyRunning)
        codex.proxyIsRequiredByCaptureOrBridge = true
        _ = await check("proxy", ["stop"], ok: false); precondition(codex.proxyRunning)
        codex.proxyIsRequiredByCaptureOrBridge = false
        _ = await check("proxy", ["stop"]); precondition(!codex.proxyRunning)
        _ = await check("vpn", ["preview"])
        _ = await check("vpn", ["nodes"])
        _ = await check("connectors", ["list"])
        if BuildChannel.allowsSystemIntegration {
            _ = await check("vpn", ["start"]); precondition(VpnManager.shared.isRunning)
            _ = await check("vpn", ["select", "Invalid"], ok: false)
            _ = await check("vpn", ["select", "Paris"], group: "Main"); precondition(VpnManager.shared.liveLeafName == "Paris")
            _ = await check("vpn", ["test", "Paris"])
            _ = await check("vpn", ["restart"])
            _ = await check("vpn", ["proxy", "off"]); precondition(!AppPreferences.shared.vpnSystemProxyEnabled)
            _ = await check("vpn", ["tun", "on"]); precondition(AppPreferences.shared.vpnTunEnabled)
            _ = await check("config", ["set", "vpn-guard", "on"])
            _ = await check("vpn", ["stop"]); precondition(!VpnManager.shared.isRunning)
            _ = await check("connectors", ["disable", "Search"]); precondition(ConnectorManager.shared.effects == 1)
            _ = await check("connectors", ["disable", "Native"], ok: false)
            _ = await check("connectors", ["remove", "Search"], ok: false)
            _ = await check("connectors", ["remove", "Search"], confirmed: true)
            precondition(ConnectorManager.shared.effects == 2)
        } else {
            for args in [["start"], ["stop"], ["restart"], ["select", "Tokyo"], ["test", "Tokyo"], ["proxy", "on"], ["tun", "on"], ["reload"]] {
                _ = await check("vpn", args, ok: false)
            }
            for verb in ["enable", "disable", "remove"] { _ = await check("connectors", [verb, "Search"], ok: false, confirmed: true) }
            _ = await check("config", ["set", "vpn-guard", "on"], ok: false)
            precondition(!AppPreferences.shared.vpnEnabled && VpnManager.shared.effects == 0 && ConnectorManager.shared.effects == 0)
            precondition(VpnProxyGuard.shared.effects == 0 && VpnSystemProxyController.effects == 0)
        }
        var invalid = request("mode", ["performance"]); invalid.channel = "wrong-channel"
        let rejectedChannel = await service.execute(invalid); precondition(!rejectedChannel.ok)
        invalid.channel = BuildChannel.name; invalid.version = 99
        let rejectedVersion = await service.execute(invalid); precondition(!rejectedVersion.ok)
        let parsed = try CLIOptions.parse(["provider", "use", "Alpha", "--agent", "codex", "--model", "First"])
        precondition(parsed.controlRequest?.command == "providers" && parsed.controlRequest?.model == "First")
        let projectListing = try CLIOptions.parse(["connectors", "--project", "/tmp/project"])
        precondition(projectListing.controlRequest?.arguments == ["list"] && projectListing.controlRequest?.project == "/tmp/project")
        for (short, full) in CLIOptions.aliases {
            let alias = try CLIOptions.parse([short])
            precondition(alias.command == (full == "watch" ? "dashboard" : full))
        }
        for (command, aliases) in CLIOptions.subcommandAliases {
            for (short, full) in aliases {
                let targets: [String]
                switch full {
                case "use", "select", "test", "show", "enable", "disable": targets = ["off"]
                case "remove": targets = ["off", "-y"]
                case "capture": targets = ["off", "on"]
                case "set": targets = ["appearance", "dark"]
                case "proxy": targets = ["off"]
                default: targets = []
                }
                let alias = try CLIOptions.parse([command, short] + targets)
                precondition(alias.arguments.first == full)
                if targets.first == "off" { precondition(alias.arguments[1] == "off", "Expanded a target name") }
            }
        }
        for args in [["-w", "1"], ["w", "1"], ["watch", "1"], ["--watch", "1"], ["s", "-w", "1", "-a", "codex", "-j"]] {
            let watched = try CLIOptions.parse(args)
            precondition(watched.watch && watched.interval == 1)
        }
        let bareWatch = try CLIOptions.parse(["-w", "s", "-j"])
        precondition(bareWatch.command == "sessions" && bareWatch.watch && bareWatch.interval == 2 && bareWatch.json)
        let shortened = try CLIOptions.parse(["s", "-w", "1", "-i", "0.5", "-n", "2", "-l", "3", "-c", "-p", "-s", "busy"])
        precondition(shortened.interval == 0.5 && shortened.samples == 2 && shortened.limit == 3 && shortened.compact && shortened.plain && shortened.status == "busy")
        for args in [["-w", "0"], ["-w", "nan"], ["w", "inf"], ["-w", "-1"], ["-w", "3601"], ["vpn", "on", "-w", "1"], ["on", "-w", "1"], ["cn", "rm", "off"]] {
            do { _ = try CLIOptions.parse(args); preconditionFailure("Unsafe/invalid shorthand accepted") } catch {}
        }
        for args in [["connectors", "remove", "Search"], ["mode", "performance", "--watch"], ["vpn", "start", "--snapshot", "/tmp/fake"], ["start", "--mode", "wrong"]] {
            do { _ = try CLIOptions.parse(args); preconditionFailure("Invalid grammar accepted") } catch {}
        }
        // Use a short, private, temporary path (Darwin sun_path is bounded).
        let parent = URL(fileURLWithPath: "/tmp/mtx-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: parent) }
        let socketURL = parent.appendingPathComponent("control.sock")
        let server = CLIControlServer()
        try server.start(at: socketURL) { await service.execute($0) }
        var info = stat(); precondition(lstat(socketURL.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        precondition(lstat(parent.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        let socketReply = try await Task.detached { try CLIControl.send(.init(command: "providers", arguments: ["catalog"]), to: socketURL) }.value
        precondition(socketReply.ok && !(socketReply.result ?? "").contains("SECRET"))
        let delayedFirstByte = try await Task.detached { () throws -> CLIControl.Response in
            let fd = try CLIControl.connect(socketURL.path)
            defer { Darwin.close(fd) }
            try await Task.sleep(for: .milliseconds(75))
            let r = CLIControl.Request(command: "mode", arguments: ["status"])
            try CLIControl.write(JSONEncoder().encode(r), to: fd)
            return try JSONDecoder().decode(CLIControl.Response.self, from: CLIControl.read(fd, limit: CLIControl.maxResponseBytes))
        }.value
        precondition(delayedFirstByte.ok)
        let duplicate = CLIControlServer()
        do { try duplicate.start(at: socketURL) { await service.execute($0) }; preconditionFailure("Replaced live socket") } catch {}
        // Wrong protocol is rejected on the actual server, before the router runs.
        let wrongVersion = try await Task.detached { () throws -> CLIControl.Response in
            var r = CLIControl.Request(command: "mode", arguments: ["performance"]); r.version = 99
            return try CLIControl.send(r, to: socketURL)
        }.value
        precondition(!wrongVersion.ok && !AppPreferences.shared.performanceMode)
        // Disconnect clients and remove only the exact endpoint this server owns.
        codex.activeProviderID = nil; codex.delay = true
        let cancelled = Task.detached { () -> Bool in
            do { _ = try CLIControl.send(.init(command: "providers", arguments: ["use", "Alpha"], agent: "codex"), to: socketURL); return false }
            catch { return true }
        }
        await waitUntil { codex.activationStarted }
        server.stop(); precondition(!FileManager.default.fileExists(atPath: socketURL.path))
        codex.releaseActivation()
        let disconnected = await cancelled.value; precondition(disconnected)
        await waitUntil { !codex.activationStarted }
        precondition(codex.activeProviderID == nil)
        try Data("not a socket".utf8).write(to: socketURL)
        do { try duplicate.start(at: socketURL) { await service.execute($0) }; preconditionFailure("Replaced a file") } catch {}
        let preserved = try String(contentsOf: socketURL, encoding: .utf8); precondition(preserved == "not a socket")
        try FileManager.default.removeItem(at: socketURL)
        try duplicate.start(at: socketURL) { r in .init(id: "foreign-request", ok: true, code: 0, message: "wrong identity") }
        let identityRejected = await Task.detached { () -> Bool in
            do { _ = try CLIControl.send(.init(command: "mode", arguments: ["status"]), to: socketURL); return false } catch { return true }
        }.value
        precondition(identityRejected)
        try FileManager.default.removeItem(at: socketURL)
        try Data("replacement".utf8).write(to: socketURL)
        duplicate.stop()
        let replacement = try String(contentsOf: socketURL, encoding: .utf8)
        precondition(replacement == "replacement")
        print("PASS: \(BuildChannel.name) real router, grammar, privacy, isolation, mutation serialization, same-user transport and endpoint ownership")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='mtx-control-tests-') as temporary:
    folder = Path(temporary)
    fixture = folder / 'Adapters.swift'
    fixture.write_text(fixtures)
    sources = [root / ('Sources/Shared/' + name + '.swift') for name in ['BuildChannel', 'CLISnapshot', 'CLIControl', 'AppPresentation']]
    sources += [root / 'Sources/CLI/CLIOptions.swift', root / 'Sources/ClaudeBar/Utils/CLIControlServer.swift', root / 'Sources/ClaudeBar/Models/CLICommandService.swift', fixture]
    for channel in ['dev', 'release']:
        binary = folder / channel
        subprocess.run(['swiftc', '-O', '-parse-as-library', '-D', 'CLAUDEBAR_' + channel.upper(), *map(str, sources), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)
