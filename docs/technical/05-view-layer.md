# 视图层

> ClaudeBar 技术文档 · §5
> 相关：设计文档 [主窗口与设计系统](../design/05-main-window-and-theme.md) · [Popup 布局](../design/04-popup-layout.md) · 技术文档 [启动与窗口](02-app-launch-and-windows.md)

ClaudeBar 有两个 UI 面：菜单栏 popup（`MenuBarView` + `Views/Popup/`，460pt，`.menu` vibrancy）与主窗口（`MainWindowView` + 9 Pages，1120×720，`.underWindowBackground` vibrancy）。两者共享 `Theme/Theme.swift` 与 `Views/Shared/`。

## `Theme` — 设计 token 单点

`Theme/Theme.swift` 集中定义所有视觉常量，popup 与主窗口共用，保证配色一致：

- **颜色**：基底四层 `bgPrimary`（浅 `#EEF3F8` / 深 `#16181C`）、`bgSecondary`、`bgOverlay`、`cardSurface`；信号色 `claude` 0x3D7DFF / `claudeHi` · `cursor` 0x8B7CFF · `codex` 0x6B7280 · `chartGreen`/`chartBlue`/`chartAmber`/`chartPurple` · `external`；语义色 `statusBusy`=claude、`statusIdle`、`statusWarning`、`statusError`、`statusSuccess`；文字 `textPrimary` / `textSecondary` / `textTertiary()`，以及 **`Theme.Ink.*`** —— 同一组信号色按明暗两套调到 ≥4.5:1 的**文字版**（形状用前者，字和字形用后者）。
- **间距/圆角/字距/字体**：`Space`（s2/s4/s6/s8/s10/s12/s14/s16/s24 + `gridGap`/`gridGapPage`）、`Radius`（sm 8 / md 12 / lg 16 / xl 20）、`Tracking`（titleSmall / caption）、`Font` —— 系统字阶（`titleSmall`/`bodyLarge`/`body`/`bodySmall`/`caption`/`captionMono`/`labelSection`）+ 显示字阶（`displayMetric`/`displayMetricSmall`/`displayHero`）+ popup 密度别名（`rowTitle`/`micro*`/`badgeMono`/`console`）+ 界面字阶（`chrome`/`chromeEmph`/`brand`/`section`/`eyebrow`/`meta`/`kpi`/`pill`）+ 瓦片字阶（`tileValue`/`tileValueSmall`/`tileMicroValue`/`tileLabel`/`tileDetail`）。
- **宫格**：`GridLayout.Preset`（`pageSession`·`pageUsage` 自适应 → `TileGrid`；`mosaic(columns:)` 是 VPN 页等宽铺满的变体）。**设置页不再走这条路径**：它整片换成了 `SettingsGroup` / `SettingsRow` / `SettingsToggleRow`（`Views/Shared/SettingsControls.swift`）——一组一张中性面板、行内标签左对齐控件右对齐、原生 macOS 开关与选择器，不再有每项一张卡、彩色图标井、深度环与悬停抬升。口径见 [设置页](../design/surfaces/settings.md)。**副作用**：`pageMetric` / `pageProvider` / `pageSetting` / `pageSettingDense` / `popupSession` / `popupProvider` / `popupUsage` 这七个枚举值随这一轮**失去了全部调用点**（设置页是最后的使用者，popup 的三个从来只有定义），目前仍留在 `Preset` 里以免在这次改动里顺手动到 `Tile.swift` 与 `Theme.swift` 的排布分支；下一次动 `TileGrid` 时应当连同 `equalRow` 的分支一起删掉。
- **动画**：`Animation`（bouncy/smooth/snappy/sparkle/roll）、`Motion.page`/`Motion.state`——全部状态驱动，无常驻时间线。
- **表面/Helper**：`panelCard()`（半透明白填充 + 发丝线描边的扁平卡片，**非** `glassEffect`——主窗口大面积玻璃曾占用约 100 MB GPU 纹理）、`.tile()`（宫格瓦片表面，与 `panelCard` 同族、更密更浅，实现在 `Views/Shared/Tile.swift` 的 `TileSurface`）、`shadowCard()`、`cardFill(_:)`、`divider`/`hairline`、`contextColor(ratio)`（blue/warning/red）、`barColor(for:)` + `djb2`（跨进程稳定 hash 调色板）、`HairlineDivider`（去卡片化的发丝线分区）、`Theme.Ink.*`（信号色的文字版）/ 原信号色（形状版）。下压按钮是 `ActionButton`（`InstrumentControls.swift`）：`tone:` 说这个控件**是什么**（`.neutral` 铣削凹槽，默认 / `.sparkle` 深色板 / `.accent` / `.destructive`），`emphasis:` 说它是不是本页的默认动作。历史名字 `ProviderActionStyle` 是同一块板的转发，`adaptiveGlassButton()` 已删除——旧写法用 `prominent:` / `filled:` / `ink:` 描述**长相**而不表态**用途**，同一页因此会出现两种按钮语言。

