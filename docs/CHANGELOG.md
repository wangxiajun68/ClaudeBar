# 更新日志

本文件记录 ClaudeBar **用户可见**的版本变化。版本规则见 [VERSIONING.md](VERSIONING.md)，发版步骤见 [RELEASING.md](RELEASING.md)。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

---

## [Unreleased]

刘海灵动岛；设置页新增「权限与隐私」（隐私能力改为逐项 opt-in）；能源卡新增电池充电控制（限充 / 暂停 / 放电）；模型页改为供应商目录；完成通知改为只在 transcript 证明交付了新答复时才发。

### 新增

- **刘海灵动岛**：把 MacBook 的硬件刘海变成"余光界面"。收起态在刘海两侧显示运行中的 Agent（多于一个显示数量，空闲时是今日节奏环）与今日 token；会话**由忙转闲且确认交付了新答复**时从刘海长出一条提醒（不需要通知权限、不打断焦点），点「继续」直接回到那个会话；鼠标停在刘海热区 120ms 展开成会话列表（最多 3 行，行内带上下文"油量"，60% 转琥珀、85% 转珊瑚）+ 可滑动的 30 天直方图 + 本月节奏 + `CC / Codex / 三方` 来源切换。顶栏路由随最相关的会话切换；无刘海的屏幕在菜单栏中央画伪刘海。开关在 设置 →「灵动岛」（总开关 / 两翼 / 完成提醒 / 全屏应用中显示，前三个默认开、全屏默认关）。新文件 `NotchIslandController.swift`、`Models/IslandLiveModel.swift`、`Utils/NotchGeometry.swift`、`Views/Island/`。设计与性能口径见 [设计 §10](design/10-notch-island.md)。
- **设置 → 权限与隐私**：所有会触发系统授权弹窗的能力集中到一处，**默认全部关闭**，逐项开启，每项旁边显示系统当前的授权状态并可跳转系统设置。清单：桌面小组件（写入 App Group / 小组件容器——这正是每次启动"访问其他 App 的数据"弹窗的来源）、空闲通知、区域截图 ⌘⇧A、在终端继续会话（自动化）、蓝牙与耳机电量、Wi-Fi 名称（定位）、读取 Cursor 会话（默认开，无系统弹窗）。关闭时不发起系统请求，对应代码路径完全不执行。新文件 `Utils/PermissionCenter.swift`、`Views/Shared/PermissionsSection.swift`。
- **电池充电控制**：能源卡支持 20–100% 充电上限（默认 80%）、充电至上限、暂停充电、接电放电至上限与恢复系统管理。首次点击控制按钮时经管理员授权安装随包签名的辅助工具；退出应用恢复系统管理，下次启动不接管。合盖或未接电源不开始主动放电；休眠前恢复原始控制值。实现、权限边界与 SMC 兼容性见 [技术 §12](technical/12-battery-control.md)。
- **供应商目录**：模型页重做为「供应商目录」——按模型平台 / Coding 与 Token Plan / 聚合与自建分组，22 个内置入口（含地区与套餐的独立入口），浏览器厂商品牌图标随包内置（LobeHub Icons，含 LICENSE）。已有供应商点「配置」开单供应商聚焦弹窗；新预设走「连接凭据 → 模型 → 保存」，**不自动激活**。卡片直接显示该供应商账户余额。
- **选择与激活分离**：卡片中间显示"当前使用 / 待激活"的目标模型，点开是搜索浮层（按配置分组、完整模型 ID、上下键 + 回车）；**只选择不写入**，点独立激活按钮才提交切换。失败由错误区显示，未写入不提前标绿。状态四态：未配置（灰）/ 待完善（琥珀）/ 已配置未激活（蓝）/ 已激活（绿）。
- **继续会话的目标终端**：设置 →「继续会话」可选 自动 / Otty / Warp / 终端（默认自动，按 Otty → Warp → 终端 降级，未安装的选项带标注）。新文件 `Utils/OttyBridge.swift`（`otty-cli` socket IPC，按 `agent_session_id` 聚焦已有窗格）、`Utils/SessionHost.swift`（沿父进程找宿主 App：终端 / iTerm2 按 tty 选标签，Cursor / VS Code 聚焦对应文件夹窗口）。
- **回到会话不再另开一个**：会话进程仍存活时只把宿主窗口 / 标签页带到前台（Otty 走 socket，无需自动化权限）；已结束的才 `claude --resume` / `codex resume`。加载在 Codex Desktop 的线程直接开 `codex://threads/<id>`。
- **Codex 额度显示重置时刻**：概览磁贴副标题从「已用 N%」改为「10 小时后重置」，tooltip 与表盘下都列出每个窗口的重置时刻与相对时间；兼容 `resets_at` 与秒 / 毫秒两种时间戳。
- **余额支持 4 家官方接口**：DeepSeek、Kimi 开放平台（moonshot.cn / moonshot.ai）、硅基流动、OpenRouter；USD 显示 `$`。余额按「同一 Key + 同一 Base URL」去重请求，所有匹配的卡片都拿到金额。帮助页与 FAQ 同步说明哪些平台会显示。
- **能源流向四态**：充电中 / 电池补电 / 电源直供 / 电池供电，色带厚度按瓦数等比，光波沿流向滚动；电源块在展开态显示「N W 适配器」额定值。读数模型明确改为 SMC `PDTR`（适配器）− `PSTR`（整机），方向由电量计决定。

