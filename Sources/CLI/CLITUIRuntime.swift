import Foundation
import AppKit
import Darwin

/// At most one outstanding sample and one explicitly submitted control request.
private final class CLITUIMailbox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    func put(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
    func take() -> Value? { lock.lock(); defer { lock.unlock() }; let result = value; value = nil; return result }
}

private final class CLITUISession {
    private var original = termios()
    private var active = false
    init() throws {
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw CLIError("Cannot read terminal settings", code: 1) }
    }
    func enter(mouse: Bool) throws {
        var raw = original
        cfmakeraw(&raw)
        raw.c_lflag |= UInt(ISIG) // Ctrl-C continues through the normal signal cleanup path.
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { throw CLIError("Cannot enter interactive terminal", code: 1) }
        active = true
        ClaudeBarCLI.write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?2004h" + Self.mouse(mouse))
    }
    static func mouse(_ enabled: Bool) -> String {
        enabled ? "\u{1B}[?1000h\u{1B}[?1006h" : "\u{1B}[?1000l\u{1B}[?1006l"
    }
    func leave() {
        guard active else { return }; active = false
        ClaudeBarCLI.write(Self.mouse(false) + "\u{1B}[?2004l\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
    }
    deinit { leave() }
}

enum CLITUIRuntime {
    nonisolated(unsafe) private static var suspendRequested = false

