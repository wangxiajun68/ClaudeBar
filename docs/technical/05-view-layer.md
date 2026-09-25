# 视图层

> ClaudeBar 技术文档 · §5
> 相关：设计文档 [主窗口与设计系统](../design/05-main-window-and-theme.md) · [Popup 布局](../design/04-popup-layout.md) · 技术文档 [启动与窗口](02-app-launch-and-windows.md)

ClaudeBar 有两个 UI 面：菜单栏 popup（`MenuBarView` + `Views/Popup/`，424pt，`.menu` vibrancy）与主窗口（`MainWindowView` + 9 Pages，1120×720，`.underWindowBackground` vibrancy）。两者共享 `Theme/Theme.swift` 与 `Views/Shared/`。

## `Theme` — 设计 token 单点

`Theme/Theme.swift` 集中定义所有视觉常量，popup 与主窗口共用，保证配色一致：

- **颜色**：`base0` 0x0D0D11 → `base4` 0x353A45（中性近黑分层；旧 `bgPrimary`…`bgOverlay` 为别名）、`claude` 0x4F8EF7 / `claudeHi` 0x79ABF9（软蓝，Claude Code）、`cursor` 0xA78BFA / `cursorHi` 0xC0ACFC（软紫，Cursor）、`statusBusy`=claude、`statusActive`=cursor、`statusWarning` 0xE0A13C、`statusError` 0xE46464、`statusIdle` 0x8A8F98、`statusSuccess` 0x46C58F、`textPrimary` 0xF5F5F7 / `textSecondary` 0xA1A1A6 / `textTertiary()`。
- **间距/圆角/字距/字体**：`Space`（8pt grid：s2–s32 + `gridGap`/`gridGapPage` 宫格间距）、`Radius`（sm 6 / md 10 / lg 14 / xl 18）、`Tracking`、`Font`（titleLarge…caption + `labelSection`）+ `displayMetric`/`displayMetricSmall`（semibold + `.monospacedDigit()`）+ popup 密度别名（`rowTitle`/`rowLarge`/`micro*`/`captionMono`/`microMono`/`badgeMono`）+ 瓦片字阶（`tileValue`/`tileValueSmall`/`tileMicroValue`/`tileLabel`/`tileDetail`）+ `systemIcon(_:)`。
- **宫格**：`GridLayout.Preset`（`pageMetric` 4 等分 / `pageSession`·`pageUsage`·`pageProvider` 自适应 / `popupSession`·`popupProvider`·`popupUsage` 2 列）→ `columns(_:)` 返回 `[GridItem]`。
- **动画**：`Animation`（bouncy/smooth/pulse/snappy）、`Motion.page`/`Motion.state`——全部状态驱动。
- **表面/Helper**：`panelCard()`（半透明白填充 + 发丝线描边的扁平卡片，**非** `glassEffect`——主窗口大面积玻璃曾占用约 100 MB GPU 纹理）、`.tile()`（宫格瓦片表面，与 `panelCard` 同族、更密更浅）、`shadowCard()`、`cardFill(_:)`、`sidebarFill`、`divider`/`hairline`、`contextColor(ratio)`（blue/warning/red）、`barColor(for:)` + `djb2`（跨进程稳定 hash 调色板）、`ActiveTileEdge`（accent 左缘选中态）、`HairlineDivider`（去卡片化的发丝线分区）。macOS 26+ 上 `adaptiveGlassButton()` 为 popup 工具栏等控件提供原生 Liquid Glass 按钮，与内容卡表面无关。

## `MenuBarView` + `Views/Popup/` — 菜单栏 popup

`MenuBarView` 是组合壳（宽 424pt 的 `VStack`）：

- **PanelHeader**：Brand + 模型/VPN 切换 chip（`HeaderSwitchChip` + `VpnNodePickerPanel`）+ 刷新。
- **MachineKpiStrip（dense）**：本机资源与风扇。
- **PowerFlowCard(compact)**：有内置电池时的能源流向紧凑卡。
- **SessionsPanel / UsagePanel**：各自观察自己的字段；Provider 宫格只存在于主窗口（popup 的模型切换在 `PanelHeader` 的 chip 里）。
- **PanelState / FeedbackToast**：toast 只由 `overlay` 里那个 reader 订阅，写反馈不再重算整个外壳。
- **底部操作栏**：刷新 / 主窗口 / 帮助 / 还原官方配置 / 管理模型 / settings.json / 空闲通知 / 深浅色 / 退出。

**外壳订阅范围**：只订阅 `hasSettingsFile` 与「Codex 供应商是否为空」，以及它自己渲染的 `appearance` / `idleNotifyEnabled`；会话与用量由各自面板观察。主题切换**不**用 `.id()` 重建整个 popup（那会重置滚动位置与展开态，而底部操作栏本身就能切主题）。

**视觉规范**：
- 配色统一 `Theme` token（`textPrimary`/`textSecondary`/`textTertiary()`/`accent`/`statusBusy`/`cursorAccent`/`divider` 等）。
- 上下文健康：`ratio < 0.6` 蓝、`< 0.85` 黄、否则红（`Theme.contextColor`）。
- busy/active 的状态点脉冲动画（`Theme.Animation.pulse`）。
- 反馈 toast（`PanelState.showFeedback` + `FeedbackToast`）2 秒淡出。

**双击行为**（经共享 `TerminalLauncher`，先把活会话的宿主窗口带到前台；见 [§9](09-file-index.md) 的 `SessionHost` / `OttyBridge`）：
- Claude 会话：`TerminalLauncher.resumeClaudeSession(cwd:sessionId:pid:)` —— 会话进程仍活着就只聚焦宿主（Otty 走 socket，无需自动化权限）；已结束的才按「继续会话」偏好（自动 / Otty / Warp / 终端）执行 `claude --resume`。
- Cursor 会话：`TerminalLauncher.openInCursor(cwd:)` 或 `NSWorkspace` 打开 Cursor.app + cwd。

编辑器由主窗口的「模型」页承载（`ProvidersView` 打开 `ProviderConnectionEditor` 单连接弹窗）；popup 底部的「管理模型」只负责 post `.openProvidersEditor` 切页，不再持有自己的 NSWindow。

## `ProviderTile` / `ProviderRow`（`Views/ProviderRow.swift`）

- `ProviderTile`：供应商瓦片（主窗口自适应网格；`dense` 切换密度，默认展开模型行）。瓦片头 = Provider 名 + 活跃胶囊 + chevron；激活瓦片顶部 48×3pt accent 胶囊 + 内描边。模型名匹配用 case-insensitive（settings.json 大小写可能不同）。
- `popup` 的模型切换走 `PanelHeader` 的 chip → `ModelSwitchList`，不用瓦片网格；`PopupModelTile` 已删除。
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
