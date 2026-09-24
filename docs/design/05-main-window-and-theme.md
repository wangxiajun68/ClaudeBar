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

- **topBar**：brand 头 + 8 项导航（概览 / 会话 / 模型 / 用量 / 流量 / VPN / 设置 + 右上角问号进「帮助」）；选中项为 accent 填充，hover 变亮。末尾为实时状态 pill（"N 运行中/空闲"）。窗口收窄时 `ViewThatFits` 先丢掉每项的图标，只留文字。
- **Detail**：按 `selectedPage`（`AppPage`）切换；流量页首次打开后保持挂载，避免检查器重建卡顿。
- **全局**：⌘K `CommandPalette`；关窗后 status item 保活。

## 8 个 Pages

全部页面走**宫格（瓦片）布局**（流量检查器与 VPN 节点列表为领域专用布局）。网格列模板集中在 `Theme.GridLayout.Preset`。

| 页面 | 要点 |
|------|------|
| **DashboardView** | 指标头行 → 资源条 → 能源流向 → VPN 卡 → 7 块指标磁贴 → 活跃会话总览 → 用量 Top |
| **SessionsView** | CLAUDE CODE / CURSOR / CODEX 频道 section |
| **ProvidersView** | 标题「模型工作台」；供应商品牌大标 + 「当前连接」+ 搜索框 / 「仅当前」筛选；Claude + Codex 两栈自适应网格 + 编辑器 |
| **UsageView** | 周期 chips + 热力图 + `CacheAnatomyBar` + 用量模型瓦片 |
| **TrafficView** | 首次进入后常驻内存（`trafficMounted`），避免每次切 tab 重建 |
| **VPNView** | mihomo 开关、节点、订阅、日志；见 [technical/11](../technical/11-vpn.md) |
| **SettingsView** | 全部为「`SectionHeader` + `TileGrid(.pageSetting)`」的宫格：启动 / 外观 / 继续会话 / 灵动岛 / **权限与隐私** / 存储 / 本机代理 / 代理上游 / 第三方接入 / VPN 代理 / 连通性 / 配置文件 / 关于 |
| **HelpView** | 左侧目录 + 右侧全文；右上角问号进入，不进顶栏 tab |

## 共享交互层（`Views/Shared/`）

- `Tile.swift`：`TileGrid` + `MetricTile` + `.tile()` modifier（与 `panelCard()` 同族的半透明表面，密度更高）。
- `ConnectionCard.swift` / `MachineKpiStrip.swift` / `HardwareDetailPanel.swift`：连接与电量 mark 行、仪表盘磁贴、硬件细节面板（`UsageBar.swift` 的 `UsageModelTile` / `UsageStackBar` 已并入）。
- `UsageRiver.swift`：`CacheAnatomyBar`（周期 token 构成横条）。
- `ProductBrandMark.swift` / `LucideHardwarePaths.swift` / `HardwareIllustration.swift`：供应商品牌图形、Lucide 硬件矢量、硬件插画。
- `Theme.Ink`（`Theme/Theme.swift`）：信号色的**文字版**（light/dark 各一套，对 `bgPrimary` / `cardSurface` / `bgOverlay` 均 ≥4.5:1）。字与图标用 `Ink`，形状（条、点、弧、胶囊底）用原信号色；`StatusPill` / `SectionHeader` / `MetricTile` 的 `ink:` 参数即此。
- `ResourceStrip`：本机 CPU / GPU / 内存与 SMC 风扇。风扇调速只在概览页的资源条与菜单栏 KPI 上；设置页不再有风扇模块。
- `VpnTopChrome.swift`：`VpnNodeMenu` / `VpnNodePickerPanel` / `VpnDelayStyle`（popup 与卡片共用）。
- `SectionHeader`、`StatusDot` / `StatusBadge`、`HeartbeatSparkline`。
- `SessionCardView` / `CursorSessionCardView` / `ExternalSessionCardView`（popup 紧凑会话卡）。
- `Interaction.swift`：`PressableStyle`、`HoverState`、`ActionChip`、`IconChip`、**`adaptiveGlassButton()`**。
- `GlassCard` + `SelectionTint`（选中着色，非系统玻璃）。
- `FeedbackToast`、`StandbyEmptyState`、**`CommandPalette`**（⌘K；macOS 26+ 结果区 `GlassEffectContainer`）。
- `ConnectivityProbeButton`、`ProxyCurlExample`（整宽卡片：说明 + 内嵌 `CodeBlock`）。
- 设置页的排版只有一种语法：`SectionHeader` 起小节，格内内容用 `TileGrid(.pageSetting)`（自适应 200pt）铺 `SettingTile`；代理上游的四个选择与第三方接入的 Base URL / 鉴权都走这套，不再有整宽行或 divider 列表。
- 整宽段落用 `panelCard()`，不套 `TileGrid`（例如 `ProxyCurlExample` 的 curl 示例）。**卡不套卡**：`CodeBlock` 只画内嵌代码井，自己不带 `panelCard()`；如果把卡片加进 `CodeBlock`，帮助页那半打代码块会变成六层嵌套卡。
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

- **表面**：`panelCard()` = 半透明白色填充（默认 `opacity 0.07`）+ 发丝线描边；`.tile()` = 更密的瓦片变体；`shadowCard()`、`cardFill()`、`sidebarFill`、`divider` / `hairline`；`HairlineDivider` 提供去卡片化的发丝线分区。
- **字体**：SF Pro 单族；`displayMetric*` + `.monospacedDigit()`；瓦片字阶 `tileValue` / `tileLabel` / `tileDetail`；popup 密度别名 `rowTitle` / `micro*` / `badgeMono`。
- **宫格**：`GridLayout.Preset`（`pageMetric` 4 等分、`pageSession` / `pageUsage` / `pageProvider` 自适应、popup 2 列预设）+ `Space.gridGap` / `gridGapPage`。
- **动效**：`bouncy` / `smooth` / `pulse` / `snappy` + `Motion.page` / `Motion.state`——全部状态驱动。
- **Helper**：`contextColor(ratio)`、`barColor(for:)` + `djb2`、`ActiveTileEdge`（accent 左缘 2px + tint 填充）。
