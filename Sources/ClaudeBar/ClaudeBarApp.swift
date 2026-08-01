import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var providerStore: ProviderStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Must be .accessory so the status item's target/action works and the
        // app can receive mouse events without stealing focus from the terminal.
        NSApp.setActivationPolicy(.accessory)

        let store = ProviderStore()
        providerStore = store

        let controller = MenuBarController(providerStore: store)
        controller.setup()
        menuBarController = controller

        store.refresh()
    }

    /// Handle widget tap → show the menu panel.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "claudebar" {
                menuBarController?.showPanel()
            }
        }
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
