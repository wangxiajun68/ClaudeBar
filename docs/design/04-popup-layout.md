# 菜单栏 Popup 面板布局

> ClaudeBar 设计文档 · §4
> 相关：[主窗口与设计系统](05-main-window-and-theme.md) · 技术文档 [视图层](../technical/05-view-layer.md)

面板宽 424pt（`MenuBarView` 固定宽度），垂直自适应（最高占满屏幕可见区 -8，上限 820pt）。实现为组合壳 `MenuBarView`，内容在 `Views/Popup/` 与 `Views/Shared/MachineKpiStrip.swift`。从上到下：

```
┌─────────────────────────────────────────────────────┐
│ ClaudeBar   [VPN 启停 · 节点]              [刷新]  ← PanelHeader
├─────────────────────────────────────────────────────┤
│ MachineKpiStrip：进程资源（+ 在用耳机）+ 风扇转速        │
├─────────────────────────────────────────────────────┤
│ PowerFlowCard(compact)  能源流向（有内置电池时）       │
├─────────────────────────────────────────────────────┤
│ PROVIDERS … Sessions … Usage（固定区高，见 MenuBarView）│
├─────────────────────────────────────────────────────┤
│ [刷新][主窗口][帮助][还原官方][管理模型][settings.json][🔔][◐]  [退出] │
└─────────────────────────────────────────────────────┘
```

VPN 运行时 **status item** 本身显示图标 + 双行 ↓/↑（`VpnMenuBarRateView`），不占用 popup 高度。popup 内的 VPN 入口是 `PanelHeader` 的 VPN chip（`VpnNodePickerPanel`）。

> settings.json 缺失且 Codex 列表为空时，供应商/会话/用量替换为「未找到 settings.json」警告卡；资源条与 VPN 页头仍在。

会话区不再按固定上限裁高（此前 190pt / 280pt 两个硬编码上限），改为按内容撑开、外壳用 `maxHeight: .infinity` 顶对齐；`fittingSize` 不再参与定位，面板高度固定取屏幕可见区 -8（上限 820pt）。

## 会话卡片信息

每张卡片（`SessionCardView` / `CursorSessionCardView`，`Views/Shared/`）展示：状态指示点（busy/active 时高亮）、**两段式标题 `目录 | 会话标题`**、上下文占用（Claude 是 `已用/上限` token，Cursor 是百分比）、当前活动工具（如 `Bash · build.sh`）、子 Agent 数量与运行数、相对更新时间、busy/idle 心跳 sparkline（`HeartbeatSparkline`）。Cursor 卡片首行下多一条 `subtitle`（如 `Edited app.py, frontend.html`）。

### 标题口径（`SessionTitle`）

标题由 `SessionTitle` 统一派生，三家数据源不同：

| 端 | 标题来源 | 回退 |
|---|---|---|
| Codex | `threads.title`（`state_*.sqlite`，`archived = 0`） | 目录名 |
| Cursor | `composerHeaders.value` 的 `name`（`subtitle` 作副行） | 目录名 |
| Claude Code | transcript 首条 `origin.kind == "human"` 的 prompt | 目录名 |

卡片头部是 **`目录 | 标题`** 两段：目录是**稳定**的一半（会话中途不变，扫一眼就能找到「那个 ClaudeBar 的」），标题是**具体**的一半。分隔符是 ASCII 竖线 + 两侧空格（`SessionTitleLine`），不是中点号 —— 中点号在 12pt 下几乎不可见，读屏时还会被念成"middle dot"或直接跳过，所以 `accessibilityText` 用逗号连接。两段各自有独立宽度预算（目录 `maxFolderWidth = 96pt`、标题 `maxWidth = 180pt`、副行 `maxSubtitleWidth = 200pt`），避免长目录把标题挤掉。**没有真实标题时只渲染目录**，不会出现「Neo | Neo」。

预算按**渲染宽度**算而不是字符数：12pt 下中文约 11.9pt/字、拉丁约 6.1pt/字，同一个字符数对中英文的截断效果差一倍（实测 Cursor 标题中位数 28 字，其中 53% 超过 24 字）。实测估算与 `NSString.size(withAttributes:)` 偏差 ≤11%。

- **Claude Code 卡片**：双击在 Warp（优先）或 Terminal 中执行 `claude --resume <sessionId>` 恢复会话。
- **Cursor 卡片**：双击用 Cursor.app 打开该 workspace。
- 空态显示 `StandbyEmptyState`（"no signals" / "no cursor signals"）。

## 模型切换

popup 内不铺供应商宫格：`PanelHeader` 的 Claude Code / Codex chip 打开 `ModelSwitchList`（`Views/Popup/PanelHeader.swift`），一行一个「供应商 / 模型」，当前项带 checkmark。切换后 `FeedbackToast` 反馈（如 "CC · DeepSeek / deepseek-v4-pro"，2 秒淡出）。

主窗口的供应商宫格（`ProviderDirectoryHost` + `ProviderConnectionEditor`）是另一条路径，见 [design/05](05-main-window-and-theme.md)：

- 瓦片头：Provider 名 + 活跃胶囊（激活瓦片左缘 2px accent 竖条）。
- 活跃模型行（case-insensitive 匹配 `ANTHROPIC_MODEL`）+ 模型总数。
- 多模型 Provider 瓦片带 chevron，点击在瓦片内展开模型行（hairline 分隔），每行独立可选；默认收起以保证网格行高一致。

## 用量区

`UsagePanel` 固定 244pt 高，只放三样东西：

- 顶部 `日 / 月 / 年 / 全部 / 自定` 周期切换 chips + 「重新统计」按钮。选「指定」时日期选择器走 **popover**（`.graphical`），不再内联展开把面板撑高。
- 两列汇总：**「Token 用量」**（副行「所选时段累计」）与 **「花费」**（按刊例价估算；副行「另有 $43.20」/「N 个未计价」/「暂无用量」）。
- 热力图，然后是**最多 3 行纯文字**的模型行（模型名 + token 量），不再画每模型的占比条 —— 完整的分布与金额在主窗口用量页。

Cursor 历史用量作为一条 `Cursor` 行附加到所有周期（因其 token 数据自 2026-03 起不再更新，是一次性全量值）。空态显示「暂无用量」。

## 底部操作栏

`MenuBarView` 内联的 icon 按钮行：刷新、打开主窗口（post `.showMainWindow` 通知）、帮助（先开窗口再 post `.openHelpPage`）、还原官方配置（带二次确认，可选只还原 Claude Code 或 Codex）、管理模型、打开 settings.json、空闲通知开关（铃铛，切换 `AppPreferences.idleNotifyEnabled`）、深浅色切换、退出。

popup 只订阅「是否有 settings.json」「Codex 供应商是否为空」两个外壳状态，会话与用量由各自面板观察，避免心跳牵动整个外层重算。
