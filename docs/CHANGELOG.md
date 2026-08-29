# 更新日志 / Changelog

> 本日志记录 ClaudeBar 各版本的演进。日期为代码实际提交日期，由文件修改时间与代码内容推断。

---

## [1.7.0] — 2026-08-29 · 信息优先重构

### 删除 — 装饰性组件（不承载数据的视觉全部移除）
- `Views/Shared/LiveRadar.swift`（实时雷达，含 `RadarBlip`/`RadarAgentDetail`）、`LivePulseGraph.swift`（伪正弦信号历史，不编码真实数据）、`SignalTrace.swift`（动画均衡器）、`PointerFX.swift`（`TiltOnHover`/`SpecularSheen`/`CursorSpotlight`）。
- Theme token：`enum Radar`、`accentGradient`/`cursorGradient`/`barGradient`/`contextGradient`（各调用点改纯色 `barColor`/`contextColor`/`claude`）、`beaconGlow`/`ambientGlow`、`glassCard`、`Elevation`+`elevation()`、`glassContainer`/`topLuminance`、`Animation.lively`。

### 变更 — 动效原则：全部状态驱动
- 仅保留有动机的动效：hover 反馈、busy 状态脉冲（`StatusBadge`/header orb）、页面切换淡入、`contentTransition(.numericText())` 数字滚动。删除 scrollTransition、symbolEffect(.bounce)、玻璃 morph 侧栏 pill（`glassEffectID` matchedGeometry → 简单选中填充）、`GlassEffectContainer` 非必要包裹。

### 变更 — Dashboard 信息化
- 移除雷达 hero + "信号历史"，新布局：**指标头行**（4 个 StatTile：活跃配置/余额/会话 busy-total/Token 总量，tabular 数字，点按跳转对应页）→ **活跃会话总览**（每行：源色点 + busy 点 + 项目/活动 + ContextBar + 上下文标签 + 更新时间，无需交互即可读全，上限 8 行 + 查看全部）→ **用量 Top**（加常显百分比，bar 纯色）。

### 变更 — 其余页面与 popup
- `MainWindowView`：侧栏去装饰（静态 brand orb、简单选中填充、静态 footer 圆点、纯 opacity 页面过渡）。
- `SessionsView`/`UsageView`：去 scrollTransition/symbolEffect；UsageBarRow 恒定高度 + 百分比常显。
- Popup：`SessionCardView`/`CursorSessionCardView` 字号 8-9pt → 10-11pt（可读性优先）；header 去 beaconGlow。
- `SettingsView` 版本号 1.4.0 → 1.6.0。

---

## [1.6.0] — 2026-08-01 · 指挥中枢 (Dispatch Radar) 视觉重构

### 新增 — 设计世界
- **视觉世界替换**：深空靛蓝 + 琥珀(Claude)/青(Cursor) 双信号，取代"近黑 + 荧光绿 + 全玻璃"的默认配方。整个应用读作 AI agent 的调度台。
- 新增签名组件 `Views/Shared/LiveRadar.swift`：Canvas + `TimelineView` 实时雷达——graticule 同心环/准线/刻度、示波器面板底、扫描束（随负载加速）、会话光点（上下文映射轨道半径，busy 时 ping 扩散环）、悬停标签。**点击光点 → 内联 agent 读数**（`RadarAgentDetail`：上下文/模型/消息/时间 + 恢复/Finder/跳转会话页），雷达即调度台。`accessibilityReduceMotion` 降级。
- 新增 `Views/Shared/SignalTrace.swift`：忙碌会话行内实时等化器（4 柱 TimelineView 波纹，reduced motion 降级）。
- 新增 `Views/Shared/RadarBackdrop.swift`（替换 `AuroraBackground`）：极淡雷达刻度网格 + 缓慢扫描光 + 颗粒 + 暗角；移除昂贵的 `MeshGradient`。

