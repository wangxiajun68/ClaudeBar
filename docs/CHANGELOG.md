# 更新日志 / Changelog

> 本日志记录 ClaudeBar 各版本的演进。日期为代码实际提交日期，由文件修改时间与代码内容推断。

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
