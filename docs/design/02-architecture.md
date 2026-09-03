# 顶层架构

> ClaudeBar 设计文档 · §2
> 索引：[设计文档](README.md) · 相关：[产品概述](01-product-overview.md) · [主窗口与设计系统](05-main-window-and-theme.md)

```
┌──────────────────────────────────────────────────────────────┐
│                        ClaudeBar.app                          │
│                                                               │
│  @main ClaudeBarApp (AppDelegate, .regular 激活策略)            │
│        │                                                      │
│        ├── MainWindowController (主窗口 NSWindow, 1120×720)    │
│        │     └── MainWindowView (NavigationSplitView)         │
│        │           ├── sidebar (6 项 + 实时 badge)             │
│        │           └── Pages/                                 │
│        │                 ├── DashboardView (概览)              │
│        │                 ├── SessionsView (会话)               │
│        │                 ├── ProvidersView (供应商→Editor)     │
│        │                 ├── UsageView (用量)                  │
│        │                 ├── TrafficView (流量 / 代理捕获)       │
│        │                 └── SettingsView (设置)               │
│        │                                                      │
│        ├── MenuBarController                                   │
│        │     ├── NSStatusItem (菜单栏图标)                     │
│        │     └── NSPanel (半透明悬浮面板, 承载 SwiftUI 视图)    │
│        │           └── MenuBarView (组合壳)                    │
│        │                 └── Views/Popup/                      │
│        │                       ├── PanelHeader                 │
│        │                       ├── ProvidersPanel              │
│        │                       ├── SessionsPanelView           │
│        │                       ├── UsagePanel                  │
│        │                       └── PanelState                  │
│        │                                                      │
│        ├── ProviderStore (Claude Code 状态中枢)                │
│        │     ├── providers / activeProviderID                 │
│        │     ├── sessions / cursorSessions (轮询)              │
│        │     ├── heartbeats / usageStats / balanceText        │
│        │     ├── peer → CodexProviderStore (联动)             │
│        │     └── writeWidgetSnapshot() → App Group (diff)      │
│        │                                                      │
│        └── CodexProviderStore (Codex 状态中枢)                 │
│              ├── providers / activeProviderID                   │
│              ├── CodexProxyServer (可选 127.0.0.1 代理)        │
│              ├── ProxyCaptureStore / ProxyAccessLog           │
│              └── peer → ProviderStore (联动)                  │
│                    空闲检测 → NotificationService (busy→idle)  │
│                                                               │
│  ┌──────────── Models ────────────┐  ┌──────────── Utils ────────────┐
│  │ Provider / ModelConfig          │  │ FilePaths                     │
│  │ CodexProvider / CodexModelConfig│  │ SettingsManager               │
│  │ EnvConfig / ProvidersFile       │  │ CodexConfigWriter             │
│  │ ProviderBridge                  │  │ BalanceFetcher                │
│  │ WidgetSnapshot(+Writer)         │  │ SessionMonitor / Cursor*      │
│  │ AppConfig / AppPreferences      │  │ CodexProxyServer/Transform    │
│  │ IdleTransitionDetector          │  │ UsageStats / ProxyCapture*    │
│  └─────────────────────────────────┘  │ NotificationService / …       │
│                                        └───────────────────────────────┘
│  ┌──────────── Theme ────────────┐    ┌──────────── Views ────────────┐
│  │ Theme (设计 token 单点)         │    │ MenuBarView + Popup/          │
│  │   panelCard() / tile() / …     │    │ MainWindowView + Pages/ (6 页)│
│  └─────────────────────────────────┘    │ Provider*Editor / Shared/     │
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
| UI 容器 | 主窗口 `NSWindow` + `NavigationSplitView`；菜单栏为自定义 `NSPanel` + `NSStatusItem`，而非 `MenuBarExtra` | 主窗口承载完整管理功能（6 页面 + ⌘K 命令面板）；菜单栏 popup 为快速概览。`MenuBarExtra.menu` 无法承载复杂瓦片，`.window` 样式又会激活应用抢焦点。自绘 popup 面板可半透明、可成为 key window、不抢终端焦点。 |
| 状态管理 | `ProviderStore` + `CodexProviderStore` 双中枢，经 `ProviderBridge` 互引 | Claude Code 与 Codex 配置域分离（不同文件格式与写入路径），但切换预设 / 激活模型需两侧同步；各 store 注入主窗口与 popup 环境。 |
| 布局语言 | 全界面宫格化：数据域以等高瓦片网格呈现，列模板收敛到 `Theme.GridLayout.Preset` | 每个数据域只在一处决定"怎么排"；瓦片等高保证网格行整齐，信息密度高于卡片列表。 |
| 设计系统 | `Theme` 设计 token（颜色/间距/圆角/字距/字体/宫格/动画/表面）单点定义 | 主窗口与 popup 共用同一套 token。内容表面为扁平半透明填充（`panelCard()` / `.tile()`），避免全窗口 `glassEffect` 的 GPU 开销；macOS 26+ 仅在按钮与命令面板使用原生 Liquid Glass。 |
| 数据格式 | JSON（Codable）+ TOML（Codex `config.toml`） | 与上游工具配置文件一致，人类可读可手改；`Provider` 解码兼容早期手写文件的旧字段。 |
| 沙盒策略 | 主 app **非沙盒**（需读 `~/.claude`、`~/.codex`、`~/.cursor`、调 osascript、监听本机代理端口），Widget **沙盒** | 主 app 必须跨目录读文件与驱动外部进程；Widget 受 WidgetKit 限制必须沙盒，故通过 App Group 共享快照。 |
| 依赖 | 零第三方依赖（仅系统框架 + libsqlite3） | 用 `swiftc` + shell 脚本构建，无 Xcode 工程，分发链路最简。 |
| 最低系统 | macOS 15，arm64 | 部署目标 `arm64-apple-macos15.0`（`Sources/build.sh` 中 `MACOS_MIN` 默认 `15.0`）；仅 Apple Silicon。终端用户从 GitHub Releases 安装 DMG，不运行 `build.sh`。 |