### 变更 — Theme 设计 token（`Theme/Theme.swift` 重写）
- **材质改为 macOS 26 原生 Liquid Glass（透明毛玻璃）**：`panelCard()` 重定义为原生 `glassEffect`，所有内容卡为真实模糊+透光+毛玻璃边缘高光；桌面透过 vibrancy 显示。整个应用是连续的玻璃台面，不再是实体面板。
- **配色改为近单色 + 冷色信号**（多次否定高饱和暖色后收敛）：中性近黑基底 `base0` 0x0D0D11（无色彩偏向）；**Claude 软蓝** `claude` 0x4F8EF7、**Cursor 软紫** `cursor` 0xA78BFA；语义色去饱和（`statusWarning` 0xE0A13C、`statusError` 0xE46464、`statusIdle` 0x8A8F98、`statusSuccess` 0x46C58F）。层级由字体字重驱动，色彩只用于状态/身份。
- **删除背景雷达**：移除 `RadarBackdrop`（graticule 同心环/准线/扫描 全窗装饰）——那是噪音；真正的雷达只在仪表盘。窗口背景为干净 vibrancy + 极淡 `CursorSpotlight`。
- 文本：`textPrimary` 0xF4F6F9（毛玻璃上高可读）、`textSecondary` 0xA7B0BE。
- 字体高级化：`displayMetric`/`displayMetricSmall` 改 SF Pro semibold + `.monospacedDigit()`（表格数字，弃用整段 mono）；`titleLarge` 28pt bold、tracking 收紧；数据仍用 mono（合法：测量）。
- 文本溢出修复：读数 value 支持 `truncationMode(.tail)` + `minimumScaleFactor`，长文本值（如 provider/model）用自适应小字号；会话行/卡片/详情统一 `lineLimit(1)` 截断。
- 新增 `beaconGlow()`（信标光晕）、`GlassEffectContainer` 包裹相邻玻璃卡合并模糊。
- 动效 token 速度优先（`smooth` ~0.2s）；移除每页 `StaggeredEntrance` 入场编排，页面切换快速淡入 + 轻 scale。

### 变更 — 视图
- `MainWindowView`：侧栏→"花名册"（信标 brand mark、导航行实时 blip 徽标、琥珀信号选中 pill 保留 glass morph、底部 `STANDBY/N RUNNING`）；页面过渡简化。
- `DashboardView`：移除四张 stat 卡与入场编排 → **雷达 hero**（`LiveRadar`）+ 系统遥测读数列（活跃配置/余额/会话/Token，mono instrument register）+ 信号历史（`LivePulseGraph` 琥珀信号）+ 活跃频道 + 用量 Top。
- `SessionsView`/`UsageView`/`SettingsView`/`ProvidersView`/`ProviderEditorView`/`ProviderRow`/`MenuBarView`：按新 token 与面板材质重排，去掉装饰性 left-edge / ambient glow / 入场编排。
- `Shared/`：`StatusBadge`/`ActivityLine` idle 色→`statusIdle`；`SessionCardView`/`CursorSessionCardView`→阳极面板 blip 卡；`IconChip`/`ActionChchip`→信标光晕；`CursorSpotlight`→极淡 beacon；`LivePulseGraph`→琥珀信号。
- Widget `WidgetTheme` 镜像新值（indigo 基底 + amber/teal）。

### 删除
- `Views/Shared/StaggeredEntrance.swift`、`AuroraBackground.swift`、`RadarBackdrop.swift`、`Theme.meshPoints`。

---

## [1.5.0] — 2026-08-01

### 新增 — 主窗口
- 新增 `MainWindowController`（1120×720，`.underWindowBackground` vibrancy，`fullSizeContentView`，透明标题栏）+ `MainWindowView`（`NavigationSplitView`）：sidebar 5 项（概览 / 会话 / 供应商 / 用量 / 设置）+ `matchedGeometryEffect` 选中 pill + 实时计数 badge（`numericText`）+ `.asymmetric` 页面切换过渡 + `AuroraBackground`（MeshGradient 漂移）+ `CursorSpotlight`（指针跟随光晕）+ `CommandPalette`（⌘K 模糊搜索导航）。
- 新增 5 个主窗口页面 `Views/Pages/`：`DashboardView`（stat cards + pulse graph + activity feed）、`SessionsView`（全宽会话行 + 子 agent 树 + 双击恢复）、`ProvidersView`（嵌入 `ProviderEditorView`）、`UsageView`（周期 chips + 用量条形图）、`SettingsView`。
- 新增 `applicationShouldHandleReopen` 重开主窗口；`applicationShouldTerminateAfterLastWindowClosed = false` 保活。

