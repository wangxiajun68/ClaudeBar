# 主窗口与设计系统

> ClaudeBar 设计文档 · §5
> 相关：[顶层架构](02-architecture.md) · 技术文档 [视图层](../technical/05-view-layer.md)

## 设计原则

ClaudeBar 的界面以**信息可视化**为唯一目标：数字 tabular 对齐、层级由字重与排版驱动、色彩只用于身份（Claude 蓝/Cursor 紫）与状态（busy/warning/error）。动效全部状态驱动（hover 反馈、busy 脉冲、页面淡入），不存在不承载数据的装饰性视觉。主内容表面为 macOS 26 原生 **Liquid Glass**（`panelCard()` / `.tile()`），无玻璃 morph、无背景光斑、无信标光晕。

## 主窗口（`MainWindowController` + `MainWindowView`）

1120×720 `NSWindow`（`.underWindowBackground` vibrancy + `fullSizeContentView` + 透明标题栏），`NavigationSplitView`：

- **Sidebar**：brand 头（蓝色圆标 "A" + "Axon"）+ 5 项导航（图标 + 标签 + 实时计数 badge，`contentTransition(.numericText())`）；选中项为简单 accent 填充（`Theme.claude.opacity(0.18)`），hover 变亮。底部状态圆点 + "N 运行中/空闲"。
- **Detail**：按 `selectedPage`（`AppPage`）切换 5 页，纯 opacity 过渡（`Theme.Motion.page`）。
- **全局**：⌘K `CommandPalette`；关窗后 status item 保活。

## 5 个 Pages

全部页面走**宫格（瓦片）布局**：数据域以等高瓦片网格呈现，网格列模板集中在 `Theme.GridLayout.Preset`（`TileGrid` 为唯一网格容器）。

- **DashboardView**：信息优先总览。**指标头行**（4 个 `MetricTile`：活跃配置/余额/会话/Token 总量，tabular 数字，点按经 `onNavigate` 跳转对应页）→ **活跃会话总览**（每行：源色点 + busy 点 + 项目/当前活动 + ContextBar + 上下文标签 + 更新时间，`TileGrid(.pageSession)` 自适应瓦片；上限 8 行 + "查看全部"）→ **用量 Top**（`UsageModelTile` + 常显百分比）。
- **SessionsView**：CLAUDE CODE / CURSOR 两个频道 section（`SectionHeader` + 发丝线分区），会话以 `TileGrid(.pageSession)` 全宽自适应瓦片呈现（`SessionTileFull`），瓦片内可展开子 agent 树，双击恢复；hover 瓦片揭示 action chips。
- **ProvidersView**：`TileGrid(.pageProvider)` 自适应瓦片网格，每格一个 `ProviderTile`（激活瓦片 accent 左缘），下方嵌入 `ProviderEditorView`。
- **UsageView**：周期 chips + 日期导航 + `TileGrid(.pageUsage)` 每模型一个 `UsageModelTile`（恒定高度、百分比常显）。
- **SettingsView**：面板卡设置页（打开 settings.json、空闲通知开关、版本信息）。

## 共享交互层（`Views/Shared/`）

- `Tile.swift`：`TileGrid`（宫格容器，吃 `Theme.GridLayout.Preset` 列模板）+ `MetricTile`（指标瓦片）+ `.tile()` modifier（瓦片表面/选中/hover）。
- `UsageBar.swift`：`UsageBarRow`（用量行，含 `ProportionBar` 比例条）、`UsageModelTile`、`MetricText`（tabular 数字文本）。
- `SectionHeader`（频道区头：图标 + 标题 + 总数/活跃数徽标）、`StatusDot`/`StatusBadge`（状态点，busy 脉冲）、`HeartbeatSparkline`（busy/idle 心跳轨迹）。
- `SessionCardView`/`CursorSessionCardView`（popup 紧凑会话卡）、`ContextBar`（上下文健康条）、`ActivityLine`（活动描述行）。
- `Interaction.swift`（`PressableStyle`/`HoverState`/`ActionChip`/`IconChip`）、`HoverActionChips`（hover 揭示 chips）、`GlassCard` + `SelectionTint`（玻璃卡/选中着色）。
- `FeedbackToast`（操作反馈 toast，2 秒淡出）、`StandbyEmptyState`（统一空态）、`CommandPalette`（⌘K 模糊搜索）。

## Theme 设计 token（`Theme/Theme.swift`）

- **基底**：`base0` 0x0D0D11 … `base4` 0x353A45（中性近黑，无色彩偏向；旧名 `bgPrimary`…`bgOverlay` 保留别名）。
- **信号**：`claude` 0x4F8EF7 / `claudeHi` 0x79ABF9（软蓝，Claude Code）；`cursor` 0xA78BFA / `cursorHi` 0xC0ACFC（软紫，Cursor）。`accent=claude`、`accentDim` 0x3A6FD1、`cursorAccent=cursor`、`signal(isCursor:)`。
- **语义**：`statusBusy`=claude、`statusActive`=cursor、`statusIdle` 0x8A8F98、`statusWarning` 0xE0A13C、`statusError` 0xE46464、`statusSuccess` 0x46C58F。
- **文本**：`textPrimary` 0xF5F5F7、`textSecondary` 0xA1A1A6、`textTertiary()`。
- **表面**：`panelCard()` = 原生 `glassEffect`（Liquid Glass 内容卡主表面）、`.tile()`（瓦片表面）、`shadowCard()`、`cardFill()`、`sidebarFill`、`divider`/`hairline`；`HairlineDivider`/`SectionBlock`/`.sectionRules()` 提供去卡片化的发丝线分区。
- **字体**：SF Pro 单族，字号+字重驱动层级；`displayMetric`/`displayMetricSmall` semibold + `.monospacedDigit()`；瓦片字阶 `tileValue`/`tileValueSmall`/`tileMicroValue`/`tileLabel`/`tileDetail`；popup 密度别名 `rowTitle`/`rowLarge`/`micro*`/`badgeMono`；代码/测量值用 mono（`captionMono`/`microMono`）；`Tracking` 字距与 `Font.systemIcon(_:)`。
- **宫格**：`GridLayout.Preset`（`pageMetric` 4 等分、`pageSession`/`pageUsage`/`pageProvider` 自适应、`popupSession`/`popupProvider`/`popupUsage` 2 列）+ `Space.gridGap`/`gridGapPage`。
- **动效**：`bouncy`/`smooth`/`pulse`/`snappy` + `Motion.page`/`Motion.state`——全部状态驱动，无循环装饰动画。
- **Helper**：`contextColor(ratio)`（blue/warning/red 阈值）、`barColor(for:)` + `djb2`（跨进程稳定的 hash 调色板）。
- **选中态**：`ActiveTileEdge`（accent 左缘 2px + tint 填充），供应商瓦片与模型行共用。
