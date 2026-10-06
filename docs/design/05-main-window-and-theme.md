# 主窗口与设计系统

> ClaudeBar 设计文档 · §5
> 索引：[设计文档](README.md) · 相关：[顶层架构](02-architecture.md) · 技术文档 [视图层](../technical/05-view-layer.md)

## 设计原则

ClaudeBar 的界面以**信息可视化**为唯一目标：数字 tabular 对齐、层级由字重与排版驱动、色彩用于产品线身份（Claude 蓝 / Cursor 紫 / Codex 灰）与状态（busy / warning / error）。动效全部状态驱动（hover 反馈、页面淡入），不存在不承载数据的装饰性视觉。

### 表面策略

| 层级 | 实现 | 说明 |
|------|------|------|
| 内容卡 / 瓦片 | `panelCard()`、`.tile()` | 扁平半透明填充 + 发丝线描边，**非** `glassEffect`；避免主窗口全幅 live blur 的 GPU 纹理开销（约 100 MB 量级） |
| 工具栏按钮 | `ActionButton` | 按**用途**命名而不是按长相：`tone:` 说这是什么控件（`.neutral` 铣削凹槽，默认 / `.sparkle` 深色板 / `.accent` / `.destructive`），`emphasis:` 说它是不是本页的默认动作。`.sparkle` 是一块近黑的板（`SparklePlate`，来自一个参考 CSS 药丸：hover 渐变 + 紫色辉光，450ms ease-in-out，即 `Theme.Animation.sparkle`）；`.neutral` 是铣削凹槽，也是不说 tone 时的默认（约 35 处裸调用点都是它）；`.sparkle` 要按名字要（当前无调用点，VPN 页的大 CTA 走的是 `SparkleCta`）。`ProviderActionStyle` 是同一块板的历史名字，`adaptiveGlassButton()` 与 `InstrumentButtonStyle` 都已删除 |
| 页头带控件 | `headerControl()` | 页头带里自己的控件：就是 `ActionPlateButtonStyle` 按这条带的尺寸画一遍，安静调。连接器与模型共用，两条带子读作同一个物件 |
| 命令面板 | `GlassEffectContainer` | **仅 macOS 26+** 且**仅**用于 ⌘K `CommandPalette` 结果列表的玻璃容器；其余表面不使用（问候卡窗台胶囊的 `SillGlass` 是另一处原生 glass：macOS 26 用 `glassEffect`，macOS 15 退回 material 叠层，减弱透明度时用实色，见 [greeting-atmosphere](greeting-atmosphere.md)） |

主窗口整体是不透明的：`isOpaque = true` + `Theme.windowNSColor` 实填（不做窗口级 vibrancy）；侧边栏与内容区依靠 token 色阶与发丝线分区，而非连续玻璃 morph 或背景光斑。

## 主窗口（`MainWindowController` + `MainWindowView`）

1120×720 `NSWindow`（不透明 `Theme.windowNSColor` 实填 + `fullSizeContentView` + 透明标题栏），顶栏 tabs + detail：

- **topBar**：冰色画布贯穿顶部，导航标签收在居中的白色悬浮圆角容器中，brand 与实时状态留在两侧；容器使用轻阴影与发丝线，不使用全幅模糊。导航包含概览 / 会话 / 模型 / 连接器 / 用量 / 流量 / VPN / 设置；选中项使用浅蓝填充，右侧问号进入「帮助」。窗口收窄时 `ViewThatFits` 先丢掉每项的图标，保留文字与原有键盘可达性。
- **Detail**（`MainWindowView.detailView`）：按 `selectedPage`（`AppPage`）切换；流量页只在选中时挂载，昂贵状态由 `MainWindowController` 持有的 `TrafficPageState` 承载，重进无需重建。
- **全局**：⌘K `CommandPalette`；关窗后 status item 保活。

## 9 个 Pages

