import SwiftUI

/// The control sheet. One section per control family, so two families can be
/// compared at once — which is the whole point: the app has three press
/// languages and three corner languages, and seeing them on one page is what
/// says so.
struct PreviewSheet: View {
    @State private var on = true
    @State private var off = false

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            section("动作按钮 · ActionButton") {
                HStack(alignment: .top, spacing: 22) {
                    // The label states the *tone the code yields*, not the
                    // tone a reader might assume: the title-only convenience
                    // inits default to `.neutral`, so a bare `ActionButton("刷新")`
                    // is the milled well shown here, and `.sparkle` has to be
                    // asked for by name.
                    group("neutral (bare ActionButton)") {
                        VStack(alignment: .leading, spacing: 8) {
                            ActionButton("刷新") {}
                            ActionButton("打开") {}
                            ActionButton("刷新", symbol: "arrow.clockwise") {}
                        }
                    }
                    group("sparkle") {
                        VStack(alignment: .leading, spacing: 8) {
                            ActionButton("刷新", tone: .sparkle) {}
                            ActionButton("打开", tone: .sparkle) {}
                        }
                    }
                    group("accent · standard") {
                        VStack(alignment: .leading, spacing: 8) {
                            ActionButton("刷新", symbol: "arrow.clockwise", tone: .accent) {}
                            ActionButton("启动", tone: .accent) {}
                        }
                    }
                    group("accent · primary") {
                        VStack(alignment: .leading, spacing: 8) {
                            ActionButton("刷新", symbol: "arrow.clockwise", tone: .accent,
                                         emphasis: .primary) {}
                            ActionButton("启动", tone: .accent, emphasis: .primary) {}
                        }
                    }
                    group("destructive") {
                        VStack(alignment: .leading, spacing: 8) {
                            ActionButton("清空", tone: .destructive) {}
                            ActionButton("移除", tone: .destructive) {}
                        }
                    }
                    group("tall · 大") {
                        ActionButton("启动代理", symbol: "bolt.fill", tone: .accent,
                                     size: .large, emphasis: .primary) {}
                    }
                    group("disabled") {
                        ActionButton("刷新") {}.disabled(true)
                    }
                }
            }

            section("芯片 · ChipButton") {
                HStack(alignment: .top, spacing: 34) {
                    group("toggle chip") {
                        VStack(alignment: .leading, spacing: 8) {
                            ChipButton("TUN 模式", on: true) {}
                            ChipButton("系统代理", on: false) {}
                            ChipButton("规则模式", symbol: "list.bullet", on: true) {}
                        }
                    }
                    group("icon · ActionIcon") {
                        HStack(spacing: 8) {
                            ActionIcon(symbol: "gearshape") {}
                            ActionIcon(symbol: "eye") {}
                            ActionIcon(symbol: "trash", tone: .destructive) {}
                        }
                    }
                }
            }

            section("开关 · InstrumentToggleStyle") {
                HStack(alignment: .top, spacing: 26) {
                    group("switch") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("菜单栏常驻", isOn: $on).instrumentToggle()
                            Toggle("低电量提醒", isOn: $off).instrumentToggle()
                            Toggle("", isOn: $on).instrumentToggle()
                        }
                    }
                }
            }

            section("分段 · SegmentedCapsule") {
                SegmentedCapsule(items: ["全部", "日", "月", "年"],
                                 selection: "月",
                                 title: { $0 },
                                 tint: Theme.Ink.claude,
                                 onSelect: { _ in })
            }
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary())
                .textCase(.uppercase)
            content()
        }
    }

    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary())
            content()
        }
    }
}
