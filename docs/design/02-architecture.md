# 顶层架构

> ClaudeBar 设计文档 · §2
> 相关：[产品概述](01-product-overview.md) · [主窗口与设计系统](05-main-window-and-theme.md)

```
┌──────────────────────────────────────────────────────────────┐
│                        ClaudeBar.app                          │
│                                                               │
│  @main ClaudeBarApp (AppDelegate, .regular 激活策略)            │
│        │                                                      │
│        ├── MainWindowController (主窗口 NSWindow, 1120×720)    │
│        │     └── MainWindowView (NavigationSplitView)         │
│        │           ├── sidebar (5 项 + 实时 badge)             │
│        │           └── Pages/                                 │
│        │                 ├── DashboardView (概览)              │
│        │                 ├── SessionsView (会话)               │
│        │                 ├── ProvidersView (供应商→Editor)     │
│        │                 ├── UsageView (用量)                  │
│        │                 └── SettingsView (设置)               │
│        │                                                      │
│        ├── MenuBarController                                   │
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
│              ├── balanceText (DeepSeek 余额, 含币种)            │
│              └── writeWidgetSnapshot() → App Group (diff)    │
│                                                               │
│  ┌──────────── Models ────────────┐  ┌──────────── Utils ────────────┐
│  │ Provider / ModelConfig          │  │ FilePaths                     │
│  │ EnvConfig / Preset (迁移用)     │  │ SettingsManager (读写 settings)│
│  │ ProvidersFile                   │  │ BalanceFetcher (DeepSeek API)  │
│  │ WidgetSnapshot                  │  │ SessionMonitor (Claude 进程)   │
│  └─────────────────────────────────┘  │ CursorSessionMonitor (SQLite) │
│                                        │ CursorUsageStats             │
│  ┌──────────── Theme ────────────┐   │ UsageStats (jsonl 扫描)       │
│  │ Theme (设计 token 单点)         │   │ CursorDB (共享 SQLite 助手)   │
│  │   颜色/间距/圆角/字体/动画       │   │ JSONCoerce (共享类型转换)     │
│  │   shadowCard()/glassCard()    │   │ TerminalLauncher (恢复/打开)  │
│  └─────────────────────────────────┘   └───────────────────────────────┘
│                                                               │
│  ┌──────────── Views ────────────┐                            │
│  │ MenuBarView / ProviderRow     │                            │
│  │ ProviderEditorView (独立窗口)  │                            │
│  │ Pages/ (5 页)                 │                            │
│  │ Shared/ (13 个交互组件)        │                            │
│  └────────────────────────────────┘                            │
└──────────────────────────────────────────────────────────────┘

           ┌───────────────────────────┐
           │  ClaudeBarWidget.appex     │  ← WidgetKit 扩展
           │  (沙盒, systemLarge)        │
           │  读取 App Group 快照渲染     │
           └───────────────────────────┘
```

## 核心设计取舍

| 决策 | 选择 | 原因 |
|------|------|------|
| UI 容器 | 主窗口 `NSWindow` + `NavigationSplitView`；菜单栏为自定义 `NSPanel` + `NSStatusItem`，而非 `MenuBarExtra` | 主窗口承载完整管理功能（5 页面 + ⌘K 命令面板）；菜单栏 popup 为快速概览。`MenuBarExtra.menu` 无法承载复杂卡片，`.window` 样式又会激活应用抢焦点。自绘 popup 面板可半透明、可成为 key window、不抢终端焦点。 |
| 状态管理 | 单一 `ProviderStore: ObservableObject` 注入环境 | 主窗口与菜单栏 popup 共享同一份真值源；轮询定时器、余额请求、快照写入都挂在 store 上，生命周期与 app 一致。 |
| 设计系统 | `Theme` 设计 token（颜色/间距/圆角/字体/动画/阴影/玻璃卡）单点定义 | 主窗口与 popup 共用同一套 token，配色一致、可单点改。13 个 Shared 交互组件（`.pressable`/`.hoverState`/`.tiltOnHover`/`CommandPalette`/`AuroraBackground` 等）复用。 |
| 数据格式 | JSON（Codable） | 与 `settings.json` 一致，人类可读可手改；`Preset` 旧格式通过 `MigrationHelper` 自动迁移。 |
| 沙盒策略 | 主 app **非沙盒**（需读 `~/.claude`、`~/.cursor`、调 osascript），Widget **沙盒** | 主 app 必须跨目录读文件与驱动外部进程；Widget 受 WidgetKit 限制必须沙盒，故通过 App Group 共享快照。 |
| 依赖 | 零第三方依赖（仅系统框架 + libsqlite3） | 用 `swiftc` + shell 脚本构建，无 Xcode 工程，自用分发最简。 |
| 最低系统 | macOS 15.0 (Sequoia), arm64 | `symbolEffect`、`MeshGradient`、`sensoryFeedback`、`onGeometryChange` 等需 15+；仅 Apple Silicon。 |