### 变更

- **默认不再双向联动激活**：切换 Claude Code 只写 `settings.json`，切换 Codex 只写 `config.toml`，激活状态互不影响（此前同名供应商会顺带切对端）。两侧共享同一份配置的名称、Key 与模型列表——首次启动会执行一次配对，为历史配置分配共享 id、把一边空着的 Key 补给另一边、模型列表取并集，然后回写两侧的 JSON（会改动 `claude-bar-providers.json` 与 `claude-bar-codex-providers.json`）。
- **Codex 第三方 Key 不再写入 `auth.json`**：改写在 `model_providers.<key>.experimental_bearer_token`（走本地代理时写代理令牌）。「保留官方登录」开启时只从 `auth.json` 移除本应用写过的 `OPENAI_API_KEY`（ChatGPT 登录原样保留），关闭时整个删除该文件。`requires_openai_auth` 跟随这个开关。修掉切到第三方后 Codex 桌面端进入 API-key 模式、看不到订阅额度、自定义模型 401 的问题。
- **切换 Claude Code 不再改写 Codex 的选中模型与 `config.toml`**：共享代理的旧令牌修复只在 Codex 自己加载配置时执行。「还原官方配置」会先取消挂起的激活任务。
- **完成通知语义收窄**：忙→闲只算候选，必须在此后 10 秒窗口内看到**新的最终答复标记**才通知——权限询问、工具暂停、被中断的一轮、陈旧的忙碌态都不再触发。文案改为「Claude 已完成 / Cursor 已完成 / …」+「<项目> · 最终答复已就绪」（原为"等待输入"+最后工具名）。
- **默认值反转**：空闲通知与区域截图 ⌘⇧A 的默认值由开改为**关**（已显式存过该键的用户不受影响）。桌面小组件写入同样改为 opt-in。
- **连接卡片只留连接**：移除电池 / 电源标记与百分比（电池控制改由能源卡承载），行内保留 Wi-Fi、以太网、隔空投送、耳机；Wi-Fi 信号按 RSSI 分级，名称不可用时区分「在设置中开启」（点击跳设置页）与「授权显示名称」。
- **概览页调整**：移除供应商余额磁贴（余额改显示在模型页卡片上）；VPN 电源卡从资源条下方移到指标网格最后一位，改为一块显示「已连接 / 启动中 / 未启用」与实时下行速率的磁贴。
- **设置页分区重排**：「截图与通知」拆分——截图热键与空闲通知归入「权限与隐私」，新增「继续会话」与「灵动岛」分区。
- **性能与采样**：主窗口被遮挡时按"无可见界面"降频（此前只要 `isVisible` 就全速）；会话全空闲时进程采样 1s → 2s，网卡状态缓存 3s、CPU 温度 5s；装饰动效全部改为 Core Animation（不再用 `TimelineView` 每帧重算 SwiftUI body），并随所属界面是否可见而启停、尊重"减弱动效"；视图订阅按字段收窄，一轮事务只失效一次。
- **流量页实时流**：从主线程 debounce 改为后台 100ms throttle——持续输出不再被饿死，整批只发一次更新，已结束 / 已删除的记录不会被延迟批次复活，数据库锁不再阻塞界面线程。
- **灵动岛 / 悬停相关的重复扫描**：`system_profiler` 60 秒内不重复跑；用量索引停止超过 30 秒才补一次重扫；灵动岛的用量刷新改为单飞 + 尾随合并，不再并发启动多批聚合查询。
- **模型列表拉取收紧**：只按所选协议请求文档化的地址（目录有专用列表地址时用它），不再跨产品 / 套餐猜测；禁止重定向，错误正文遮蔽 Key，重试前清掉旧认证头；Base URL 拒绝带凭据、query 或 fragment（提示"请勿在 URL 中附带 Key"）。
- **Key 输入**：编辑时用普通 TextField（避开 macOS Passwords 接管），失焦后遮蔽为 `••••`。
- **VPN 页**：节点列表虚拟化；日志拆到独立的环形缓冲，追加日志不再让整页（含节点马赛克）重绘。
- **帮助页**：余额条目改写为「供应商卡片没有余额」，列出现在能查的 4 家平台。

