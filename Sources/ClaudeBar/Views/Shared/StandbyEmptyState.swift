import SwiftUI

/// Standby empty state — a quiet oscilloscope-style marker: `// no signals`
/// in mono type with a blinking block cursor. Used when a session list has
/// nothing to show; the restraint *is* the design.
struct StandbyEmptyState: View {
    var label: String = "no signals"
    /// Blink only while visible — a `.task` heartbeat toggling the cursor.
    @State private var cursorVisible = true

    var body: some View {
        HStack(spacing: 0) {
            Text("// \(label)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textTertiary(0.35))
            Text("▍")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.signal(isCursor: false).opacity(0.7))
                .opacity(cursorVisible ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityLabel("无活跃会话")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000)
                cursorVisible.toggle()
            }
        }
    }
}
