import SwiftUI
import WidgetKit

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
                    .foregroundColor(.white.opacity(0.35))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                // Row 1: Header + Token + Balance
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ClaudeBar")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(formatTokens(s.todayTotalTokens))
                                .font(.system(size: 28, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                            Text("tokens")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.35))
                        }
                    }
                    Spacer()
                    if let bal = s.balanceText {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("余额")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.35))
                            Text("¥\(bal)")
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundColor(.green.opacity(0.85))
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 10)

                // Row 2: Provider + Model
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(s.activeProviderName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                    Text(s.activeModelName)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                        .lineLimit(1)
                    Spacer()
                    Text(relativeTime(s.updatedAt))
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.25))
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
                                .fill(barColor(for: m.model))
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
                                Circle().fill(barColor(for: m.model)).frame(width: 4, height: 4)
                                Text(truncateModel(m.model))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.45))
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
                            .foregroundColor(.white.opacity(0.4))
                        Spacer()
                        let busy = s.sessions.filter { $0.status == "busy" }.count
                        Text("\(s.sessions.count) 个 · \(busy) 忙碌")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.25))
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
                            .foregroundColor(.white.opacity(0.4))
                        Text("CURSOR")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.4))
                        Spacer()
                        let active = s.cursorSessions.filter { $0.status == "active" }.count
                        Text("\(s.cursorSessions.count) · \(active)A")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.25))
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
            Color(white: 0.10)
        }
    }

    // MARK: - Session Row

    private func sessionRow(_ s: WidgetSnapshot.SessionSummary) -> some View {
        let isBusy = s.status == "busy"
        return HStack(spacing: 8) {
            Circle()
                .fill(isBusy ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(s.projectFolder.isEmpty ? "session-\(s.pid)" : s.projectFolder)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                if !s.currentActivity.isEmpty {
                    Text(s.currentActivity)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                        .lineLimit(1)
                }
            }

            Spacer()

            // Context bar
            if s.contextLimit > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(s.contextRatio * 100))%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(contextColor(s.contextRatio))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.06))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(contextColor(s.contextRatio))
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
        let accent: Color = Color(red: 0.62, green: 0.52, blue: 0.95)
        return HStack(spacing: 8) {
            Circle()
                .fill(isActive ? accent : Color.gray.opacity(0.4))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(s.projectFolder.isEmpty ? "cursor" : s.projectFolder)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                if !s.currentActivity.isEmpty {
                    Text(s.currentActivity)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                        .lineLimit(1)
                }
            }

            Spacer()

            // Context bar (percent-based for Cursor)
            if s.contextPercent >= 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(s.relativeUpdated)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.06))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(accent)
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

    private func contextColor(_ ratio: Double) -> Color {
        if ratio > 0.8 { return .orange }
        if ratio > 0.5 { return .yellow }
        return .green
    }

    private func barColor(for model: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.40, green: 0.58, blue: 0.95),
            Color(red: 0.30, green: 0.75, blue: 0.60),
            Color(red: 0.92, green: 0.62, blue: 0.40),
            Color(red: 0.78, green: 0.50, blue: 0.90),
            Color(red: 0.90, green: 0.50, blue: 0.55),
        ]
        let hash = abs(model.hashValue)
        return palette[hash % palette.count]
    }
}
