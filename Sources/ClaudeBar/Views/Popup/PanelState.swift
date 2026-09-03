import SwiftUI
import Observation

/// Popup panel UI state: toast feedback.
/// One instance owned by the popup shell and passed to panel subviews.
@Observable @MainActor
final class PanelState {
    var feedbackMessage: String? = nil
    /// Monotonic token bumping on each showFeedback — drives the auto-dismiss
    /// .task(id:) in the shell without holding a Timer anywhere.
    var feedbackToken = 0

    func showFeedback(_ message: String) {
        feedbackToken += 1
        withAnimation(Theme.Animation.smooth) { feedbackMessage = message }
    }
}