## 表面语言（`Views/Shared/UiverseSurfaces.swift`）

一个表面 = 四个部件，`panelCard()` 与 `.tile()` 各自组装同一套：底 + 强调水洗、内嵌白环（`InnerFrameRing`，`Theme.innerFrame` / `innerFrameMuted`）、角上的深度环（`DepthLens`，一个 `Canvas`，三层**不同心**的环 —— 每层同时缩小并朝角落漂移，漂移才是"深度"的来源；**不画字形**）、悬停描边 + 2pt 抬升。

- `.tile(tint:hovered:dense:lens:framed:wash:lift:)` 是宫格形态；`.hoverTile(...)` 是"这个点的 body 没有别处要用 hover"时的简写（同一个 target 不开两个 `.onHover`）。`lift:` 是那个 2pt 抬升的开关，页头带传 `false`。
- **角上已有内容的卡片不加 `lens`**（会话瓦片的角上是子 agent 簇），只取 `tint` 的水洗。
- `SegmentedCapsule` 是唯一的筛选 / 分段控件：一个胶囊井 + 一颗 `matchedGeometryEffect` 滑动药丸，连接器的类型与平台筛选、供应商的客户端与分类筛选、用量的周期条、VPN 的分组条都走它。
- **2pt 抬升是网格卡片的行为，不是页头的**：抬升会移动卡片自己的 frame，而 hover 热区跟着它走——指针停在卡片下缘 2pt 内时，会被抬升"送出"卡片、落下时又"接回"，于是每帧来回翻转，看起来就是页头在抖。所以：`TileSurface` 的 `.contentShape` 钉在**未抬升**的几何上（modifier 顺序上先于 `.offset`），命中区不随位移走；整宽的**页头带**另外显式关掉抬升（`PageHeaderCard` 传 `lift: false`），它只保留水洗、白环与描边点亮。页头带**不**画角上的深度环，也**不**画 `OrbitGauge`：一条只有一个控件高的带子裁出来的圆，读起来是残缺的装饰，还会压住按钮和构成条。概览不用这条带，标题直接落在画布上。`Tests/inflight-animation-regressions.py` 把抬升这两条源码性质都钉住了。
- **页头带只有一种解剖**（`PageHeaderCard`）：左半是 `PageTitle` + 紧随其下的副标题，右半是这条带自己的控件（`.headerControl()`），两侧都 `alignment: .top`。副标题**永远在标题下面**，绝不和控件叠在同一列里——把「副标题 + 按钮」竖着摞在右下角，会让这条带成为全应用最高的一条（74pt vs 68pt），按钮底边还会压进内嵌白环，就是「模型」页那个错乱的样子。标题一律走 `PageTitle`（22pt bold + 34pt `GlyphWell`，字形与色相由 `PageIdentity` 决定），不要再手写字号 / 字重 / 井的大小——「连接器」页曾自己画 `GlyphWell(size: 38)` + 22pt **semibold**，和隔壁「模型」页并排就是两个字形、两个井。
- **带里控件的按钮必须 `.buttonStyle(.plain)`**：`headerControl()` 的井与描边就是控件的全部表面，默认 macOS 按钮样式会在胶囊井**内部**再画一个灰色圆角矩形，两层灰叠起来就读成「禁用」。
- **控件语言不在这个文件里**：按钮、字段、开关与页头带控件的单点是 `Views/Shared/InstrumentControls.swift`（`InstrumentField` / `InstrumentWell` / `InstrumentFieldStyle` / `InstrumentToggleStyle` / `PerimeterSweep` / `GroundShadow` / `headerControl()` / `ActionButton` + `ActionPlateButtonStyle` + `ControlPlate` / `InstrumentMenuLabel` / `ProviderActionStyle`）。表面文件说卡片*是什么*，控制文件说控件被碰到时*做什么*，两者守同两条性能规则。深色「sparkle」板的口径（`SparklePlate`、`Theme.Animation.sparkle` 的 450ms）见 [DESIGN.md](../../DESIGN.md) 的 Controls 表。
- `OrbitGauge`（额度表盘：trim 弧 + 沿弧走的圆点）、`ConveyorBelt`（扫描中那种"正在持续做事"的走带，`DecorativeMotion.kind == .conveyor`）、`ShineSweep` + `.depthTilt()`（一次性扫光与 3D 倾斜，**只给单张 hero 卡**，不进 `.tile()`）。这里**已经没有 `LoadRing`，也没有取代它的 `InstrumentRing`**：两者都曾是按读数调速的装饰（一条光的弧 / 一圈 conic 环绕在机器图标背后，转速 ∝ 读数，<5% 完全静止，读数变化时用 `timeOffset` 就地重定时），但弧与环在 20–28pt 上读起来都是「转圈 = 等待」，而且它们复述了下方三行已经印出的数字 —— 视图、`DecorativeMotion.loadRing` 与 `InstrumentRing` 一并删除。

