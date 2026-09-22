# 更新日志

本文件记录 ClaudeBar **用户可见**的版本变化。版本规则见 [VERSIONING.md](VERSIONING.md)，发版步骤见 [RELEASING.md](RELEASING.md)。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

---

## [Unreleased]

供应商余额一屏、Codex 套餐额度、AirPods 电量与开机自启动；本地代理改为令牌鉴权 + 仅 `127.0.0.1`；订阅下载改为直连绕开机场占位节点。

### 新增

- **帮助页**：主窗口右上角问号进入，左侧章节导航 + 右侧全文（26 篇：上手 / 本地代理 / 会话与用量 / VPN / 快捷键 / 常见问题），支持搜索。
- **概览细节浮层**：内存液面与硬盘占用点开分别是内存明细与磁盘占用图（复用系统采样器，打开不扫盘）。
- **供应商余额**：概览「供应商余额」卡并发查询所有可用供应商，显示「名称 · ¥12.34 / …」；货币符号不再重复、非 CNY 不再错标。
- **Codex 套餐额度**：模型页 Codex 供应商显示 5 小时 / 7 天窗口的已用百分比与重置时间；未登录 ChatGPT、API Key 登录、登录过期各有对应说明。
- **还原为官方配置**：Claude 侧清除 ClaudeBar 写入的 `env` 键，Codex 侧切到不占保留名的 `openai_http`（保留 `auth.json` 里的 ChatGPT 登录），修掉切回官方后反复 "Reconnecting 1/5…" 的问题。
- **配置文件自动备份**：首次改写前各写一份 `settings.json.bak` 与 `config.toml.bak`。
- **电量与功率**：概览「连接」卡显示电量、充电 / 已接通状态，点击进入电源流：输入 / 系统 / 电池功率；无电池的机器不显示。
- **蓝牙耳机电量**：概览「耳机」卡显示 AirPods / Beats 等左右耳与充电盒电量、充电中标记；放进充电盒只是「播报」而非在用，不误报为活跃。
- **开机自启动**：设置页开关以系统 `SMAppService` 状态为准；需用户到系统设置确认时显示「已在系统设置中等待允许」。
- **VPN**
  - 订阅节点预览：不切换当前订阅也能看某份订阅的节点与策略组。
  - 端口占用诊断：启动前只回收自己的残留内核，再用 `lsof` 探测端口；被 Clash Verge 等外部进程占用时直接报出占用的进程名，并提供重试。
  - GeoSite 预置：含 `GEOSITE,` 规则的订阅不再卡在「内核启动超时」。
  - 出口 IP 探测端点换成 Clash Verge 同款并逐个查询。
- **流量访问日志**：每行显示 token 合计与输入 / 输出 / 命中拆分，未开流量记录时也有。

### 变更

