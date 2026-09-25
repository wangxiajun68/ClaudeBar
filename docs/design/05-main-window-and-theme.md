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

1120×720 `NSWindow`（`.underWindowBackground` vibrancy + `fullSizeContentView` + 透明标题栏），顶栏 tabs + detail：

- **topBar**：冰色画布贯穿顶部，导航标签收在居中的白色悬浮圆角容器中，brand 与实时状态留在两侧；容器使用轻阴影与发丝线，不使用全幅模糊。导航包含概览 / 会话 / 模型 / 连接器 / 用量 / 流量 / VPN / 设置；选中项使用浅蓝填充，右侧问号进入「帮助」。窗口收窄时 `ViewThatFits` 先丢掉每项的图标，保留文字与原有键盘可达性。
- **Detail**：按 `selectedPage`（`AppPage`）切换；流量页首次打开后保持挂载，避免检查器重建卡顿。
- **全局**：⌘K `CommandPalette`；关窗后 status item 保活。

## 9 个 Pages

全部页面走**宫格（瓦片）布局**（流量检查器与 VPN 节点列表为领域专用布局）。网格列模板集中在 `Theme.GridLayout.Preset`。

| 页面 | 要点 |
|------|------|
| **DashboardView** | 标题 → 资源条（CPU / GPU / 内存 / 磁盘 / 连接 / 双风扇）→ 能源流向 → 活跃会话总览（网格 + 「查看全部 N 个会话」）。用量对照与用量分布日历已移到用量页 |
| **SessionsView** | CLAUDE CODE / CURSOR / CODEX 频道 section |
| **ProvidersView** | 标题「模型工作台」；供应商品牌大标 + 「当前连接」+ 搜索框 / 「仅当前」筛选；`ProviderDirectoryHost` 渲染供应商目录（Claude + Codex 两栈），配置走 `ProviderConnectionEditor` 弹窗 |
| **ConnectorsView** | 连接器：三家客户端的本机 Skills / MCP / 插件，左侧客户端筛选 + 「本机共享」，详情页渲染 SKILL.md、MCP `tools/list` 与插件组成；见 [technical/16](../technical/16-connectors.md) |
| **UsageView** | 周期 chips + 热力图 + `CacheAnatomyBar` + 用量模型瓦片（每块带自己的估算金额） |
| **TrafficView** | 只在选中时挂载；昂贵状态由 `MainWindowController` 持有的 `TrafficPageState` 承载，重进无需重建 |
| **VPNView** | mihomo 开关、节点、订阅、日志；见 [technical/11](../technical/11-vpn.md) |
| **SettingsView** | 全部为「`SectionHeader` + `TileGrid(.pageSetting)`」的宫格：启动 / 电池管理授权 / 外观 / 模型花费 / 继续会话 / 灵动岛 / **权限与隐私** / 存储 / 本机代理 / 代理上游 / 第三方接入 / VPN 代理 / 连通性 / 配置文件 / 关于 |
| **HelpView** | 左侧目录 + 右侧全文；右上角问号进入，不进顶栏 tab |

## 共享交互层（`Views/Shared/`）

