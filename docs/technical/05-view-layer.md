# 视图层

> ClaudeBar 技术文档 · §5
> 相关：设计文档 [主窗口与设计系统](../design/05-main-window-and-theme.md) · [Popup 布局](../design/04-popup-layout.md) · 技术文档 [启动与窗口](02-app-launch-and-windows.md)

ClaudeBar 有两个 UI 面：菜单栏 popup（`MenuBarView` + `Views/Popup/`，560pt，`.menu` vibrancy）与主窗口（`MainWindowView` + 7 Pages，1120×720，`.underWindowBackground` vibrancy）。两者共享 `Theme/Theme.swift` 与 `Views/Shared/`。

## `Theme` — 设计 token 单点

## `Theme` — 设计 token 单点

`Theme/Theme.swift` 集中定义所有视觉常量，popup 与主窗口共用，保证配色一致：

- **颜色**：`base0` 0x0D0D11 → `base4` 0x353A45（中性近黑分层；旧 `bgPrimary`…`bgOverlay` 为别名）、`claude` 0x4F8EF7 / `claudeHi` 0x79ABF9（软蓝，Claude Code）、`cursor` 0xA78BFA / `cursorHi` 0xC0ACFC（软紫，Cursor）、`statusBusy`=claude、`statusActive`=cursor、`statusWarning` 0xE0A13C、`statusError` 0xE46464、`statusIdle` 0x8A8F98、`statusSuccess` 0x46C58F、`textPrimary` 0xF5F5F7 / `textSecondary` 0xA1A1A6 / `textTertiary()`。
- **间距/圆角/字距/字体**：`Space`（8pt grid：s2–s32 + `gridGap`/`gridGapPage` 宫格间距）、`Radius`（sm 6 / md 10 / lg 14 / xl 18）、`Tracking`、`Font`（titleLarge…caption + `labelSection`）+ `displayMetric`/`displayMetricSmall`（semibold + `.monospacedDigit()`）+ popup 密度别名（`rowTitle`/`rowLarge`/`micro*`/`captionMono`/`microMono`/`badgeMono`）+ 瓦片字阶（`tileValue`/`tileValueSmall`/`tileMicroValue`/`tileLabel`/`tileDetail`）+ `systemIcon(_:)`。
- **宫格**：`GridLayout.Preset`（`pageMetric` 4 等分 / `pageSession`·`pageUsage`·`pageProvider` 自适应 / `popupSession`·`popupProvider`·`popupUsage` 2 列）→ `columns(_:)` 返回 `[GridItem]`。
- **动画**：`Animation`（bouncy/smooth/pulse/snappy）、`Motion.page`/`Motion.state`——全部状态驱动。
- **表面/Helper**：`panelCard()`（半透明白填充 + 发丝线描边的扁平卡片，**非** `glassEffect`——主窗口大面积玻璃曾占用约 100 MB GPU 纹理）、`.tile()`（宫格瓦片表面，与 `panelCard` 同族、更密更浅）、`shadowCard()`、`cardFill(_:)`、`sidebarFill`、`divider`/`hairline`、`contextColor(ratio)`（blue/warning/red）、`barColor(for:)` + `djb2`（跨进程稳定 hash 调色板）、`ActiveTileEdge`（accent 左缘选中态）、`HairlineDivider`/`SectionBlock`/`.sectionRules()`（去卡片化的发丝线分区）。macOS 26+ 上 `adaptiveGlassButton()` 为 popup 工具栏等控件提供原生 Liquid Glass 按钮，与内容卡表面无关。

## `MenuBarView` + `Views/Popup/` — 菜单栏 popup

`MenuBarView` 是组合壳（宽 560pt 的 `VStack`）：

- **PanelHeader**：Brand + 模型/VPN 切换 chip（`HeaderSwitchChip` + `VpnNodePickerPanel`）+ 刷新。
- **ResourceStrip（dense）**：本机资源与风扇。
- **SessionsPanel / UsagePanel**：固定区高，避免互相挤压。Provider 宫格只存在于主窗口（popup 的模型切换在 `PanelHeader` 的 chip 里）。
- **PanelState**：feedback toast、折叠态。
- **底部操作栏**：刷新 / 主窗口 / 编辑供应商 / settings.json / 空闲通知 / 退出。

**视觉规范**：
- 配色统一 `Theme` token（`textPrimary`/`textSecondary`/`textTertiary()`/`accent`/`statusBusy`/`cursorAccent`/`divider` 等）。
- 上下文健康：`ratio < 0.6` 蓝、`< 0.85` 黄、否则红（`Theme.contextColor`）。
- busy/active 的状态点脉冲动画（`Theme.Animation.pulse`）。
- 反馈 toast（`PanelState.showFeedback` + `FeedbackToast`）2 秒淡出。

**双击行为**（经共享 `TerminalLauncher`）：
- Claude 会话：`TerminalLauncher.resumeClaudeSession(cwd:sessionId:)` → 优先 Warp（`/Applications/Warp.app` 存在时），否则 Terminal。Warp 路径：`NSWorkspace.open` 打开 cwd + 后台 `osascript` 注入 `claude --resume <sessionId>` 并回车。Terminal 路径：`do script`。
- Cursor 会话：`TerminalLauncher.openInCursor(cwd:)` 或 `NSWorkspace` 打开 Cursor.app + cwd。

编辑器由主窗口的「模型」页承载（`ProvidersView` 嵌入 `ProviderEditorView`）；popup 底部的编辑按钮只负责 post `.openProvidersEditor` 切页，不再持有自己的 NSWindow。

## `ProviderTile` / `ProviderRow`（`Views/ProviderRow.swift`）

- `ProviderTile`：供应商宫格瓦片（popup 2 列与主窗口自适应网格共用，`dense` 切换密度）。瓦片头 = Provider 名 + 活跃胶囊 + chevron；激活瓦片左缘 2px accent 竖条（`ActiveTileEdge` 风格）。收起时瓦片等高（网格行整齐）；chevron 展开后瓦片内列出模型行（hairline 分隔），每行独立可选。模型名匹配用 case-insensitive（settings.json 大小写可能不同）。
- `PopupModelTile`：popup 模型选择列表的一行（`PopupModelTile` 定义同文件；popup 的模型切换走 `PanelHeader` 的 chip → `ModelSwitchList`，不走 2 列宫格）。
- `formatContext`：`200000 → 200K`、`1000000 → 1M`。

## `ProviderEditorView` — 编辑视图

编辑器视图没有独立窗口：popup 底部「编辑供应商」按钮 post `.openProvidersEditor`，主窗口切到「模型」页并嵌入 `ProviderEditorView`，共用同一 `ProviderEditorModel`（`@Observable`，`Models/ProviderEditorModel.swift`，含 `EditableModel` 本地副本、校验与保存 spinner）。左 220pt Provider 列表（`List(selection:)` + 增/删/复制），右侧 master-detail：
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
