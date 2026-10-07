# 菜单栏 Popup 面板布局

> ClaudeBar 设计文档 · §4
> 相关：[主窗口与设计系统](05-main-window-and-theme.md) · 技术文档 [视图层](../technical/05-view-layer.md)

面板宽 460pt（`MenuBarView` 的 `frame(width:)` 与 `MenuBarController.sizeAndPosition` 里的 `width` 常量，两处必须相等），高度取屏幕可见区高 - 8pt（上限 820pt）。实现为组合壳 `MenuBarView`，内容在 `Views/Popup/` 与 `Views/Shared/MachineKpiStrip.swift`。从上到下：

```
┌─────────────────────────────────────────────────────┐
│ [●] N 会话 · 本地 17890 · [VPN 节点 · 延迟]  [主窗口][刷新] │ ← PanelHeader 状态行
├─────────────────────────────────────────────────────┤
│ [CC] [Codex 额度] [Cursor 额度]  ← 三个切换 chip       │ ← PanelHeader 切换行
├─────────────────────────────────────────────────────┤
│ MachineKpiStrip：进程资源（+ 在用耳机）+ 风扇转速        │
├─────────────────────────────────────────────────────┤
│ PowerFlowCard(compact)  能源流向（有内置电池时）       │
├─────────────────────────────────────────────────────┤
│ SessionsPanel（撑满剩余高度） · UsagePanel（固定 244pt）│
├─────────────────────────────────────────────────────┤
│ [充电控制][刷新][主窗口][帮助][还原官方][管理模型][settings.json][🔔][◐] │ [退出] │
└─────────────────────────────────────────────────────┘
```

（有电池的机器在操作栏行首多一个充电控制按钮；方框只是示意，实际由 `IconChipRow` 画成一个胶囊分组。）

460pt 而不是 424：多出的 36pt 全给切换行——三列各 143pt，`deepseek-v4.1-flash` 这类长模型名能按 `minimumScaleFactor(0.85)` 缩到整名放下（424 时 127pt 的列会把它截成 `deepsee...flash`），两个 Codex 额度窗口也不必缩写。

status item 本身常驻「图标 + 双行 ↓/↑ + 电池格」（`VpnMenuBarRateView`），不占用 popup 高度。三种读数都不需要隧道：电池是机器的电量，速率是机器的吞吐（`SystemThroughput`）；隧道开着时速率换成 mihomo 自己的计数并画成绿色（绿=走隧道），关掉时是系统总吞吐的静息白色。popup 内的 VPN 入口是状态行的 VPN 药丸（`VpnStatusPill`，切到主窗口 VPN 页）——它是一条连接状态，不是一种模型，所以住状态行而不占切换行的第三格；那一格现在给 Cursor 额度。

> settings.json 缺失且 Codex 列表为空时，会话与用量两区替换为「未找到 settings.json」警告卡（副行「请先运行 Claude Code，然后刷新。」）；状态行、切换行与资源条仍在。

会话区撑满剩余高度、外壳顶对齐；面板高度固定取屏幕可见区 -8（上限 820pt），`fittingSize` 不参与定位。

## 会话卡片信息

每张卡片（`SessionCardView` / `CursorSessionCardView` / `ExternalSessionCardView`，`Views/Shared/`）展示：状态指示点（busy/active 时高亮）、两段式标题 `目录 | 会话标题`、上下文占用（Claude 是 `已用/上限` token，Cursor 是百分比）、当前活动工具（如 `Bash · build.sh`）、子 Agent 数量与运行数、相对更新时间、busy/idle 心跳 sparkline（`HeartbeatSparkline`）。Cursor 卡片在标题行与活动行之间多一条 `subtitle`（如 `Edited app.py, frontend.html`）。

### 标题口径（`SessionTitle`）

标题由 `SessionTitle` 统一派生，三家数据源不同：

| 端 | 标题来源 | 回退 |
|---|---|---|
| Codex | `threads.title`（`state_*.sqlite`，`archived = 0`） | 目录名 |
| Cursor | `composerHeaders.value` 的 `name`（`subtitle` 作副行） | 目录名 |
| Claude Code | transcript 首条 `origin.kind == "human"` 的 prompt | 目录名 |

卡片头部是 `目录 | 标题` 两段：目录是稳定的一半（会话中途不变，扫一眼就能找到「那个 ClaudeBar 的」），标题是具体的一半。分隔符是 ASCII 竖线 + 两侧空格（`SessionTitleLine`），不是中点号 —— 中点号在 12pt 下几乎不可见，读屏时还会被念成"middle dot"或直接跳过，所以 `accessibilityText` 用逗号连接。两段各自有独立宽度预算（目录 `maxFolderWidth = 96pt`、标题 `maxWidth = 180pt`、副行 `maxSubtitleWidth = 200pt`），避免长目录把标题挤掉。没有真实标题时只渲染目录（`cardLabel` 在标题与目录相同时同样返回空标题），不会出现「Neo | Neo」。