- **本地代理鉴权**：只监听 `127.0.0.1`（此前是通配地址，局域网可达），每个连接都必须带 `~/Library/Application Support/ClaudeBar/proxy-token`（0600）的令牌，`/health` 也不例外；客户端自带凭据不再转发给上游，由代理统一注入。401 提示指向 设置 → 本地代理。
- **VPN 订阅下载改为直连**：按 `mihomo` / `clash.meta` / `ClashforWindows` / `clash-verge` 轮换 UA，不再经 mixed-port 或系统代理（机场会对代理来源回 403 或只给 1 个占位节点 + 假 1 GB 配额）。超时 30s → 45s。**这是「链接在 Clash Verge 有节点、在 ClaudeBar 没有」的原因**。
- **订阅结果校验**：200 但少于 2 个节点且无 `proxy-providers:` 判为占位不保存；刷新后节点数骤降到原数 20% 以下则保留原节点并提示；配额头也走直连，占位配额不再覆盖真实用量。
- **订阅解析**：`---` / `...` 文档标记不再让 mihomo 丢掉全部节点；base64 订阅已含 `proxies:` 时直接使用，否则转换 `ss://` / `vmess://` 分享链接；节点计数兼容列 0 的 `- name:` 写法。
- **菜单栏 popup 改版**：模型切换移到页头 Claude Code / Codex chip（一行一个「供应商 / 模型」+ checkmark），VPN 换成 chip + 电源卡；popup 不再铺供应商宫格（宫格只在主窗口「模型」页），底部去掉独立「编辑供应商」窗口。
- **用量页**：周期图改为热力图，`CacheAnatomyBar` 保留为 token 构成横条。
- **文字颜色**：新增 `Theme.Ink`（作文字用的信号色，对比度 ≥4.5:1），字与图标用 `Ink`，形状仍用原信号色。
- **Codex `config.toml`**：受管表名不再固定 `[model_providers.custom]`，保留名（`openai` / `ollama` / `lmstudio` / `amazon-bedrock*`）自动改名；`wire_api` 固定 `responses`（此前带 `chat` 会导致 Codex 无法启动）。
- **Codex 会话判定**：是否归档读桌面索引 `state_*.sqlite`（`archived = 0`），忙碌状态来自 `task_started` / `task_complete` / `turn_aborted` 事件而非 mtime；尊重 `CODEX_HOME`；子 agent 只在活跃时成卡。上下文百分比改读本轮 `last_token_usage`（此前用累计值，出现过 412%）。
- **连接卡片有线判定**：必须是真正的以太网端口（排除桥接 / iPhone USB / 蓝牙 PAN）且有载波，拔线后有线会如实关闭。
- **窗口不可见时降低采样与动画**：会话轮询三档（忙 2.5s / 全空闲 5s / 无可见窗口 15s），并同时关停 FSEvents 用量重扫、进程采样、VPN 连接轮询与全部常驻动画。
- **文件权限**：写入密钥的文件统一 0600（`settings.json` 及其 `.bak`、`presets.json`、`codex-providers.json`、`proxy-token`）；抓包记录落盘前脱敏 `authorization` / `x-api-key` / `cookie`。
- **风扇 helper 收紧**：安装前校验签名，非 root 拒绝执行，转速按 SMC 的 `FNum` 校验并夹在 0…12000。

### 修复

- **多处尾部读取静默返回 0**：读 transcript / rollout 尾部时严格 UTF-8 解码遇到多字节字符被截断会让整个窗口读不出来（实测 600 份 transcript 中 31 份、291 份 rollout 中 14 份上下文一直显示 0），改为宽容解码；JSONL 存储与原始 SSE 报文同理。
- **含图片的一轮反复 400**：base64 被截断或 PNG 缺 `IEND` 的图片仍被转发，上游每轮都 400 并重放；现在替换为 `[image omitted — incomplete data URI]`。
- **VPN 端口冲突**：不再出现「同一端口跑着第二个内核、系统代理与 TUN 标记还在、流量走未受管的进程」的状态；内核自身报的 `address already in use` 会显示出来。
- **代理健康检查误报**：探测改为携带令牌请求 `/health`，代理正常时不再判为不可用。
- **代理日志与抓包泄漏**：抓包 DB 显式级联删除 payload 行、清扫孤儿媒体目录、限制实时预览缓冲；空闲页超阈值时 `VACUUM`（实测 `proxy-capture.db` 84 MB / 20,581 空闲页 / 2 行有效数据）。
- **余额显示**：不再重复打印 `¥`；URL 的查询串或路径里含 `127.0.0.1` 不再被误判成本地代理。
- **端口被占用**：SQLite 加 `busy_timeout`，备份进程或 `sqlite3` 持锁时不再静默丢写入。
- **VPN 日志膨胀**：`core.log` / `vpn.log` 限 8 MB 轮转（此前无上限，实测涨到 86 MB）。
- **窗口不可见时的无谓开销**：心跳字典不再按写入逐次发布，1 Hz 采样与常驻动画跟随可见性。

