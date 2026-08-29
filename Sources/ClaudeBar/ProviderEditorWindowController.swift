import AppKit
import SwiftUI

/// Owns the provider-editor window's lifecycle: creation, reuse, close
/// bookkeeping. Extracted from MenuBarView so the popup view carries no
/// window-management state.
@MainActor
final class ProviderEditorWindowController {
    static let shared = ProviderEditorWindowController()

    private var window: NSWindow?
    private let delegate = Delegate()

    func show(store: ProviderStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Edit Providers — Axon"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ProviderEditorView(providerStore: store))
        window.delegate = delegate
        window.setFrameAutosaveName("ClaudeBarProviderEditor")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private final class Delegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            Task { @MainActor in
                ProviderEditorWindowController.shared.window = nil
            }
        }
    }
}
