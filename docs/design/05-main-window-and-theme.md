# 主窗口与设计系统

> ClaudeBar 设计文档 · §5
> 索引：[设计文档](README.md) · 相关：[顶层架构](02-architecture.md) · 技术文档 [视图层](../technical/05-view-layer.md)

## 设计原则

ClaudeBar 的界面以**信息可视化**为唯一目标：数字 tabular 对齐、层级由字重与排版驱动、色彩用于产品线身份（Claude 蓝 / Cursor 紫 / Codex 瓷白）与状态（busy / warning / error）。动效全部状态驱动（hover 反馈、busy 脉冲、页面淡入），不存在不承载数据的装饰性视觉。

### 表面策略

| 层级 | 实现 | 说明 |
|------|------|------|
| 内容卡 / 瓦片 | `panelCard()`、`.tile()` | 扁平半透明填充 + 发丝线描边，**非** `glassEffect`；避免主窗口全幅 live blur 的 GPU 纹理开销（约 100 MB 量级） |
| 工具栏按钮 | `adaptiveGlassButton()` | **仅 macOS 26+** 映射为原生 Liquid Glass（`.glass` / `.glassProminent`）；更早系统回退为 `.bordered` |
| 命令面板 | `GlassEffectContainer` | **仅 macOS 26+** 且**仅**用于 ⌘K `CommandPalette` 结果列表的玻璃容器；其余表面不使用 |

主窗口背景为 `.underWindowBackground` vibrancy；侧边栏与内容区依靠 token 色阶与发丝线分区，而非连续玻璃 morph 或背景光斑。

## 主窗口（`MainWindowController` + `MainWindowView`）

1120×720 `NSWindow`（`.underWindowBackground` vibrancy + `fullSizeContentView` + 透明标题栏），`NavigationSplitView`：

- **Sidebar**：brand 头 + 6 项导航（图标 + 标签 + 实时计数 badge，`contentTransition(.numericText())`）；选中项为简单 accent 填充（`Theme.claude.opacity(0.18)`），hover 变亮。底部状态圆点 + "N 运行中/空闲"。
- **Detail**：按 `selectedPage`（`AppPage`）切换 6 页，纯 opacity 过渡（`Theme.Motion.page`）。
- **全局**：⌘K `CommandPalette`；关窗后 status item 保活。

## 6 个 Pages

全部页面走**宫格（瓦片）布局**：数据域以等高瓦片网格呈现，网格列模板集中在 `Theme.GridLayout.Preset`（`TileGrid` 为唯一网格容器）。

| 页面 | 要点 |
|------|------|
| **DashboardView** | 指标头行（4× `MetricTile`）→ 活跃会话总览（Claude / Cursor / Codex 色点）→ 用量 Top |
| **SessionsView** | CLAUDE CODE / CURSOR / CODEX 频道 section；`SessionTileFull` 宫格，可展开子 agent 树，双击恢复 |
| **ProvidersView** | Claude + Codex 供应商宫格；`ProviderEditorView` / `CodexProviderEditorView` 嵌入详情层 |
| **UsageView** | 周期 chips + 日期导航 + `UsageModelTile` 宫格 |
| **TrafficView** | 代理状态、请求捕获列表、对话 / 工具 / 原始 JSON 分栏；含 `ProxyLogView` 访问日志 |
| **SettingsView** | Codex 本机代理开关与端口、连通性探测、配置文件快捷打开、空闲通知、版本信息 |

## 共享交互层（`Views/Shared/`）

- `Tile.swift`：`TileGrid` + `MetricTile` + `.tile()` modifier（与 `panelCard()` 同族的半透明表面，密度更高）。
- `UsageBar.swift`：`UsageBarRow`、`UsageModelTile`、`MetricText`。
- `SectionHeader`、`StatusDot` / `StatusBadge`、`HeartbeatSparkline`。
- `SessionCardView` / `CursorSessionCardView` / `ExternalSessionCardView`（popup 紧凑会话卡）。
- `Interaction.swift`：`PressableStyle`、`HoverState`、`ActionChip`、`IconChip`、**`adaptiveGlassButton()`**。
- `GlassCard` + `SelectionTint`（选中着色，非系统玻璃）。
- `FeedbackToast`、`StandbyEmptyState`、**`CommandPalette`**（⌘K；macOS 26+ 结果区 `GlassEffectContainer`）。
- `ConnectivityProbeButton`、`ProxyCurlExample`、`ResourceStrip`（ClaudeBar / CC / Cursor / Codex 资源占比）。

## Theme 设计 token（`Theme/Theme.swift`）

### 色彩

| 类别 | Token | 用途 |
|------|-------|------|
| 基底 | `base0` … `base4` | 中性近黑背景阶（旧名 `bgPrimary` … `bgOverlay` 保留别名） |
| Claude | `claude` / `claudeHi` | 软蓝，Claude Code |
| Cursor | `cursor` / `cursorHi` | 软紫，Cursor |
| Codex | `codex` | 暖瓷白，Codex 会话与供应商 |
| 语义 | `statusBusy` / `statusActive` / `statusIdle` / `statusWarning` / `statusError` / `statusSuccess` | 状态与反馈 |
| 文本 | `textPrimary` / `textSecondary` / `textTertiary()` | 三级字色 |

### 表面与排版

- **表面**：`panelCard()` = 半透明白色填充（默认 `opacity 0.07`）+ 发丝线描边；`.tile()` = 更密的瓦片变体；`shadowCard()`、`cardFill()`、`sidebarFill`、`divider` / `hairline`；`HairlineDivider` / `SectionBlock` / `.sectionRules()` 提供去卡片化的发丝线分区。
- **字体**：SF Pro 单族；`displayMetric*` + `.monospacedDigit()`；瓦片字阶 `tileValue` / `tileLabel` / `tileDetail`；popup 密度别名 `rowTitle` / `micro*` / `badgeMono`。
- **宫格**：`GridLayout.Preset`（`pageMetric` 4 等分、`pageSession` / `pageUsage` / `pageProvider` 自适应、popup 2 列预设）+ `Space.gridGap` / `gridGapPage`。
- **动效**：`bouncy` / `smooth` / `pulse` / `snappy` + `Motion.page` / `Motion.state`——全部状态驱动。
- **Helper**：`contextColor(ratio)`、`barColor(for:)` + `djb2`、`ActiveTileEdge`（accent 左缘 2px + tint 填充）。
