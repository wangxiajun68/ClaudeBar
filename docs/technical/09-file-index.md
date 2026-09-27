# 关键文件索引

> ClaudeBar 技术文档 · §9
> 相关：设计文档 [文件结构](../design/07-file-structure.md) · [VPN](11-vpn.md) · [电池控制](12-battery-control.md)

| 文件 | 职责 |
|------|------|
| `ClaudeBarApp.swift` | AppDelegate：激活策略、启动时序、`claudebar://`、空闲通知 Resume |
| `MenuBarController.swift` | NSStatusItem + NSPanel；`MenuBarMark` 矢量模板标；常驻速率 + 电池条 `VpnMenuBarRateView`（宽度由布局常量推导，`Tests/menubar-strip-regressions.py` 锁定宽度、隧道内外两色与无头 1.618∶1 胶囊） |
| `Utils/SystemThroughput.swift` | 机器总吞吐：`getifaddrs(AF_LINK)` 读各网卡 `if_data` 字节数，按接口做 `UInt32` 回绕差分后求和；隧道关闭时菜单栏 ↓/↑ 的来源 |
| `NotchIslandController.swift` | 刘海灵动岛：`NotchIslandState`（收起 / 提醒 / 展开）、固定尺寸面板、热区与离开判定、完成提醒计时 |
| `Models/IslandLiveModel.swift` | 灵动岛数据：三家会话扁平化、忙→闲完成事件、当前路由、VPN、今日 / 本月 / 30 天用量 |
| `Utils/NotchGeometry.swift` | 从 `NSScreen` 读刘海尺寸；无刘海时的伪刘海 |
| `Views/Island/*.swift` | 灵动岛形状、根视图与 `IslandStyle`、会话行、用量卡（`Canvas` 直方图）、完成提醒 |
| `Utils/PermissionCenter.swift` | 权限清单 `AppPermission`、线程安全开关 `PermissionGate`、系统授权状态 `PermissionCenter` |
| `Utils/CurrentLocation.swift` | 问候卡天气的单次定位 fix（`CLLocationManager`，千米精度）：仅在「当前位置」开关打开后请求，关闭即丢弃坐标 |
| `Utils/MachineIdentity.swift` | 这台机器的名字：`SCDynamicStoreCopyComputerName`（= `scutil --get ComputerName`，用户在系统设置 → 共享里打的名字），**不再读 `kern.hostname`**（那个名字在同一网络里会被改写，按地址发租约的路由器会让问候语叫出 `192.168.10.102`）。纯规则 `person(in:)` 从机器名里取人：「的」/ `'s` / `’s` 之前是名字，无所有格的机型标记（`deMacBook` / `sMacBook` / `iMac` …）之后再剥掉连接用的 `s`；不足两个字符的前缀是残留标记，整串保留。回退是 `Mac` 而不是主机名 |
| `Utils/GreetingPhrase.swift` | 问候语里那声「招呼」的决定：`forDate(_:)` 先查节日表（固定节日 + 2026/2027 农历：春节 / 元宵 / 端午 / 中秋，加母亲节 / 父亲节 / 夏至），再落到**六个时段**（深夜 / 拂晓 / 上午 / 正午 / 下午 / 傍晚 / 夜里；22:00 那条线划分「傍晚」与「深夜」，23:28 不是傍晚）。**不随机**——每次重绘都变的问候语是老虎机，而卡片每次指针移动都会重绘。`Phrase { script, aside }`，`aside` 只在节日或该被点名的时刻出现 |
| `Utils/WeatherFetcher.swift` | 天气读数的共享源 `WeatherStore`：优先 Open-Meteo，失败退回 wttr.in；有定位时用 `lat,lon`，否则用「天气城市」，失败退回城市名并写明原因 |
| `Utils/WeatherForecastFetcher.swift` | Open-Meteo 六日预报（今天 + 5 天）：地理编码 / 坐标直用、`forecast_days=6`、`timezone=auto`；日数组缺失时保留有效日期并标明部分可用，不编造天数 |
| `Utils/SkyAstronomy.swift` | 低精度天文：J2000 轨道根数 → 赤道坐标 → 观察者地平高度 / 方位角；太阳、月亮、月相与固定亮星表。UTC 驱动恒星时，设备时区不改变天空。**是插画用的近似，不是导航级星图** |
| `Views/Shared/WeatherExplorer.swift` | 天气详情 popover：六日选择轨、共享刻度温区、太阳高度曲线 `SolarHorizon` 与各项读数；无嵌套面板底 |
| `Views/Shared/CodexModelMark.swift` | 概览状态单上的客户端 mark：品牌图形 + 一条 Codex 额度 lane（一窗口一条、条高即剩余；可选按读数调速扫光） |
| `Views/Shared/PermissionsSection.swift` | 设置页"权限与隐私"：逐项开关、系统状态、跳转系统设置 |
| `Utils/TerminalLauncher.swift` | 继续会话：`ResumeTerminal`（自动 / Otty / Warp / 终端）选择与回退；Warp / 终端走 AppleScript（需"自动化"） |
| `Utils/OttyBridge.swift` | `otty-cli` socket IPC（`pane list`，勿用 `panes` 简写）：按 `agent_session_id` 聚焦已有窗格；活会话 `reveal` 只聚焦不新建；已结束会话才新开标签 resume |
| `Utils/SessionHost.swift` | 活会话跳转：沿父进程找到宿主 App（Otty / 终端 / iTerm2 按 tty 选中标签，Cursor / VS Code 聚焦对应文件夹窗口，其它激活）|
| `Utils/ExternalSessionMonitor.swift` | Codex 会话；`CodexProcessScan` 用 libproc 找被 `codex` 进程打开的 rollout，作为存活判定与跳转目标 |
| `Views/Shared/PowerFlowCard.swift` | 能源流向：SMC `PDTR` / `PSTR` 推出四态；按瓦数等比的色带 Sankey，彩色光波由 Core Animation 沿流向滚动 |
| `Views/Shared/InstrumentWidgets.swift` | 仪表组件；`CompactFanPair` 是风扇瓦片上的一对转子（转子本体在 `LucideRotor.swift`） |
| `MainWindowController.swift` | 主窗口 NSWindow + vibrancy |
| `Models/ProviderStore.swift` | Claude 状态中枢；`activateModel(providerID:modelID:)` 只切换 Claude Code |
| `Models/ProviderCatalog.swift` | 内置供应商目录：按客户端的端点、协议与模型预设，注释指向 [§13](13-provider-directory.md) |
| `Models/ProviderProfileSync.swift` | 一份配置两份客户端：补链旧行、Key 仅在对面为空时复制、模型并集；基址与激活状态各留一侧 |
| `Models/ScopedStoreObservation.swift` | `StoreInvalidation`：按字段合并 store 变更，一轮事务只失效一次视图 |
| `Models/BatteryChargeController.swift` | 电池控制状态机：模式、上限、回读确认、heartbeat 与恢复 |
| `Utils/BatteryHelperInstaller.swift` | 安装 / 校验 setuid 电池辅助进程（SHA-256 + 代码签名），无 launch daemon |
| `Sources/batteryctl/batteryctl.c` | 独立 C 辅助进程：`--probe` 只读、`--serve` 需 root；固定 SMC key 白名单 |
| `Views/Shared/BatteryChargeControls.swift` | 能源卡的电池控制段：上限滑杆与四个模式按钮 |
| `Views/Shared/ProviderDirectory.swift` | 模型页供应商目录：分组、卡片、搜索与筛选 |
| `Views/Shared/ProviderQuickSetup.swift` | 新预设「连接凭据 → 模型 → 保存」弹窗，不自动激活 |
| `Views/Shared/ProviderControls.swift` | 供应商卡的状态、目标模型与激活控件 |
| `Views/Shared/ProviderModelFetchButton.swift` | 拉取模型列表（导入前需勾选确认，已存在的模型不重复添加） |
| `Views/Shared/APIKeyField.swift` | Key 输入：编辑用普通 TextField，失焦后遮蔽 |
| `Views/Shared/DecorativeMotion.swift` | `DecorativeMotion`：Core Animation 装饰动效（`sparkles` / `sweep` / `orbit` / `pulse` / `scan` / `conveyor`），不跑 SwiftUI 时间线 |
| `Views/Shared/LucideHardwareGeometry.swift` | **生成文件**：Lucide 官方 `cpu` / `gpu` / `memory-stick` / `hard-drive`（以及风扇 popover 的 `laptop-minimal`、转子来源的 `fan`）转成的 `Path`，由 `Tools/gen-lucide-hardware.py` 从上游 SVG 生成；改图标要重跑脚本 |
| `Views/Shared/HardwareIllustration.swift` | 本机负载的实时 mark，分两条 lane：上层是 Lucide 图标（说明这是哪个部件），下层是读数条 —— CPU 每个逻辑核心一条、GPU 每组图形子单元一条、内存 / 硬盘按容量区域，条高即读数；另有按读数调速的扫光（<4%、减弱动效或不可见时停止）。浮层共用同一 mark（`HardwareDetailPanel.swift`） |
| `Views/Shared/LucideRotor.swift` | 插画涡轮裁切、SF Symbols 回退与 Core Animation 旋转层；就地改速，停转与恢复保持相位 |
| `Views/Shared/FanInternalsPanel.swift` | 风扇卡的 popover：Lucide `laptop-minimal` 机身 + 左右两个风扇位（各自按自己的 rpm 转、各自一圈按自己最大值填充的转速弧）+ 每个风扇一行读数与「拉满 / 恢复自动」。机身轮廓是 `ChassisOutline`（`Shape`），因为把 24pt 的图标 `aspectRatio(.fit)` 进这么宽的框只会缩成一张缩略图 |
| `Views/Shared/HardwareDetailPanel.swift` | `HardwareIdentity`（机型 / GPU 名，进程内不变）+ `HardwareSiliconMark` + `LoadHistoryChart` + `HardwareDetailPanel`（CPU / GPU）+ `ConnectionDetailPanel`（连接卡 popover：网络 / 本机代理 / 附近与设备三段，顶部是链路本身的状态而非「连接」这个标题，RSSI 刻度与 `ConnectionStatus` 词汇表和卡片共用；地址行归档进「复制诊断」）+ `CapacityHardwareMark` |
| `Resources/macbook-internals-illustration.png` | 独立生成的详细结构插画（PNG，非 SVG）；来源与提示词见 `ASSET-LICENSES.md`，随应用离线分发 |
| `Tools/gen-fan-blade.py` | 把 Lucide `fan` 的一片叶转成单位空间并**断言它仍是 Lucide 的形状**（每条弧必须是 131.8° 的 6.082 半径弧、四个内点必须相隔 90°、最后一个弦必须回到起点）。旧版几何生成工具；当前风扇插画不再依赖它 |
| `Tools/gen-brand-marks.py` | 品牌方块的归一化：把 `Sources/ProviderIcons/` 的 LobeHub 原图剪到自己的墨迹、按画布 90% 写回 `Sources/BrandAssets/`（构建随包 + 随 appex 内置）。原图各自带着到画布边缘的留白，13pt 的方块里 Anthropic 只剩 65%。**按宽度定标**——共享边长会让竖高的 Cursor 立方体比旁边的 CC 小 12% |
| `Tools/make-claudebar-mark.py` | 从 `Sources/AppIcon-1024.png` 推出 ClaudeBar 自己的 mark（两个明暗变体），给用量图例里的「第三方」用；`Tests/provider-icon-regressions.py` 因此要能读 RGBA 真彩色 PNG |
| `Tools/render-control-preview.py` + `Tools/control-preview-sheet.swift` / `control-preview-support.swift` | 控件预览图：900pt 的明暗两版控件表（`ActionButton` / `ChipButton` / `InstrumentToggleStyle` / `SegmentedCapsule`），`ImageRenderer` 出 `.build/control-preview/sheet-{light,dark}.png`。**声明是从生产源码里抽出来的**（`InstrumentControls.swift` / `Interaction.swift` / `UiverseSurfaces.swift`），所以预览图不会和真控件漂移；`AppPreferences` / `surfaceIsVisible` 用替身 |
| `Views/Shared/UiverseSurfaces.swift` | 表面语言单点：`TileSurface` 的四个部件（底 + 强调水洗 / `InnerFrameRing` / `DepthLens` / 悬停描边 + 抬升，`lift:` 可关）、`SegmentedCapsule`（唯一的筛选胶囊）、`OrbitGauge`、`ConveyorBelt`、`ShineSweep`、`.depthTilt()` 与 `PageHeaderCard`；`LoadRing` 与 `InstrumentRing` 均已删除（弧与环在图标尺寸上读作「转圈等待」且复述下方数字）；见 [DESIGN.md](../../DESIGN.md) 的 Surfaces 与 Machine marks |
| `Views/Shared/InstrumentControls.swift` | 控件语言单点（表面文件说卡片*是什么*，这个文件说控件被碰到时*做什么*）：`InstrumentField` / `InstrumentWell` / `InstrumentFieldStyle`（唯一的字段凹槽）、`InstrumentToggleStyle`（唯一的开关）、`PerimeterSweep` + `GroundShadow`、`headerControl()`（页头带自己的控件）、`ActionButton` + `ActionPlateButtonStyle` + `ControlPlate`（唯一的下压按钮；`ControlTone` = 这个控件**是什么**：`.sparkle` 深色板（默认）/ `.neutral` / `.accent` / `.destructive`，`ControlEmphasis` = 是不是本页默认动作）、`InstrumentButtonStyle` 与 `ProviderActionStyle` 是同一块板的两个历史名（调用点按位置传参，转发到 `ActionPlateButtonStyle`，因此不会漂移）、`InstrumentMenuLabel`。`adaptiveGlassButton()` 已删除，口径见 [DESIGN.md](../../DESIGN.md) 的 Controls 表 |
| `Views/Shared/ProductBrandMark.swift` | 三家客户端 + ClaudeBar 自己的真实品牌图形（LobeHub `@lobehub/icons-static-png@1.97.1`，素材随包内置在 `Sources/BrandAssets/`）单点：`Brand { claude, codex, cursor, claudebar }`，唯一 init `(brand:well:page:inkWell:)`。**`page:` 不是 `Theme.isDark`**——`nil` 主题面、`true` 黑底（灵动岛在两种主题下都是黑的）、`false` 亮底；**`-light` 文件是黑墨、`-dark` 是白墨**（LobeHub 按背景命名，不是按字形），搞反就会画出黑底黑字。图形由 `Tools/gen-brand-marks.py` 剪到墨迹并按画布 90% 写回，**按宽度**定标（Cursor 的立方体比宽高，按共享边长会被画小 12%）；`Tests/product-mark-regressions.py` 渲染真实视图量这条比例 |
| `Views/Shared/Tile.swift` | `TileGrid` + `.tile()` / `.hoverTile()`（宫格表面，即 `TileSurface` 的修饰符形态） |
| `Models/CodexProviderStore.swift` | Codex 状态中枢 + 本机代理生命周期 |
| `Models/AppPreferences.swift` | 空闲通知、代理端口、第三方上游、VPN mixed-port / 系统代理 / TUN 等 |
| `Utils/FilePaths.swift` | Claude / Codex / Cursor / App Group / `vpnDir` |
| `Utils/VpnManager.swift` | mihomo 进程、测速、流量流、超时 failover |
| `Utils/VpnHTTP.swift` | 控制器 HTTP，禁用系统代理 |
| `Utils/VpnSubscriptionStore.swift` | 订阅、YAML 合成、`tuneForStability` |
| `Utils/VpnSystemProxyController.swift` | `networksetup` + Guard + TUN DNS |
| `Utils/VpnNetProbe.swift` | 连通性探测 |
| `Utils/FanMonitor.swift` | SMC 风扇 / 温度；读取在后台队列，主线程只做去重发布 |
| `Utils/ScreenshotHotKey.swift` | Carbon 全局 ⌘⇧A |
| `Utils/ScreenshotOverlay.swift` | ScreenCaptureKit 拉框截图 |
| `Theme/Theme.swift` | 设计 token + `Theme.Ink`（作文字用的信号色，≥4.5:1） |
| `Views/MainWindowView.swift` | 9 页 `AppPage`；顶栏 tabs（帮助走右上角问号）；每页只在选中时挂载（`TrafficPageState` 让流量页重进无代价） |
| `Views/MenuBarView.swift` | popup 壳（424pt）：Header + MachineKpiStrip + 能源流向 + 两面板 + 操作栏；只订阅外壳状态 |
| `Views/Pages/VPNView.swift` | VPN 主界面 |
| `Models/IdleTransitionDetector.swift` | `IdleTransitionDetector` / `ConfirmedCompletionDetector` / `QuotaResetDetector` —— 忙碌、完成、额度重置三种边沿检测 |
| `Utils/SessionTitle.swift` | 会话卡片标题的唯一推导：Codex `threads.title` / Cursor `composerHeaders.name` / CC 首条人类 prompt，回退目录名 |
| `Utils/ModelPricing.swift` | 模型花费估算：slug 归一化与匹配、分币种累加、金额格式化（`Tests/model-cost-regressions.py` 锁定） |
| `Utils/ModelPriceTable.swift` | 内置官方刊例价表（每行标注来源，见 [§15](15-model-cost.md)）；更新只需改这一个文件 |
| `Utils/ExchangeRate.swift` | USD→CNY 汇率：用户要求折算时才联网（两个无 Key 日更源），也可手动钉住一个值 |
| `Models/ConnectorManager.swift` | 连接器扫描：三家客户端的本机 Skills / MCP / 插件，及其启停方式；只读元数据，不启动服务 |
| `Models/MCPToolDiscovery.swift` | MCP `initialize` + `tools/list`（不发 `tools/call`），HTTP 与 stdio 两种传输，带超时与上限 |
| `Views/Pages/ConnectorsView.swift` | 连接器页：客户端筛选 + 「本机共享」+ 类型筛选 + 搜索 + 等高卡片网格 |
| `Views/Pages/ConnectorDetailSheet.swift` | 连接器详情：Skill Markdown、MCP 工具列表、插件组成 |
| `Views/Shared/SkillMarkdownPreview.swift` | SKILL.md 的原生 SwiftUI 渲染（标题 / 列表 / 引用 / 代码块 / 表格） |
| `Views/Shared/ExchangeRateTile.swift` | 设置 → 模型花费 → 汇率：显示当前汇率与日期、手动钉值 |
| `Views/Shared/VpnTopChrome.swift` | `VpnNodePickerPanel`（popup 页头 chip 的面板）+ `VpnDelayStyle` |
| `Views/Shared/UsageRiver.swift` | `CacheAnatomyBar`（周期 token 构成） |
| `Views/Shared/ProxyUpstreamPickers.swift` | 本地代理上游：CC/Codex 只读 + 第三方选择（设置页宫格里的 4 张 tile） |
| `Sources/ensure-dev-cert.sh` | 本机 ClaudeBar Dev 代码签名身份 |
| `Sources/ci/extract-changelog.py` | 切出某版本的 CHANGELOG 段，拼 Release 说明 |
| `Tests/*.py` | 源码切片回归（`make test` / CI）；不改用户配置、不联网。`make test` 是那份清单的唯一出处，CI 调用它——两处各抄一份的写法已经漏掉过六个脚本 |
| `Tests/battery-control.c` | 电池辅助进程回归：IOKit transport 换内存模拟，不写真实 SMC |
| `Sources/Widget/*.swift` | WidgetKit |
| `Sources/BrandAssets/*.png` | 三家客户端 + ClaudeBar 自己的品牌图形（`Tools/gen-brand-marks.py` 生成）；`Sources/build.sh` 除随应用内置外**还会复制进 appex**——扩展有它自己的 `Bundle.main`，不复制的话小组件会静默退回兜底字形，看起来就像一次有意的改动 |
| `Sources/build.sh` | 构建 / 签名 / 安装 / 拉取 mihomo |