### 修复

- **Codex 会话漏报与误报**：成员改为读只读的桌面索引 `state_*.sqlite`（`archived = 0`），空闲的主会话现在也会保留；`exec` / `mcp` 一次性运行、子代理与归档线程排除；崩溃遗留的 open turn 10 分钟后不再算存活；索引不可用时回退旧的近期文件扫描。卡片标题取索引里的标题，便于区分同一项目的多个会话。
- **命令面板里 Cursor 会话跳转无效**（跳到空 UUID 的供应商）→ 改为跳到会话页。
- **主窗口被遮挡时仍在全速轮询 / 跑动画** → 同时检查 `occlusionState`。
- **设置页每个文件卡片重复扫描目录**（在视图 body 里做同步 I/O）→ 后台每 5 秒扫描，离开页面即取消。
- **原始 JSON 视图**：取消解析后仍会回写；长字符串在深色模式下不可读（硬编码深灰 → `NSColor.labelColor`）。
- **Gemini（`/v1beta/openai`）的 Chat 地址多插了一层 `/v1`**。
- **原生 Responses 预设被静默降级成 Chat 转换**。
- **Wi-Fi 卡片在名称不可用时整行变灰**（禁用了按钮）→ 改为可点击的提示。
- **更少的无谓重绘**：菜单栏速率图标复用、网速数值量化（RSSI 取偶、功率保留 0.1W）、等高网格的测量缓存设上限、VPN 节点单元格预建索引。

### 内部

- 新增源码切片回归 `Tests/performance-regressions.py`（流式发布节流、批量通知、取消与延迟批次、灵动岛刷新合流）与 `Tests/rendering-regressions.py`（字段级订阅、动效生命周期、万轮会话过滤），`make test` 已包含；另有 `Tests/codex-session-regressions.py`、`Tests/battery-control.c` 供手工执行。审查记录见 [技术 §14](technical/14-performance-audit.md)。
- `Sources/build.sh` 新增两项硬性步骤：把 `Sources/ProviderIcons` 打进 `Resources/`，以及用 `clang -Wall -Wextra -Werror` 编译电池辅助进程（编译失败即构建失败）并单独签名。构建与签名流程见 [技术 §7](technical/07-build-and-signing.md)。

---

## [1.12.0] — 2026-09-23

应用内帮助手册、概览新增仪表与余额 / 额度磁贴、开机自启动；本地代理改为令牌鉴权 + 仅 `127.0.0.1`；VPN 订阅下载改直连绕开机场占位节点；模型页重做为「模型工作台」。

### 新增