### 新增 — Theme 设计系统
- 新增 `Theme/Theme.swift` 设计 token 单点：颜色（`bgPrimary` 0x000B1A / `accent` 0x68E78E Harmony Green / `cursorAccent` 0x9E85F2 / `statusWarning`/`statusError`）、间距 `Space`（8pt grid）、`Radius`、`Font`、`Animation`、`shadowCard()`/`glassCard()`/`contextColor()`。popup 与主窗口共用，统一配色。
- 新增 13 个共享交互组件 `Views/Shared/`：`PressableStyle`（.pressable）、`HoverState`（.hoverState）、`IconChip`、`ActionChip`、`TiltOnHover`（.tiltOnHover + SpecularSheen）、`CursorSpotlight`、`AuroraBackground`、`CommandPalette`、`LivePulseGraph`、`StaggeredEntrance`、`StatusBadge`、`ActivityLine`、`SessionCardView`/`CursorSessionCardView`/`UsageRowView`。

### 变更 — 激活策略
- `.accessory`（`LSUIElement=true`）→ `.regular`（`LSUIElement=false`）：现含 Dock 图标 + 主窗口，菜单栏 status item popup 保留为快速概览。
- 最低系统 macOS 14.0 → macOS 15.0（依赖 `symbolEffect`/`MeshGradient`/`sensoryFeedback`/`onGeometryChange`）。

### 重构 — 结构优化（D 组）
- **删除死代码**：`InteractiveCard`/`interactiveCard()`、`FocusRing`/`focusRing()`、`HoverReveal`/`hoverReveal()`（`Interaction.swift`）、`ContextBar.swift` 整文件（均 0 调用点）。
- **去重**：提取 `Utils/CursorDB.swift`（共享 SQLite 打开 + `textColumn`，供 `CursorSessionMonitor`/`CursorUsageStats` 复用）、`Utils/JSONCoerce.swift`（共享 `intVal`，消除 3 份重复）、`Utils/TerminalLauncher.swift`（共享 `resumeClaudeSession`/`openInCursor`，统一 Warp 优先 + osascript + Terminal 回退，消除 `MenuBarView` 与 `SessionsView` 两份实现）。
- **Token 迁移（D3）**：`ProviderRow`（0→22 Theme 引用）、`ProviderEditorView`、`MenuBarView`（CB logo 渐变 + 散落 `Color(white: x)`）统一迁移到 `Theme` token，popup 与主窗口视觉一致。
- `ProviderStore.writeWidgetSnapshot()` 拆为 `buildSnapshot()` + `persistSnapshot(_:)`。

### 修复 — Bug（B 组）
- **B1**：`ProviderStore` 加 `deinit { sessionTimer?.invalidate() }`，修复轮询定时器泄漏。
- **B2**：`refreshCursorSessions()` / `refreshUsage()` 的 `Task.detached` 改用 `MainActor.run { [weak self] in }`，修复强引用 self + Swift 6 "captured var" 警告。
- **B3**：`CursorSessionMonitor` 的 `map[key]!` → `map[key]?.sort`，消除 force-unwrap 崩溃面（并入 `CursorDB` 重构）。
- **B4**：`SettingsManager.preserve()` 空值保留语义确认为有意设计（保护用户手填配置），在 `design.md` §5.1 文档化此取舍；`buildEnv()` 切换时显式写入新 Provider token 已覆盖风险。
- **B5**：`BalanceFetcher` 由 `baseURL.contains("deepseek")` 改为 `URL(string:)?.host` 判定，避免向非预期主机发送 token。
- **B6**：`writeWidgetSnapshot()` 加 diff 缓存，仅数据变化时才写四路文件 + `reloadAllTimelines()`；删除已弃用的 `shared.synchronize()`。
- **B7**：`ProviderStore.init()` 移除 `refresh()`，统一由 AppDelegate 启动时调用，避免重复刷新。
- **B8**：`usageReferenceDate.didSet` 加 `!= oldValue` 守卫，避免值未变也触发全量扫描。
- **B9**：删除 `updateProvider` 中 no-op 的 `if activeProviderID == provider.id { activeProviderID = provider.id }`。
- **B10**：`balanceText` 现含币种（`"\(balance) \(currency)"`）。
- **B11**：`readSettings()` 简化为返回 `EnvConfig?`，删除无调用方的 `raw` 元组通道。