### 性能

- 用量索引重扫不再对每个文件单独 `attributesOfItem`（每个文件少两次 `getxattr`），改为一次目录枚举取回属性。
- 供应商余额、Codex 激活改为可取消的串行任务，连点不再互相覆盖。
- `DateFormatter` 按格式缓存；Widget 快照编码复用同一个 `JSONEncoder`；访问日志 token 计数在流结束时写一次。
- VPN 出口 IP 探测端点从 4 并发 + 7 端点改为 4 端点逐个查询，不再占满当前节点的连接槽导致超时。

### 测试

- 新增 `Tests/ui-regressions.py`：从源码切片 + 生成 Swift 编译运行，覆盖心跳发布语义（无变化不发布 / 多次变化只发布一次 / 上限 24 / 缺席会话被裁剪）与 `EqualRowGrid` 布局缓存（内容变化使缓存失效、宽度跟随、回缩恢复）。只需 Python 3 标准库与 `swiftc`，不需启动 App 或任何 TCC 授权。

---

## [1.11.0] — 2026-09-19

冰面 / 石墨两套作者色、玉环图标，以及概览 2×3 本机仪表与更密的菜单栏 popup。

### 新增

- **浅色冰面 / 深色石墨** 两套手写主题，设置或 popup 一键切换，不跟随系统外观。
- 概览资源格改为 **2×3**：CPU 芯片、GPU 均衡器、内存液面、硬盘占用、Wi-Fi / 蓝牙 / 有线、左右风扇。风扇转子可分别点到最大或回到自动。
- 用量：**日 / 月 / 年** 热力图、来源三柱、Token 构成条；只统计模型 Token，VPN 配额留在 VPN 页。
- 菜单栏 popup：CC / Codex / VPN 三格切换、会话一列、用量热力与构成；底部去掉装饰文案。

### 变更

- Dock 图标改为三枚玉环 + 底栏；菜单栏模板标改为 **一环一线**。
- VPN 出站路径改为 `›` 面包屑，不再画装饰地铁线。
- 宫格瓦片按行拉齐；设置项固定两行说明，避免一行高一行矮。
- 菜单栏面板无标题栏、22pt 圆角；会话区按内容收高度。

### 修复

- 风扇叶片不再在刷新时弹回起点，转速随 RPM 变化但仍保持连续旋转。
- 流量速率从 `VpnManager` 抽到 `VpnLiveRates`，降低 VPN 页卡顿。

---

## [1.10.0] — 2026-09-10

VPN、区域截图、本地代理三路上游，以及本机自签后屏幕录制授权可保持。

### 新增

- **VPN**：内置 mihomo sidecar；订阅、节点选择、延迟测试、系统代理 / TUN、连通性探测；出口连续 `i/o timeout` 时自动切到延迟更好的 HY2 / KR。
- **区域截图**：全局 ⌘⇧A 拉框（复制 / 保存 / 钉住 / 标注），需屏幕录制权限。运行时占用 Finder「前往 → 应用程序」。
- 菜单栏在 VPN 运行时显示双行 ↓/↑ 速率；popup 页头含 VPN 启停与节点选择（主窗口不重复该 chrome）。
- **本地代理三路上游**：Claude Code 与 Codex 各跟「模型」页当前供应商；第三方 OpenAI / Anthropic 可另选供应商，不改写 `settings.json` / `config.toml`。

### 变更

- 主窗口增加 **VPN** 页（概览 / 会话 / 模型 / 用量 / 流量 / VPN / 设置）。
- 用量周期图改为平涂堆叠柱（无空槽网格）；悬停显示当天。
- 本机开发签名改为钥匙串身份 **ClaudeBar Dev**（须信任为 code-signing 根），避免每次重编译都要重新授权屏幕录制。CI 仍为 ad-hoc。
- 设置页展示 CC / Codex 当前上游，并为第三方提供独立选择器。

