# 视图层

> ClaudeBar 技术文档 · §5
> 相关：设计文档 [主窗口与设计系统](../design/05-main-window-and-theme.md) · [Popup 布局](../design/04-popup-layout.md) · 技术文档 [启动与窗口](02-app-launch-and-windows.md)

ClaudeBar 有两个 UI 面：菜单栏 popup（`MenuBarView` + `Views/Popup/`，424pt，`.menu` vibrancy）与主窗口（`MainWindowView` + 9 Pages，1120×720，`.underWindowBackground` vibrancy）。两者共享 `Theme/Theme.swift` 与 `Views/Shared/`。

## `Theme` — 设计 token 单点

`Theme/Theme.swift` 集中定义所有视觉常量，popup 与主窗口共用，保证配色一致：

- **颜色**：`base0` 0x0D0D11 → `base4` 0x353A45（中性近黑分层；旧 `bgPrimary`…`bgOverlay` 为别名）、`claude` 0x4F8EF7 / `claudeHi` 0x79ABF9（软蓝，Claude Code）、`cursor` 0xA78BFA / `cursorHi` 0xC0ACFC（软紫，Cursor）、`statusBusy`=claude、`statusActive`=cursor、`statusWarning` 0xE0A13C、`statusError` 0xE46464、`statusIdle` 0x8A8F98、`statusSuccess` 0x46C58F、`textPrimary` 0xF5F5F7 / `textSecondary` 0xA1A1A6 / `textTertiary()`。
- **间距/圆角/字距/字体**：`Space`（8pt grid：s2–s32 + `gridGap`/`gridGapPage` 宫格间距）、`Radius`（sm 6 / md 10 / lg 14 / xl 18）、`Tracking`、`Font`（titleLarge…caption + `labelSection`）+ `displayMetric`/`displayMetricSmall`（semibold + `.monospacedDigit()`）+ popup 密度别名（`rowTitle`/`rowLarge`/`micro*`/`captionMono`/`microMono`/`badgeMono`）+ 瓦片字阶（`tileValue`/`tileValueSmall`/`tileMicroValue`/`tileLabel`/`tileDetail`）+ `systemIcon(_:)`。
- **宫格**：`GridLayout.Preset`（`pageMetric` 4 等分 / `pageSession`·`pageUsage`·`pageProvider` 自适应 / `popupSession`·`popupProvider`·`popupUsage` 2 列）→ `columns(_:)` 返回 `[GridItem]`。
- **动画**：`Animation`（bouncy/smooth/snappy）、`Motion.page`/`Motion.state`——全部状态驱动。`pulse` 当前无调用点。
- **表面/Helper**：`panelCard()`（半透明白填充 + 发丝线描边的扁平卡片，**非** `glassEffect`——主窗口大面积玻璃曾占用约 100 MB GPU 纹理）、`.tile()`（宫格瓦片表面，与 `panelCard` 同族、更密更浅，实现在 `Views/Shared/Tile.swift` 的 `TileSurface`）、`shadowCard()`、`cardFill(_:)`、`sidebarFill`、`divider`/`hairline`、`contextColor(ratio)`（blue/warning/red）、`barColor(for:)` + `djb2`（跨进程稳定 hash 调色板）、`ActiveTileEdge`（accent 左缘选中态）、`HairlineDivider`（去卡片化的发丝线分区）、`Theme.Ink.*`（信号色的文字版）/ 原信号色（形状版）。macOS 26+ 上 `adaptiveGlassButton()` 为 popup 工具栏等控件提供原生 Liquid Glass 按钮，与内容卡表面无关。

## 表面语言（`Views/Shared/UiverseSurfaces.swift`）

一个表面 = 四个部件，`panelCard()` 与 `.tile()` 各自组装同一套：底 + 强调水洗、内嵌白环（`InnerFrameRing`，`Theme.innerFrame` / `innerFrameMuted`）、角上的深度环（`DepthLens`，一个 `Canvas`，三层**不同心**的环 —— 每层同时缩小并朝角落漂移，漂移才是"深度"的来源；**不画字形**）、悬停描边 + 2pt 抬升。

