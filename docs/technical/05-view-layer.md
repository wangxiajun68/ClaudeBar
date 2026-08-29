# 视图层

> ClaudeBar 技术文档 · §5
> 相关：设计文档 [主窗口与设计系统](../design/05-main-window-and-theme.md) · [Popup 布局](../design/04-popup-layout.md) · 技术文档 [启动与窗口](02-app-launch-and-windows.md)

ClaudeBar 有两个 UI 面：菜单栏 popup（`MenuBarView` + `Views/Popup/` 五文件，560pt，`.menu` vibrancy）与主窗口（`MainWindowView` + 5 Pages，1120×720，`.underWindowBackground` vibrancy）。两者共享 `Theme/Theme.swift` 设计 token 与 `Views/Shared/` 组件层。

## `Theme` — 设计 token 单点

`Theme/Theme.swift` 集中定义所有视觉常量，popup 与主窗口共用，保证配色一致：

- **颜色**：`base0` 0x0D0D11 → `base4` 0x353A45（中性近黑分层；旧 `bgPrimary`…`bgOverlay` 为别名）、`claude` 0x4F8EF7 / `claudeHi` 0x79ABF9（软蓝，Claude Code）、`cursor` 0xA78BFA / `cursorHi` 0xC0ACFC（软紫，Cursor）、`statusBusy`=claude、`statusActive`=cursor、`statusWarning` 0xE0A13C、`statusError` 0xE46464、`statusIdle` 0x8A8F98、`statusSuccess` 0x46C58F、`textPrimary` 0xF5F5F7 / `textSecondary` 0xA1A1A6 / `textTertiary()`。
- **间距/圆角/字距/字体**：`Space`（8pt grid：s2–s32 + `gridGap`/`gridGapPage` 宫格间距）、`Radius`（sm 6 / md 10 / lg 14 / xl 18）、`Tracking`、`Font`（titleLarge…caption + `labelSection`）+ `displayMetric`/`displayMetricSmall`（semibold + `.monospacedDigit()`）+ popup 密度别名（`rowTitle`/`rowLarge`/`micro*`/`captionMono`/`microMono`/`badgeMono`）+ 瓦片字阶（`tileValue`/`tileValueSmall`/`tileMicroValue`/`tileLabel`/`tileDetail`）+ `systemIcon(_:)`。
- **宫格**：`GridLayout.Preset`（`pageMetric` 4 等分 / `pageSession`·`pageUsage`·`pageProvider` 自适应 / `popupSession`·`popupProvider`·`popupUsage` 2 列）→ `columns(_:)` 返回 `[GridItem]`。
- **动画**：`Animation`（bouncy/smooth/pulse/snappy）、`Motion.page`/`Motion.state`——全部状态驱动。
- **表面/Helper**：`panelCard()`（原生 `glassEffect` Liquid Glass）、`shadowCard()`、`cardFill(_:)`、`sidebarFill`、`divider`/`hairline`、`contextColor(ratio)`（blue/warning/red）、`barColor(for:)` + `djb2`（跨进程稳定 hash 调色板）、`ActiveTileEdge`（accent 左缘选中态）、`HairlineDivider`/`SectionBlock`/`.sectionRules()`（发丝线分区）。

## `MenuBarView` + `Views/Popup/` — 菜单栏 popup

`MenuBarView` 是组合壳（宽 560pt 的 `VStack`），内容拆在 `Views/Popup/`：

- **PanelHeader.swift**（`PanelHeader`）：brand 圆标（busy 时 `symbolEffect(.pulse)`）+ 折叠按钮 + 刷新按钮。
- **ProvidersPanel.swift**（`ProvidersPanel`）：当前配置条（状态点 + Provider 名/模型 + host + ¥余额，折叠态隐藏）→ PROVIDERS 区：`TileGrid(.popupProvider)` 2 列 `ProviderTile`，激活后 `FeedbackToast` 反馈。
- **SessionsPanel.swift**（`SessionsPanelView`）：CLAUDE CODE / CURSOR 两个 section（`SectionHeader` 计数徽标），各用 `TileGrid(.popupSession)` 2 列渲染 `SessionCardView` / `CursorSessionCardView`（含 `HeartbeatSparkline`）；空态 `StandbyEmptyState`；最高 260pt，区内滚动。
- **UsagePanel.swift**（`UsagePanel`）：周期 chips + 内联 DatePicker（`指定`）+ 日期导航 + `TileGrid(.popupUsage)` 每模型一个 `UsageModelTile`。
- **PanelState.swift**（`PanelState`）：popup UI 状态——feedback 消息 + 单调 token（驱动壳层 `.task(id:)` 2s 自动消失）、`configCollapsed`（UserDefaults 持久化）。
- **底部操作栏**（`MenuBarView.actionBar`）：刷新 / 打开主窗口（post `.showMainWindow`）/ 编辑供应商 / 打开 settings.json / 空闲通知开关（铃铛，切 `AppPreferences.idleNotifyEnabled`）/ 退出。