### 修复

- 控制器 API 不走系统代理，避免经 mixed-port 死锁。
- 系统代理回读使用 Wi-Fi / Ethernet，不再信任 `listallnetworkservices` 第一行。
- 菜单栏模板图标改为矢量三叶标：带薄荷绿底的 PNG 在 `isTemplate` 下会整块变白。
- 截图：Esc 可退出；全屏覆盖层不再被菜单栏挤偏导致发糊与画框偏移。

---

## [1.9.0] — 2026-09-03

Claude / Codex 供应商独立选择；流量简洁视图默认折叠工具与系统提示，并支持搜索。

### 新增

- 流量简洁视图：连续工具调用、系统提示默认折叠；对话区支持关键词搜索。
- 流量检查器可渲染请求里的图片（base64 落盘后按文件引用显示）。
- 版本管理文档 [`docs/VERSIONING.md`](VERSIONING.md)；GitHub Release 说明自动截取对应 CHANGELOG 段。

### 变更

- Claude Code 与 Codex 的供应商列表**各自独立**，激活一侧不再改写另一侧配置。需要拷贝时到管理页手动「导入」。
- 菜单栏 popup 分栏展示并切换 Claude / Codex 模型；设置页连通性检测按协议分开。
- README 增加流量检查器截图，修正表格排版。

### 性能

- 流量页首次打开后保留在内存，避免每次切 tab 重建整页。
- 对话解析与图片解码改到后台；简洁模式截断超长工具/系统正文，主线程不再吞整份请求 JSON。

### 修复

- 菜单栏未观察 Codex 列表时，切换模型或流量记录开关界面不刷新。
- 仅使用 Codex、没有 Claude `settings.json` 时 popup 被整块挡住。

---

## [1.8.0] — 2026-09-03

本地 LLM 代理、Codex 供应商、流量检查器，以及主窗口宫格与空闲通知。最低系统 **macOS 15+**，安装包改为 GitHub Releases DMG。

### 新增

- **本机 LLM 代理**：`127.0.0.1` 转发 Anthropic Messages 与 OpenAI Chat / Responses；Chat 桥接与 MCP 工具名修复。
- **流量检查器**：请求列表、对话 / 工具 / 原始报文、流式展示、访问日志；供应商卡片可开关流量记录。
- **Codex 供应商**：独立 `~/.claude/claude-bar-codex-providers.json`，激活写 `~/.codex/config.toml`；支持预设与互导。
- **空闲通知**：会话由忙碌转空闲时系统通知，可在终端恢复。
- 外部会话纳入 Codex（及当时的其它 CLI）巡检；用量改为 SQLite 日聚合索引。
- 本机资源条：会话相关 CPU / GPU / 内存归因。
- GitHub Actions CI 与 `v*` Release 打包（DMG + zip + checksums）。

### 变更

- 主窗口改为顶部导航 + 宫格瓦片（概览 / 会话 / 模型 / 用量）；菜单栏 popup 同步宫格。
- 模型页可管理 Claude 供应商与预设；应用图标更换为 Axon。
- 用户安装路径改为 Releases DMG；`Sources/build.sh` 仅供开发与 CI。版本号单一来源：根目录 `VERSION`。

### 移除

- WorkBuddy / OpenClaw 会话与用量数据源。
- 旧 Preset 迁移通道（`claude-bar-presets.json`）。
- 不承载数据的装饰动效（雷达、伪示波器、指针光效等）。

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

[Unreleased]: https://github.com/wangxiajun68/ClaudeBar/compare/v1.10.0...HEAD
[1.10.0]: https://github.com/wangxiajun68/ClaudeBar/releases/tag/v1.10.0
[1.9.0]: https://github.com/wangxiajun68/ClaudeBar/releases/tag/v1.9.0
[1.8.0]: https://github.com/wangxiajun68/ClaudeBar/releases/tag/v1.8.0

