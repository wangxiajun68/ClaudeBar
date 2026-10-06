# 关键文件索引

> ClaudeBar 技术文档 · §9
> 相关：设计文档 [文件结构](../design/07-file-structure.md) · [VPN](11-vpn.md) · [电池控制](12-battery-control.md)

| 文件 | 职责 |
|------|------|
| `ClaudeBarApp.swift` | AppDelegate：激活策略、启动时序、`claudebar://`、空闲通知 Resume |
| `MenuBarController.swift` | NSStatusItem + NSPanel；`MenuBarMark` 矢量模板标；常驻速率 + 电池条 `VpnMenuBarRateView`（宽度由布局常量推导，`Tests/menubar-strip-regressions.py` 锁定宽度、隧道内外两色与无头 1.618∶1 胶囊） |
| `Utils/SystemThroughput.swift` | 机器总吞吐：`getifaddrs(AF_LINK)` 读各网卡 `if_data` 字节数，按接口做 `UInt32` 回绕差分后求和；隧道关闭时菜单栏 ↓/↑ 的来源 |
| `NotchIslandController.swift` | 刘海灵动岛：`NotchIslandState`（收起 / 提醒 / 展开）、固定尺寸面板、热区与离开判定、完成提醒计时 |
| `Models/IslandLiveModel.swift` | 灵动岛数据：三家会话扁平化、按轮次键判定「交付了新答案」的完成事件、当前路由、VPN、今日 / 本月 / 30 天用量 |
| `Utils/NotchGeometry.swift` | 从 `NSScreen` 读刘海尺寸；无刘海时的伪刘海 |
| `Views/Island/*.swift` | 灵动岛形状、根视图与 `IslandStyle`、会话行、用量卡（`Canvas` 直方图）、完成提醒 |
| `Utils/PermissionCenter.swift` | 权限清单 `AppPermission`、线程安全开关 `PermissionGate`、系统授权状态 `PermissionCenter` |
| `Utils/CurrentLocation.swift` | 问候卡天气的单次定位 fix（`CLLocationManager`，千米精度）：仅在「当前位置」开关打开后请求，关闭即丢弃坐标 |
| `Utils/MachineIdentity.swift` | 这台机器的名字：`SCDynamicStoreCopyComputerName`（= `scutil --get ComputerName`，用户在系统设置 → 共享里打的名字），**不再读 `kern.hostname`**（那个名字在同一网络里会被改写，按地址发租约的路由器会让问候语叫出 `192.168.10.102`）。两步纯规则：`person(in:)` 从机器名里取人（「的」/ `'s` / `’s` 之前是名字，无所有格的机型标记 `deMacBook` / `sMacBook` / `iMac` … 之后再剥掉连接用的 `s`；不足两个字符的前缀是残留标记，整串保留），`displayName(for:)` 再把汉名写成**拼音、名在前**（`王夏军` → `Xiajun Wang`；拉丁名原样保留；姓氏取第一个字，双字姓是这条规则唯一拼不对的形状，见注释）。回退是 `Mac` 而不是主机名 |
| `Utils/GreetingPhrase.swift` | 问候语里那声「招呼」的决定：`forDate(_:)` 先查节日表（固定节日 + 2026/2027 农历：春节 / 元宵 / 端午 / 中秋，加母亲节 / 父亲节 / 夏至），再落到**七个时段**（深夜 0–5 / 拂晓 5–7 / 上午 7–11 / 正午 11–14 / 下午 14–18 / 傍晚 18–22 / 夜里 22–24）。**不随机**——每次重绘都变的问候语是老虎机，而卡片每次指针移动都会重绘。`Phrase { script, aside }`，`aside` 只在节日或该被点名的时刻出现。普通日子改成一句古典诗词：中文取真实诗句（柳宗元《江雪》、白居易《夜雪》、杜牧《山行》…），英文取公共领域英诗短句；节气与季节来自 `SolarTerm.swift`，`Selection.verse` 只看节气/季节，`automatic` 还会让节日和天气优先 |
| `Utils/SolarTerm.swift` | 二十四节气的离线日历 + 四季：提交 2026–2030 的公历日期（香港天文台年历，与 NOAA 视太阳黄经跨越时刻一致），`term(on:)` 判当天节气，`season(on:)` 以立春/立夏/立秋/立冬划季。每个节气含中/英文诗句池，普通日子的季节诗池分深夜/拂晓/白天三档。窗口外年份复用最近表，不发明日期 |
| `Utils/WeatherFetcher.swift` | 天气读数的共享源 `WeatherStore`：取数顺序 **高德 → 中国天气网 → Open-Meteo → wttr.in**（前两家国内 IP 命中 `GEOIP,CN → Direct`，不依赖代理）；有定位时用 `lat,lon`，否则用「天气城市」，失败退回城市名并写明原因。`DomesticWeatherParser` 是两家国内源的纯解析（蒲福级→km/h、中文/`d`/`n` 天气码→`Sky`、`weather_index` 的 JS 变量取块、cityid 表查找），随本文件的标记前切片一起进回归测试 |
| `Utils/WeatherAmapFetcher.swift` | 高德（AMap）Web 服务天气，免代理主源：地理编码 / 逆地理（直辖市 `city` 为空，回落 `province`）取 adcode，`weatherInfo` 的 `extensions=base`（实况）+ `extensions=all`（4 天预报）并发取；key 留空则直接跳过，只覆盖大陆城市 |
| `Utils/WeatherCNFetcher.swift` | 中国天气网（中央气象台数据），免 key 兜底：城市名 → cityid 走编译进二进制的 `CNWeatherCityTable.swift`（该站的 `toy1` 名字搜索已失效，返回空数组；表由 `Tools/gen-cn-weather-cities.py` 从仍在服务的省→市树生成，只到地级市），再取 `d1.weather.com.cn/weather_index/{id}.html` 的 `dataSK`（实况）与 `fc`（5–7 天预报），必须带 `Referer: http://www.weather.com.cn/`；坐标与表外的区县名无法反查，回落 Open-Meteo |
| `Utils/CNWeatherCityTable.swift` | 中国天气网 cityid 表（生成物，勿手改）：348 个地级市 → `weather_index` id，由 `Tools/gen-cn-weather-cities.py` 用 `city3jdata` 的省→市树 + 逐个 id 探测生成 |
| `Utils/WeatherForecastFetcher.swift` | Open-Meteo 六日预报（今天 + 5 天）：地理编码 / 坐标直用（坐标经 `PlaceNamer` 反向地理编码为"城市 · 区"，按约 1 km 缓存）、`forecast_days=6`、`timezone=auto`；日数组缺失时保留有效日期并标明部分可用，不编造天数。现为海外城市与兜底源 |
| `Utils/SkyAstronomy.swift` | 低精度天文：J2000 轨道根数 → 赤道坐标 → 观察者地平高度 / 方位角；太阳、月亮、月相与固定亮星表。UTC 驱动恒星时，设备时区不改变天空。**是插画用的近似，不是导航级星图** |
| `Views/Shared/WeatherReadingSky.swift` | `WeatherReading.Sky` 的 SF Symbols 符号名与中文文案映射（`symbol(night:)` / `caption`），给天气卡、预报带与供应商图标用。原文件里的 620pt popover 成稿 `WeatherExplorer` / `SolarHorizon` / `ForecastStrip` 已无调用点，已删除；预报现在是 `GreetingInstruments.swift` 的 `ForecastRibbon` |
| `Views/Shared/GreetingCard.swift` | 仪表盘问候卡：`GreetingCard`（读 store）+ 纯展示 `GreetingStatusSheet`。天空为 Metal 大气；左上时钟 + **自动 / 手动**天空模式，右上实时天气（地点、温度、图标化体感 / 湿度 / 风向 / 降水），右下六日预报带，左下日轨（手动时换成天气 × 时段 × 24h 时间轴控制台），底部窗台读数。无悬浮层：预报聚焦某天时右上原位改读那天，窗台胶囊悬停原位展开。手动模式的天气 / 时刻存 `@AppStorage("greeting.*")`，时刻拖动中只放 `@State`，落定才写回。时间动画由 `FrameTicker`（`CADisplayLink`）驱动；窗台、预报带、右上此刻包在 `Unchanged(key:)` 里，拖动时不重建（性能见 `docs/design/greeting-atmosphere.md` §5.7） |
| `Views/Shared/GreetingInstruments.swift` | 问候卡的仪表：`WeatherGlyph`、`HumidityDrop`、`WindDial`、`InstrumentMetric`、`ForecastRibbon`（高低温带 + 降水柱，悬停聚焦 / 点击固定 / ←→）、`SunPath`（含日出日落时刻解析）、`SillGauge`（窗台额度：剩余百分比，读法同弹窗 `QuotaSwayGauge`）、`SkyModeToggle`、`SkyConsole` + `SkyTimeline`（手动天空） |
| `Views/Shared/Atmosphere/*.swift` | Metal 天空：`SkyScene`（太阳高度 × 天气 → 调色与参数，`mix` 供天气交叉淡变）、`AtmosphereShader`（运行时编译的 MSL）、`AtmosphereRenderer`（问候语排版 / 双通道纹理、天气 1.2 s 淡变、入场与书写）、`AtmosphereView`（`MTKView`、帧率策略、`PageScrollActivity` 滚动定帧、不阻塞主线程的 drawable 预算）、`GreetingScript`（`GreetingTypeface` 字体目录：53 款可选（14 款中文 / 39 款拉丁，其中 49 款随包、4 款系统）、各自的 `wght` 与加粗；按字体 × 文本缓存字形轮廓，缺字体时回落 Snell Roundhand） |
| `Views/Shared/CodexModelMark.swift` | popup 头部 chip 的客户端 mark：只有 `ProductBrandMark` 的品牌图形（13pt），家族名不再并排重复（chip 自己已写）；`CursorMark` 是 Cursor 的独立类型（`CodexModelMark` 的整体形状是一个 `codex: Bool`，Cursor 只能从 `ProductBrandMark.Brand` 走单独的 init，否则会被画成 Claude） |
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
| `Sources/fanctl/fanctl.c` | 独立 C 辅助进程：`set <fanID> <rpm>` / `auto <fanID>` / `autoall` / `status`；macOS 26 的 80 字节 SMC 协议，`_Static_assert(sizeof(SMCKeyData) == 80)`。写 `F%dTg` 目标转速并置 `F%dMd` 模式，读 `FNum` / `F%dAc` / `F%dMn` / `F%dMx`；`auto` 先写 `Ftst`。安装由 `FanHelperInstaller` 装到 `/usr/local/bin/claudebar-fanctl`（setuid 4755） |
| `Views/Shared/BatteryChargeControls.swift` | 能源卡的电池控制段：上限滑杆与四个模式按钮 |
| `Views/Shared/ProviderDirectory.swift` | 模型页供应商目录：分组、卡片、搜索与筛选 |
| `Views/Shared/ProviderQuickSetup.swift` | 新预设「连接凭据 → 模型 → 保存」弹窗，不自动激活 |
| `Views/Shared/ProviderControls.swift` | 供应商卡的状态、目标模型与激活控件 |
| `Views/Shared/ProviderModelFetchButton.swift` | 拉取模型列表（导入前需勾选确认，已存在的模型不重复添加） |
| `Views/Shared/APIKeyField.swift` | Key 输入：编辑用普通 TextField，失焦后遮蔽 |
| `Views/Shared/DecorativeMotion.swift` | `DecorativeMotion`：Core Animation 装饰动效（`sparkles` / `sweep` / `orbit` / `pulse` / `scan` / `conveyor`），不跑 SwiftUI 时间线 |
| `Views/Shared/LucideHardwareGeometry.swift` | **生成文件**：Lucide 官方 `cpu` / `gpu` / `memory-stick` / `hard-drive` 四枚机件 mark 转成的 `Path`，由 `Tools/gen-lucide-hardware.py` 从上游 SVG 生成；改图标要重跑脚本。生成物只留这四枚：它们由 `HardwareIllustration` / `HardwareKpiStrip` 经 `HardwareIllustration.mark(for:)` 使用，而风扇 popover 画的是随包插画 `Resources/macbook-internals-illustration.png`、转子用它的裁切（`FanArtwork`），不经过这份几何 |
| `Views/Shared/HardwareIllustration.swift` | 本机负载的实时 mark，分两条 lane：上层是 Lucide 图标（说明这是哪个部件），下层是读数条 —— CPU 每个逻辑核心一条、GPU 每组图形子单元一条、内存 / 硬盘按容量区域，条高即读数；另有按读数调速的扫光（<4%、减弱动效或不可见时停止）。浮层共用同一 mark（`HardwareDetailPanel.swift`） |
| `Views/Shared/LucideRotor.swift` | 插画涡轮裁切、SF Symbols 回退与 Core Animation 旋转层；就地改速，停转与恢复保持相位 |
| `Views/Shared/FanInternalsPanel.swift` | 风扇卡的 popover：直接画随包的 `Resources/macbook-internals-illustration.png` 机身插画，左右两个风扇位按插画坐标切成圆形涡轮（`FanArtwork` 裁切，各自按自己的 rpm 转、各自一圈按自己最大值填充的转速弧），各自一行读数与「拉满 / 恢复自动」；插画缺失时退回 `laptopcomputer` SF 符号 |
| `Views/Shared/HardwareDetailPanel.swift` | `HardwareIdentity`（机型 / GPU 名，进程内不变）+ `HardwareSiliconMark` + `LoadHistoryChart` + `HardwareDetailPanel`（CPU / GPU）+ `ConnectionDetailPanel`（连接卡 popover：网络 / 本机代理 / 附近与设备三段，顶部是链路本身的状态而非「连接」这个标题，RSSI 刻度与 `ConnectionStatus` 词汇表和卡片共用；地址行归档进「复制诊断」）+ `CapacityHardwareMark` |
| `Resources/macbook-internals-illustration.png` | 独立生成的详细结构插画（PNG，非 SVG）；来源与提示词见 `ASSET-LICENSES.md`，随应用离线分发 |
| `Sources/Fonts/*.ttf` + `*-OFL.txt` / `*-LICENSE.txt` | 问候的可选 49 款随包手写体与**各自的许可证**（每款一个文件，版权与保留字体名在其中）。`Sources/build.sh` 复制进 `Resources/Fonts`，`GreetingScript` 按文件名加载；字体不装进系统、不单独分发，出处逐条记在 `Resources/ASSET-LICENSES.md` |
| `Tools/gen-cn-weather-cities.py` | 生成 `CNWeatherCityTable.swift`：从仍在服务的 `city3jdata` 省→市树取地级市，逐个探测 `weather_index/{id}.html` 是否有效再写回（该站的 `toy1` 名字搜索接口已失效，对任何中文城市名都返回空数组，所以名字→id 只能这样离线建表）。**表是生成物，改它要重跑脚本** |
| `Tools/bench-atmosphere.py` | 问候卡天空的性能基准：用生产着色器按卡片实际尺寸离屏绘制各天气，报 GPU / CPU 每帧中位数，以及排版、栅格化、首次取字形的主线程耗时。SwiftUI 侧的每步更新耗时见 `Tools/render-greeting-preview.py --bench`（`BENCH_PACE=0` 定频对比，`--bench-baseline` 为对照） |
| `Tools/gen-brand-marks.py` | 品牌方块的归一化：把 `Sources/ProviderIcons/` 的 LobeHub 原图剪到自己的墨迹、按画布 90% 写回 `Sources/BrandAssets/`（构建随包 + 随 appex 内置）。原图各自带着到画布边缘的留白，13pt 的方块里 Anthropic 只剩 65%。**按宽度定标**——共享边长会让竖高的 Cursor 立方体比旁边的 CC 小 12% |
| `Tools/make-claudebar-mark.py` | 从 `Sources/AppIcon-1024.png` 推出 ClaudeBar 自己的 mark（两个明暗变体），给用量图例里的「第三方」用；`Tests/provider-icon-regressions.py` 因此要能读 RGBA 真彩色 PNG |
| `Tools/recompress-icon.py` | 无损重压一个 `.icns`（默认 `Sources/AppIcon.icns`，可传路径）：容器里每个尺寸各是一张独立 PNG，逐成员重编并**逐像素比对**后才落盘（不通过就整档拒写）。发布图标 2,071,438 → 1,705,955 B，开发图标 2,220,382 → 1,884,046 B（同样像素）；`Tests/icon-minimal-regressions.py` 对两个图标都跑 `--check`，并证明改坏的副本会被拒且不落盘 |
| `Sources/ClaudeBar/Resources/mihomo-core.xz` | 随包内置的 VPN 内核压缩档（`.version` 记版本）。原始二进制 54 MB，deflate 压不动（release `.zip` 里仍占 20 MB），`.xz` 是 13.1 MB；提交在仓库里所以发布构建不必重跑 LZMA。`Tests/core-regressions.py` 解它一次做往返断言 |
| `Tools/render-control-preview.py` + `Tools/control-preview-sheet.swift` / `control-preview-support.swift` | 控件预览图：900pt 的明暗两版控件表（`ActionButton` / `ChipButton` / `InstrumentToggleStyle` / `SegmentedCapsule`），`ImageRenderer` 出 `.build/control-preview/sheet-{light,dark}.png`。**声明是从生产源码里抽出来的**（`InstrumentControls.swift` / `Interaction.swift` / `UiverseSurfaces.swift`），所以预览图不会和真控件漂移；`AppPreferences` / `surfaceIsVisible` 用替身 |
| `Tools/render-feishu-preview.py` | 飞书文档预览：切出 `Theme.swift` 的 token 段 + `DocumentTable.swift` / `DocumentMarkup.swift`，配合成数据渲染原生文档表面到 `.build/feishu-preview/`，不联网、不读用户数据 |
| `Views/Shared/UiverseSurfaces.swift` | 表面语言单点：`TileSurface` 的四个部件（底 + 强调水洗 / `InnerFrameRing` / `DepthLens` / 悬停描边 + 抬升，`lift:` 可关）、`SegmentedCapsule`（唯一的筛选胶囊）、`OrbitGauge`、`ConveyorBelt`、`ShineSweep`（+ `shineOnHover`）与 `PageHeaderCard`；`LoadRing` 与 `InstrumentRing` 均已删除（弧与环在图标尺寸上读作「转圈等待」且复述下方数字）、`depthTilt` / `DepthTiltModifier` 同（连接器卡 2026-10-02 去掉 3D 倾斜后无调用方）；见 [DESIGN.md](../../DESIGN.md) 的 Surfaces 与 Machine marks |
| `Views/Shared/InstrumentControls.swift` | 控件语言单点（表面文件说卡片*是什么*，这个文件说控件被碰到时*做什么*）：`InstrumentField` / `InstrumentWell` / `InstrumentToggleStyle`（唯一的开关）、`PerimeterSweep` + `GroundShadow`、`headerControl()`（页头带自己的控件）、`ActionButton` + `ActionPlateButtonStyle` + `ControlPlate`（唯一的下压按钮；`ControlTone` = 这个控件**是什么**：`.neutral` 铣削凹槽（默认）/ `.sparkle` 深色板 / `.accent` / `.destructive`，`ControlEmphasis` = 是不是本页默认动作）、`ProviderActionStyle` 是同一块板的历史名（调用点按位置传参，转发到 `ActionPlateButtonStyle`，因此不会漂移）、`InstrumentMenuLabel`。唯一的字段凹槽 `InstrumentFieldStyle` 在 `Views/Shared/InstrumentSearchField.swift`。`adaptiveGlassButton()` 已删除，口径见 [DESIGN.md](../../DESIGN.md) 的 Controls 表 |
| `Views/Shared/ProductBrandMark.swift` | 三家客户端 + ClaudeBar 自己的真实品牌图形（LobeHub `@lobehub/icons-static-png@1.97.1`，素材随包内置在 `Sources/BrandAssets/`）单点：`Brand { claude, codex, cursor, claudebar }`，两个 init：`(brand:well:page:)` 与 `(codex:well:page:)`。**`page:` 不是 `Theme.isDark`**——`nil` 主题面、`true` 黑底（灵动岛在两种主题下都是黑的）、`false` 亮底；**`-light` 文件是黑墨、`-dark` 是白墨**（LobeHub 按背景命名，不是按字形），搞反就会画出黑底黑字。图形由 `Tools/gen-brand-marks.py` 剪到墨迹并按画布 90% 写回，**按宽度**定标（Cursor 的立方体比宽高，按共享边长会被画小 12%）；`Tests/product-mark-regressions.py` 渲染真实视图量这条比例 |
| `Views/Shared/Tile.swift` | `TileGrid` + `.tile()` / `.hoverTile()`（宫格表面，即 `TileSurface` 的修饰符形态） |
| `Models/CodexProviderStore.swift` | Codex 状态中枢 + 本机代理生命周期 |
| `Models/CursorUsageStore.swift` | Cursor 额度的可观察持有者与轮询（`AppConfig.cursorQuotaPollInterval` 20 分钟）：启动先用 `lastKnown()` 的落盘读数渲染，探针回来原地替换；`loading` 只门住按钮，只有**从来没有读数**时才画转圈 |
| `Utils/CursorUsageFetcher.swift` | Cursor 额度探针：读 `state.vscdb` 里 Cursor 自己的 token（无登录、无 cookie），**两套鉴权面**——Connect RPC 收裸 JWT、`cursor.com/api/*` 收 `<sub>::<jwt>` 编码后的 cookie + `Origin`；月度 `GetCurrentPeriodUsage`（含两个命名池 `autoPercentUsed`=Cursor Models / `apiPercentUsed`=Other Models，以 `cursorModelsFraction` / `otherModelsFraction` 暴露）与 Grok 周窗口 `GetSandUsageStatus`。已用比例取 `includedSpend / limit`，**不是** `totalSpend / limit`（后者含不在上限里的 `bonusSpend`）；两个池不各持 money limit，共享同一个 `limit` + `includedSpend`；失败重试退避 4 s，跨过系统代理写入窗口。`number(_:)` 是**本文件唯一**的 JSON 数值取值口（数字与字符串都收，聚合接口的 token 是字符串），`billingCycle()` 给账本提供窗口退化目标 |
| `Utils/CursorLedger.swift` | Cursor 的**实际扣费**解码（`GetAggregatedUsageEvents` / `GetFilteredUsageEvents` 两个 RPC 的纯解析）：`Row`（四桶 token + `costCents`）与 `Snapshot`，以及窗口规划 `windowChunks` / `plan(for:billingCycle:)`。**token 字段是字符串**、`tokenUsage` 可能整个缺失、错误信封 `{"code":"internal"}` 必须返回 nil 而不是空结果（空结果 = $0.00 = 免费的月份）；`folded` 把 Cursor 的 `claude-opus-5-5-medium` 折到本地客户端的 `claude-opus-5-5`。全 `static`、无网络，供 `Tests/cursor-ledger-regressions.py` 切片 |
| `Utils/CursorLedgerStore.swift` | 实际扣费的可观察持有者：按用量页当前周期取窗口（`年`/`全部` 退化为账单周期并标记）、失败保留旧值绝不写空、落盘 `cursor-ledger.json` 供启动即渲染；只在窗口变化/手动/超过 6 h 时发请求，落地后发 `.cursorLedgerDidChange`。与 `CursorUsageStore`（额度）分开：一个跟周期 chip 走、一个跟月度边界走 |
| `Models/AppPreferences.swift` | 空闲通知、代理端口、第三方上游、VPN mixed-port / 系统代理 / TUN 等 |
| `Utils/FilePaths.swift` | Claude / Codex / Cursor / App Group / `vpnDir`（Cursor 的两份落盘读数 `cursor-allowance.json`（额度）与 `cursor-ledger.json`（实际扣费）都在 Application Support 根下） |
| `Utils/VpnManager.swift` | mihomo 进程、测速、流量流、超时 failover；内核 stdout/stderr 的一段除写 `core.log` 外还顺手喂给 `VpnDomainLog`（同一份字节）。`core.log` 超过 8 MB 时自截尾轮转并保留最后 512 KB，写方每次 `append` 不 `fstat`，读取方靠 `generation` 判断偏移是否已失效 |
| `Utils/VpnDomainLog.swift` | VPN 流量日志：把内核 `level=info` 的连接行（`[TCP] src --> host:port match 规则 using 出口`，失败走 `level=warning` 的 `dial 出口 (match 规则) … error:`）切出域名 / 端口 / 规则 / 出口，按出口末段（`[DIRECT]`→直连、`[REJECT]`→拒绝、否则已代理）归类，环形 2000 行（`VpnDomainLog.limit`）+ 按域名汇总。只在内存。`VpnDomainFeed` 按字节缓冲、只在 `\n` 切断（分块可能落在多字节字符中间），解析在管道线程上做，主线程只收 ≤1 Hz 的批量发布（`minInterval`，一串连接只花一次视图更新）—— 与 `VpnLiveRates` 同一形状。`VpnWatchlist` 是「该走代理却走了直连」那条分析用的小服务表（六项：Anthropic / OpenAI / Gemini / xAI / Cursor / GitHub，按域名后缀匹配） |
| `Utils/XZArchive.swift` | `.xz` → 文件的流式解压（`libcompression` 的 `COMPRESSION_LZMA`，无第三方依赖）。收的是 `.xz` 容器而非裸 LZMA 流；峰值内存是字典 + 两个 1 MB 缓冲，不整档入内存。唯一调用者是内核解包 |
| `Utils/VpnHTTP.swift` | 控制器 HTTP，禁用系统代理 |
| `Utils/VpnSubscriptionStore.swift` | 订阅、YAML 合成、`tuneForStability`；合成前先插 `VpnProviderDirect.inject`（见下）——顺序不能反，`tuneForStability` 会改规则正文 |
| `Utils/VpnSystemProxyController.swift` | `networksetup` + Guard + TUN DNS；绕过列表在 clash-verge 的默认项之外**追加本机供应商的 host**（默认项全是地址与网段，绕不过域名） |
| `Utils/VpnNetProbe.swift` | 连通性探测 |
| `Utils/VpnProviderDirect.swift` | 把本机**两份供应商表**里的 host 钉在规则链最前面（`DOMAIN,<host>,DIRECT`）并加进系统代理绕过列表：自建 / 虚拟域名的端点在国内却命不中 `GEOSITE,CN`，会落进末尾的 `MATCH` 绕道出国再回来（实测一台广州端点每轮 26–41 MB 上下文全这么走）。**拒绝名单**——认不出的 host 一律直连，只把 `anthropic.com` / `openai.com` / `x.ai` / `openrouter.ai` / `googleapis.com` / `nvidia.com` / `lmstudio.ai` 排除在外；注入按 profile 自己第一条规则的缩进写，否则 YAML 直接解析失败 |
| `Utils/FanMonitor.swift` | SMC 风扇 / 温度；读取在后台队列，主线程只做去重发布 |
| `Utils/ScreenshotHotKey.swift` | Carbon 全局 ⌘⇧A |
| `Utils/ScreenshotOverlay.swift` | ScreenCaptureKit 拉框截图 |
| `Theme/Theme.swift` | 设计 token + `Theme.Ink`（作文字用的信号色，≥4.5:1） |
| `Views/MainWindowView.swift` | 9 页 `AppPage`；顶栏 tabs（帮助走右上角问号）；每页只在选中时挂载（`TrafficPageState` 让流量页重进无代价） |
| `Views/MenuBarView.swift` | popup 壳（460pt，与 `MenuBarController.sizeAndPosition` 同一数字）：Header + MachineKpiStrip + 能源流向 + 两面板 + 操作栏；只订阅外壳状态 |
| `Views/Pages/VPNView.swift` | VPN 主界面（节点宫格、实时速率、订阅，以及折叠的「日志」与「流量日志」两节；两节的徽章与内容都是独立小视图，`VPNView` 本身不观察那两个 store） |
| `Views/Pages/VpnDomainLogSection.swift` | 「流量日志」一节：明细 / 汇总两个模式 + 路由筛选 + 搜索 + 复制 / 清空（清空二次确认）。汇总给出按命中排序的域名、路由构成微条、「常见服务走了直连」告警，以及「内核只记 TCP、不含字节数」的口径说明 |
| `Models/IdleTransitionDetector.swift` | `ConfirmedCompletionDetector` / `QuotaResetDetector` / `QuotaPollScheduler` —— 完成、额度重置两种边沿检测 + 下次额度轮询的排程（按已知重置点对齐，不再是固定 15 分钟）（文件名是历史遗留） |
| `Utils/SessionTitle.swift` | 会话卡片标题的唯一推导：Codex `threads.title` / Cursor `composerHeaders.name` / CC 首条人类 prompt，回退目录名 |
| `Utils/ModelPricing.swift` | 模型花费估算：slug 归一化与匹配、分币种累加、金额格式化（`Tests/model-cost-regressions.py` 锁定） |
| `Utils/ModelPriceTable.swift` | 内置官方刊例价表（每行标注来源，见 [§15](15-model-cost.md)）；更新只需改这一个文件 |
| `Utils/ExchangeRate.swift` | USD→CNY 汇率：用户要求折算时才联网（两个无 Key 日更源），也可手动钉住一个值 |
| `Models/ConnectorManager.swift` | 连接器扫描：三家客户端的本机 Skills / MCP / 插件，及其启停方式；只读元数据，不启动服务。Skill 的启停对三家都是同一套可逆移库（`DisabledSkills/` + `registry.json`），平台筛选只收窄联动的同名安装集合，不改写法。`shared` 是全应用一份（每次进页面新建会让清单从空起步），重扫只发布变化 |
| `Models/MCPToolDiscovery.swift` | MCP `initialize` + `tools/list`（不发 `tools/call`），HTTP 与 stdio 两种传输，带超时与上限 |
| `Views/Pages/ConnectorsView.swift` | 连接器页：客户端筛选 + 「本机共享」+ 类型筛选 + 搜索 + 等高卡片网格 |
| `Views/Pages/ConnectorDetailSheet.swift` | 连接器详情：Skill Markdown、MCP 工具列表、插件组成 |
| `Views/Shared/SkillMarkdownPreview.swift` | SKILL.md 的原生 SwiftUI 渲染（标题 / 列表 / 引用 / 代码块 / 表格） |
| `Models/DocumentMarkup.swift` | 上面那套 Markdown 的**解析**：块模型与 `parse` 从视图文件里提出来，供渲染、飞书文档预览与两条回归共用一份实现（`interaction-performance-regressions.py` 直接切这个文件，不再从视图里抠切片） |
| `Views/Shared/ExchangeRateTile.swift` | 设置 → 通用 → 用量与花费 → 美元兑人民币：显示当前汇率与日期、手动钉值（清空恢复自动查询） |
| `Views/Shared/VpnTopChrome.swift` | `VpnStatusPill`（popup 状态行的节点 / 延迟药丸）+ `CursorUsagePanel`（Cursor chip 的面板）+ `VpnDelayStyle`。`VpnNodePickerPanel` 已无调用点，已删除 |
| `Views/Shared/ProxyUpstreamPickers.swift` | 本地代理上游：只保留第三方 OpenAI / Anthropic 两个选择（默认跟随 Codex / Claude Code 当前供应商，不写 `config.toml` / `settings.json`）；CC / Codex 的只读卡已删——它们的选择在「模型」页 |
| `Sources/ensure-dev-cert.sh` | 本机 ClaudeBar Dev 代码签名身份 |
| `Sources/ci/extract-changelog.py` | 切出某版本的 CHANGELOG 段，拼 Release 说明 |
| `Views/Pages/UsageView.swift` | 用量页：周期条（日 / 月 / 年 / 全部）、热力图、来源构成、按模型瓦片；瓦片上**两行钱**（估算 + Cursor 实扣）与一个单独的 `CursorTokenUsageCard`（按官方账单、按窗口取数）；刷新按钮同时失效额度快照与账本缓存 |
| `Views/Pages/CursorTokenUsageCard.swift` | 用量页上 Cursor 的独立卡：按模型的四桶 token 与实扣金额（`CursorLedgerStore`），没有日粒度就不画走势与占比，只把 token 限定在**它实际覆盖的窗口**里并在卡上标出日期区间 |
| `Tests/*.py` | 源码切片回归（`make test` / CI）；不改用户配置、不联网。`make test` 是那份清单的唯一出处，CI 调用它——两处各抄一份的写法已经漏掉过六个脚本。Cursor 三条：`cursor-usage-regressions.py`（解码器与 cookie 拼写）、`cursor-ledger-regressions.py`（实际扣费解码 / 折价窗口，模板在 `Tests/fixtures/cursor-ledger-probe.swift`）与 `cursor-turn-regressions.py`（忙碌的写时钟界）；VPN 两条：`vpn-domain-log-regressions.py`（本机 `core.log` 的真实行型、被切在多字节字符中间的残行、ClaudeBar 自身诊断的误判）与 `vpn-provider-direct-regressions.py`（哪些 host 该钉直连、已知境外域名不得被钉、规则缩进抄的是 profile 自己那一列）。定价页一条：`model-price-source-regressions.py`（六家厂商页面 + models.dev 快照，在 `Tests/fixtures/price-pages/`，断言解析结果与**内置价表逐桶相等**——阿里页的 `&lt;` 解码顺序、Kimi K3 的双写入列、DeepSeek 的高峰/空闲对都在这条上）。图标一条：`icon-minimal-regressions.py`（两个 `.icns` 都已是最小，且 `--check` 会拒绝一个被重新膨胀的副本）；推广图一条：`promo-key-regressions.py`。**时序类断言一律等效果不等时长**（`performance-regressions.py` 的发布预算与用量去重）——固定常数已经把两条 CI 跑红过。`e2e-codex-tree.py` 是额外的端到端脚本：monitor 交出的东西 → `externalSessionTree` / 各计数器，合成 fixture 常跑，加 `CLAUDEBAR_E2E_REAL_INDEX=1` 时再对真实 `~/.codex` 索引断言一遍；它要编整个 app target（约 2 分钟），**不在 `make test` 里** |
| `Tests/battery-control.c` | 电池辅助进程回归：IOKit transport 换内存模拟，不写真实 SMC |
| `Sources/Widget/*.swift` | WidgetKit |
| `Sources/BrandAssets/*.png` | 三家客户端 + ClaudeBar 自己的品牌图形（`Tools/gen-brand-marks.py` 生成）；`Sources/build.sh` 除随应用内置外**还会复制进 appex**——扩展有它自己的 `Bundle.main`，不复制的话小组件会静默退回兜底字形，看起来就像一次有意的改动 |
| `Sources/build-config.sh` | 构建身份与输出路径的单点：`CLAUDEBAR_CHANNEL`（dev / release）、`CLAUDEBAR_SKIP_INSTALL`（默认 1）、`CLAUDEBAR_PACKAGE`、产物目录与安装路径 |
| `Sources/Shared/BuildChannel.swift` | 主应用与 Widget 共享的编译期版本身份：bundle ID、App Group、URL scheme、`allowsSystemIntegration`、`promptsForSystemPermissions` 与 `restrictionMessage` |
| `Sources/build.sh` | 构建 / 签名 / 安装 / 拉取 mihomo（打成 `.xz` 并复用仓库内那份）/ 把 `Sources/BrandAssets/` 复制进 appex / 把 `Sources/Fonts/`（问候的 49 款随包手写体 + 各自的许可证）复制进 `Resources/Fonts`，由 `GreetingScript` 按文件名加载 |
