# ClaudeBar 设计文档

> 最后更新：2026-08-01
> 状态：文档已与 `Sources/` 实际代码对齐。

## 1. 产品概述

ClaudeBar 是一款 macOS 菜单栏应用，面向同时使用 **Claude Code**（CLI）与 **Cursor**（IDE）的开发者，在一个悬浮面板里集中完成三件事：

1. **配置切换** — 一键切换 Claude Code 的 Provider / Model（API 地址、密钥、模型名、上下文窗口等），并写入 `~/.claude/settings.json`。
2. **会话监控** — 实时展示本机所有活跃的 Claude Code 进程与 Cursor Composer 会话：上下文占用、当前正在执行的工具、子 Agent / Workflow 状态。
3. **用量统计** — 按日 / 月 / 年 / 自定义日期聚合各模型的 token 消耗，并在桌面 Widget 中呈现概览。

应用以 `LSUIElement`（无 Dock 图标）方式运行，点击菜单栏图标弹出半透明毛玻璃面板，失焦自动收起。

### 目标用户

- 同时配置了多家 Claude Code 兼容服务商（DeepSeek、Kimi、Anthropic 直连等），需要频繁切换的开发者。
- 希望在不离开当前终端 / 编辑器的前提下，掌握各会话上下文健康度与 token 开销的 Claude Code 重度用户。

### 非目标

- 不是 Claude Code 的替代前端，不替用户与模型对话。
- 不做模型推理、不代理 API 流量。
- 不支持非 macOS 平台。

---

## 2. 顶层架构

```
┌──────────────────────────────────────────────────────────────┐
│                        ClaudeBar.app                          │
│                                                               │
│  @main ClaudeBarApp (AppDelegate, .accessory)                 │
│        │                                                      │
│        ├── MenuBarController                                  │
│        │     ├── NSStatusItem (菜单栏图标)                     │
│        │     └── NSPanel (毛玻璃悬浮面板, 承载 SwiftUI 视图)    │
│        │           └── MenuBarView                             │
│        │                 ├── Header / 当前配置 / 折叠按钮        │
│        │                 ├── Sessions (Claude Code 会话卡片)    │
│        │                 ├── Cursor Sessions (Cursor 会话卡片) │
│        │                 ├── Providers (供应商/模型切换)       │
│        │                 ├── Usage Stats (token 用量)          │
│        │                 └── ActionBar (刷新/编辑/设置/退出)    │
│        │                                                      │
│        └── ProviderStore (ObservableObject, 单例状态中枢)      │
│              ├── providers / activeProviderID                 │
│              ├── sessions / cursorSessions (2.5s 轮询)         │
│              ├── usageStats (按周期聚合)                       │
│              ├── balanceText (DeepSeek 余额)                   │
│              └── writeWidgetSnapshot() → App Group            │
│                                                               │
│  ┌──────────── Models ────────────┐  ┌──────────── Utils ────────────┐
│  │ Provider / ModelConfig          │  │ FilePaths                     │
│  │ EnvConfig / Preset (迁移用)     │  │ SettingsManager (读写 settings)│
│  │ ProvidersFile                   │  │ BalanceFetcher (DeepSeek API)  │
│  │ WidgetSnapshot                  │  │ SessionMonitor (Claude 进程)   │
│  └─────────────────────────────────┘  │ CursorSessionMonitor (SQLite) │
│                                        │ CursorUsageStats             │
│                                        │ UsageStats (jsonl 扫描)       │
│                                        └───────────────────────────────┘
│                                                               │
│  ┌──────────── Views ────────────┐                            │
│  │ MenuBarView / ProviderRow     │                            │
│  │ ProviderEditorView (独立窗口)  │                            │
│  └────────────────────────────────┘                            │
└──────────────────────────────────────────────────────────────┘

           ┌───────────────────────────┐
           │  ClaudeBarWidget.appex     │  ← WidgetKit 扩展
           │  (沙盒, systemLarge)        │
           │  读取 App Group 快照渲染     │
           └───────────────────────────┘
```

### 核心设计取舍

| 决策 | 选择 | 原因 |
|------|------|------|
| UI 容器 | 自定义 `NSPanel` + `NSStatusItem`，而非 `MenuBarExtra` | `MenuBarExtra.menu` 样式无法承载复杂卡片 / 进度条 / 滚动；`.window` 样式又会激活应用抢焦点。自绘面板可半透明、可成为 key window、不抢终端焦点。 |
| 状态管理 | 单一 `ProviderStore: ObservableObject` 注入环境 | 面板内所有视图共享同一份真值源；轮询定时器、余额请求、快照写入都挂在 store 上，生命周期与 app 一致。 |
| 数据格式 | JSON（Codable） | 与 `settings.json` 一致，人类可读可手改；`Preset` 旧格式通过 `MigrationHelper` 自动迁移。 |
| 沙盒策略 | 主 app **非沙盒**（需读 `~/.claude`、`~/.cursor`、调 osascript），Widget **沙盒** | 主 app 必须跨目录读文件与驱动外部进程；Widget 受 WidgetKit 限制必须沙盒，故通过 App Group 共享快照。 |
| 依赖 | 零第三方依赖（仅系统框架 + libsqlite3） | 用 `swiftc` + shell 脚本构建，无 Xcode 工程，自用分发最简。 |
| 最低系统 | macOS 14 (Sonoma) | `MenuBarExtra`、`containerBackground(for: .widget)` 等需 14+。 |