全部页面走**宫格（瓦片）布局**（流量检查器与 VPN 节点列表为领域专用布局）。网格列模板集中在 `Theme.GridLayout.Preset`。

| 页面 | 要点 |
|------|------|
| **DashboardView** | 画布上的标题（会话数 + 刷新控件，**不**包进页头带）→ 问候卡 → 资源条（CPU / GPU / 内存 / 磁盘 / 连接 / 双风扇）→ 能源流向 → 活跃会话总览（网格 + 「查看全部 N 个会话」，默认 6 块） |
| **SessionsView** | 迁移历史条 + 按客户端分 section：Claude Code、Cursor，再按外部客户端各一节（Codex），每节是可双击恢复的瓦片网格；有运行中子 agent 或 workflow 的会话来单独一行或整宽瓦片 |
| **ProvidersView** | 标题「模型」+ 副标题「发现模型平台，为你的编程工具接入新能力。」；`ProviderDirectoryHost` 渲染供应商目录（Claude + Codex 两栈），配置走 `ProviderConnectionEditor` 弹窗。页头带是「`PageTitle` + 副标题」一列 + 右侧 `headerControl()` 的「导入另一侧 / 自定义」按钮，两侧 `alignment: .top`。状态行给出当前连接、已保存配置数与「仅显示已配置」开关 |
| **ConnectorsView** | 连接器：三家客户端的本机 Skills / MCP / 插件。工具栏是搜索 + 项目范围 + 刷新等操作，下面一条控件带放类型段（插件 / Skills / MCP / 本机 CLI）与平台段筛选，再按分组铺卡片；详情走 `ConnectorDetailSheet`，渲染 SKILL.md、MCP `tools/list` 与插件组成；见 [technical/16](../technical/16-connectors.md) |
| **UsageView** | 周期条（日 / 月 / 年 / **全部** / 自定）+ 热力图 + 五张指标卡（本地 Token / 有记录的天数 / 日用量中位数 / P95 / 缓存命中率）+ 活动卡（热力图 + 来源图例）+ 构成卡（Token 构成分段条 + 缓存命中）+ 按平台 / 按供应商 / 按模型瓦片（每块带自己的估算金额与 Cursor 结算）。「全部」不显示上一周期 / 下一周期 |
| **TrafficView** | 只在选中时挂载；昂贵状态由 `MainWindowController` 持有的 `TrafficPageState` 承载，重进无需重建 |
| **VPNView** | mihomo 开关、节点、订阅、日志；见 [technical/11](../technical/11-vpn.md) |
| **SettingsView** | 分类侧栏六个：「通用 / 外观与天气 / 灵动岛 / 用量与计费 / 权限与隐私 / 本地代理」；容器 ≥860pt 用 200pt 固定侧栏，内容最大宽 900pt，低于 860pt 收成顶部分类菜单。设置组采用中性列表，标签在左、控件在右。见 [设置页](surfaces/settings.md) |
| **HelpView** | 左侧目录 + 右侧全文；右上角问号进入，不进顶栏 tab |

## 共享交互层（`Views/Shared/`）