预算按渲染宽度算而不是字符数：12pt 下中文约 11.9pt/字、拉丁约 6.1pt/字，同一个字符数对中英文的截断效果差一倍（实测 Cursor 标题中位数 28 字，其中 53% 超过 24 字）。`SessionTitle.width` 用同一套每字权重做估算，误差约一个字符量级。

- Claude Code 卡片：双击恢复会话（`TerminalLauncher`）。进程还活着时把承载它的终端窗口切到前台；已结束的会话按「设置 → 继续会话」的偏好（自动 = Otty → Warp → 终端）执行 `claude --resume <sessionId>`。
- Cursor 卡片：双击用 Cursor.app 打开该 workspace。
- 空态显示 `StandbyEmptyState`（「暂无会话」）。

## 模型切换

popup 内不铺供应商宫格：`PanelHeader` 的三个 chip 打开各自的 popover——CC / Codex 是 `ModelSwitchList`（`Views/Popup/PanelHeader.swift`），一行一个「供应商 / 模型」，当前项带 checkmark；Cursor 是 `CursorUsagePanel`（月度套餐 + 其中的两个命名池 Cursor Models / Other Models + Grok Bot 周窗口）。切换后 `FeedbackToast` 反馈（如 "CC · DeepSeek / deepseek-v4-pro"，2 秒淡出）。

三个 chip 是同一张四区表（mark 15 / 模型名 16 / 额度行 26 / 页脚 11pt）：它们载的东西不同（CC 有供应商无额度、Codex 有额度、Cursor 两者都有），按各自内容堆叠会让三列呈阶梯状。额度在 `QuotaSwayGauge` 里读剩余（`100 − used`），重置时刻在弧的下方——与百分比同行时它是那行最宽的东西，两个窗口在 143pt 的列里放不下。

Cursor chip 的两个 gauge 是 Cursor 自己命名的两个池：Cursor（`autoPercentUsed`，Cursor Models，Grok / Composer）与 Other（`apiPercentUsed`，Other Models，按 API 价计费的三方模型）。这两个名字来自 Cursor 的 `auto-spillover-ui.ts`；池名在 chip 里缩写为一个词，因为「Cursor Models」+「Other Models」实测合计 166pt，超过额度行的 ~119pt 会双双截断成「Cursor Mo…」；完整名字在 chip 打开的 `CursorUsagePanel` 里。月度总额（`includedSpend / limit`）是这两个池共享的唯一 money limit，服务端只发一个 `limit`，所以 chip 的页脚只写一行金额、不按池拆；Grok Bot 的周窗口是独立额度，只住在 popover 里（有它自己的周重置）。

主窗口的供应商宫格（`ProviderDirectoryHost` + `ProviderConnectionEditor`）是另一条路径，见 [design/05](05-main-window-and-theme.md)：

- 瓦片是 `ProviderCardSurface` + 状态色（`ProviderCardState`：未配置 / 待完善 / 已配置 · 未激活 / 已激活），顶部是 Provider 名、身份 mark 与余额读数。
- 模型选择走 `ProviderModelSelector`（一枚字段凹槽，点击弹出 `ProviderModelPicker` 搜索列表）；选中只是「待激活」意图，回到瓦片按「激活」才写入配置。
- 瓦片状态由 `ProviderCardState` 决定，激活时底部按钮读「已激活」，没有展开式模型行。

## 用量区

`UsagePanel` 固定 244pt 高，只放三样东西：

- 顶部 `日 / 月 / 年 / 全部 / 自定` 周期切换 chips + 「重新统计」按钮。选「自定」时日期选择器走 popover（`.graphical`），不再内联展开把面板撑高。
- 两列汇总：「Token 用量」（副行「所选时段累计」）与「花费」（按刊例价估算；经 `ModelPricing.present` 按「显示货币」渲染，副行「另有 $43.20」/「N 个模型未计价」/「暂无用量」）。
- 热力图，然后是最多 3 行纯文字的模型行（模型名 + token 量），不再画每模型的占比条 —— 完整的分布与金额在主窗口用量页。

Cursor 侧的 token 与金额只能联网拿（本地 transcript 里没有可用的量，`bubbleId:*` 最近 2 万条实测 `tokenCount` 全为 0），所以它们不混进这里的周期图表，真实读数在用量页的 `CursorTokenUsageCard`（它自己按官方账单、按窗口取数）。空态显示「暂无用量」。

## 底部操作栏

`MenuBarView` 内联的 icon 按钮行：刷新、打开主窗口（post `.showMainWindow` 通知）、帮助（同一条通知带上目的地 `page: .help`）、还原官方配置（带二次确认，可选只还原 Claude Code 或 Codex）、管理模型、打开 settings.json、空闲通知开关（铃铛，切换 `AppPreferences.idleNotifyEnabled`）、深浅色切换、退出。

popup 只订阅「是否有 settings.json」「Codex 供应商是否为空」两个外壳状态，会话与用量由各自面板观察，避免心跳牵动整个外层重算。
