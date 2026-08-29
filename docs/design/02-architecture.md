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
│        │           └── MenuBarView (组合壳)                    │
│        │                 └── Views/Popup/                      │
│        │                       ├── PanelHeader                 │
│        │                       ├── ProvidersPanel           │
│        │                       │     (当前配置 + 供应商宫格)    │
│        │                       ├── SessionsPanelView          │
│        │                       │     (Claude/Cursor 会话卡)   │
│        │                       ├── UsagePanel (用量瓦片)       │
│        │                       └── PanelState (UI 状态)        │
│        │                                                      │
│        └── ProviderStore (ObservableObject, 单例状态中枢)      │
│              ├── providers / activeProviderID                 │
│              ├── sessions / cursorSessions (2.5s 轮询)         │
│              ├── heartbeats (busy/idle 心跳轨迹)               │
│              ├── usageStats (按周期聚合)                       │
│              ├── balanceText (DeepSeek 余额, 含币种)            │
│              └── writeWidgetSnapshot() → App Group (diff)      │
│                    空闲检测 → NotificationService (busy→idle)  │
│                                                               │
│  ┌──────────── Models ────────────┐  ┌──────────── Utils ────────────┐
│  │ Provider / ModelConfig          │  │ FilePaths                     │
│  │ EnvConfig / ProvidersFile       │  │ SettingsManager (读写 settings)│
│  │ WidgetSnapshot(+Writer)         │  │ BalanceFetcher (DeepSeek API)  │
│  │ ProviderEditorModel             │  │ SessionMonitor (Claude 进程)   │
│  │ WidgetSnapshot(+Writer)         │  │ CursorSessionMonitor (SQLite) │
│  │ AppConfig / AppPreferences      │  │ CursorUsageStats             │
│  │ IdleTransitionDetector          │  │ UsageStats (jsonl 扫描)       │
│  └─────────────────────────────────┘  │ CursorDB (共享 SQLite 助手)   │
│                                        │ JSONCoerce (共享类型转换)     │
│  ┌──────────── Theme ────────────┐    │ NotificationService (空闲通知)│
│  │ Theme (设计 token 单点)         │    │ TerminalLauncher (恢复/打开)  │
│  │   颜色/间距/圆角/字距/字体       │    └───────────────────────────────┘
│  │   GridLayout (宫格列模板)       │
│  │   panelCard()/tile()/hairline  │    ┌──────────── Views ────────────┐
│  └─────────────────────────────────┘   │ MenuBarView + Popup/ (5 文件) │
│                                        │ MainWindowView + Pages/ (5 页)│
│                                        │ ProviderTile / ProviderEditor │
│                                        │ Shared/ (宫格+交互组件层)      │
│                                        └───────────────────────────────┘
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
| UI 容器 | 主窗口 `NSWindow` + `NavigationSplitView`；菜单栏为自定义 `NSPanel` + `NSStatusItem`，而非 `MenuBarExtra` | 主窗口承载完整管理功能（5 页面 + ⌘K 命令面板）；菜单栏 popup 为快速概览。`MenuBarExtra.menu` 无法承载复杂瓦片，`.window` 样式又会激活应用抢焦点。自绘 popup 面板可半透明、可成为 key window、不抢终端焦点。 |
| 状态管理 | 单一 `ProviderStore: ObservableObject` 注入环境 | 主窗口与菜单栏 popup 共享同一份真值源；轮询定时器、余额请求、快照写入都挂在 store 上，生命周期与 app 一致。 |
| 布局语言 | 全界面宫格化：数据域以等高瓦片网格呈现，列模板收敛到 `Theme.GridLayout.Preset` | 每个数据域只在一处决定"怎么排"；瓦片等高保证网格行整齐，信息密度高于卡片列表。 |
| 设计系统 | `Theme` 设计 token（颜色/间距/圆角/字距/字体/宫格/动画/表面）单点定义 | 主窗口与 popup 共用同一套 token，配色一致、可单点改。`Shared/` 组件层（`TileGrid`/`MetricTile`/`SectionHeader`/`SessionCardView`/`CommandPalette` 等）跨面复用。 |
| 数据格式 | JSON（Codable） | 与 `settings.json` 一致，人类可读可手改；`Provider` 解码兼容早期手写文件的旧字段。 |
| 沙盒策略 | 主 app **非沙盒**（需读 `~/.claude`、`~/.cursor`、调 osascript），Widget **沙盒** | 主 app 必须跨目录读文件与驱动外部进程；Widget 受 WidgetKit 限制必须沙盒，故通过 App Group 共享快照。 |
| 依赖 | 零第三方依赖（仅系统框架 + libsqlite3） | 用 `swiftc` + shell 脚本构建，无 Xcode 工程，自用分发最简。 |
| 最低系统 | macOS 26，arm64 | 主内容表面用原生 `glassEffect`（Liquid Glass），`build.sh` 以 `arm64-apple-macos26.0` 编译；仅 Apple Silicon。 |