---

## 3. 数据模型

### 3.1 Provider / ModelConfig（新格式，`claude-bar-providers.json`）

一个 **Provider** 代表一个 API 服务商，共享 `baseURL` 与 `authToken`，下挂多个 **ModelConfig**：

```json
{
  "providers": [
    {
      "id": "UUID",
      "name": "DeepSeek",
      "authToken": "sk-...",
      "baseURL": "https://api.deepseek.com/anthropic",
      "models": [
        {
          "id": "UUID",
          "name": "deepseek-v4-pro[1M]",
          "contextTokens": "1000000",
          "disableCompact": true,
          "disableExperimentalBetas": true,
          "autoCompactWindow": ""
        }
      ],
      "activeModelID": "UUID"
    }
  ],
  "activeProviderID": "UUID"
}
```

### 3.2 EnvConfig（`settings.json` 的 env 块镜像）

`EnvConfig` 是 Claude Code `settings.json` 中 `env` 字段的 Swift 镜像，包含全部受支持的键：

`ANTHROPIC_AUTH_TOKEN`、`ANTHROPIC_BASE_URL`、`ANTHROPIC_MODEL`、`CLAUDE_CODE_MAX_CONTEXT_TOKENS`、`DISABLE_COMPACT`、`GITHUB_PERSONAL_ACCESS_TOKEN`、`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`、`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL[_NAME]`、`CLAUDE_CODE_AUTO_COMPACT_WINDOW`。

切换模型时，`buildEnv()` 会把所选模型的 `name` 同时写入 `ANTHROPIC_MODEL` 与全部四个 `ANTHROPIC_DEFAULT_*_MODEL[_NAME]`，使 Claude Code 内部按 tier 选择时一致指向该模型。

### 3.3 旧格式迁移（`claude-bar-presets.json`）

旧版的扁平 `Preset` 列表（每个 preset 各自带 baseURL/authToken/model）在首次加载时由 `MigrationHelper.migrateIfNeeded()` 自动转换：按 `baseURL` 分组归并为 Provider，每个旧 preset 退化为该 Provider 下的一个 ModelConfig，迁移后删除旧文件。

### 3.4 WidgetSnapshot（主 app → Widget 的快照）

主 app 每次刷新都把面板状态序列化为 `WidgetSnapshot`，写入 **四个** 冗余位置以保证沙盒 Widget 一定能读到（见技术文档 §4.3）：

```json
{
  "todayTotalTokens": 38690638,
  "modelBreakdown": [{"model": "kimi-k2.6", "totalTokens": 30000000}],
  "activeProviderName": "Kimi Local",
  "activeModelName": "kimi-k2.6",
  "balanceText": "42.50",
  "totalSessionCount": 2,
  "busySessionCount": 1,
  "sessions": [/* SessionSummary, 最多 5 条 */],
  "cursorSessions": [/* CursorSessionSummary, 最多 5 条 */],
  "updatedAt": "2026-08-01T12:00:00Z"
}
```

---

## 4. 面板布局

面板宽 560pt，垂直自适应（最高占满屏幕可见区）。从上到下：

```
┌─────────────────────────────────────────────────────────────┐
│ ▦ CB  ClaudeBar            [展开/折叠] [刷新]    ← Header    │
├─────────────────────────────────────────────────────────────┤
│ （折叠态默认隐藏）当前 Provider · Model · host · ¥余额        │
├─────────────────────────────────────────────────────────────┤
│ ⬢ CLAUDE CODE          ● 1B · 2I                            │
│  ┌──────────────┐ ┌──────────────┐                          │
│  │ ● ClaudeBar │ │ ○ Proj2      │  ← 2 列会话卡片网格        │
│  │ 159K/200K   │ │ 80%          │                            │
│  │ Bash·build  │ │              │                            │
│  │ ⚙2 · 12m    │ │ · 5m         │                            │
│  └──────────────┘ └──────────────┘                          │
├─────────────────────────────────────────────────────────────┤
│ ✦ CURSOR              ● 1A · 1I                             │
│  ┌──────────────┐ ┌──────────────┐                          │
│  │ ● Proj      │ │ ○ cursor    │                            │
│  └──────────────┘ └──────────────┘                          │
├─────────────────────────────────────────────────────────────┤
│ PROVIDERS              │ 日 月 年 指定 ◀ JULY 2026 ▶ 38.7M   │
│  ◉ DeepSeek            │  kimi-k2.6   ████████ 30.0M        │
│    ◉ deepseek-v4-pro   │  cursor       ███      8.6M        │
│  ○ Kimi Local          │  claude-...   ██       2.1M        │
│ ▼ Anthropic (3 models) │                                       │
└─────────────────────────────────────────────────────────────┘
│ [刷新] [编辑供应商] [打开 settings.json]      [退出]        │
└─────────────────────────────────────────────────────────────┘
```