- `.tile(tint:hovered:dense:lens:framed:)` 是宫格形态；`.hoverTile(...)` 是"这个点的 body 没有别处要用 hover"时的简写（同一个 target 不开两个 `.onHover`）。
- **角上已有内容的卡片不加 `lens`**（会话瓦片的角上是子 agent 簇），只取 `tint` 的水洗。
- `SegmentedCapsule` 是唯一的筛选 / 分段控件：一个胶囊井 + 一颗 `matchedGeometryEffect` 滑动药丸，连接器的类型与平台筛选、供应商的客户端与分类筛选、用量的周期条、VPN 的分组条都走它。
- `OrbitGauge`（额度表盘：trim 弧 + 沿弧走的圆点）、`ConveyorBelt`（扫描中那种"正在持续做事"的走带，`DecorativeMotion.kind == .conveyor`）、`ShineSweep` + `.depthTilt()`（一次性扫光与 3D 倾斜，**只给单张 hero 卡**，不进 `.tile()`）。这里**已经没有 `LoadRing`**：它曾是唯一按读数调速的装饰（一条光的弧绕在机器图标背后，转速 ∝ 读数，<5% 完全静止，读数变化时用 `timeOffset` 就地重定时），但约 96° 的弧在 22–28pt 上读起来就是「转圈 = 等待」，而且它复述了下方三行已经印出的数字 —— 视图与 `DecorativeMotion.loadRing` 一并删除。实时读数改由右侧的 mark 承担：**上层是 Lucide 官方图标（`cpu` / `gpu` / `memory-stick` / `hard-drive`，由 `Tools/gen-lucide-hardware.py` 生成到 `LucideHardwareGeometry.swift`），下层是读数条 —— CPU 每个逻辑核心一条、GPU 每组图形子单元一条、内存按页类别、硬盘按已用/空闲，条高即读数**，另有一条按读数调速的扫光（`TimelineView` 驱动，<4%、减弱动效或不可见时停止）（见 `HardwareIllustration` 与 [DESIGN.md](../../DESIGN.md) 的 Machine marks）。
- 成本口径：装饰是几何而不是动画（每个 `Canvas` 只画一次）；两处会动的东西（扫光、走带）都由 `surfaceIsVisible` + 减弱动效双重门控；3D 倾斜只在被悬停的那一张上。见 [DESIGN.md](../../DESIGN.md) 的 Motion / performance。


## `MenuBarView` + `Views/Popup/` — 菜单栏 popup

`MenuBarView` 是组合壳（宽 424pt 的 `VStack`）：

- **PanelHeader**：Brand + 模型/VPN 切换 chip（`HeaderSwitchChip` + `VpnNodePickerPanel`）+ 刷新。
- **MachineKpiStrip**：本机资源（CPU / GPU / 内存 / 风扇，耳机在用时时多一格）。
- **PowerFlowCard(compact)**：有内置电池时的能源流向紧凑卡。
- **SessionsPanel / UsagePanel**：各自观察自己的字段；Provider 宫格只存在于主窗口（popup 的模型切换在 `PanelHeader` 的 chip 里）。
- **PanelState / FeedbackToast**：toast 只由 `overlay` 里那个 reader 订阅，写反馈不再重算整个外壳。
- **底部操作栏**：刷新 / 主窗口 / 帮助 / 还原官方配置 / 管理模型 / settings.json / 空闲通知 / 深浅色 / 退出。

**外壳订阅范围**：只订阅 `hasSettingsFile` 与「Codex 供应商是否为空」，以及它自己渲染的 `appearance` / `idleNotifyEnabled`；会话与用量由各自面板观察。主题切换**不**用 `.id()` 重建整个 popup（那会重置滚动位置与展开态，而底部操作栏本身就能切主题）。

