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
│        │     └── MainWindowView (顶栏 tabs + detail)          │
│        │           ├── topBar (8 项 + 实时状态)                │
│        │           └── Pages/                                 │
│        │                 ├── DashboardView (概览)              │
│        │                 ├── SessionsView (会话)               │
│        │                 ├── ProvidersView (模型)               │
│        │                 ├── UsageView (用量)                  │
│        │                 ├── TrafficView (流量 / 代理捕获)       │
│        │                 ├── VPNView (mihomo)                   │
│        │                 └── SettingsView (设置 · 风扇)         │
│        │                                                      │
│        ├── MenuBarController                                   │
│        │     ├── NSStatusItem（闲：矢量标；VPN 开：双行速率）   │
│        │     └── NSPanel                                        │
│        │           └── MenuBarView                            │
│        │                 ├── PanelHeader（模型 / VPN chip）    │
│        │                 ├── MachineKpiStrip（CPU/GPU/内存/风扇）│
│        │                 └── Popup/ Providers · Sessions · Usage │
│        │                                                      │
│        ├── ProviderStore (Claude Code 状态中枢)                │
│        │     ├── providers / activeProviderID                 │
│        │     ├── sessions / cursorSessions (轮询)              │
│        │     ├── heartbeats / usageStats / balanceText        │
│        │     ├── peer → CodexProviderStore (共享代理状态)     │
│        │     └── writeWidgetSnapshot() → App Group (diff)      │
│        │                                                      │
│        └── CodexProviderStore (Codex 状态中枢)                 │
│              ├── providers / activeProviderID                   │
│              ├── CodexProxyServer (可选 127.0.0.1 代理)        │
│              └── peer → ProviderStore（读取 Claude 上游）    │
│                                                               │
│        VpnManager + VpnSubscriptionStore（可选 VPN）           │
│        FanMonitor（SMC 转速 / 温度，设置页）                    │
│                                                               │
│  ┌──────────── Models ────────────┐  ┌──────────── Utils ────────────┐
│  │ Provider / ModelConfig          │  │ FilePaths                     │
│  │ CodexProvider / CodexModelConfig│  │ SettingsManager               │
│  │ EnvConfig / ProvidersFile       │  │ CodexConfigWriter             │
│  │ ProviderBridge                  │  │ BalanceFetcher                │
│  │ WidgetSnapshot(+Writer)         │  │ SessionMonitor / Cursor*      │
│  │ AppConfig / AppPreferences      │  │ CodexProxyServer/Transform    │
│  │ IdleTransitionDetector          │  │ UsageStats / ProxyCapture*    │
│  └─────────────────────────────────┘  │ Vpn* / FanMonitor / …          │
│                                        └───────────────────────────────┘
│  ┌──────────── Theme ────────────┐    ┌──────────── Views ────────────┐
│  │ Theme (设计 token 单点)         │    │ MenuBarView + Popup/          │
│  │   panelCard() / tile() / …     │    │ MainWindowView + Pages/ (9 页)│
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
| UI 容器 | 主窗口 `NSWindow` + 顶栏 tabs（`VStack` + `ViewThatFits`）；菜单栏为自定义 `NSPanel` + `NSStatusItem`，而非 `MenuBarExtra` | 主窗口承载完整管理功能（9 页面 + ⌘K）；菜单栏 popup 为快速概览。 |
| 状态管理 | `ProviderStore` + `CodexProviderStore` 双中枢，经 peer 互引 | 配置域与激活状态分离；peer 只用于共享代理状态，不联动模型切换。 |
| 依赖 | 零 **Swift** 第三方包（系统框架 + libsqlite3）；VPN 另捆绑 **mihomo** 二进制 sidecar | `swiftc` + shell；内核由 `build.sh` 下载到 `vendor/mihomo/`，不进 Git。 |
| 布局语言 | 全界面宫格化：数据域以等高瓦片网格呈现，列模板收敛到 `Theme.GridLayout.Preset` | 每个数据域只在一处决定"怎么排"；瓦片等高保证网格行整齐，信息密度高于卡片列表。 |
| 设计系统 | `Theme` 设计 token（颜色/间距/圆角/字距/字体/宫格/动画/表面）单点定义 | 主窗口与 popup 共用同一套 token。内容表面为扁平半透明填充（`panelCard()` / `.tile()`），避免全窗口 `glassEffect` 的 GPU 开销；macOS 26+ 仅在按钮与命令面板使用原生 Liquid Glass。 |
| 数据格式 | JSON（Codable）+ TOML（Codex `config.toml`） | 与上游工具配置文件一致，人类可读可手改；`Provider` 解码兼容早期手写文件的旧字段。 |
| 沙盒策略 | 主 app **非沙盒**（需读 `~/.claude`、`~/.codex`、`~/.cursor`、调 osascript、监听本机代理端口、写系统代理），Widget **沙盒** | 主 app 必须跨目录读文件与驱动外部进程；Widget 受 WidgetKit 限制必须沙盒，故通过 App Group 共享快照。 |
| 最低系统 | macOS 15，arm64 | 部署目标 `arm64-apple-macos15.0`（`Sources/build.sh` 中 `MACOS_MIN` 默认 `15.0`）；仅 Apple Silicon。终端用户从 GitHub Releases 安装 DMG，不运行 `build.sh`。 |
