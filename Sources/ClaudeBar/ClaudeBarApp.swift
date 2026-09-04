import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var mainWindowController: MainWindowController?
    private var providerStore: ProviderStore?
    private var codexProviderStore: CodexProviderStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .regular: the app has a Dock icon, standard app menu, and proper
        // window management for the new main window. The menu-bar status item
        // and its non-activating popup panel work regardless of this policy.
        NSApp.setActivationPolicy(.regular)

        let store = ProviderStore()
        providerStore = store
        let codexStore = CodexProviderStore()
        codexProviderStore = codexStore
        store.peer = codexStore
        codexStore.claudePeer = store
        codexStore.load()

        let controller = MenuBarController(providerStore: store, codexProviderStore: codexStore)
        controller.setup()
        menuBarController = controller

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

        store.refresh()

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
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        default:
            break
        }
    }

    @objc private func resumeSession(_ note: Notification) {
        guard let pid = note.userInfo?["pid"] as? Int,
              let session = providerStore?.sessions.first(where: { $0.pid == pid }) else { return }
        TerminalLauncher.resumeClaudeSession(cwd: session.cwd, sessionId: session.sessionId)
    }

    @objc private func showMainWindow() {
        mainWindowController?.showWindow()
    }

    /// Handle widget tap → show the menu panel.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "claudebar" {
                menuBarController?.showPanel()
            }
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
