import SwiftUI
import Observation

/// Popup panel UI state: toast feedback + config-collapse persistence.
/// One instance owned by the popup shell and passed to panel subviews.
@Observable @MainActor
final class PanelState {
    var feedbackMessage: String? = nil
    /// Monotonic token bumping on each showFeedback — drives the auto-dismiss
    /// .task(id:) in the shell without holding a Timer anywhere.
    var feedbackToken = 0
    /// Collapse the model-config/provider area so sessions + usage get the
    /// full panel width. Persisted across launches.
    @ObservationIgnored var configCollapsed: Bool {
        didSet { UserDefaults.standard.set(configCollapsed, forKey: "configCollapsed") }
    }

    init() {
        configCollapsed = UserDefaults.standard.object(forKey: "configCollapsed") as? Bool ?? true
    }

    func showFeedback(_ message: String) {
        feedbackToken += 1
        withAnimation(Theme.Animation.smooth) { feedbackMessage = message }
    }
}