- **帮助页**：主窗口右上角问号（popup 底部也有）进入，左侧目录 + 右侧全文（26 篇：上手 / 本地代理 / 会话与用量 / VPN / 快捷键 / 排障），支持搜索、可复制的命令块与键帽。
- **概览新增磁贴**：Claude Code 配置、Codex 配置、本地代理（`127.0.0.1:端口` + 监听胶囊）、**Codex 额度**（双环表盘 + 「已用 N% · 重置时间」，点一下刷新）、**供应商余额**（逐供应商列余额，可重试）。
- **概览细节浮层**：CPU / GPU / 内存 / 硬盘四格现在都可点开——CPU 与 GPU 是负载历史曲线，内存是进程内存面板（按 RSS 排序，可打开活动监视器），硬盘是启动盘环形占用图；「连接」格点开是连接地图（Wi-Fi 信号强度、耳机、隔空投送入口）。
- **能源流向**：检测到内置电池时，概览画一张功率 Sankey（电源输入 → 整机消耗 / 电池充电，电池放电时汇入整机），菜单栏 popup 里是同一张图的紧凑版。
- **Codex 额度**：概览磁贴与 popup 的 Codex chip 都能刷新——chip 副标题显示「N 小时已用 X% · N 天已用 Y%」并带双环表盘，popup 里点它就直接查询，不用回主窗口。
- **连接卡片**：整卡状态字改为「已连接 / Wi-Fi 已开启 / 本机 / 离线」—— Wi-Fi 由「读到名称或有线或有信号」判定，不再只看 RSSI；新增**隔空投送**入口（打开 Finder 的隔空投送）；Wi-Fi 未拿到名称时显示「授权显示名称」，点一下请求定位授权（新文件 `Utils/WiFiNameAuthorization.swift`，8 秒超时后给提示而不是静默），授权后直接显示网络名与 dBm。
- **硬件细节浮层**（新文件 `Views/Shared/HardwareDetailPanel.swift` / `HardwareIllustration.swift` / `LucideHardwarePaths.swift`）：CPU / GPU 面板含矢量芯片插画（亮度跟随整体负载）、最近采样曲线、逻辑核心数、温度与峰值；GPU 显示 Metal 设备名，CPU 显示 `machdep.cpu.brand_string` 型号。
- **进程内存面板**（新文件 `Views/Shared/MemoryDetailPanel.swift`、`Utils/ProcessMemoryRow.swift`）：只列占用最高的 8 个进程 + 按最大值缩放的条形，PID 收进 tooltip；读取失败给「无法读取进程，请重试」。
- **蓝牙耳机电量**：左右耳与充电盒分别读数（含充电中）。连上即成卡（无电量读数显示「—」）；「在用」由 CoreAudio 默认输出路由 + 蓝牙已连接名单共同判定，「放进充电盒」只是播报态，不误判为活跃。popup 的 KPI 条在有耳机使用中时多出一列耳机电量。
- **开机自启动**：设置页「启动」分区，开关状态即系统 `SMAppService` 状态；等待允许时提示并可直接跳系统设置。
- **还原为官方配置**：模型页与 popup 均可一键还原（带二次确认、可选只还原 Claude Code 或 Codex）。Claude 侧清掉 ClaudeBar 写入的 `env` 键，Codex 侧切到不占保留名的 `openai_http` 并保留 `auth.json` 的 ChatGPT 登录 —— 修掉切回官方后反复 "Reconnecting 1/5…"。
- **配置文件自动备份**：每次启动首次改写前各写一份 `settings.json.bak` 与 `config.toml.bak`。
- **Wi-Fi 名称授权**：设置页说明为什么需要定位权限（读取 SSID），未授权时可一键跳到系统设置；请求期间显示进行中，超时后给出提示而不是静默失败。
- **VPN**
  - 订阅**预览**：点订阅卡只「查看」，大卡列出该订阅的分组与节点名，不切换当前订阅、不启内核。
  - 端口占用诊断：启动前先回收自己的残留内核，再探测端口；被 Clash Verge 等外部进程占用时**指名占用进程**，并提供「换个端口」一键换到空闲端口。
  - GeoSite 预置：含 `GEOSITE,` 规则的订阅不再卡在「内核启动超时」。
  - 日志控制台不再强制滚底，上翻后出现「回到最新」。
- **流量访问日志**：每行新增 token 合计与输入 / 输出 / 命中拆分（未开流量记录时也有）。
- **Widget**：新增 Codex 会话区；token 总量旁显示周期标签（今天 / 9月 / 2026年）；单位与深浅色跟随 App 设置。
- 菜单栏 popup 支持 Esc 关闭；设置页「存储」下的文件「打开」按钮会随文件增减刷新。

