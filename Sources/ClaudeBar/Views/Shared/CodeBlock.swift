import AppKit
import SwiftUI

/// A copyable monospace block — the one place the app renders a shell command.
///
/// Lifted out of `ProxyCurlExample`, which had the only copy of this styling;
/// a help page wants half a dozen of them and duplicating the surface six times
/// is how the next tweak lands in five of the six.
///
/// The "已复制" confirmation is local state on purpose: `FeedbackToast` lives in
/// the menu-bar popup's `PanelState` and is not reachable from a main-window
/// page.
struct CodeBlock: View {
    var title: String? = nil
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s6) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                    Text(title)
                        .font(Theme.Font.body)
                        .foregroundColor(Theme.textPrimary)
                    Spacer(minLength: Theme.Space.s8)
                    copyButton
                }
            }
            Text(code)
                .font(Theme.Font.console)
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.s12)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.cardFill(0.08)))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Theme.hairline, lineWidth: 1))
            if title == nil {
                HStack {
                    Spacer()
                    copyButton
                }
            }
        }
    }

    private var copyButton: some View {
        Button(copied ? "已复制" : "复制") { copy() }
            .font(Theme.Font.caption)
            .adaptiveGlassButton()
            .tint(Theme.Ink.codex)
            .fixedSize()
            .help("复制命令")
            .accessibilityLabel(copied ? "已复制" : "复制命令")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

// MARK: - Keycaps

/// One shortcut: the individual keys, then what they do.
///
/// `keys` arrives already split (`["⌘", "⇧", "A"]`). Help content is fixed, so
/// the split is written out as a literal rather than parsed at runtime — a
/// chord parser would be pure surface area for a table that never changes.
///
/// Keys are drawn as *shapes* (fill + hairline stroke), so they take the
/// neutral `cardFill` rather than a signal hue; the caption is text and takes
/// `Theme.textSecondary`, which is already ≥4.5:1.
struct KeycapRow: View {
    let keys: [String]
    let caption: String

    var body: some View {
        HStack(spacing: Theme.Space.s10) {
            HStack(spacing: 3) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(Theme.Font.captionMono)
                        .foregroundColor(Theme.textSecondary)
                        .frame(minWidth: 20)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                .fill(Theme.cardFill(0.08)))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                .strokeBorder(Theme.hairline, lineWidth: 1))
                }
            }
            .frame(minWidth: 78, alignment: .leading)
            Text(caption)
                .font(Theme.Font.bodySmall)
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(keys.joined()) \(caption)")
    }
}
