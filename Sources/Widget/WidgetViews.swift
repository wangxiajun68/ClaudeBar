import SwiftUI
import WidgetKit

/// Minimal local copy of the main-app Theme tokens so the Widget (which
/// compiles as an independent appex target and cannot import Theme) stays
/// visually consistent with the main app. Mirrors the values in
/// `Sources/ClaudeBar/Theme/Theme.swift`.
private enum WidgetTheme {
    // Foundation (luminous dark, matching the main app's macOS 26 glass world)
    static let bgPrimary = Color(hex: 0x0D0D11)
    static let bgSecondary = Color(hex: 0x15151B)
    // Signals: soft blue = Claude Code
    static let accent = Color(hex: 0x4F8EF7)
    static let accentDim = Color(hex: 0x3A6FD1)
    static let claudeHi = Color(hex: 0x79ABF9)
    // Text
    static let textPrimary = Color(hex: 0xF5F5F7)
    static let textSecondary = Color(hex: 0xA1A1A6)
    static func textTertiary(_ opacity: Double = 0.4) -> Color { .white.opacity(opacity) }
    // Semantic
    static let statusBusy = Color(hex: 0x4F8EF7)
    static let statusIdle = Color(hex: 0x8A8F98)
    static let statusWarning = Color(hex: 0xE0A13C)
    static let statusError = Color(hex: 0xE46464)
    // Cursor identity (violet)
    static let cursorAccent = Color(hex: 0xA78BFA)
    // Surfaces
    static func cardFill(_ opacity: Double = 0.06) -> Color { .white.opacity(opacity) }

    /// Context-health color using the SAME thresholds as the main app (0.6 / 0.85).
    static func contextColor(_ ratio: Double) -> Color {
        if ratio < 0.6 { return statusBusy }
        if ratio < 0.85 { return statusWarning }
        return statusError
    }

    /// Hash-stable per-model gradient mirroring `Theme.barGradient(for:)`.
    static func barGradient(for model: String) -> LinearGradient {
        let c = barColor(for: model)
        return LinearGradient(colors: [c, c.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
    }

    static func barColor(for model: String) -> Color {
        let palette: [Color] = [
            Color(hex: 0x4F8EF7),
            Color(hex: 0xA78BFA),
            Color(hex: 0x46C58F),
            Color(hex: 0xE0A13C),
            Color(hex: 0xE46464),
        ]
        return palette[abs(model.hashValue) % palette.count]
    }
}

private extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: opacity)
    }
}

struct WidgetEntryView: View {
    let entry: WidgetEntry

