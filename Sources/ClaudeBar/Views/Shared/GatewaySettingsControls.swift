import SwiftUI

/// Captions use the full row, so their length cannot push a numeric control
/// into a different column. The control lane is identical across all groups.
struct GatewaySettingRow<Control: View>: View {
    var title: String
    var caption: String = ""
    @ViewBuilder var control: () -> Control
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Text(title).font(Theme.Font.bodySmall).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                control().controlSize(.small).frame(width: 148, alignment: .trailing)
            }
            if !caption.isEmpty {
                Text(caption).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 20).padding(.vertical, 14)
            .accessibilityElement(children: .contain)
    }
}

/// Native steppers retain focus, keyboard and accessibility. A dedicated value
/// lane and reset slot keep single and triple digits aligned across suppliers.
struct GatewayNumberControl: View {
    var title: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var unit: String
    var onReset: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 8) {
            Text("\(value) \(unit)").font(Theme.Font.captionMono).monospacedDigit()
                .foregroundStyle(Theme.textPrimary).frame(width: 68, alignment: .trailing)
                .accessibilityHidden(true)
            Stepper(title, value: $value, in: range).labelsHidden().fixedSize()
                .accessibilityLabel(title).accessibilityValue("\(value) \(unit)")
            if let onReset {
                ActionIcon(symbol: "arrow.counterclockwise", tint: Theme.textSecondary, size: 24, action: onReset)
                    .help("恢复默认并发").accessibilityLabel("\(title) 恢复默认并发")
            } else {
                Color.clear.frame(width: 24, height: 24).accessibilityHidden(true)
            }
        }.fixedSize()
    }
}