### 变更

- **本地代理鉴权**：只监听 `127.0.0.1`（此前是通配地址，局域网可达），每个连接都必须带 `~/Library/Application Support/ClaudeBar/proxy-token`（0600）的令牌，`/health` 也不例外；客户端自带凭据不再转发给上游，由代理统一注入。401 提示指向 设置 → 本地代理。
- **VPN 订阅下载改为直连**：按 `mihomo` / `clash.meta` / `ClashforWindows` / `clash-verge` 轮换 UA，不再经 mixed-port 或系统代理（机场会对代理来源回 403 或只给 1 个占位节点 + 假 1 GB 配额）。超时 30s → 45s。**这是「同一条链接 Clash Verge 有节点、ClaudeBar 没有」的原因**。
- **订阅结果校验**：200 但少于 2 个节点且无 `proxy-providers:` 判为占位不保存；刷新后节点数骤降到原数 20% 以下则保留原节点并提示；配额头也走直连，占位配额不再覆盖真实用量。
- **订阅解析**：`---` / `...` 文档标记不再让 mihomo 丢掉全部节点；base64 订阅已含 `proxies:` 时直接使用，否则转换 `ss://` / `vmess://` 分享链接；节点计数兼容列 0 的 `- name:` 写法。
- **模型页改为「模型工作台」**：标题 + 供应商品牌大标（Claude 八芒星 / Codex 六瓣花）+「当前连接 · 供应商名」；下方是供应商 / 模型搜索框与「仅当前」筛选，无命中显示空态而不是空网格。供应商卡默认展开模型行，网格改为自适应列。
- **菜单栏 popup 改版**：模型切换移到页头 Claude Code / Codex chip（一行一个「供应商 / 模型」+ checkmark），VPN 换成 chip + 电源卡；popup 不再铺供应商宫格（宫格只在主窗口「模型」页），底部去掉独立「编辑供应商」窗口，新增帮助与「还原官方配置」。会话区上限 250→190pt、用量区 320→280pt，并新增能源流向紧凑卡。
- **会话卡重排**：状态胶囊右移、上下文百分比与细条同排、快捷键读数替代齿轮图标；Codex 卡不再内嵌子 agent 列表，改为 `⋯N` 胶囊点开看全部 swarm，卡片高度不再随 fan-out 增长。
- **模型页**：Claude / Codex 两个 chip 带产品图形与滑动选中 pill，tooltip 写明各自写入哪个配置文件。
- **硬件图形改用 Lucide 矢量**：CPU / GPU / 内存 / 硬盘 / Wi-Fi / 以太网 / 电量等自绘成统一线条风格（`LucideHardwarePaths`），替换了此前各自为政的示意图；VPN 仍是盾牌，但未运行时的对勾换回短横，一眼能看出通没通。`NestedOrbit` 等旧装饰件删除。
- **用量页**：周期图改为热力图，`CacheAnatomyBar` 保留为 token 构成横条。
- **文字颜色 `Theme.Ink`**：信号色的「文字版」（浅色加深 / 深色提亮，对比度 ≥4.5:1）。状态胶囊、上下文百分比、模型占比、协议徽章、错误文字全部改用 Ink；字与图标用 `Ink`，形状仍用原信号色。
- **图标与标题**：页面图标换成自绘 `InstrumentGlyph`（27 种），页面标题左侧带 34pt 图标井；`GlyphWell` / `IconChip` 改带描边内边缘，hover 微动。
- **搜索框统一**：帮助页、预设选择、流量页、代理日志四处改为自绘 `InstrumentSearchField`（聚焦高亮 + 清除按钮）。
- **空态与提示**：`StandbyEmptyState` 改为图标井 + 文字；反馈 toast 改为 `info.circle.fill` 卡片；设置项说明文字放宽到 3 行。
- **Codex `config.toml`**：受管表名不再固定 `[model_providers.custom]`，保留名（`openai` / `ollama` / `lmstudio` / `amazon-bedrock*`）自动改名；`wire_api` 固定 `responses`（此前带 `chat` 会导致 Codex 无法启动）。
- **Codex 会话判定**：是否归档读桌面索引 `state_*.sqlite`（`archived = 0`），忙碌状态来自 `task_started` / `task_complete` / `turn_aborted` 事件而非 mtime；尊重 `CODEX_HOME`；子 agent 只在活跃时成卡。上下文百分比改读本轮 `last_token_usage`（此前用累计值，出现过 412%）。
- **连接卡片有线判定**：必须是真正的以太网端口（排除桥接 / iPhone USB / 蓝牙 PAN）且有载波，拔线后有线会如实关闭。
- **窗口不可见时降低采样与动画**：会话轮询三档（忙 2.5s / 全空闲 5s / 无可见窗口 15s），并同时关停 FSEvents 用量重扫、进程采样、VPN 连接轮询与全部常驻动画。采样器从可见性闸门恢复时会立刻补一次采样，不再等下一个周期。
- **风扇控制串行化**：同一风扇的连续指令按序列号排队并作废旧指令，快速点「最大 / 自动」不会两个进程互相打架。
- **文件权限**：写入密钥的文件统一 0600（`settings.json` 及其 `.bak`、`presets.json`、`codex-providers.json`、`proxy-token`）；抓包记录落盘前脱敏 `authorization` / `x-api-key` / `cookie`。
- **风扇 helper 收紧**：安装前校验签名，非 root 拒绝执行，转速按 SMC 的 `FNum` 校验并夹在 0…12000。
- **`ProvidersPanel` 不再挂载**：popup 里的 2 列供应商宫格已停用（文件保留）。
- **README 截图更新**：主窗口与菜单栏 popup 换成本轮界面；补充界面图标来源（Lucide，ISC，随包内置 `Resources/Lucide.txt`）。