### 会话卡片信息

每张卡片（`sessionCard` / `cursorSessionCard`）展示：状态指示点（busy/active 时绿色脉冲动画）、项目文件夹名、上下文占用（Claude 是 `已用/上限` token，Cursor 是百分比）、当前活动工具（如 `Bash · build.sh`）、子 Agent 数量与运行数、相对更新时间。

- **Claude Code 卡片**：双击在 Warp（优先）或 Terminal 中执行 `claude --resume <sessionId>` 恢复会话。
- **Cursor 卡片**：双击用 Cursor.app 打开该 workspace。

### Provider 行

- **单模型 Provider**：整行可点选，行内显示模型名与上下文上限（如 `1M`）。
- **多模型 Provider**：头部可折叠/展开，展开后列出每个模型行，每行独立可选；右键可设为该 Provider 的默认模型。

展开的子 Agent / Workflow 行显示类型、描述、当前活动与运行/完成状态。

### 用量区

- 顶部周期切换 chips：`日 / 月 / 年 / 指定`，`指定` 弹出内联 DatePicker。
- 下方 `◀ 标签 ▶` 可前后翻页，标签如 `JULY 2026` 或 `2026-08-01`。
- 每个模型一行水平条形图，按 token 总量降序，颜色按模型名 hash 分配。
- Cursor 历史用量作为一条 `Cursor` 行附加到所有周期（因其 token 数据自 2026-03 起不再更新，是一次性全量值）。

---

## 5. 关键交互流程

### 5.1 切换 Provider / Model

1. 用户点击模型行 → `ProviderStore.activateModel(providerID:modelID:)`。
2. `buildEnv()` 用所选 Provider + Model 构造完整 `EnvConfig`。
3. `SettingsManager.writeSettings(env:)` 读旧 env，用 `preserve()` 合并（空值不覆盖已有值），保留 `permissions` 等顶层字段，写回 `~/.claude/settings.json`（并修复 JSONSerialization 转义的 `\/`）。
4. 更新 `activeProviderID` / `activeModelID`，持久化 `providers.json`，刷新余额。
5. 面板显示 "checkmark ✓ DeepSeek / deepseek-v4-pro" 反馈 toast（2 秒后淡出）。

### 5.2 会话监控（2.5s 轮询）

1. `ProviderStore.refresh()` → `startSessionPolling()` 启动 2.5s 定时器。
2. `SessionMonitor.fetchActive()`：扫描 `~/.claude/sessions/*.json`，解析 PID/cwd/status，用 `kill(pid, 0)` 判活，按 recency 排序。
3. 对每个活跃会话 `fetchContext()`：读其 transcript `*.jsonl` 的**尾部 ~96KB**，取最后一条 assistant 消息的 `input + cache_read + cache_creation` 作为当前上下文 token，并从最近的 `tool_use` 推断当前活动；若 `tool_use` 后无 `tool_result` 则标记 `toolPending = true`（busy）。
4. `fetchSubagents()`：扫描会话目录的 `subagents/*.meta.json` 与 `subagents/workflows/<id>/`，聚合子 Agent 与 Workflow。
5. `CursorSessionMonitor.fetchActive()` 在后台线程读 Cursor 的 `state.vscdb`（SQLite，只读，WAL 安全），按 `recency` 取最近 80 个非归档 composer，过滤 3 天内活跃的，再扫描其 transcript 尾部补充活动状态。
6. 全部结果回主线程后 `writeWidgetSnapshot()` 同步给 Widget。

### 5.3 用量统计

1. `UsageStats.fetch(in: interval)` 扫描 `~/.claude/projects/**/*.jsonl`。
2. **三级过滤优化**：① 文件 mtime 早于区间起点则跳过；② 行首 ISO 日期字符串粗筛（±1 天 slack 容错时区）；③ 精确解析时间戳并 `interval.contains`。
3. 用 `DispatchQueue.concurrentPerform` 并行解析各文件，合并为按模型聚合的 `ModelUsage`（input/output/cacheRead/cacheCreation）。
4. 追加 `CursorUsageStats.fetch()` 的全量 Cursor token，按总量降序排序。

