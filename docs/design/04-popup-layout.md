# 菜单栏 Popup 面板布局

> ClaudeBar 设计文档 · §4
> 相关：[主窗口与设计系统](05-main-window-and-theme.md) · 技术文档 [视图层](../technical/05-view-layer.md)

面板宽 560pt，垂直自适应（最高占满屏幕可见区）。实现为组合壳 `MenuBarView`（`Views/MenuBarView.swift`），内容拆分在 `Views/Popup/` 五个文件（`PanelHeader` / `ProvidersPanel` / `SessionsPanelView` / `UsagePanel` / `PanelState`）。从上到下：

```
┌─────────────────────────────────────────────────────────────┐
│ ⬤ Axon                    [折叠] [刷新]        ← PanelHeader│
├─────────────────────────────────────────────────────────────┤
│ （折叠态默认隐藏）当前配置条：状态点 · Provider · Model · host │
│                                              · ¥余额         │
├─────────────────────────────────────────────────────────────┤
│ PROVIDERS                                                    │
│  ┌──────────────┐ ┌──────────────┐                          │
│  │ ◉ DeepSeek   │ │ ○ Kimi Local │  ← 2 列供应商瓦片         │
│  │ 1M · 1 model │ │ ▸ 3 models   │    （瓦片内展开模型行）    │
│  └──────────────┘ └──────────────┘                          │
├─────────────────────────────────────────────────────────────┤
│ ⬢ CLAUDE CODE          ● 1B · 2I     ← SessionsPanelView    │
│  ┌──────────────┐ ┌──────────────┐                          │
│  │ ● ClaudeBar │ │ ○ Proj2      │  ← 2 列会话卡片网格        │
│  │ 159K/200K   │ │ 80%          │  （最高 260pt，区内滚动）   │
│  │ Bash·build  │ │              │                            │
│  │ ⚙2 · 12m    │ │ · 5m         │                            │
│  └──────────────┘ └──────────────┘                          │
├─────────────────────────────────────────────────────────────┤
│ ✦ CURSOR              ● 1A · 1I                             │
│  ┌──────────────┐ ┌──────────────┐                          │
│  │ ● Proj      │ │ ○ cursor    │                            │
│  └──────────────┘ └──────────────┘                          │
├─────────────────────────────────────────────────────────────┤
│ 日 月 年 指定   ◀ JULY 2026 ▶        ← UsagePanel           │
│  ┌──────────────┐ ┌──────────────┐                          │
│  │ kimi-k2.6    │ │ cursor       │  ← 2 列用量瓦片           │
│  │ 30.0M ██████ │ │ 8.6M ███     │                            │
│  └──────────────┘ └──────────────┘                          │
├─────────────────────────────────────────────────────────────┤
│ [刷新][主窗口][编辑供应商][settings.json][🔔空闲通知]  [退出] │
└─────────────────────────────────────────────────────────────┘
```

> settings.json 缺失时其余区段整体替换为 "No settings.json found" 警告卡。

## 会话卡片信息

每张卡片（`SessionCardView` / `CursorSessionCardView`，`Views/Shared/`）展示：状态指示点（busy/active 时高亮）、项目文件夹名、上下文占用（Claude 是 `已用/上限` token，Cursor 是百分比）、当前活动工具（如 `Bash · build.sh`）、子 Agent 数量与运行数、相对更新时间、busy/idle 心跳 sparkline（`HeartbeatSparkline`）。

- **Claude Code 卡片**：双击在 Warp（优先）或 Terminal 中执行 `claude --resume <sessionId>` 恢复会话。
- **Cursor 卡片**：双击用 Cursor.app 打开该 workspace。
- 空态显示 `StandbyEmptyState`（"no signals" / "no cursor signals"）。

## 供应商瓦片

供应商区不再使用可折叠行，而是 `TileGrid(.popupProvider)` 2 列宫格，每格一个 `ProviderTile`（`Views/ProviderRow.swift`）：

- 瓦片头：Provider 名 + 活跃胶囊（激活瓦片左缘 2px accent 竖条）。
- 活跃模型行（case-insensitive 匹配 `ANTHROPIC_MODEL`）+ 模型总数。
- 多模型 Provider 瓦片带 chevron，点击在瓦片内展开模型行（hairline 分隔），每行独立可选；默认收起以保证网格行高一致。
- 激活模型后弹出 `FeedbackToast` 反馈（如 "DeepSeek / deepseek-v4-pro"，2 秒淡出）。

## 用量区

- 顶部周期切换 chips：`日 / 月 / 年 / 指定`，`指定` 弹出内联 DatePicker。
- 下方 `◀ 标签 ▶` 可前后翻页，标签如 `JULY 2026` 或 `2026-08-01`。
- 每个模型一个 `UsageModelTile`（2 列 `TileGrid(.popupUsage)`）：模型名 + token 总量 + 比例条，颜色按模型名 hash 分配（`Theme.barColor(for:)`）。
- Cursor 历史用量作为一条 `Cursor` 行附加到所有周期（因其 token 数据自 2026-03 起不再更新，是一次性全量值）。
- 空态显示 `StandbyEmptyState`（"no usage"）。

## 底部操作栏

`MenuBarView` 内联的 icon 按钮行：刷新、打开主窗口（post `.showMainWindow` 通知）、编辑供应商（`ProviderEditorWindowController`）、打开 settings.json、空闲通知开关（铃铛，切换 `AppPreferences.idleNotifyEnabled`）、退出。
