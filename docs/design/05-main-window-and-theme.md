# 主窗口与设计系统 — 信息优先

> ClaudeBar 设计文档 · §5（信息优先重构 1.7.0）
> 相关：[顶层架构](02-architecture.md) · 技术文档 [视图层](../technical/05-view-layer.md)

## 设计原则

ClaudeBar 的界面以**信息可视化**为唯一目标：数字 tabular 对齐、层级由字重与排版驱动、色彩只用于身份（Claude 蓝/Cursor 紫）与状态（busy/warning/error）。动效全部状态驱动（hover 反馈、busy 脉冲、页面淡入），不存在不承载数据的装饰性视觉。表面仍为 macOS 26 原生 **Liquid Glass**（`panelCard()`），但无玻璃 morph、无背景光斑、无信标光晕。

## 主窗口（`MainWindowController` + `MainWindowView`）

1120×720 `NSWindow`（`.underWindowBackground` vibrancy + `fullSizeContentView` + 透明标题栏），`NavigationSplitView`：

- **Sidebar**：静态 brand mark（"CB" 蓝色圆标）+ 5 项导航（图标 + 标签 + 实时计数 badge）；选中项为简单 accent 填充，hover 变亮。底部状态圆点（busy 时变蓝）+ "N 运行中/空闲"。
- **Detail**：按 `selectedPage` 切换 5 页，纯 opacity 过渡（`Theme.Motion.page`）。
- **全局**：⌘K `CommandPalette`；关窗后 status item 保活。

## 5 个 Pages

- **DashboardView**：信息优先总览。**指标头行**（4 个 StatTile：活跃配置/余额/会话 busy-total/Token 总量；label 在上、`displayMetricSmall` + `.monospacedDigit()` tabular 值在下，点按跳转对应页）→ **活跃会话总览**（每行：源色点 + busy 点 + 项目/当前活动 + ContextBar + 上下文标签 + 更新时间，无需交互即全部可读；上限 8 行 + "查看全部"）→ **用量 Top**（比例条 + 常显百分比 + token 数）。
- **SessionsView**：CLAUDE CODE / CURSOR 两个频道面板（`panelCard`），全宽会话行，可展开子 agent 树，双击恢复；hover 行揭示 action chips（有动机的 hover 反馈）。
- **ProvidersView**：嵌入 `ProviderEditorView`。
- **UsageView**：周期 chips + 日期导航 + 用量条形图（恒定高度、百分比常显）。
- **SettingsView**：面板卡设置页。

## 共享交互层（`Views/Shared/`）

- `PressableStyle`、`HoverState`、`ActionChip`/`IconChip`（hover 反馈）、`StatusBadge`（busy 脉冲点）、`ActivityLine`、`ContextBar`（上下文健康条）、`SessionCardView`/`CursorSessionCardView`（popup 紧凑卡）、`UsageRowView`、`CommandPalette`（⌘K）。

## Theme 设计 token（`Theme/Theme.swift`）

- **基底**：`base0` 0x0D0D11 … `base4` 0x353A45（中性近黑，无色彩偏向）。
- **信号**：`claude` 0x4F8EF7 / `claudeHi`（软蓝，Claude Code）；`cursor` 0xA78BFA / `cursorHi`（软紫，Cursor）。`accent=claude`。
- **语义**：`statusBusy`=claude、`statusActive`=cursor、`statusIdle`、`statusWarning` 0xE0A13C、`statusError` 0xE46464、`statusSuccess` 0x46C58F。
- **文本**：`textPrimary` 0xF5F5F7、`textSecondary` 0xA1A1A6、`textTertiary()`。
- **表面**：`panelCard()` = 原生 `glassEffect`（内容卡主表面）、`shadowCard()`、`cardFill()`、`divider`/`hairline`。
- **字体**：SF Pro 单族，字号+字重驱动层级；`displayMetric`/`displayMetricSmall` semibold + `.monospacedDigit()`；代码/测量值用 mono（`captionMono`）。
- **动效**：`bouncy`/`smooth`/`pulse`/`snappy` + `Motion.page`/`Motion.state`——全部状态驱动，无循环装饰动画。
- **Helper**：`contextColor(ratio)`（blue/warning/red 阈值）、`barColor(for:)`（hash 调色板）。

## 设计世界：指挥中枢

ClaudeBar 是你运行中的 AI agent 的调度台。深空靛蓝基底（非近黑）上，琥珀是 Claude Code 信号、青是 Cursor 信号；界面读作任务调度/仪表：发丝刻度网格、信标光晕、阳极氧化面板。**签名时刻**是主窗口仪表盘上的**实时雷达**：每个活跃会话化为轨道光点，忙碌时 ping 扩散，扫描束随负载加速。

