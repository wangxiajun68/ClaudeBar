import SwiftUI

struct FanControlSection: View {
    @ObservedObject private var monitor = FanMonitor.shared
    @State private var draftRPM: [Int: Double] = [:]
    @State private var editingFan: Int?

    var body: some View {
        Group {
            if !monitor.smcAvailable {
                Text("无法连接 Apple SMC，风扇信息不可用。")
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
            } else if monitor.fans.isEmpty {
                Text("未检测到风扇。")
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // 表头
                    HStack {
                        Text("风扇")
                            .font(Theme.Font.caption)
                            .foregroundColor(Theme.textTertiary())
                        Spacer()
                        Text("模式")
                            .font(Theme.Font.caption)
                            .foregroundColor(Theme.textTertiary())
                            .frame(width: 110, alignment: .center)
                        Text("转速")
                            .font(Theme.Font.caption)
                            .foregroundColor(Theme.textTertiary())
                            .frame(width: 220, alignment: .leading)
                    }
                    .padding(.bottom, 6)

                    ForEach(monitor.fans) { fan in
                        fanRow(fan)
                        if fan.id != monitor.fans.last?.id {
                            Divider()
                        }
                    }

                    HStack {
                        Spacer()
                        Button("全部恢复自动") {
                            monitor.resetAllToAutomatic()
                        }
                        .adaptiveGlassButton()
                        .tint(Theme.claude)
                        .controlSize(.small)
                    }
                    .padding(.top, 12)

                    if let err = monitor.lastError {
                        Text(err)
                            .font(Theme.Font.caption)
                            .foregroundColor(Theme.statusError)
                            .padding(.top, 6)
                    }
                }
            }
        }
        .onAppear {
            monitor.start()
            syncDraftRPM()
        }
        .onDisappear { monitor.stop() }
        .onChange(of: monitor.fans) { _, _ in syncDraftRPM() }
    }

    private func syncDraftRPM() {
        for fan in monitor.fans where draftRPM[fan.id] == nil || editingFan != fan.id {
            draftRPM[fan.id] = Double(fan.rpm)
        }
    }

    @ViewBuilder
    private func fanRow(_ fan: FanInfo) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.s16) {
            // 名称 + 当前转速
            VStack(alignment: .leading, spacing: 2) {
                Text(fan.name)
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textPrimary)
                Text("\(fan.rpm) RPM")
                    .font(Theme.Font.captionMono)
                    .monospacedDigit()
                    .foregroundColor(Theme.textSecondary)
            }
            .frame(minWidth: 90, alignment: .leading)

            // 模式切换（列对齐）
            Picker("模式", selection: Binding(
                get: { fan.mode.isAutomatic },
                set: { automatic in
                    editingFan = nil
                    if automatic {
                        monitor.setAutomatic(fan.id)
                    } else {
                        let rpm = Int(draftRPM[fan.id] ?? Double(fan.rpm))
                        monitor.setManual(fan.id, rpm: rpm)
                    }
                })) {
                Text("自动").tag(true)
                Text("手动").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)

            // 转速控制（列对齐）：min — slider — max — 目标值
            HStack(spacing: Theme.Space.s8) {
                Text("\(fan.minRPM)")
                    .font(Theme.Font.captionMono)
                    .foregroundColor(Theme.textTertiary())

                let binding = Binding(
                    get: { draftRPM[fan.id] ?? Double(fan.rpm) },
                    set: { draftRPM[fan.id] = $0 })
                Slider(value: binding,
                       in: Double(fan.minRPM)...Double(fan.maxRPM)) { editing in
                    monitor.setUserAdjusting(editing)
                    editingFan = editing ? fan.id : nil
                    if !editing {
                        monitor.setManual(fan.id, rpm: Int(binding.wrappedValue))
                    }
                }
                .controlSize(.small)

                Text("\(fan.maxRPM)")
                    .font(Theme.Font.captionMono)
                    .foregroundColor(Theme.textTertiary())

                Text("\(Int(binding.wrappedValue))")
                    .font(Theme.Font.captionMono)
                    .monospacedDigit()
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 46, alignment: .trailing)
            }
            .frame(width: 280, alignment: .leading)
        }
        .padding(.vertical, 8)
    }
}