**视觉规范**：
- 配色统一 `Theme` token（`textPrimary`/`textSecondary`/`textTertiary()`/`accent`/`statusBusy`/`cursorAccent`/`divider` 等）。
- 上下文健康：`ratio < 0.6` 蓝、`< 0.85` 黄、否则红（`Theme.contextColor`）。
- busy/active 的状态点是静态实心 + 光晕环（`BusyPulseRing` 不再脉冲；`Theme.Animation.pulse` 当前无调用点）。
- 反馈 toast（`PanelState.showFeedback` + `FeedbackToast`）2 秒淡出。

**双击行为**（经共享 `TerminalLauncher`，先把活会话的宿主窗口带到前台；见 [§9](09-file-index.md) 的 `SessionHost` / `OttyBridge`）：
- Claude 会话：`TerminalLauncher.resumeClaudeSession(cwd:sessionId:pid:)` —— 会话进程仍活着就只聚焦宿主（Otty 走 socket，无需自动化权限）；已结束的才按「继续会话」偏好（自动 / Otty / Warp / 终端）执行 `claude --resume`。
- Cursor 会话：`TerminalLauncher.openInCursor(cwd:)` 或 `NSWorkspace` 打开 Cursor.app + cwd。

编辑器由主窗口的「模型」页承载（`ProvidersView` 打开 `ProviderConnectionEditor` 单连接弹窗）；popup 底部的「管理模型」只负责带着目的地 post `.showMainWindow` 切页，不再持有自己的 NSWindow。

## `ProviderTile`（`Views/ProviderRow.swift`）

- `ProviderTile`：供应商瓦片（自适应网格；`dense` 切换密度）。**唯一没有挂载点的视图**（`ProvidersView` 走 `ProviderDirectoryHost` + `ProviderConnectionEditor`）—— 单文件 232 行，不引用任何只为它存在的类型，所以留着而不是删掉：它组合的 `SignatureGlyph` / `ConnectivityTileButton` / `ActiveTileEdge` / `StatusPill` 都另有实际调用点，且它是目录宫格那颗瓦片的唯一成稿。见 [17](17-ui-audit-backlog.md) §9。瓦片头 = Provider 名 + 活跃胶囊 + chevron；激活瓦片顶部 48×3pt accent 胶囊 + 内描边。模型名匹配用 case-insensitive（settings.json 大小写可能不同）。
- `popup` 的模型切换走 `PanelHeader` 的 chip → `ModelSwitchList`，不用瓦片网格；`PopupModelTile` 已删除。
- `formatContext`：`200000 → 200K`、`1000000 → 1M`。

## `ProviderEditorView` — 已删除

源码里那套 master-detail 编辑器（`ProviderEditorView` / `CodexProviderEditorView` /
`ProviderEditorSidebar` / `ProviderEditorModel` / `CodexEditorModel`，1,512 行）没有挂载点，
主窗口「模型」页一直渲染的是 `ProviderDirectoryHost` + `ProviderConnectionEditor` 弹窗，
所以它被删掉了 —— 一个没有任何调用点的第二套编辑器只会在改字段时误导人。

它持有过四个只有它才有的字段（Claude `contextTokens` / `disableCompact` /
`disableExperimentalBetas`，Codex `contextWindow` / `autoCompactTokenLimit`）；删之前这些
字段已经折进 `ProviderConnectionEditor`（`modelOptions`），所以能力没有留下缺口。新增字段
请照 [10-extension-guide](10-extension-guide.md) 走 `ProviderConnectionModel`。

## Widget 视图 `WidgetViews.swift`

`WidgetEntryView` 渲染 systemLarge：
- Header：ClaudeBar + 大号 token 总数 + 余额。
- Provider + Model + 相对时间。
- 模型分布条（多个模型按 ratio 横向拼接）+ 图例。
- 活跃会话列表（最多 3 条 Claude + 3 条 Cursor），每行状态点 + 项目 + 活动 + 上下文条。
- 空态显示 "等待数据..."。
- 点击整个 Widget 触发 `claudebar://` 唤起主面板。

`WidgetProvider.getTimeline`：读快照（四路回退），30s 后刷新；读失败返回 `diagnosticEntry`（把诊断字符串塞进 `activeProviderName` 显示，如 `UD:2048B F:Y/2048B`）。