### 修复

- **退出 App 不再留下孤儿 mihomo 内核与系统代理**：退出时停止内核、卸下速率 accessory、停截图热键。
- **多处尾部读取静默返回 0**：读 transcript / rollout 尾部时严格 UTF-8 解码遇到多字节字符被截断会让整个窗口读不出来（实测 600 份 transcript 中 31 份、291 份 rollout 中 14 份上下文一直显示 0），改为宽容解码；JSONL 存储与原始 SSE 报文同理。
- **含图片的一轮反复 400**：base64 被截断或 PNG 缺 `IEND` 的图片仍被转发，上游每轮都 400 并重放；现在替换为 `[image omitted — incomplete data URI]`。
- **VPN 端口冲突**：不再出现「同一端口跑着第二个内核、系统代理与 TUN 标记还在、流量走未受管的进程」的状态；内核自身报的 `address already in use` 会显示出来。
- **代理健康检查误报**：探测改为携带令牌请求 `/health`，代理正常时不再判为不可用。
- **代理日志与抓包泄漏**：抓包 DB 显式级联删除 payload 行、清扫孤儿媒体目录、限制实时预览缓冲；空闲页超阈值时 `VACUUM`（实测 `proxy-capture.db` 84 MB / 20,581 空闲页 / 2 行有效数据）。
- **余额显示**：不再重复打印 `¥`（DeepSeek 返回 `¥12.34 CNY` 曾显示成 `¥¥12.34`）；非 CNY 显示 `12.34 USD`；URL 的查询串或路径里含 `127.0.0.1` 不再被误判成本地代理。
- **端口被占用**：SQLite 加 `busy_timeout`，备份进程或 `sqlite3` 持锁时不再静默丢写入。
- **VPN 日志膨胀**：`core.log` / `vpn.log` 限 8 MB 轮转（此前无上限，实测涨到 86 MB）。
- **Widget**：单位设置现在真的生效（此前 Widget 读自己的 `UserDefaults` 永远拿不到 App 的单位设置）；时间戳改中文「刚刚 / N 分钟前」；模型色条与图例数量统一为 4；深色下空闲圆点不再不可见；深色配色整体修正；条宽按容器宽度计算，Large 尺寸不再溢出。
- **设置页代理端口**：不再逐字符写入，只有合法端口（1024–65535）且失焦 / 回车才提交。
- **会话卡悬停操作条对键盘与 VoiceOver 可达**（此前鼠标悬停才可点）；补齐大量 `accessibilityLabel`。
- **主窗口反复关闭 / 打开不再泄漏窗口观察者**（长时间使用不再越来越卡）。
- **删除供应商、清空抓包**均加带名字 / 条数的二次确认。
- **编辑器的校验更严**：Base URL 必须是带非空 host 的 `http` / `https`（此前只看能否解析出 host）；模型名两端空白会被清掉、空名与重名（不区分大小写）都会拦下；保存失败会在编辑器顶部显示可关闭的错误条并**回滚内存里的改动**，而不是静默不动还闪「已保存」。
- **写配置的语义**：空值不再沿用旧值——切到没填 token 的供应商会**清掉上一个 token**（此前会保留，必须手改 `settings.json` 才能删）；`env` 里用户自填的非字符串键（数字、布尔）保持原类型不被改写成字符串；`settings.json` 顶层或 `env` 不是对象时**不再覆盖原文件**，而是报错保留；备份 `.bak` 写失败会在下次写入重试。风扇命令的子进程输出改走 `/dev/null`（此前挂 Pipe 不读会卡住等待）。
- **设置页与模型页的加载**改为懒加载栈，长页滚动手感更稳。

