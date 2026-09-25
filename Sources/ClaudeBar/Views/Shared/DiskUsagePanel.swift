import SwiftUI

/// Reuses the system sampler; opening this chart never walks the filesystem.
struct DiskUsagePanel: View {
    private let sampler = ProcessSampler.shared

    var body: some View {
        let total = sampler.host.diskTotal
        let used = min(sampler.host.diskUsed, total)
        let free = total - used
        let fraction = total > 0 ? Double(used) / Double(total) : 0
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                InstrumentBadge(kind: .disk, tint: Theme.Ink.cursor)
                Text("启动磁盘空间").font(Theme.Font.displayHero)
            }
            if total <= 1 {
                Text("正在读取磁盘容量…").foregroundColor(Theme.textSecondary)
            } else {
                HStack(spacing: 24) {
                    ZStack {
                        Circle().stroke(Theme.hairline, lineWidth: 14)
                        Circle().trim(from: 0, to: fraction)
                            .stroke(Theme.chartPurple, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 3) {
                            RollingNumberText(String(format: "%.0f%%", fraction * 100)).font(Theme.Font.tileValue)
                            Text("已使用").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                        }
                    }.frame(width: 126, height: 126).padding(8)
                    VStack(alignment: .leading, spacing: 14) {
                        metric("已用", bytes: used, color: Theme.chartPurple)
                        metric("可用", bytes: free, color: Theme.textSecondary)
                        metric("总容量", bytes: total, color: Theme.textPrimary)
                    }
                }
                Text("显示系统报告的整体空间。APFS 共享空间、快照与可清除空间可能影响其他工具的统计口径。")
                    .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            }
        }
        .padding(22).frame(width: 370)
        .background(Theme.cardSurface)
    }

    private func metric(_ title: String, bytes: UInt64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.Font.caption).foregroundColor(color)
            RollingNumberText(ProcessSampler.Snapshot(memoryBytes: bytes).memoryLabel)
                .font(Theme.Font.chromeEmph).monospacedDigit()
        }
    }
}