### 文档
- `design.md`：§1 产品概述、§2 架构图、§3.2 `buildEnv` 取舍、新增 §4b 主窗口与设计系统、§5 交互流程、§6 文件结构、§8 构建全面对齐当前代码。
- `architecture.md`：最低系统 macOS 15.0、`LSUIElement=false`、`.regular` 激活策略、新增 §2.2/§2.3 主窗口架构、§4.3 Widget diff、§4.8 host 判定、§5 Theme token 与 token 迁移、§9 文件索引更新。
- `CHANGELOG.md`：新增本段。

---

## [1.4.0] — 2026-08-01

### 文档
- 重写 `docs/design.md`：对齐当前 Provider/Model 架构、会话监控、用量统计、Widget 的真实代码状态，替换早期已过时的 Preset 扁平列表设计。
- 新增 `docs/architecture.md`：完整技术实现文档，覆盖构建命令、NSPanel 定位、ProviderStore 状态中枢、各数据访问模块、迁移逻辑、签名陷阱与扩展指南。
- 新增本更新日志 `docs/CHANGELOG.md`。
- 删除历史实现计划 `docs/superpowers/plans/`（已归档，内容过时）。

### 代码
- 无功能变更，本次为文档补全版本。

---

## [1.3.0] — 2026-07-31

### 新增 — Cursor IDE 集成
- 新增 `CursorSessionMonitor`：只读访问 Cursor 的 `state.vscdb`（SQLite，WAL 模式并发安全），解析 `composerHeaders` 表，按 recency 取最近 80 个 composer，过滤 3 天内活跃会话并展示。
- 新增 `CursorUsageStats`：聚合 `cursorDiskKV` 表中 `bubbleId:*` 的历史 token 计数为单条 "Cursor" 行（受 Cursor 自 2026-03 起停止写入 token 的限制，为全量值）。
- 新增 Cursor 会话卡片：紫色 accent，百分比上下文条，双击用 Cursor.app 打开 workspace。
- Widget 增加 Cursor 会话区段。

### 新增 — WidgetKit 扩展
- 新增 `Sources/Widget/`：`ClaudeBarWidget`（systemLarge）、`WidgetProvider`（TimelineProvider，30s 刷新）、`WidgetViews`（渲染 token 总数、余额、模型分布、活跃会话）。
- 主 app `writeWidgetSnapshot()` 四路冗余写入快照（App Group 文件 / `~/.claude` / Widget 沙盒容器 / UserDefaults），保证沙盒 Widget 必能读取。
- Widget 点击通过 `claudebar://` URL scheme 唤起主面板。
- `build.sh` 扩展为编译 Widget appex + 签名 + `lsregister`/`pluginkit` 注册。

### 重构 — 面板控制器
- 弃用 SwiftUI `MenuBarExtra`，改用自定义 `NSStatusItem` + `KeyablePanel`（`NSPanel` 子类）。
- 面板毛玻璃背景（`NSVisualEffectView.material: .menu`），以状态项图标 x 中心水平居中，紧贴菜单栏下方。
- 非激活面板（`.nonactivatingPanel`）可成为 key window 但不抢终端焦点；失焦自动收起（local + global mouse monitor）。
- `ClaudeBarApp` 改用 `@NSApplicationDelegateAdaptor` + `.accessory` 激活策略。