    var body: some View {
        let s = entry.snapshot
        let isEmpty = s.todayTotalTokens == 0 && s.totalSessionCount == 0 && s.cursorSessions.isEmpty

        VStack(alignment: .leading, spacing: 0) {
            if isEmpty {
                Spacer()
                Text("等待数据...")
                    .font(.system(size: 14))
                    .foregroundColor(WidgetTheme.textTertiary())
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                // Row 1: Header + Token + Balance
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Axon")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(WidgetTheme.textSecondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(formatTokens(s.todayTotalTokens))
                                .font(.system(size: 28, weight: .semibold))
                                .monospacedDigit()
                                .foregroundColor(WidgetTheme.textPrimary)
                            Text("tokens")
                                .font(.system(size: 9))
                                .foregroundColor(WidgetTheme.textTertiary())
                        }
                    }
                    Spacer()
                    if let bal = s.balanceText {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("余额")
                                .font(.system(size: 9))
                                .foregroundColor(WidgetTheme.textTertiary())
                            Text("¥\(bal)")
                                .font(.system(size: 15, weight: .semibold))
                                .monospacedDigit()
                                .foregroundColor(WidgetTheme.accent.opacity(0.85))
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 10)

                // Row 2: Provider + Model
                HStack(spacing: 6) {
                    Circle()
                        .fill(WidgetTheme.accent)
                        .frame(width: 6, height: 6)
                    Text(s.activeProviderName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(WidgetTheme.textPrimary.opacity(0.7))
                    Text(s.activeModelName)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(WidgetTheme.textTertiary())
                        .lineLimit(1)
                    Spacer()
                    Text(relativeTime(s.updatedAt))
                        .font(.system(size: 9))
                        .foregroundColor(WidgetTheme.textTertiary(0.25))
                }
                .padding(.horizontal, 16).padding(.top, 8)

                // Model breakdown bars
                if s.modelBreakdown.count > 1 {
                    HStack(spacing: 2) {
                        ForEach(Array(s.modelBreakdown.prefix(5)), id: \.model) { m in
                            let ratio = s.todayTotalTokens > 0
                                ? CGFloat(m.totalTokens) / CGFloat(s.todayTotalTokens)
                                : 0
                            RoundedRectangle(cornerRadius: 2)
                                .fill(WidgetTheme.barGradient(for: m.model))
                                .frame(width: max(8, 260 * ratio))
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 16).padding(.top, 8)

                    // Model legend
                    HStack(spacing: 10) {
                        ForEach(Array(s.modelBreakdown.prefix(4)), id: \.model) { m in
                            HStack(spacing: 3) {
                                Circle().fill(WidgetTheme.barColor(for: m.model)).frame(width: 4, height: 4)
                                Text(truncateModel(m.model))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundColor(WidgetTheme.textTertiary(0.45))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 6)
                }

                // Sessions header + list
                if !s.sessions.isEmpty {
                    HStack {
                        Text("活跃会话")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(WidgetTheme.textTertiary())
                        Spacer()
                        let busy = s.sessions.filter { $0.status == "busy" }.count
                        Text("\(s.sessions.count) 个 · \(busy) 忙碌")
                            .font(.system(size: 9))
                            .foregroundColor(WidgetTheme.textTertiary(0.25))
                    }
                    .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)

                    ForEach(s.sessions.prefix(3), id: \.pid) { session in
                        sessionRow(session)
                    }
                }

                // Cursor sessions section
                if !s.cursorSessions.isEmpty {
                    HStack {
                        Image(systemName: "cursorarrow.rays")
                            .font(.system(size: 9))
                            .foregroundColor(WidgetTheme.textTertiary())
                        Text("CURSOR")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(WidgetTheme.textTertiary())
                        Spacer()
                        let active = s.cursorSessions.filter { $0.status == "active" }.count
                        Text("\(s.cursorSessions.count) · \(active)A")
                            .font(.system(size: 9))
                            .foregroundColor(WidgetTheme.textTertiary(0.25))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, s.sessions.isEmpty ? 10 : 6)
                    .padding(.bottom, 4)

                    ForEach(s.cursorSessions.prefix(3), id: \.composerId) { session in
                        cursorSessionRow(session)
                    }
                }

                Spacer(minLength: 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            WidgetTheme.bgPrimary
        }
    }

    // MARK: - Session Row

    private func sessionRow(_ s: WidgetSnapshot.SessionSummary) -> some View {
        let isBusy = s.status == "busy"
        return HStack(spacing: 8) {
            Circle()
                .fill(isBusy ? WidgetTheme.statusBusy : WidgetTheme.statusIdle.opacity(0.5))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(s.projectFolder.isEmpty ? "session-\(s.pid)" : s.projectFolder)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(WidgetTheme.textPrimary.opacity(0.8))
                    .lineLimit(1)
                if !s.currentActivity.isEmpty {
                    Text(s.currentActivity)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(WidgetTheme.textTertiary())
                        .lineLimit(1)
                }
            }

            Spacer()

            // Context bar
            if s.contextLimit > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(s.contextRatio * 100))%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(WidgetTheme.contextColor(s.contextRatio))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(WidgetTheme.cardFill(0.06))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(WidgetTheme.contextColor(s.contextRatio))
                                .frame(width: geo.size.width * min(s.contextRatio, 1.0))
                        }
                    }
                    .frame(width: 54, height: 3)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 3)
    }

    // MARK: - Cursor Session Row

    private func cursorSessionRow(_ s: WidgetSnapshot.CursorSessionSummary) -> some View {
        let isActive = s.status == "active"
        return HStack(spacing: 8) {
            Circle()
                .fill(isActive ? WidgetTheme.cursorAccent : WidgetTheme.statusIdle.opacity(0.5))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(s.projectFolder.isEmpty ? "cursor" : s.projectFolder)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(WidgetTheme.textPrimary.opacity(0.8))
                    .lineLimit(1)
                if !s.currentActivity.isEmpty {
                    Text(s.currentActivity)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(WidgetTheme.textTertiary())
                        .lineLimit(1)
                }
            }

            Spacer()

            // Context bar (percent-based for Cursor)
            if s.contextPercent >= 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(s.relativeUpdated)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(WidgetTheme.textTertiary())
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(WidgetTheme.cardFill(0.06))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(WidgetTheme.cursorAccent)
                                .frame(width: geo.size.width * min(s.contextRatio, 1.0))
                        }
                    }
                    .frame(width: 54, height: 3)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 3)
    }

    // MARK: - Helpers

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func truncateModel(_ name: String) -> String {
        if name.count > 16 { return String(name.prefix(16)) + "…" }
        return name
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}
