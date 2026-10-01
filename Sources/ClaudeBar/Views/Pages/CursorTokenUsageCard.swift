import SwiftUI

/// Cursor's aggregate endpoint has no daily buckets or call count. Keep its
/// tokens scoped to their actual window instead of inventing a trend/share.
struct CursorTokenUsageCard: View {
    let window: DateInterval
    @ObservedObject private var ledger = CursorLedgerStore.shared
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
        let stats = ranked.map {
            ModelUsage(model: $0.model, inputTokens: $0.inputTokens, outputTokens: $0.outputTokens,
                       cacheReadTokens: $0.cacheReadTokens, cacheCreationTokens: $0.cacheWriteTokens)
        }
        let total = stats.reduce(into: ModelUsage(model: "Cursor")) { $0.merge($1) }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                Circle().fill(Theme.cursor).frame(width: 7, height: 7).padding(.top, 6)
                Text("Cursor")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 5) {
                        if ledger.loading { ProgressView().controlSize(.small) }
                        Button { refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain)
                            .disabled(ledger.loading)
                            .help("刷新 Cursor Token 用量")
                            .accessibilityLabel("刷新 Cursor Token 用量")
                    }.foregroundColor(Theme.textTertiary())
                    CacheHitBadge(stat: total)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RollingNumberText(ledger.window == nil ? "—" : UsageStats.formatTokens(total.totalTokens))
                    .font(Theme.Font.displayMetricSmall)
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 4)
                Text("官方账单")
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(ledger.window == nil ? "请先在本机登录 Cursor，再刷新用量。" : coverageLabel)
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textSecondary)
                        .frame(minHeight: 28, alignment: .leading)

                    HairlineDivider()
                    Text("模型明细")
                        .font(Theme.Font.microSemibold)
                        .foregroundColor(Theme.textSecondary)
                    if ranked.isEmpty {
                        StandbyEmptyState(label: ledger.loading ? "正在读取用量…" : "暂无用量",
                                          symbol: "chart.bar", tint: Theme.textSecondary)
                    } else {
                        ForEach(ranked, id: \.model) { row in
                            HStack(spacing: 8) {
                                Text(row.model).lineLimit(1).truncationMode(.middle).help(row.model)
                                Spacer(minLength: 4)
                                RollingNumberText(UsageStats.formatTokens(row.totalTokens)).monospacedDigit()
                            }.font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
                        }
                        Text("Token 构成")
                            .font(Theme.Font.microSemibold)
                            .foregroundColor(Theme.textSecondary)
                            .padding(.top, 4)
                        TokenMixStrip(stats: stats, compact: true)
                            .help("输入 \(total.inputTokens.formatted()) · 缓存读取 \(total.cacheReadTokens.formatted()) · 缓存写入 \(total.cacheCreationTokens.formatted()) · 输出 \(total.outputTokens.formatted()) Token")
                    }

                    if ledger.window != nil, ledger.isStale(for: window) {
                        Text(ledger.loading
                             ? "正在读取所选周期，暂显示上次统计。"
                             : "仅覆盖上述日期，未覆盖所选周期的完整用量。")
                            .font(Theme.Font.micro)
                            .foregroundColor(Theme.Ink.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = ledger.note {
                        Text(note + (ledger.window == nil ? "，请稍后重试。" : "，已保留上次统计。"))
                            .font(Theme.Font.micro)
                            .foregroundColor(Theme.Ink.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity).frame(height: 260, alignment: .topLeading)
        .tile(tint: Theme.cursor, hovered: hovered,
              lens: DepthLensSpec(tint: Theme.cursor, size: 124), lift: false)
        .hoverState($hovered)
        .task(id: window) { refresh() }
    }

    private func refresh(force: Bool = false) {
        ledger.refresh(window: window, billingCycle: CursorUsageFetcher.billingCycle(), force: force)
    }
}
