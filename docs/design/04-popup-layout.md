# 菜单栏 Popup 面板布局

> ClaudeBar 设计文档 · §4
> 相关：[主窗口与设计系统](05-main-window-and-theme.md) · 技术文档 [视图层](../technical/05-view-layer.md)

面板宽 560pt，垂直自适应（最高占满屏幕可见区）。实现为组合壳 `MenuBarView`，内容在 `Views/Popup/` 与 `ResourceStrip`。从上到下：

```
┌─────────────────────────────────────────────────────────────┐
│ ClaudeBar   [VPN 启停 · 节点]              [刷新]  ← PanelHeader
├─────────────────────────────────────────────────────────────┤
│ ResourceStrip：进程资源 + 风扇转速（dense）                    │
├─────────────────────────────────────────────────────────────┤
│ PROVIDERS … Sessions … Usage（固定区高，见 MenuBarView）      │
├─────────────────────────────────────────────────────────────┤
│ [刷新][主窗口][帮助][还原官方][管理模型][settings.json][🔔][◐]  [退出] │
└─────────────────────────────────────────────────────────────┘
```

VPN 运行时 **status item** 本身显示图标 + 双行 ↓/↑（`VpnMenuBarRateView`），不占用 popup 高度。popup 内的 VPN 入口是 `PanelHeader` 的 VPN chip（`VpnNodePickerPanel`）。

> settings.json 缺失且 Codex 列表为空时，供应商/会话/用量替换为「未找到 settings.json」警告卡；资源条与 VPN 页头仍在。

## 会话卡片信息

每张卡片（`SessionCardView` / `CursorSessionCardView`，`Views/Shared/`）展示：状态指示点（busy/active 时高亮）、项目文件夹名、上下文占用（Claude 是 `已用/上限` token，Cursor 是百分比）、当前活动工具（如 `Bash · build.sh`）、子 Agent 数量与运行数、相对更新时间、busy/idle 心跳 sparkline（`HeartbeatSparkline`）。

- **Claude Code 卡片**：双击在 Warp（优先）或 Terminal 中执行 `claude --resume <sessionId>` 恢复会话。
- **Cursor 卡片**：双击用 Cursor.app 打开该 workspace。
- 空态显示 `StandbyEmptyState`（"no signals" / "no cursor signals"）。

## 模型切换

popup 内不铺供应商宫格：`PanelHeader` 的 Claude Code / Codex chip 打开 `ModelSwitchList`（`Views/Popup/PanelHeader.swift`），一行一个「供应商 / 模型」，当前项带 checkmark。切换后 `FeedbackToast` 反馈（如 "CC · DeepSeek / deepseek-v4-pro"，2 秒淡出）。

主窗口的供应商宫格（`TileGrid` + `ProviderTile`，`Views/ProviderRow.swift`）是另一条路径，见 [design/05](05-main-window-and-theme.md)：

- 瓦片头：Provider 名 + 活跃胶囊（激活瓦片左缘 2px accent 竖条）。
- 活跃模型行（case-insensitive 匹配 `ANTHROPIC_MODEL`）+ 模型总数。
- 多模型 Provider 瓦片带 chevron，点击在瓦片内展开模型行（hairline 分隔），每行独立可选；默认收起以保证网格行高一致。

## 用量区

- 顶部周期切换 chips：`日 / 月 / 年 / 指定`，`指定` 弹出内联 DatePicker。
- 下方 `◀ 标签 ▶` 可前后翻页，标签如 `JULY 2026` 或 `2026-08-01`。
- 每个模型一个 `UsageModelTile`（2 列 `TileGrid(.popupUsage)`）：模型名 + token 总量 + 比例条，颜色按模型名 hash 分配（`Theme.barColor(for:)`）。
- Cursor 历史用量作为一条 `Cursor` 行附加到所有周期（因其 token 数据自 2026-03 起不再更新，是一次性全量值）。
- 空态显示 `StandbyEmptyState`（"no usage"）。

## 底部操作栏

`MenuBarView` 内联的 icon 按钮行：刷新、打开主窗口（post `.showMainWindow` 通知）、帮助（先开窗口再 post `.openHelpPage`）、还原官方配置（带二次确认，可选只还原 Claude Code 或 Codex）、管理模型、打开 settings.json、空闲通知开关（铃铛，切换 `AppPreferences.idleNotifyEnabled`）、深浅色切换、退出。

popup 只订阅「是否有 settings.json」「Codex 供应商是否为空」两个外壳状态，会话与用量由各自面板观察，避免心跳牵动整个外层重算。
