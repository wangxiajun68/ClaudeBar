import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var mainWindowController: MainWindowController?
    private var notchIslandController: NotchIslandController?
    private var providerStore: ProviderStore?
    private var codexProviderStore: CodexProviderStore?
    /// A widget tap that arrived before the menu-bar controller existed (see
    /// `application(_:open:)`). Replayed at the end of launch.
    private var pendingOpenURL = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .regular: the app has a Dock icon, standard app menu, and proper
        // window management for the new main window. The menu-bar status item
        // and its non-activating popup panel work regardless of this policy.
        NSApp.setActivationPolicy(.regular)
        AppearanceSync.apply()
        BatteryChargeController.shared.probe()
        // Touch the notification service before launch returns so its
        // `UNUserNotificationCenter` delegate is installed in time. The
        // singleton registers the delegate in its `init`, and nothing else here
        // reaches it synchronously: the first `post(...)` rides the async
        // session scan, whose main-actor publish cannot run before this method
        // returns. Apple's contract is explicit — a delegate assigned after
        // launch "might cause you to miss incoming notifications" — and the one
        // that matters is the banner tap that *launches* the app
        // (在终端继续 / 去确认 → `.resumeSession`), whose response would arrive
        // before the service existed. Creating it installs the delegate; the
        // authorization prompt stays behind its own build-channel gate.
        _ = NotificationService.shared

        let store = ProviderStore()
        providerStore = store
        let codexStore = CodexProviderStore()
        codexProviderStore = codexStore
        store.peer = codexStore
        codexStore.claudePeer = store
        codexStore.load()

        // VPN module: start the mihomo core if it was enabled last session,
        // and restore the system proxy if we took it over.
        if AppPreferences.shared.vpnEnabled {
            VpnManager.shared.syncRuntime()
            if AppPreferences.shared.vpnSystemProxyEnabled {
                VpnProxyGuard.shared.start()
            }
        } else {
            // A previous session may have died with the proxy still set. The
            // clear spawns one `networksetup` per service, so it runs off the
            // main thread — launch does not wait on it.
            VpnSystemProxyController.clearSystemProxyAsync()
        }

        // The menu bar's ↓/↑ strip is always on screen, and without a tunnel
        // the reading it carries is the machine's own throughput, so the
        // sampler starts with the app rather than with the VPN.
        SystemThroughput.shared.start()

        let controller = MenuBarController(providerStore: store, codexProviderStore: codexStore)
        controller.setup()
        menuBarController = controller

        let island = NotchIslandController(providerStore: store, codexStore: codexStore)
        island.start()
        notchIslandController = island

        let main = MainWindowController(providerStore: store, codexProviderStore: codexStore)
        mainWindowController = main
        main.showWindow()

        // The menu-bar popup's "open main window" button posts this notification.
        NotificationCenter.default.addObserver(
            self, selector: #selector(showMainWindow),
            name: .showMainWindow, object: nil)

        // Tapping an idle notification (or its Resume action) resumes the
        // session in a terminal.
        NotificationCenter.default.addObserver(
            self, selector: #selector(resumeSession(_:)),
            name: .resumeSession, object: nil)

        // `refresh()` calls `peer?.refreshQuota()`, and every reading — that
        // first one included — schedules the next poll from the reset instant
        // it carries (`QuotaPollScheduler`), so there is no poll to arm here.
        store.refresh()

        // Cursor's allowance reads the account directly (no login, no CLI), so
        // it has no reader in `store.refresh()` to piggyback on — arm its poll
        // and take the first reading here. `fetch()` refuses to probe more than
        // once per few seconds, so a popup `onAppear` racing this is harmless.
        CursorUsageStore.shared.start()
        CursorUsageStore.shared.refresh()

        ScreenshotHotKey.shared.startIfEnabled()

        // Fetches only when the saved preference already asks for a converted
        // cost display — the default 分列 mode makes no outbound request at all.
        ExchangeRate.shared.start()

        // Loads the saved price overrides and, only if a previous check has
        // aged past the weekly interval, proposes a fresh one in the background.
        // It never applies: a background job that changed a price on its own is
        // the one thing this feature must not do.
        ModelPriceCatalog.shared.autoCheckIfStale()

        // Re-read the login item so the Settings toggle reflects the system
        // rather than a remembered value. Also re-runs on every activation, so
        // a change made in System Settings shows up on return.
        LaunchAtLogin.shared.refresh()

        // A widget tap that launched this process was delivered before
        // `menuBarController` existed; open the panel now that it does.
        if pendingOpenURL {
            pendingOpenURL = false
            menuBarController?.showPanel()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(fanPermissionNeeded),
            name: .fanPermissionNeeded, object: nil)
    }

    /// 风扇调速需要 root；弹窗引导用户安装特权辅助工具或打开系统设置。
    @objc private func fanPermissionNeeded() {
        let alert = NSAlert()
        alert.messageText = "风扇调速需要管理员权限"
        alert.informativeText = "调整风扇转速需要安装 ClaudeBar 特权辅助工具（输入一次管理员密码）。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "安装辅助工具")
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            FanHelperInstaller.install()
        case .alertSecondButtonReturn:
            LaunchAtLogin.openLoginItemsSettings()
        default:
            break
        }
    }

    /// Posted from the notification-center delegate, which may run off main.
    ///
    /// The payload names the agent (`agent` / `sessionId` / `cwd` / `pid` /
    /// `inDesktop`) rather than only a pid, because a Cursor or Codex banner
    /// has no Claude pid to give — routing those through the Claude store was
    /// what left their 在终端继续 / 去确认 actions inert. A pid still wins
    /// when present: it points at the window already holding a *live* session,
    /// and the store only knows it through the pid.
    @objc private func resumeSession(_ note: Notification) {
        let info = note.userInfo ?? [:]
        guard let agent = info["agent"] as? String,
              let sessionId = info["sessionId"] as? String, !sessionId.isEmpty else { return }
        let cwd = info["cwd"] as? String ?? ""
        let pid = info["pid"] as? Int
        let inDesktop = info["inDesktop"] as? Bool ?? false
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                switch agent {
                case "cursor":
                    TerminalLauncher.openInCursor(cwd: cwd)
                case "codex":
                    TerminalLauncher.resumeCodexSession(cwd: cwd, sessionId: sessionId,
                                                        pid: pid, inDesktop: inDesktop)
                default:
                    let live = pid.flatMap { wanted in
                        self?.providerStore?.sessions.first { $0.pid == wanted }
                    }
                    TerminalLauncher.resumeClaudeSession(cwd: live?.cwd ?? cwd,
                                                         sessionId: live?.sessionId ?? sessionId,
                                                         pid: live.flatMap { $0.isAlive ? $0.pid : nil })
                }
            }
        }
    }

    @objc private func showMainWindow(_ note: Notification) {
        // Cross-surface entries name their destination on the same notification
        // (`userInfo["page"]`, optionally `userInfo["editor"]`) instead of
        // posting a second one: a fresh window's SwiftUI graph subscribes to
        // `NotificationCenter` only on its first display pass, ~50 ms after the
        // window is ordered front, so a trailing page post raced that
        // subscription and the window opened on whatever page it last
        // remembered. See `Notification.showMainWindow(page:editor:)`.
        guard let raw = note.userInfo?["page"] as? String,
              let page = AppPage(rawValue: raw) else {
            mainWindowController?.showWindow()
            return
        }
        let editor = note.userInfo?["editor"] as? Bool ?? false
        mainWindowController?.showWindow(on: editor ? .editor(page) : .page(page))
    }

    /// Handle widget tap → show the menu panel.
    ///
    /// Launch Services can deliver this **before** `applicationDidFinishLaunching`
    /// returns — AppKit's own documentation on the delegate ordering says so for
    /// the file-open form, and a widget tap is exactly the cold start that hits
    /// it. At that moment `menuBarController` does not exist yet, and the
    /// optional chain made the tap a silent no-op; the user's second tap
    /// worked, which is what made it look like the first one "didn't register".
    /// Park the request instead and replay it once the controller is up.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == BuildChannel.urlScheme {
            guard let menuBarController else {
                pendingOpenURL = true
                continue
            }
            menuBarController.showPanel()
        }
    }

    /// Re-open the main window if the user clicked the Dock icon while it was
    /// closed. The app stays alive after the window closes (status item runs).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindowController?.showWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Tear-down that has to happen while the process is still alive.
    ///
    /// There was no termination hook at all: quitting left the mihomo core
    /// running as an orphan (PPID 1) with the TUN marker and the system proxy
    /// still applied, and the next launch spawned a second core on the same
    /// ports. `VpnManager.reapOrphanCore()` covers the crash case; this covers
    /// the ordinary Quit menu item.
    func applicationWillTerminate(_ notification: Notification) {
        BatteryChargeController.shared.shutdown()
        SystemThroughput.shared.stop()
        // Fans pinned at max keep that target in the SMC after the process is
        // gone, and this app is the only thing that knows they were taken.
        FanMonitor.shared.adoptSystemControlOnQuit()
        // Detach the rate accessory first: it hangs off the status-bar button
        // and its `objectWillChange` sink can fire during the rest of teardown.
        menuBarController?.teardownVpnRateDisplay()
        if AppPreferences.shared.vpnEnabled {
            VpnManager.shared.stopCore()
        }
        // The core is being stopped, so any service still pointing at its
        // port is pointing at nothing: this is the quit that has to unset the
        // proxy, and `clearSystemProxy()` is synchronous exactly for it. The
        // async variant (everywhere else) would be racing the process exit,
        // and the launch-time branch above only recovers a *crashed* session,
        // not this clean one. It also restores the TUN DNS override and
        // removes its marker — those lived on too, until the next launch.
        VpnSystemProxyController.clearSystemProxy()
        ScreenshotHotKey.shared.stop()
    }
}

@main
struct ClaudeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