### 5.4 编辑 Provider（独立窗口）

点击面板底部 "编辑供应商" 图标 → 打开 `ProviderEditorView` 独立 `NSWindow`（760×520，可缩放，位置持久化）。左侧 Provider 列表（增/删/复制），右侧 master-detail：Provider 配置（名/Key/URL）+ 模型列表（增/删/设默认/编辑各字段）。保存时若该 Provider 当前激活，则重新 `activateModel` 应用变更。

### 5.5 Widget 联动

- Widget 点击通过 `widgetURL("claudebar://")` 触发；主 app 的 `AppDelegate.application(_:open:)` 收到该 URL 后调用 `showPanel()` 弹出面板。
- 主 app 每次状态变化调 `WidgetCenter.shared.reloadAllTimelines()`，Widget 30s 后也会主动刷新。

---

## 6. 文件结构

```
ClaudeBar/
├── Sources/
│   ├── build.sh                          ← 构建 + 签名 + 安装脚本
│   ├── AppIcon.icns / AppIcon.iconset/   ← 应用图标
│   ├── ClaudeBar/                        ← 主 app 源码
│   │   ├── ClaudeBarApp.swift            ← @main, AppDelegate
│   │   ├── MenuBarController.swift       ← NSStatusItem + NSPanel
│   │   ├── Models/
│   │   │   ├── Provider.swift            ← Provider/ModelConfig/迁移
│   │   │   ├── Preset.swift              ← EnvConfig/Preset(旧)
│   │   │   ├── ProviderStore.swift       ← 状态中枢
│   │   │   ├── SettingsManager.swift     ← settings.json 读写
│   │   │   └── WidgetSnapshot.swift      ← Widget 快照模型
│   │   ├── Utils/
│   │   │   ├── FilePaths.swift           ← 路径常量 (Claude/Cursor/AppGroup)
│   │   │   ├── BalanceFetcher.swift      ← DeepSeek 余额 API
│   │   │   ├── SessionMonitor.swift     ← Claude Code 会话/transcript
│   │   │   ├── CursorSessionMonitor.swift← Cursor SQLite 会话
│   │   │   ├── UsageStats.swift         ← token 用量扫描
│   │   │   └── CursorUsageStats.swift    ← Cursor 历史 token
│   │   └── Views/
│   │       ├── MenuBarView.swift         ← 主面板
│   │       ├── ProviderRow.swift         ← Provider 行
│   │       └── ProviderEditorView.swift  ← 编辑窗口
│   └── Widget/                          ← WidgetKit 扩展源码
│       ├── ClaudeBarWidget.swift         ← @main Widget
│       ├── WidgetProvider.swift          ← TimelineProvider
│       └── WidgetViews.swift             ← Widget 视图
├── docs/
│   ├── design.md                        ← 本文件
│   ├── architecture.md                  ← 技术架构文档
│   └── superpowers/plans/               ← 早期实现计划（历史归档）
├── ClaudeBar.pen                        ← Pencil 原型
└── .build/                              ← 构建产物
```

---

## 7. 错误处理

| 场景 | 行为 |
|------|------|
| `~/.claude/settings.json` 缺失 | 面板显示 "No settings.json found" 警告，提示先运行 Claude Code |
| `providers.json` 缺失或解析失败 | providers 置空，可手动添加 |
| 写 settings.json 失败 | `errorMessage` 提示，面板反馈 |
| 无活跃会话 | 会话区显示 "No active sessions" |
| Cursor 未安装 / DB 不存在 | Cursor 区显示 "none"，不影响 Claude 区 |
| DeepSeek 余额请求失败 / 非 DeepSeek | `balanceText = nil`，不显示余额 |
| Widget 读不到快照 | 先试 UserDefaults → App Group 文件 → `~/.claude` → Widget 沙盒容器，全部失败则显示诊断信息（`UD:nil F:N/-1B`） |

---

## 8. 构建与分发

- **开发构建**：`bash Sources/build.sh`，用 `swiftc` 编译主 app + Widget appex，ad-hoc 签名（`codesign -s -`），安装到 `/Applications/ClaudeBar.app`。
- **运行**：`open /Applications/ClaudeBar.app`，菜单栏出现 `arrow.triangle.2.circlepath` 图标。
- **Widget 启用**：构建脚本自动 `lsregister -f` + `pluginkit -e use` 强制注册；首次需在桌面右键添加 "ClaudeBar"（systemLarge）小组件。
- **分发范围**：自用（ad-hoc 签名，无 Developer Team ID，不经公证）。

详细的签名陷阱与 Widget 注册细节见 [技术架构文档](architecture.md) §构建与签名。