### 性能

- 用量索引重扫不再对每个文件单独 `attributesOfItem`（每个文件少两次 `getxattr`），改为一次目录枚举取回属性。
- 供应商余额、Codex 激活改为可取消的串行任务，连点不再互相覆盖；会话 / Cursor / 外部三类扫描各自加了「已在跑就跳过」的闸门，慢盘上不再叠加重扫。
- `DateFormatter` 按格式缓存；Widget 快照编码复用同一个 `JSONEncoder`；访问日志 token 计数在流结束时写一次。
- VPN 出口 IP 探测端点从 4 并发 + 7 端点改为 4 端点逐个查询，不再占满当前节点的连接槽导致超时。
- 会话页网格改为懒加载；tile 与 panelCard 的描边改为 hover 时才染色，并且描边不再拦截点击。
- 本机指标在需要归因且窗口可见时统一 **1 秒**一跳（此前忙 1s、空闲 2.5s），周期变更后立即重排；硬盘容量查询相应降到每 10 秒一次（占用最多滞后 10 秒）。
- 耳机状态改由 CoreAudio 路由变更通知驱动（此前靠定时轮询日志文件），连接 / 断开响应更快也不白耗采样。
- Codex rollout 解析结果按 mtime + size 缓存，未被追加的文件只做一次元数据检查，不再每 2.5s 重读 32 KB 头 + 48 KB 尾。
- 界面动效尊重「减弱动态效果」：页面切换与栈切换在开启该选项时直接跳变，不做过渡。

### 测试

- 新增 `Tests/ui-regressions.py`：从源码切片 + 生成 Swift 编译运行，覆盖心跳发布语义（无变化不发布 / 多次变化只发布一次 / 上限 24 / 缺席会话被裁剪）与 `EqualRowGrid` 布局缓存（内容变化使缓存失效、宽度跟随、回缩恢复）。只需 Python 3 标准库与 `swiftc`，不需启动 App 或任何 TCC 授权。
- 新增 `Tests/core-regressions.py`：覆盖数值边界（`Infinity` / `NaN` / `Int64` 越界不崩）、配置写入的私有原子落盘与 0600 权限、写配置时保留用户自有键（`permissions`、`GITHUB_PERSONAL_ACCESS_TOKEN` 等）并清掉受管键、损坏的 `settings.json` 不被覆盖、备份内容等于改写前的原文，以及 Codex rollout 头尾解析（含 subagent 判定与 `task_complete`）。
- 两者都由 `make test` 与 CI 的 **Regression tests** 步骤执行。

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

[Unreleased]: https://github.com/wangxiajun68/ClaudeBar/compare/v1.12.0...HEAD
[1.12.0]: https://github.com/wangxiajun68/ClaudeBar/releases/tag/v1.12.0
[1.11.0]: https://github.com/wangxiajun68/ClaudeBar/releases/tag/v1.11.0
[1.10.0]: https://github.com/wangxiajun68/ClaudeBar/releases/tag/v1.10.0
[1.9.0]: https://github.com/wangxiajun68/ClaudeBar/releases/tag/v1.9.0
[1.8.0]: https://github.com/wangxiajun68/ClaudeBar/releases/tag/v1.8.0

