# 视图层

> ClaudeBar 技术文档 · §5
> 相关：设计文档 [主窗口与设计系统](../design/05-main-window-and-theme.md) · [Popup 布局](../design/04-popup-layout.md) · 技术文档 [启动与窗口](02-app-launch-and-windows.md)

ClaudeBar 有两个 UI 面：菜单栏 popup（`MenuBarView`，560pt，`.menu` vibrancy）与主窗口（`MainWindowView` + 5 Pages，1120×720，`.underWindowBackground` vibrancy）。两者共享 `Theme/Theme.swift` 设计 token 与 `Views/Shared/` 交互组件层。

## `Theme` — 设计 token 单点

`Theme/Theme.swift` 集中定义所有视觉常量，popup 与主窗口共用，保证配色一致：

- **颜色**：`base0` 0x070B14 → `base4` 0x223452（深空靛蓝亮度分层；旧 `bgPrimary`…`bgOverlay` 为别名）、`claude` 0xF5A623（琥珀，Claude Code）、`cursor` 0x37D0C6（青，Cursor）、`statusBusy`=amber、`statusWarning` 0xFFC465、`statusError` 0xFF5C6C、`statusIdle` 0x8A94AB、`textPrimary` 0xE9EEF6/`textSecondary` 0x9BA7BD/`textTertiary()`。
- **间距/圆角/字体**：`Space`（8pt grid：s4/s8/s12/s16/s24/s32）、`Radius`（sm/md/lg/xl）、`Font`（body/caption/titleLarge/labelSection/bodySmall/bodyLarge/captionMono/titleSmall）+ `displayMetric`/`displayMetricSmall`（mono 大遥测读数）。
- **动画**：`Animation`（bouncy/smooth/lively/pulse/snappy）、`Motion.page`/`Motion.state`。
- **helper**：`contextColor(ratio)`（amber/warning/red）、`barColor(for:)`（信号系 hash 调色板）、`cardFill(_:)`、`panelCard()`（阳极面板，内容卡）、`glassCard()`（Liquid Glass，悬浮层）、`beaconGlow()`（信标光晕）、`shadowCard()`。

## `MenuBarView` — 菜单栏 popup

宽 560pt 的 `VStack`，按区段组织：

- **Header**：CB 图标 + 标题 + 折叠按钮（`@AppStorage("configCollapsed")` 持久化）+ 刷新按钮。
- **当前配置**（折叠态隐藏）：绿/橙状态点 + Provider 名 + 模型 + host + ¥余额。
- **Sessions / Cursor Sessions**：各用 `LazyVGrid` 双列网格渲染 `sessionCard` / `cursorSessionCard`；`sessionRow` 是展开的详细版（含子 Agent）。
- **底部 HStack**：左 `providersSection`，右 `usageSection`，`maxHeight: 150`。
- **ActionBar**：刷新 / 编辑供应商 / 打开 settings.json / 退出。

**视觉规范**：
- 配色：深色半透明，统一使用 `Theme` token（`Theme.textPrimary`/`textSecondary`/`textTertiary()`/`accent`/`statusBusy`/`cursorAccent`/`divider` 等）；CB logo 渐变用 `Theme.accent`/`Theme.accentDim` + `Theme.bgPrimary` 文字（与主窗口对齐，D3）。
- 上下文健康：`ratio < 0.6` 绿、`< 0.85` 黄、否则红（`Theme.contextColor`）。
- busy/active 的状态点带 `repeatForever(autoreverses: true)` 脉冲动画。
- 反馈 toast（`switchFeedback`）2 秒淡出。

**双击行为**（经共享 `TerminalLauncher`，D2 去重）：
- Claude 会话：`TerminalLauncher.resumeClaudeSession(cwd:sessionId:)` → 优先 Warp（`/Applications/Warp.app` 存在时），否则 Terminal。Warp 路径：`NSWorkspace.open` 打开 cwd + 后台 `osascript` 注入 `claude --resume <sessionId>` 并回车。Terminal 路径：`do script`。
- Cursor 会话：`TerminalLauncher.openInCursor(cwd:)` 或 `NSWorkspace` 打开 Cursor.app + cwd。

`EditorWindowDelegate` 监听编辑窗口关闭，清理 `MenuBarView.editorWindowRef` 静态引用。

## `ProviderRow` — Provider 行

- `isSingleModel`：整行可点选，显示 radio + 模型名 + checkmark。
- 多模型：`expandableHeader`（chevron + Provider 名 + "active" 胶囊 + "N models"）+ 展开后 `modelRow` 列表，每行 radio + 模型名（monospaced）+ 上下文上限（如 `1M`）+ checkmark。
- `formatContext`：`200000 → 200K`、`1000000 → 1M`。
- 模型名匹配用 case-insensitive（settings.json 大小写可能不同）。
- 配色统一 `Theme` token：`Theme.accent`（单选/选中）、`Theme.statusBusy`（active/checkmark）、`Theme.accent.opacity(0.16)`（选中填充，与 sidebar pill 一致）、`Theme.cardFill(0.06)`（标签背景）、`Theme.textTertiary()`（次要文字）、`Theme.Radius.sm`（圆角）（D3）。

## `ProviderEditorView` — 编辑视图

popup 底部「编辑供应商」按钮弹出独立 `NSWindow`，主窗口「供应商」页（`ProvidersView`）也嵌入同一 `ProviderEditorView`，共用一套编辑逻辑。左 220pt 固定宽 Provider 列表（`List(selection:)` + 增/删/复制），右侧 master-detail：
- **Provider Configuration** GroupBox：Name / API Key / Base URL。
- **Model Configuration** GroupBox：左 170pt 模型列表（`EditableModel` 本地副本，回车或点 + 添加，右键设默认 / 删除），右模型详情（Name / Context Tokens / Auto Compact Window / Disable Compact / Disable Experimental Betas）。
- 底部 Save 按钮（⌘S / ⌘⏎），保存后 "Saved ✓" 反馈 2 秒。保存激活 Provider 时触发 `activateModel` 应用变更。
- 配色统一 `Theme` token：`Theme.textSecondary`/`textTertiary()`、`Theme.statusBusy`（checkmark/Saved）、`Theme.statusWarning`（默认模型徽章）、`Theme.accent.opacity(0.15)`（选中）、`Theme.Font.*`（D3）。

## Widget 视图 `WidgetViews.swift`

`WidgetEntryView` 渲染 systemLarge：
- Header：ClaudeBar + 大号 token 总数 + 余额。
- Provider + Model + 相对时间。
- 模型分布条（多个模型按 ratio 横向拼接）+ 图例。
- 活跃会话列表（最多 3 条 Claude + 3 条 Cursor），每行状态点 + 项目 + 活动 + 上下文条。
- 空态显示 "等待数据..."。
- 点击整个 Widget 触发 `claudebar://` 唤起主面板。

`WidgetProvider.getTimeline`：读快照（四路回退），30s 后刷新；读失败返回 `diagnosticEntry`（把诊断字符串塞进 `activeProviderName` 显示，如 `UD:2048B F:Y/2048B`）。