    @MainActor static func run(_ options: CLIOptions) throws {
        let terminal = try CLITUISession()
        try terminal.enter(mouse: true)
        defer { terminal.leave() }
        let previousSuspend = signal(SIGTSTP) { _ in CLITUIRuntime.suspendRequested = true }
        defer { signal(SIGTSTP, previousSuspend) }
        let samples = CLITUIMailbox<CLIFrame>()
        let commands = CLITUIMailbox<Result<CLIControl.Response, Error>>()
        let sampleQueue = DispatchQueue(label: "com.claudebar.cli.tui.sample", qos: .utility)
        let commandQueue = DispatchQueue(label: "com.claudebar.cli.tui.control", qos: .userInitiated)
        var state = CLITUIState(command: options.command == "models" && options.argument == "usage" ? "usage" : options.command)
        var input = CLITUIInput(), diff = CLITUIDiff()
        var latest: CLIFrame?, sampling = false, commandBusy = false, done = false
        var nextSample = 0.0, lastInput = 0.0, sampleCount = 0
        var lastSize = "", dirty = true
        func submit(_ draft: String) throws {
            guard !commandBusy else { throw CLIError("A command is still running; query its result before retrying") }
            guard options.snapshotPath == nil else { throw CLIError("Archived snapshot views cannot control the running application") }
            let parsed = try CLIOptions.parse(CLITUIState.arguments(draft))
            guard let request = parsed.controlRequest, !parsed.watch, parsed.snapshotPath == nil else {
                throw CLIError("Use a control command, e.g. vpn preview, pv catalog or cn list; lifecycle commands belong in the shell")
            }
            try CLIControlPolicy.validate(request)
            commandBusy = true; state.notice = "Running: " + draft
            commandQueue.async {
                commands.put(Result { try CLIControl.send(request, to: CLIControl.socketURL(
                    home: FileManager.default.homeDirectoryForCurrentUser, appName: BuildChannel.appName)) })
            }
        }
        while !done && !ClaudeBarCLI.interrupted {
            if suspendRequested {
                suspendRequested = false; terminal.leave()
                signal(SIGTSTP, SIG_DFL); raise(SIGTSTP)
                signal(SIGTSTP) { _ in CLITUIRuntime.suspendRequested = true }
                try terminal.enter(mouse: state.mouse); diff.reset(); dirty = true
            }
            let now = ProcessInfo.processInfo.systemUptime
            if let frame = samples.take() {
                latest = frame; state.receive(frame); sampling = false; sampleCount += 1; dirty = true
            }
            if let result = commands.take() {
                commandBusy = false
                switch result {
                case .success(let reply):
                    state.notice = reply.ok ? reply.message : "Failed: " + reply.message
                    var detail = [reply.ok ? "COMMAND RESULT" : "COMMAND FAILED", reply.message, "Channel: \(reply.channel)", ""]
                    if let json = reply.result, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed),
                       let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
                       let text = String(data: data, encoding: .utf8) { detail += text.components(separatedBy: "\n") }
                    if state.receiveCatalog(reply) { nextSample = 0; dirty = true; continue }
                    state.modal = Array(detail.prefix(10000)) + (detail.count > 10000 ? ["Result truncated at 10000 lines; use --json from the shell for complete output"] : []); state.modalOffset = 0
                case .failure(let error): state.notice = "Failed: " + String(describing: error)
                }
                nextSample = 0; dirty = true
            }
            let size = CLITerminal.current(options)
            let sizeKey = "\(size.width)x\(size.height)"
            if sizeKey != lastSize { lastSize = sizeKey; dirty = true }
            if dirty {
                let output = diff.draw(state.screen(options: options, terminal: size), width: size.width)
                if !output.isEmpty { ClaudeBarCLI.write(output) }
                dirty = false
            }
            if options.samples.map({ sampleCount >= $0 }) == true { break }
            if !sampling && now >= nextSample {
                sampling = true; nextSample = now + options.interval
                var focused = options; focused.command = state.page
                let sampleOptions = focused
                let pids = NSRunningApplication.runningApplications(withBundleIdentifier: BuildChannel.bundleID).map { Int($0.processIdentifier) }
                sampleQueue.async { samples.put(ClaudeBarCLI.readFrame(sampleOptions, processIDs: pids)) }
            }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let available = poll(&descriptor, 1, 40)
            var events: [CLITUIEvent] = []
            if available > 0 && descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { break }
            if available > 0 && descriptor.revents & Int16(POLLIN) != 0 {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count == 0 { break }
                if count > 0 { events = input.feed(Array(buffer.prefix(count))); lastInput = now }
            } else if now - lastInput >= 0.08 { events = input.feed([], flushEscape: true) }
            let bodyHeight = max(1, size.height - 7)
            for event in events {
                dirty = true
                if let editor = state.editing {
                    switch event {
                    case .escape: state.editing = nil; state.draft = ""
                    case .backspace: if !state.draft.isEmpty { state.draft.removeLast() }
                    case .text(let text), .paste(let text): if state.draft.utf8.count + text.utf8.count <= 4096 { state.draft += CLITerminal.clean(text) }
                    case .enter:
                        let draft = state.draft; state.editing = nil; state.draft = ""
                        if editor == "/" {
                            var viewport = state.viewports[state.page] ?? .init(); viewport.query = draft
                            viewport.offset = 0; viewport.top = nil; viewport.selected = nil
                            state.viewports[state.page] = viewport
                        } else {
                            do {
                                try submit(draft)
                            } catch { state.notice = "Failed: " + String(describing: error) }
                        }
                    default: break
                    }
                    continue
                }
                if state.modal != nil {
                    switch event {
                    case .escape, .enter: state.modal = nil
                    case .up, .text("k"): state.modalOffset -= 1
                    case .down, .text("j"): state.modalOffset += 1
                    case .pageUp: state.modalOffset -= bodyHeight
                    case .pageDown: state.modalOffset += bodyHeight
                    case .home, .text("g"): state.modalOffset = 0
                    case .end, .text("G"): state.modalOffset = max(0, (state.modal?.flatMap { CLITUIState.wrap($0, width: max(1, size.width - 1)) }.count ?? 0) - bodyHeight)
                    case .mouse(let code, _, _, let release): if state.mouse && !release { state.modalOffset += code == 64 ? -3 : code == 65 ? 3 : 0 }
                    case .text("q"): done = true
                    case .text("m"): state.mouse.toggle(); ClaudeBarCLI.write(CLITUISession.mouse(state.mouse))
                    default: break
                    }
                    continue
                }
                let rows = state.rows(options: options, terminal: CLITUIState.bodyTerminal(size))
                var viewport = state.viewports[state.page] ?? .init()
                var nextPage: String?
                switch event {
                case .text("q"): done = true
                case .text(" "): state.togglePause(latest: latest)
                case .text("m"):
                    state.mouse.toggle(); ClaudeBarCLI.write(CLITUISession.mouse(state.mouse))
                case .text("r"):
                    let query = ["models": "pv cat" + (options.agent.map { " -a " + $0 } ?? ""), "vpn": "vpn pv", "connectors": "cn ls"][state.page]
                    if let query { do { try submit(query) } catch { state.notice = "Failed: " + String(describing: error) } }
                    else { nextSample = 0 }
                case .text("?"): state.modal = CLITUIState.help; state.modalOffset = 0
                case .text("/"), .text(":"):
                    state.editing = event == .text("/") ? "/" : ":"
                    state.draft = state.editing == "/" ? viewport.query : ""
                case .up, .text("k"): viewport.move(-1, rows: rows, height: bodyHeight)
                case .down, .text("j"): viewport.move(1, rows: rows, height: bodyHeight)
                case .pageUp: viewport.move(-bodyHeight, rows: rows, height: bodyHeight)
                case .pageDown: viewport.move(bodyHeight, rows: rows, height: bodyHeight)
                case .home, .text("g"): viewport.move(-rows.count, rows: rows, height: bodyHeight)
                case .end, .text("G"): viewport.move(rows.count, rows: rows, height: bodyHeight)
                case .enter:
                    if let row = rows.first(where: { $0.id == viewport.selected }) {
                        state.modal = row.detail.isEmpty ? [CLITUIState.plain(row.text)] : row.detail; state.modalOffset = 0
                    }
                case .tab, .right, .left:
                    let index = CLITUIState.pages.firstIndex(of: state.page) ?? 0
                    let delta = event == .left ? -1 : 1
                    nextPage = CLITUIState.pages[(index + delta + CLITUIState.pages.count) % CLITUIState.pages.count]
                case .text(let number): if let index = Int(number), (1...7).contains(index) { nextPage = CLITUIState.pages[index - 1] }
                case .mouse(let code, _, let y, let release):
                    if state.mouse && !release {
                        if code == 64 || code == 65 { viewport.scroll(code == 64 ? -3 : 3, rows: rows, height: bodyHeight) }
                        else if code == 0 && y >= 5 && y < 5 + bodyHeight {
                            let index = viewport.offset + y - 5
                            if rows.indices.contains(index) { viewport.selected = rows[index].id }
                        }
                    }
                case .escape: viewport.query = ""; viewport.top = nil; viewport.offset = 0
                default: break
                }
                state.viewports[state.page] = viewport
                if let nextPage { state.page = nextPage; nextSample = 0 }
            }
        }
        if ClaudeBarCLI.interrupted { throw CLIError("Interrupted", code: 130) }
    }
}
