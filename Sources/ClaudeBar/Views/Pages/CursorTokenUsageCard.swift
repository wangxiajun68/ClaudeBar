import SwiftUI

/// Cursor's aggregate endpoint has no daily buckets or call count. Keep its
/// tokens scoped to their actual window instead of inventing a trend/share.
struct CursorTokenUsageCard: View {
    let window: DateInterval
    @ObservedObject private var ledger = CursorLedgerStore.shared
    @State private var expanded = false
    @State private var hovered = false

    private var rows: [CursorLedger.Row] {
        ledger.rows.values.sorted {
            $0.totalTokens == $1.totalTokens
                ? $0.model < $1.model : $0.totalTokens > $1.totalTokens
        }
    }

    private var coverageLabel: String {
        guard let covered = ledger.window else { return "" }
        let start = covered.start.formatted(.dateTime.year().month().day())
        let end = covered.end.formatted(.dateTime.year().month().day())
        return "\(start)–\(end)"
    }

    var body: some View {
        let ranked = rows
        let input = ranked.reduce(0) { $0 + $1.inputTokens }
        let output = ranked.reduce(0) { $0 + $1.outputTokens }
        let read = ranked.reduce(0) { $0 + $1.cacheReadTokens }
        let write = ranked.reduce(0) { $0 + $1.cacheWriteTokens }

        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            HStack {
                Circle().fill(Theme.cursor).frame(width: 7, height: 7)
                Text("Cursor")
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textPrimary)
                Spacer(minLength: 4)
                if ledger.loading {
                    ProgressView().controlSize(.small)
                }
                Button { refresh(force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(ledger.loading)
                .help("刷新 Cursor Token 用量")
                .accessibilityLabel("刷新 Cursor Token 用量")
            }

            if ledger.window != nil {
                RollingNumberText(UsageStats.formatTokens(input + output + read + write))
                    .font(Theme.Font.displayMetricSmall)
                    .foregroundColor(Theme.textPrimary)
                    .monospacedDigit()
                Text("Token · " + coverageLabel)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textSecondary)

                if ledger.isStale(for: window) {
                    Text(ledger.loading
                         ? "正在读取所选周期，暂显示上次统计。"
                         : "此数据仅覆盖上述日期，不代表所选周期的完整用量。")
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.Ink.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Grid(alignment: .leading, horizontalSpacing: Theme.Space.s16,
                     verticalSpacing: Theme.Space.s8) {
                    GridRow {
                        tokenValue("输入", input)
                        tokenValue("输出", output)
                    }
                    GridRow {
                        tokenValue("缓存读取", read)
                        tokenValue("缓存写入", write)
                    }
                }

                DisclosureGroup("模型明细（\(ranked.count)）", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: Theme.Space.s8) {
                        if ranked.isEmpty {
                            Text("该时段暂无 Token 用量")
                                .foregroundColor(Theme.textSecondary)
                        }
                        ForEach(ranked, id: \.model) { row in
                            HStack(spacing: Theme.Space.s8) {
                                Text(row.model)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(row.model)
                                Spacer(minLength: 4)
                                Text(UsageStats.formatTokens(row.totalTokens))
                                    .monospacedDigit()
                            }
                            .foregroundColor(Theme.textSecondary)
                        }
                    }
                    .font(Theme.Font.caption)
                    .padding(.top, Theme.Space.s8)
                }
                .font(Theme.Font.caption)
            } else {
                Text(ledger.loading ? "正在读取 Cursor 用量…" : "暂无 Cursor 用量数据")
                    .font(Theme.Font.bodySmall)
                    .foregroundColor(Theme.textSecondary)
                Text("请先在本机登录 Cursor，再刷新用量。")
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textSecondary)
            }

            if let note = ledger.note {
                Text(note + (ledger.window == nil ? "，请稍后重试。" : "，已保留上次统计。"))
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.Ink.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile(tint: Theme.cursor, hovered: hovered,
              lens: DepthLensSpec(tint: Theme.cursor, size: 124))
        .hoverState($hovered)
        .task(id: window) { refresh() }
    }

    private func tokenValue(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textSecondary)
            Text(UsageStats.formatTokens(value))
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.Ink.cursor)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(label)：\(value) Token")
    }

    private func refresh(force: Bool = false) {
        ledger.refresh(window: window, billingCycle: CursorUsageFetcher.billingCycle(), force: force)
    }
}