- **THESIS**：ClaudeBar 是 AI agent 的指挥中枢，以 macOS 26 原生 **Liquid Glass（透明毛玻璃）** 呈现——真实模糊、透光、毛玻璃边缘高光；近单色的克制配色，**软蓝(Claude)/紫(Cursor)** 信号，层级由字体驱动。
- **OWN-WORLD**：透明毛玻璃面板（原生 `glassEffect`，桌面透过 vibrancy 显示）；干净背景（无装饰性雷达网格，真雷达只在仪表盘）；软蓝/紫信号仅用于身份与状态；信标光晕（仅活动/选中）。
- **STORY**：开发者瞥一眼菜单栏 → 打开面板/主窗口 → 雷达显示 agent 在轨道上工作；悬停光点看它在干嘛，点击跳到会话页；余额与 token 像遥测读数。
- **FORM**：雷达扫描束 + 轨道光点（唯一 authored 时刻）；其余界面精密、克制、速度优先（Operate）。

## 主窗口（`MainWindowController` + `MainWindowView`）

1120×720 `NSWindow`（`.underWindowBackground` vibrancy + `fullSizeContentView` + 透明标题栏），`NavigationSplitView`：

- **Sidebar（花名册）**：信标 brand mark（琥珀 orb + ping 环）+ 5 项导航，每项带实时 blip 徽标；选中项用 Liquid Glass `glassEffectID` morph 的琥珀信号 pill；底部 `STANDBY / N RUNNING` 状态。
- **Detail**：按 `selectedPage` 切换 5 页，快速淡入 + 轻 scale（`Theme.Motion.page`）。
- **全局**：干净玻璃背景（vibrancy + 极淡 `CursorSpotlight` beacon，无装饰性雷达网格）；`⌘K` `CommandPalette`；关窗后 status item 保活。

## 5 个 Pages

- **DashboardView**：**雷达 hero**（`LiveRadar`，签名）+ 系统遥测读数列（活跃配置/余额/会话/Token 总量，mono instrument register + 发丝分隔）+ 信号历史（`LivePulseGraph` 琥珀波形）+ 活跃频道 + 用量 Top。点击读数/光点跳转到对应页。
- **SessionsView**：CLAUDE CODE / CURSOR 两个频道面板（`panelCard`），全宽会话行，可展开子 agent 树，双击恢复；hover 行 lift + action chips 滑入。
- **ProvidersView**：嵌入 `ProviderEditorView`（阳极面板材质）。
- **UsageView**：周期 chips（玻璃分段控件）+ 日期导航 + 信号色用量条形图。
- **SettingsView**：面板卡设置页。

## 共享交互层（`Views/Shared/`）

- `LiveRadar`（签名）、`RadarBackdrop`（背景）。
- `PressableStyle`、`HoverState`、`IconChip`/`ActionChip`（信标光晕）、`TiltOnHover`、`CursorSpotlight`。
- `CommandPalette`（⌘K）、`LivePulseGraph`（琥珀信号）、`StatusBadge`、`ActivityLine`、`ContextBar`、`SessionCardView`/`CursorSessionCardView`（阳极 blip 卡）、`UsageRowView`。

## Theme 设计 token（`Theme/Theme.swift`）

- **基底**：`base0` 0x0D0D11（中性近黑，无色彩偏向）/ `base1` 0x15151B / `base2` 0x1E2026 / `base3` 0x292C34 / `base4` 0x353A45。旧名 `bgPrimary`…`bgOverlay` 保留别名。
- **信号**：`claude` 0x4F8EF7 / `claudeHi` 0x79ABF9（软蓝，Claude Code）；`cursor` 0xA78BFA / `cursorHi` 0xC0ACFC（软紫，Cursor）。`accent=claude`、`accentDim` 0x3A6FD1、`cursorAccent=cursor`。
- **语义**：`statusBusy`=claude、`statusWarning` 0xE0A13C、`statusError` 0xE46464、`statusIdle` 0x8A8F98、`statusSuccess` 0x46C58F。
- **文本**：`textPrimary` 0xF4F6F9（毛玻璃上高可读）、`textSecondary` 0xA7B0BE、`textTertiary()`。
- **表面**：`panelCard()` = **原生 Liquid Glass**（`glassEffect`，真模糊+透光；内容卡主表面）、`glassCard()`（别名）、`beaconGlow()`（信标光晕）、`elevation`、`GlassEffectContainer` 包裹相邻玻璃卡合并模糊。`RadarBackdrop` 透明，桌面透过 vibrancy 显示。
- **字体**：SF Pro 单族，字号+字重驱动层级（Linear 式）；`displayMetric`（30pt）/`displayMetricSmall`（19pt）SF Pro semibold + `.monospacedDigit()`（表格数字，弃用整段 mono）；代码/测量值仍用 SF Mono。
- **动效**：`bouncy`/`smooth`/`pulse`/`snappy` + `Motion.page`/`Motion.state`（速度优先，150–250ms）。雷达扫描由 `TimelineView` 驱动，不走 spring。移除 `StaggeredEntrance` 入场编排。
- **Radar**：`Theme.Radar`（ring/crosshair/sweep 色）供雷达与背景共用。
- **Helper**：`contextColor(ratio)`（amber/warning/red 阈值不变）、`barColor(for:)`（信号系 hash 调色板）、`contextGradient`/`barGradient`。