**视觉规范**：
- 配色统一 `Theme` token（`textPrimary`/`textSecondary`/`textTertiary()`/`accent`/`statusBusy`/`cursorAccent`/`divider` 等）。
- 上下文健康：`ratio < 0.6` 蓝、`< 0.85` 黄、否则红（`Theme.contextColor`）。
- busy/active 的状态点脉冲动画（`Theme.Animation.pulse`）。
- 反馈 toast（`PanelState.showFeedback` + `FeedbackToast`）2 秒淡出。

**双击行为**（经共享 `TerminalLauncher`）：
- Claude 会话：`TerminalLauncher.resumeClaudeSession(cwd:sessionId:)` → 优先 Warp（`/Applications/Warp.app` 存在时），否则 Terminal。Warp 路径：`NSWorkspace.open` 打开 cwd + 后台 `osascript` 注入 `claude --resume <sessionId>` 并回车。Terminal 路径：`do script`。
- Cursor 会话：`TerminalLauncher.openInCursor(cwd:)` 或 `NSWorkspace` 打开 Cursor.app + cwd。

编辑器窗口由 `ProviderEditorWindowController`（根目录）管理——单例持有 NSWindow，关闭时清理引用；popup 底部按钮与主窗口供应商页共用同一 `ProviderEditorView`。

## `ProviderTile` / `ProviderRow`（`Views/ProviderRow.swift`）

- `ProviderTile`：供应商宫格瓦片（popup 2 列与主窗口自适应网格共用，`dense` 切换密度）。瓦片头 = Provider 名 + 活跃胶囊 + chevron；激活瓦片左缘 2px accent 竖条（`ActiveTileEdge` 风格）。收起时瓦片等高（网格行整齐）；chevron 展开后瓦片内列出模型行（hairline 分隔），每行独立可选。模型名匹配用 case-insensitive（settings.json 大小写可能不同）。
- `ProviderRow`：保留的单 Provider 折叠行实现（`isSingleModel` 整行可点选；多模型 `expandableHeader` + `modelRow`）。popup 当前主用 `ProviderTile`。
- `formatContext`：`200000 → 200K`、`1000000 → 1M`。

## `ProviderEditorView` — 编辑视图

popup 底部「编辑供应商」按钮经 `ProviderEditorWindowController` 弹出独立 `NSWindow`（760×520），主窗口「供应商」页（`ProvidersView`）也嵌入同一 `ProviderEditorView`，共用一套编辑逻辑。表单状态在 `ProviderEditorModel`（`@Observable`，`Models/ProviderEditorModel.swift`，含 `EditableModel` 本地副本、校验与保存 spinner）。左 220pt Provider 列表（`List(selection:)` + 增/删/复制），右侧 master-detail：
- **Provider Configuration**：Name / API Key / Base URL。
- **Model Configuration**：左 170pt 模型列表（回车或点 + 添加，右键设默认 / 删除），右模型详情（Name / Context Tokens / Auto Compact Window / Disable Compact / Disable Experimental Betas）。
- 底部 Save 按钮（⌘S），保存后 "Saved ✓" 反馈 2 秒。保存激活 Provider 时触发 `activateModel` 应用变更。

## Widget 视图 `WidgetViews.swift`

`WidgetEntryView` 渲染 systemLarge：
- Header：ClaudeBar + 大号 token 总数 + 余额。
- Provider + Model + 相对时间。
- 模型分布条（多个模型按 ratio 横向拼接）+ 图例。
- 活跃会话列表（最多 3 条 Claude + 3 条 Cursor），每行状态点 + 项目 + 活动 + 上下文条。
- 空态显示 "等待数据..."。
- 点击整个 Widget 触发 `claudebar://` 唤起主面板。

`WidgetProvider.getTimeline`：读快照（四路回退），30s 后刷新；读失败返回 `diagnosticEntry`（把诊断字符串塞进 `activeProviderName` 显示，如 `UD:2048B F:Y/2048B`）。