实时读数改由右侧的 mark 承担：**上层是 Lucide 官方图标（`cpu` / `gpu` / `memory-stick` / `hard-drive`，由 `Tools/gen-lucide-hardware.py` 生成到 `LucideHardwareGeometry.swift`；同一脚本还生成 `laptop-minimal` 与 `fan`），下层是读数条 —— CPU 每个逻辑核心一条、GPU 每组图形子单元一条、内存按页类别、硬盘按已用/空闲，条高即读数**，另有一条按读数调速的扫光（`ReadingSweep`：每个忙柱一条 `CAGradientLayer`，按 `0.35 + load × 1.35` 周/秒平移，<4%、减弱动效或不可见时速率为 0；**不再是 `TimelineView`** —— 那一条调度的代价是每个显示周期重排整个 hosting view，见 [技术 §8](08-performance.md) 的 2026-09-29 一节）（见 `HardwareIllustration` 与 [DESIGN.md](../../DESIGN.md) 的 Machine marks）。mark 的尺寸是 `ResourceStrip.markSlot`（176×130），瓦片与 popover 共用同一个常量。

风扇使用共享结构插画的涡轮区域，缺失时回退到 SF Symbols `fanblades.fill`（`LucideRotor.swift` 保留旧文件名）。Core Animation 按 RPM 就地重定时，低于 80 RPM、窗口不可见或减弱动效时停转。详情使用随包分发的高清矢量风格概念插画，保留电路、散热管、电池细节；图中双风扇按各自 RPM 动画，按钮独立控制风速。
- 成本口径：装饰是几何而不是动画（每个 `Canvas` 只画一次）；两处会动的东西（扫光、走带）都由 `surfaceIsVisible` + 减弱动效双重门控；3D 倾斜只在被悬停的那一张上（`DepthTiltModifier` 不悬停时**不装在树上** —— 角度为 0 的 `rotation3DEffect` 也留在树上，滚动时整份网格会逐帧重新光栅化）。见 [DESIGN.md](../../DESIGN.md) 的 Motion / performance。
- 滚动：`ScrollHoverGate` 在拖动 / 惯性 / 动画阶段丢掉 hover 的 enter/exit，停下后补发一次 `mouseMoved`（宫格里的瓦片各自持一个 `hovered`，指针扫过时每个都翻转一次、每次都是一次布局）；`Views/Pages/*` 与模型目录统一 `.scrollHoverGate()`，概览自己写滚动阶段（它还要同时停住天空，走 `PageScrollActivity` 这个引用）。有卡片的网格是 `ScrollView` 的直接内容（`LazyVGrid` / `LazyVStack`），不再套一层普通 `VStack`——否则按理想高度问出来的是全部卡片。


## 数字滚动（`Views/Shared/Interaction.swift`）— 全局唯一一条

所有界面上**会变动的数字**都是同一个逐位滚动效果（灵动岛 token 数字的那个）：`monospacedDigit()` + `.contentTransition(.numericText(countsDown: true))`，**不带**任何隐式 `.animation(_:value:)`。