- `Tile.swift`：`TileGrid` + `MetricTile` + `.tile()` / `.hoverTile()` modifier。表面本身（底 + 强调水洗 + 内嵌白环 + 角上深度环 + 悬停描边与抬升）定义在 `Views/Shared/UiverseSurfaces.swift`，`panelCard()` 与 `.tile()` 是同一套的两种密度；与 `panelCard()` 同族的半透明表面，密度更高。
- `UiverseSurfaces.swift`：表面语言的单点 —— `InnerFrameRing`、`DepthLens`（**不同心**的三层角环，一个 `Canvas`，不画字形）、`SegmentedCapsule`（唯一的筛选 / 分段控件：连接器类型与平台、供应商客户端与分类、用量周期、VPN 分组）、`OrbitGauge`、`ConveyorBelt`、`LoadRing` 已删除（曾是唯一按读数调速的装饰：一条光的弧，转速 ∝ 负载，<5% 完全静止；约 96° 的弧在图标尺寸上读作「转圈等待」且复述下方数字，故视图与装饰 kind 一并移除）、`ShineSweep` + `.depthTilt()`（只给单张 hero 卡）。**角上已有内容的瓦片（会话瓦片的子 agent 簇）只取 `tint`，不加 `lens`**；`Theme.Ink.*` 是信号色的文字版，原信号色只画形状。口径见 [DESIGN.md](../../DESIGN.md)。
- `ConnectionCard.swift` / `MachineKpiStrip.swift` / `HardwareDetailPanel.swift`：连接与电量 mark 行、仪表盘磁贴、硬件细节面板（`UsageBar.swift` 的 `UsageModelTile` / `UsageStackBar` 已并入）。
- `UsageRiver.swift`：`CacheAnatomyBar`（周期 token 构成横条）。
- `ProviderRow.swift` 的 `ProviderTile` 与 `ProviderEditorView` / `CodexProviderEditorView` / `ProviderEditorSidebar` 目前**没有挂载点**（`ProvidersView` 走 `ProviderDirectoryHost` + `ProviderConnectionEditor`）；见 [technical/17](../technical/17-ui-audit-backlog.md)。
- `ProductBrandMark.swift` / `LucideHardwarePaths.swift` / `HardwareIllustration.swift`：供应商品牌图形、Lucide 硬件矢量、硬件插画。`HardwareIllustration` 是**实时**的：CPU 每个逻辑核心画一格、GPU 每组图形子单元画一列，各自按自己的读数点亮（12 核就是 12 格），无分组读数时回退到整体负载的单片；内存 / 硬盘各画一个 100×76 的容量模组，用「页类别」「已用 / 空闲」的等比条表示。
- `Theme.Ink`（`Theme/Theme.swift`）：信号色的**文字版**（light/dark 各一套，对 `bgPrimary` / `cardSurface` / `bgOverlay` 均 ≥4.5:1）。字与图标用 `Ink`，形状（条、点、弧、胶囊底）用原信号色；`StatusPill` / `SectionHeader` / `MetricTile` 的 `ink:` 参数即此。
- `ResourceStrip`：本机 CPU / GPU / 内存与 SMC 风扇。小图标只负责标注瓦片（背后不再套 `LoadRing`——弧在这个尺寸读作「转圈等待」，且复述下方数字）；实时读数由右侧的大 mark 承担。风扇调速只在概览页的资源条与菜单栏 KPI 上；设置页不再有风扇模块。
- `VpnTopChrome.swift`：`VpnNodeMenu` / `VpnNodePickerPanel` / `VpnDelayStyle`（popup 与卡片共用）。
- `SectionHeader`、`StatusDot` / `StatusBadge`、`HeartbeatSparkline`。
- `SessionCardView` / `CursorSessionCardView` / `ExternalSessionCardView`（popup 紧凑会话卡）。
- `Interaction.swift`：`PressableStyle`、`HoverState`、`ActionChip`、`IconChip`、**`adaptiveGlassButton()`**。
- `GlassCard` + `SelectionTint`（选中着色，非系统玻璃）。
- `FeedbackToast`、`StandbyEmptyState`、**`CommandPalette`**（⌘K；macOS 26+ 结果区 `GlassEffectContainer`）。
- `ConnectivityProbeButton`、`ProxyCurlExample`（与其他设置等大的瓦片，弹出层内查看并复制完整 curl 命令）。
- 设置页的排版只有一种语法：`SectionHeader` 起小节，格内内容用 `TileGrid(.pageSetting)`（自适应 300pt）铺 `SettingTile`；代理上游的四个选择、第三方接入的 Base URL / 鉴权 / curl 示例，以及 `PermissionsSection` 的权限卡都走这套（权限卡内容更密，但表面与列宽与页面其余部分一致）。
- `CodeBlock` 只画内嵌代码井，自己不带 `panelCard()`；帮助页的代码块也复用它。
- `PermissionsSection.swift`：设置页「权限与隐私」——逐项开关、系统授权状态、跳转系统设置（见 [§10](10-notch-island.md)）。
- `APIKeyField.swift` / `ProviderDirectory.swift` / `ProviderQuickSetup.swift` / `ProviderControls.swift` / `ProviderModelFetchButton.swift`：供应商目录与快速配置控件（见 [surfaces/providers.md](surfaces/providers.md)）。
- `BatteryChargeControls.swift`：能源卡的电池控制段（见 [technical/12](../technical/12-battery-control.md)）。
- `DecorativeMotion.swift`：Core Animation 装饰动效，不跑 SwiftUI 时间线。

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

- **表面**：`panelCard()` = 半透明白色填充（默认 `opacity 0.07`）+ 强调水洗 + 内嵌白环 + 发丝线描边；`.tile()` = 更密的瓦片变体，两者共用 `UiverseSurfaces.swift` 的四个部件（底 / 水洗 / 角上深度环 / 内白环 + 悬停描边）；`shadowCard()`、`cardFill()`、`sidebarFill`、`divider` / `hairline`；`HairlineDivider` 提供去卡片化的发丝线分区。
- **字体**：SF Pro 单族；`displayMetric*` + `.monospacedDigit()`；瓦片字阶 `tileValue` / `tileLabel` / `tileDetail`；popup 密度别名 `rowTitle` / `micro*` / `badgeMono`。
- **宫格**：`GridLayout.Preset`（`pageMetric` 4 等分、`pageSession` / `pageUsage` / `pageProvider` 自适应、popup 2 列预设）+ `Space.gridGap` / `gridGapPage`。
- **动效**：`bouncy` / `smooth` / `pulse` / `snappy` + `Motion.page` / `Motion.state`——全部状态驱动。
- **Helper**：`contextColor(ratio)`、`barColor(for:)` + `djb2`、`ActiveTileEdge`（accent 左缘 2px + tint 填充）。