### 增强 — 会话监控
- `SessionMonitor` 增加子 Agent / Workflow 扫描（`subagents/*.meta.json` + `subagents/workflows/<id>/`）。
- 上下文扫描读 transcript 尾部 96KB，支持 `toolPending` 判定（tool_use 无后续 tool_result → busy）。
- 会话卡片改为 2 列 `LazyVGrid` 紧凑布局；双击在 Warp（优先）或 Terminal 执行 `claude --resume <sessionId>`。

### 增强 — 用量统计
- 周期切换：日 / 月 / 年 / 自定义日期，支持 ◀ ▶ 翻页。
- 三级过滤优化：文件 mtime 预筛 + UTC 日期字符串粗筛 + 精确时间戳解析，`concurrentPerform` 并行。

### 其他
- `FilePaths` 增加 Cursor 路径与 cwd 编码（去前导 `/`，不加前导 `-`，区别于 Claude Code）。
- `SettingsManager.writeSettings` 增加空值保留逻辑（`preserve`），避免空字段覆盖用户已有配置；修复 JSONSerialization 转义 `\/` 的问题。

---

## [1.2.0] — 2026-07-30

### 重构 — Preset → Provider/Model 架构
- 引入 `Provider`（一个服务商，共享 baseURL + authToken，下挂多 `ModelConfig`）替代扁平 `Preset` 列表。
- 新增 `MigrationHelper`：旧 `claude-bar-presets.json` 按 baseURL 分组自动迁移为 `claude-bar-providers.json`，迁移后删除旧文件。
- `Provider.Decodable` 兼容旧格式（`models` 为 `[String]`、`activeModel` 为模型名）。
- 数据文件 `claude-bar-presets.json` → `claude-bar-providers.json`。

### 新增 — Provider 编辑器
- `ProviderEditorView`：独立 NSWindow，左侧 Provider 列表（增/删/复制），右侧 master-detail（Provider 配置 + 模型列表管理）。
- 模型可设默认、编辑 contextTokens / disableCompact / disableExperimentalBetas / autoCompactWindow。

### 新增 — 会话与用量监控雏形
- `SessionMonitor`：扫描 `~/.claude/sessions/*.json`，`kill(pid, 0)` 判活，读 transcript 上下文。
- `UsageStats`：扫描 `~/.claude/projects/**/*.jsonl` 聚合 per-model token。
- `BalanceFetcher`：DeepSeek 余额 API（仅 baseURL 含 "deepseek" 时）。
- `ProviderRow`：支持单模型 / 多模型可折叠行。
- 面板增加会话区、用量区、当前配置区。

### 扩展 — EnvConfig
- 新增字段：`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`、`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL[_NAME]`、`CLAUDE_CODE_AUTO_COMPACT_WINDOW`。
- `buildEnv` 把所选模型名同时写入全部 4 个 tier 的 DEFAULT_MODEL 字段。

---

## [1.1.0] — 2026-06-23

### 增强
- `Preset.swift` 扩展 `EnvConfig` 至全部 Claude Code env 键，增加自定义 `Decodable`（全字段 `decodeIfPresent` 缺失默认空）。
- `Preset` 增加缺失 id 自动生成，兼容无 id 的旧数据。

---

## [1.0.0] — 2026-06-08

### 初始版本
- macOS 菜单栏应用，基于 SwiftUI `MenuBarExtra`，切换 Claude Code 配置预设。
- `Preset` / `PresetStore` / `SettingsManager` 数据层，读写 `~/.claude/settings.json` 与 `~/.claude/claude-bar-presets.json`。
- `MenuBarView` / `PresetRow` / `PresetEditorView` 三视图。
- `build.sh` 用 `swiftc` + shell 构建（无 Xcode 工程）。
- Pencil 原型 `ClaudeBar.pen` 与应用图标资源。
