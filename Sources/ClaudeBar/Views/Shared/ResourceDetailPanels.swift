import SwiftUI

struct ProviderBalancePanel: View {
    let providers: [Provider]
    let activeID: UUID?
    @State private var selectedID: UUID?
    @State private var result: String?
    @State private var loading = false
    @State private var refresh = 0

    private var selected: Provider? {
        providers.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("供应商余额").font(Theme.Font.displayHero)
            Picker("供应商", selection: $selectedID) {
                Text("选择供应商").tag(nil as UUID?)
                ForEach(providers) { provider in
                    Text(provider.name).tag(Optional(provider.id))
                }
            }
            if let selected {
                if BalanceFetcher.supports(selected.baseURL) {
                    Text(result ?? (loading ? "正在获取…" : "点击获取余额"))
                        .font(Theme.Font.tileValueSmall)
                    Button(loading ? "获取中…" : "获取 \(selected.name) 的余额") { refresh += 1 }
                        .disabled(loading)
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("当前仅支持 DeepSeek 官方 API 余额查询，此供应商暂不支持。")
                        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                }
            } else {
                Text(providers.isEmpty ? "请先添加供应商。" : "选择要查询的供应商。")
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(20).frame(width: 340)
        .background(Theme.cardSurface)
        .onAppear { selectedID = activeID ?? providers.first?.id }
        .onChange(of: selectedID) { _, _ in result = nil; loading = false; refresh = 0 }
        .task(id: "\(selectedID?.uuidString ?? "")-\(refresh)") {
            guard refresh > 0, let provider = selected,
                  BalanceFetcher.supports(provider.baseURL) else { return }
            loading = true
            let response = await BalanceFetcher.fetch(authToken: provider.authToken, baseURL: provider.baseURL)
            guard !Task.isCancelled else { return }
            result = response?.display ?? "获取失败，请检查网络与 API Key 后重试。"
            loading = false
        }
    }
}

private struct ProcessMemoryRow: Identifiable, Sendable {
    let id: Int
    let name: String
    let bytes: UInt64

    static func read() -> [Self]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,rss=,comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> Self? in
            let parts = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard parts.count == 3, let pid = Int(parts[0]), let kb = UInt64(parts[1]) else { return nil }
            return Self(id: pid, name: (String(parts[2]) as NSString).lastPathComponent, bytes: kb * 1024)
        }.sorted { $0.bytes > $1.bytes }
    }
}

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
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).lineLimit(1)
                                Text("PID \(row.id)").font(Theme.Font.microMono).foregroundColor(Theme.textSecondary)
                            }
                            Spacer()
                            Text(ProcessSampler.Snapshot(memoryBytes: row.bytes).memoryLabel)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            }.frame(height: 310)
            Button("打开活动监视器") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
        }
        .padding(20).frame(width: 390)
        .background(Theme.cardSurface)
        .task(id: refresh) {
            loading = true
            let snapshot = await Task.detached(priority: .utility) { ProcessMemoryRow.read() }.value
            guard !Task.isCancelled else { return }
            failed = snapshot == nil
            rows = snapshot ?? []
            loading = false
        }
    }
}
