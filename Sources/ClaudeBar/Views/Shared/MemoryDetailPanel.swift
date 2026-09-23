import SwiftUI

struct MemoryDetailPanel: View {
    @State private var rows: [ProcessMemoryRow] = []
    @State private var loading = true
    @State private var failed = false
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("进程内存").font(Theme.Font.displayHero)
                Spacer()
                Button("刷新") { refresh += 1 }.disabled(loading)
            }
            Text("按驻留内存 RSS 排序；共享页可能重复计入，合计不等于系统已用内存。")
                .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            if loading { ProgressView("读取中…") }
            if failed { Text("无法读取进程，请重试。").foregroundColor(Theme.Ink.error) }
            if !loading && !failed && rows.isEmpty {
                Text("暂无可显示的进程数据。").foregroundColor(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(rows.prefix(8))) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.name).lineLimit(1)
                            Spacer()
                            Text(ProcessSampler.Snapshot(memoryBytes: row.bytes).memoryLabel).monospacedDigit()
                        }.font(Theme.Font.caption)
                        GeometryReader { proxy in
                            Capsule().fill(Theme.hairline)
                            Capsule().fill(Theme.chartAmber.opacity(0.85))
                                .frame(width: proxy.size.width * CGFloat(Double(row.bytes) / Double(max(1, rows.first?.bytes ?? 1))))
                        }.frame(height: 9)
                    }.help("PID \(row.id) · RSS")
                }
            }
            Text("占用最高的 8 个进程 · 长度按最大值缩放")
                .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            Button("打开活动监视器") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
        }
        .padding(20).frame(width: 390)
        .background(Theme.cardSurface)
        .task(id: refresh) {
            loading = true
            failed = false
            let snapshot = await Task.detached(priority: .utility) { ProcessMemoryRow.read() }.value
            guard !Task.isCancelled else { return }
            failed = snapshot == nil
            rows = snapshot ?? []
            loading = false
        }
    }
}