- **一个定义，两种写法**：`View.rollingNumber(_:)` 是公共方法（`RollingNumberModifier`，内部门控 `accessibilityReduceMotion`），`RollingNumberText(_:)` 是同一 transition 的薄包装（让调用处一眼看出"这里渲染的是一个数字"）。二者共用同一个 modifier，不存在第二份实现。`rollingNumber(false)` 用于同一个 `Text` 有时显示数字、有时显示别的东西的场合（比如 JSON 值只有一种 kind 才是数）。
- **Widget 是独立编译目标**，看不到 app 的 `rollingNumber()`，所以 `WidgetViews.swift` 里有一份同 transition 的私有副本 `widgetRollingNumber()`（同样不配隐式 `.animation(value:)`）。改 transition 时两处都要改。
- **加在哪一层**：加在**渲染数字的那个 `Text` / `Label` 叶子上**，不是容器上——容器上会连带整棵子树进出 transition。数字夹在句子里（"共 N 个可用 · 已选 M 个"）也照样加：`.numericText` 只滚数字字形，周围文案不动。
- **不要再用裸的 `.contentTransition(.numericText())`**：那正是重复实现；一律走 `rollingNumber()`。
- 同样地，**不要给这些叶子补 `.animation(_:value:)`**：值每秒/每次轮询都变，隐式动画会让事务常驻在飞，每个显示周期都重排整个 hosting view（见 [08-performance.md](08-performance.md)），而 `.numericText` 自己就是动画。`Tests/inflight-animation-regressions.py` 把这条钉在 `RollingNumberText` / `RollingNumberModifier` / `SectionHeader.trailingView` 上，另外三处同一违反（灵动岛收起态的今日 token、灵动岛用量卡 hero、未挂载的 `MetricTile`）已一并删掉——都是「1 Hz 读数 + 隐式动画」的同一个形状，下一处不该再写。`MetricTile` 随后连视图本身也删了（[17](../reviews/ui-audit-backlog.md) §10）。
- **按钮标题里的数字也算数字**：`Button("… \(count)")` 会自己造一个够不到的 `Text`。要滚就改用 `Button { … } label: { Text("… \(count)").rollingNumber() }`（导入表就是这么写的）。
- 静态文案（路径、版本号、模型名、确认弹窗里一次算好的计数）不需要滚动——没有"变动"可言。

## `MenuBarView` + `Views/Popup/` — 菜单栏 popup

`MenuBarView` 是组合壳（宽 460pt 的 `VStack`，与 `MenuBarController.sizeAndPosition` 里那份数字必须相等）：

- **PanelHeader**：状态行（会话 · 本地代理 · VPN 药丸 `VpnStatusPill` + 刷新）+ 三个切换 chip（`HeaderSwitchChip`：CC / Codex / Cursor，各自带 popover）+ 刷新；额度读 `QuotaSwayGauge`（剩余、弧与百分比同向），Cursor 的 chip 走 `CursorUsagePanel`。状态行的固定事实 `fixedSize()`，节点名有 228pt 上限、超出自己截尾。
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

## `ProviderTile` — deleted

- `ProviderTile`（`Views/ProviderRow.swift`）自 `2fd24f7` 起**没有挂载点**（`ProvidersView` 走 `ProviderDirectoryHost` + `ProviderConnectionEditor`），2026-09-30 随同一批无调用点视图删除。目录宫格那颗瓦片现在由 `ProviderDirectoryCard` 承担；理由与结果见 [审查证据](../reviews/ui-audit-backlog.md) §9。
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
- Header：ClaudeBar + 大号 token 总数 + 余额（两者都走 `.widgetRollingNumber()` —— widget 是独立编译目标，看不到 app 的 `View.rollingNumber()`，所以这里有一份同 transition 的私有副本，`.numericText(countsDown: true)`，同样**不**配隐式 `.animation(value:)`）。
- Provider + Model + 相对时间。
- 模型分布条（多个模型按 ratio 横向拼接）+ 图例。
- 活跃会话列表（最多 3 条 Claude + 3 条 Cursor），每行状态点 + 项目 + 活动 + 上下文条。
- 空态显示 "等待数据..."。
- 点击整个 Widget 触发 `claudebar://` 唤起主面板。

`WidgetProvider.getTimeline`：读快照（四路回退），30s 后刷新；读失败返回 `diagnosticEntry`（把诊断字符串塞进 `activeProviderName` 显示，如 `UD:2048B F:Y/2048B`）。
