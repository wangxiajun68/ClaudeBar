import SwiftUI

/// Compact vector controls; each fan toggles independently.
struct CompactFanPair: View {
    let fans: [FanInfo]
    /// The pair's resting hue — the fan tile's own accent.
    ///
    /// The blades used to be `Theme.textSecondary` at rest: a neutral grey that
    /// left the two rotors reading as greyscale photographs pasted onto a
    /// coloured card, and that could not answer the pointer in the card's own
    /// language. Taking the tile's hue puts them in the same family as the five
    /// marks around them, whose outlines are all drawn in that hue.
    ///
    /// Only the *colour* changed here — the rotors' size, spacing, captions and
    /// artwork are exactly what they were. A fan held above the system's request
    /// still switches to amber, so the override is never quieter than the mark
    /// above it.
    var restingTint: Color = Theme.textSecondary
    var onToggle: (FanInfo) -> Void = { _ in }

    private var shown: [FanInfo] {
        fans.isEmpty ? [] : Array(fans.prefix(2))
    }

    var body: some View {
        HStack(spacing: 14) {
            if shown.isEmpty {
                // A Mac with no fans (or without the helper) still gets the pair's
                // footprint, dimmed: an empty slot is a fact about the machine.
                LucideRotor(rpm: 0, maxRPM: 1, tint: restingTint, forced: false, size: 64, artwork: nil)
                    .opacity(0.4)
            } else {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, fan in
                    Button {
                        onToggle(fan)
                    } label: {
                        VStack(spacing: 3) {
                            LucideRotor(
                                rpm: fan.rpm,
                                maxRPM: fan.maxRPM,
                                tint: bladeTint(fan),
                                forced: !fan.mode.isAutomatic,
                                size: 64,
                                artwork: nil
                            )
                            Text(shortName(fan, index: index))
                                .font(.system(size: 8, weight: .medium, design: .rounded))
                                .foregroundColor(fan.mode.isAutomatic ? Theme.textTertiary() : bladeTint(fan))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.borderless)
                    .help(help(fan))
                    .accessibilityLabel(help(fan))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortName(_ fan: FanInfo, index: Int) -> String {
        let raw = fan.name.trimmingCharacters(in: .whitespaces)
        if raw.localizedCaseInsensitiveContains("left") || raw.contains("左") { return "左" }
        if raw.localizedCaseInsensitiveContains("right") || raw.contains("右") { return "右" }
        return fans.count == 1 ? "风扇" : "\(index + 1)"
    }

    private func help(_ fan: FanInfo) -> String {
        if fan.mode.isAutomatic {
            return "\(fan.name) 自动 \(fan.rpm) rpm · 点击切换最大转速"
        }
        return "\(fan.name) 手动 \(fan.rpm) / \(fan.maxRPM) rpm · 点击恢复自动"
    }

    /// Automatic cooling follows the tile's hue; an explicit override is amber.
    /// The same amber the tile's header and wash take under an override, so the
    /// whole card turns together rather than the blades disagreeing with the
    /// badge above them.
    private func bladeTint(_ fan: FanInfo) -> Color {
        if !fan.mode.isAutomatic { return Theme.chartAmber }
        return restingTint
    }
}