- `Tile.swift`：`TileGrid` + `.tile()` modifier。表面本身（底 + 强调水洗 + 内嵌白环 + 角上深度环 + 悬停描边与抬升）定义在 `TileSurface`（`Tile.swift`），`.hoverTile()` 是自动跟踪 hover 的薄包装（`UiverseSurfaces.swift`），`panelCard()` 与 `.tile()` 是同一套的两种密度。
- `UiverseSurfaces.swift`：表面语言的单点 —— `InnerFrameRing`、`DepthLens`（不同心的三层角环，一个 `Canvas`，不画字形）、`SegmentedCapsule`（唯一的筛选 / 分段控件：连接器类型与平台、供应商客户端与分类、用量周期；VPN 页的分组切换是原生 `Picker`）、`OrbitGauge`、`ConveyorBelt`、`ShineSweep`（+ `shineOnHover`；`depthTilt` 已删除）。**角上已有内容的瓦片（会话瓦片的子 agent 簇）只取 `tint`，不加 `lens`**；`Theme.Ink.*` 是信号色的文字版，原信号色只画形状。口径见 [DESIGN.md](../../DESIGN.md)。
- `ConnectionCard.swift` / `MachineKpiStrip.swift` / `HardwareDetailPanel.swift`：连接与电量 mark 行、仪表盘磁贴、硬件细节面板。`HardwareDetailPanel` 里的 `ConnectionDetailPanel` 分网络 / 本机代理 / 附近与设备三段；旧 `UsageBar.swift` 的 `UsageModelTile` / `UsageStackBar` 早已删除，用量瓦片由 `UsageModelCard` 承担。
- `ProviderTile`（原 `ProviderRow.swift`）**没有挂载点**（`ProvidersView` 走 `ProviderDirectoryHost` + `ProviderConnectionEditor`），连同文件一起已删除；目录宫格那颗瓦片由 `ProviderDirectoryCard` 承担。同一轮里 `ProviderEditorView` / `CodexProviderEditorView` / `ProviderEditorSidebar` 也没有挂载点，已删除（[审查证据](../reviews/ui-audit-backlog.md) §3、§9）。
- `CodexModelMark.swift`：popup 头部 chip 的客户端 mark 本身——`ProductBrandMark` 的真实品牌图形（Anthropic 的 "A\" / OpenAI 的花结 / Cursor 的立方体），13pt；`CursorMark` 是 Cursor 那格的同型视图。**那一版「增长图形 + Codex 额度 lane」的合并 mark 已删**：它唯一的 `.tile` 调用点随概览状态单重做而消失，额度改由 chip 自己的行承载（`QuotaSwayGauge`）。
- `ProductBrandMark.swift` / `LucideHardwarePaths.swift` / `HardwareIllustration.swift`：供应商品牌图形、Lucide 硬件矢量、硬件 mark。`ProductBrandMark` 画的是四家客户端的真实品牌图形 —— Anthropic 的 `A\`、OpenAI 的花结、Cursor 的立方体（LobeHub 1.97.1，Cursor 原先画的是 `cursorarrow.motionlines`，那是一支指针而不是这家的 mark），以及 ClaudeBar 自己的 mark（从 `Sources/AppIcon-1024.png` 由 `Tools/make-claudebar-mark.py` 推出，给用量图例里的「第三方」用 —— 一个四项图例里三项有图形、第四项只有文字，读起来是一行没画完）。外面套一层 `Theme.bgSecondary` 圆角方块（`well:`）——白标在浅色面上、黑标在深色面上都会消失，所以底色是图形的可读性前提，不是装饰。哪一层由 `page:` 决定而不是 `Theme.isDark`：灵动岛在两种主题下都是黑的。图形由 `Tools/gen-brand-marks.py` 归一化到画布 90%（`Sources/BrandAssets/`）：原始 PNG 各自带着到画布边缘的留白，归一化按宽度定标（Cursor 的立方体是竖长形，触到 `MAX_HEIGHT` 上限后宽约 0.878 对邻居的 0.900，差约 2.4%），于是一行里并排的三家看起来是同一个尺寸。`HardwareIllustration` 分两条 lane：上层是 Lucide 官方图标（`LucideHardwareGeometry.swift`，生成自上游 SVG，说明这是哪个部件），下层是实时读数条 —— CPU 每个逻辑核心一条、GPU 每组图形子单元一条、内存按页类别、硬盘按已用/空闲，条的高度就是它自己的读数（12 核就是 12 条，6 核忙就是 6 条满格）；另有按读数调速的扫光（`ReadingSweep`，<4% 或减弱动效时静止）。图标与读数分两条 lane，是因为把读数塞进图形里会互相打架。
- `Theme.Ink`（`Theme/Theme.swift`）：信号色的**文字版**（light/dark 各一套，对 `bgPrimary` / `cardSurface` / `bgOverlay` 均 ≥4.5:1）。字与图标用 `Ink`，形状（条、点、弧、胶囊底）用原信号色；`StatusPill` / `SectionHeader` 的 `ink:` 参数即此。
- `ResourceStrip`：本机 CPU / GPU / 内存 / 硬盘 / 连接 / 风扇。小图标只负责标注瓦片（背后没有 `LoadRing`，也没有取代它的 `InstrumentRing`——弧与环在这个尺寸都读作「转圈等待」，且复述下方数字）；实时读数由右侧的大 mark 承担，**尺寸常量是 `ResourceStrip.markSlot`（176×130），四格与 popover 共用**。`连接` 与 `风扇` 两张卡整格可点：连接弹出 `ConnectionDetailPanel`（**网络 / 本机代理 / 附近与设备三段**：网络段是链路本身的状态与一根标定过的 RSSI 尺，代理段是这台机器上由本应用提供的本机服务，设备段是挂在上面的耳机与隔空投送入口；底部的「复制诊断」汇总网络 / 代理 / 蓝牙与音频设备读数。卡片与面板共用同一个 `ConnectionStatus` 词汇表和同一根 `ConnectionSignalScale`，两处不会对同一条链路说两个词；且两处都写明「接入」与「可用」是两件事，结构由 `Tests/connection-panel-regressions.py` 锁定），风扇弹出 `FanInternalsPanel`（随包 `macbook-internals-illustration.png` 机身插画，两个涡轮按插画坐标裁切（`FanArtwork`），插画缺失时退回 `laptopcomputer` SF 符号）。风扇调速只在概览页的资源条与菜单栏 KPI 上；设置页不再有风扇模块。
- 风扇使用精细涡轮插画、转速弧及随 RPM 连续旋转的 Core Animation。资源条上每个转子本身是按钮，直接切换该风扇的最大 / 自动；点击卡片其余区域打开详情。机内结构使用高清矢量风格概念插画，不代表精确机型图。
- `VpnTopChrome.swift`：`VpnStatusPill`（popup 状态行的节点 / 延迟药丸，点击切到主窗口 VPN 页选节点、测速）、`CursorUsagePanel`（Cursor chip 的面板：月度池 + Grok 周窗口三条额度）、`VpnDelayStyle`。`VpnNodePickerPanel` 已无调用点，已删除；`GlassCard` 视图本身也已删除，文件只剩 `selectionTint`。
- `SectionHeader`、`PulsingStatusDot` / `OverviewStatusDot`（`SessionStatusViews.swift`）、`ProviderStatusBadge`、`HeartbeatSparkline`。
- `SessionCardView` / `CursorSessionCardView` / `ExternalSessionCardView`（popup 紧凑会话卡）。
- `Interaction.swift`：`PressableStyle`、`HoverState`、`ActionChip`、`IconChip`、`rollingNumber()`。下压按钮曾在这里（`adaptiveGlassButton()`），现已移到 `InstrumentControls.swift` 的 `ActionButton`。
- `InstrumentControls.swift`：控件语言单点 —— 唯一的字段凹槽（`InstrumentField` / `InstrumentWell`）、唯一的开关（`InstrumentToggleStyle`）、页头带控件（`headerControl()`）、唯一的下压按钮（`ActionButton` + `ActionPlateButtonStyle` + `ControlPlate`；`ProviderActionStyle` 是同一块板的历史名字）、`ActionIcon`、菜单凹槽（`InstrumentMenuLabel`）、`PerimeterSweep` / `GroundShadow`。`InstrumentFieldStyle`（唯一的 TextField 凹槽）在 `Views/Shared/InstrumentSearchField.swift`，`InstrumentBadge` / `InstrumentGlyph` 在 `Views/Shared/InstrumentGlyph.swift`，`GlyphWell` 在 `Theme/Theme.swift`。表面文件（`UiverseSurfaces.swift`）说卡片*是什么*，这个文件说控件被碰到时*做什么*。
- `GlassCard.swift`：只剩 `selectionTint(_:color:corner:)`（选中行的强调水洗，非系统玻璃）。
- `FeedbackToast`、`StandbyEmptyState`、**`CommandPalette`**（⌘K；macOS 26+ 结果区 `GlassEffectContainer`）。
- `ProxyCurlExample`：第三方接入中的一行，按需查看并复制 curl 示例。
- 设置页采用 `SettingsGroup` / `SettingsRow` / `SettingsToggleRow`，统一行内对齐与细分隔线，使用原生 macOS 开关和选择器；不再使用每项一张卡片的宫格。布局与精简明细见 [设置页](surfaces/settings.md)。
- `CodeBlock` 只画内嵌代码井，自己不带 `panelCard()`；帮助页的代码块也复用它。
- `PermissionsSection.swift`：设置页「权限与隐私」——逐项开关、系统授权状态、跳转系统设置（见 [§10](10-notch-island.md)）。
- `APIKeyField.swift` / `ProviderDirectory.swift` / `ProviderQuickSetup.swift` / `ProviderControls.swift` / `ProviderModelFetchButton.swift`：供应商目录与快速配置控件（见 [surfaces/providers.md](surfaces/providers.md)）。
- `BatteryChargeControls.swift`：能源卡的电池控制段（见 [technical/12](../technical/12-battery-control.md)）。
- `DecorativeMotion.swift`：Core Animation 装饰动效，不跑 SwiftUI 时间线。

## Theme 设计 token（`Theme/Theme.swift`）

### 色彩

| 类别 | Token | 用途 |
|------|-------|------|
| 基底 | `bgPrimary` / `bgSecondary` / `bgOverlay` / `cardSurface` | 浅色冰面 / 深色石墨两套表面阶 |
| Claude | `claude` / `claudeHi` | 软蓝，Claude Code |
| Cursor | `cursor` | 软紫，Cursor（文字用 `Theme.Ink.cursor`） |
| Codex | `codex` | 中性灰 `0x6B7280`，Codex 会话与供应商（文字用 `Theme.Ink.codex`） |
| 语义 | `statusBusy` / `statusIdle` / `statusWarning` / `statusError` / `statusSuccess` | 状态与反馈 |
| 文本 | `textPrimary` / `textSecondary` / `textTertiary()` | 三级字色 |

### 表面与排版

- **表面**：`panelCard()` = `cardSurface` 填充 + 可选强调水洗 + 内嵌白环 + 发丝线描边；`.tile()` = 更密的瓦片变体，两者共用 `UiverseSurfaces.swift` 的四个部件（底 / 水洗 / 角上深度环 / 内白环 + 悬停描边）；`shadowCard()`、`cardFill()`、`divider` / `hairline`；`HairlineDivider` 提供去卡片化的发丝线分区。
- **字体**：SF Pro 单族（`Font` 按系统字阶 + 显示字阶 + 界面字阶分层）；`displayMetric*` + `.monospacedDigit()`；瓦片字阶 `tileValue` / `tileLabel` / `tileDetail`；popup 密度别名 `rowTitle` / `micro*` / `badgeMono`。
- **宫格**：`GridLayout.Preset`（`pageMetric` 4 等分、`pageSession` / `pageUsage` / `pageProvider` 自适应；`pageSetting` / `pageSettingDense` / `popupSession` / `popupProvider` / `popupUsage` 目前没有外部调用点）+ `Space.gridGap` / `gridGapPage`。
- **动效**：`bouncy` / `smooth` / `snappy` / `sparkle` / `roll` + `Motion.page` / `Motion.state`——全部状态驱动，无常驻时间线。
- **Helper**：`contextColor(ratio)` / `contextInk(ratio)`、`barColor(for:)` / `barInk(for:)` + `djb2`、`sessionStatus(waiting:active:accent:ink:)`、`ContextLevel`（0.6 / 0.85 两级阈值）。
