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
