# 文件结构

> ClaudeBar 设计文档 · §7
> 索引：[设计文档](README.md) · 相关：[顶层架构](02-architecture.md) · [构建与分发](09-build-and-distribution.md)

```
ClaudeBar/
├── Sources/
│   ├── build.sh                          ← 开发者 / CI 构建脚本（非终端用户安装器）
│   ├── AppIcon.icns / AppIcon.svg        ← 应用图标
│   ├── ClaudeBar/                        ← 主 app 源码
│   │   ├── ClaudeBarApp.swift            ← AppDelegate（.regular 激活策略；@main App 壳）
│   │   ├── MenuBarController.swift       ← NSStatusItem + NSPanel（菜单栏 popup）
│   │   ├── MainWindowController.swift    ← NSWindow 主窗口（1120×720）
│   │   ├── ProviderEditorWindowController.swift
│   │   ├── Theme/Theme.swift             ← 设计 token 单点
│   │   ├── Models/
│   │   │   ├── Provider.swift / CodexProvider.swift
│   │   │   ├── ProviderStore.swift / CodexProviderStore.swift
│   │   │   ├── ProviderBridge.swift      ← Claude ↔ Codex 联动
│   │   │   ├── ProviderEditorModel.swift / CodexEditorModel.swift
│   │   │   ├── CodexProxyState.swift
│   │   │   ├── SettingsManager.swift / AppConfig.swift / AppPreferences.swift
│   │   │   ├── WidgetSnapshot.swift / WidgetSnapshotWriter.swift
│   │   │   └── …
│   │   ├── Utils/
│   │   │   ├── FilePaths.swift           ← Claude / Codex / Cursor / App Group 路径
│   │   │   ├── CodexProxyServer.swift  ← 本机 127.0.0.1 协议代理
│   │   │   ├── CodexProxyTransform.swift / CodexConfigWriter.swift
│   │   │   ├── ProxyCaptureStore.swift / ProxyAccessLog.swift
│   │   │   ├── SessionMonitor.swift / CursorSessionMonitor.swift / ExternalSessionMonitor.swift
│   │   │   ├── UsageStats.swift / ProcessSampler.swift / …
│   │   │   └── …
│   │   └── Views/
│   │       ├── MainWindowView.swift      ← NavigationSplitView（sidebar 6 项）
│   │       ├── MenuBarView.swift         ← popup 组合壳
│   │       ├── ProviderEditorView.swift / CodexProviderEditorView.swift
│   │       ├── ProviderRow.swift         ← ProviderTile / CodexProviderTile
│   │       ├── Popup/                    ← PanelHeader / ProvidersPanel / SessionsPanel / UsagePanel / PanelState
│   │       ├── Pages/                    ← Dashboard / Sessions / Providers / Usage / Traffic / Settings
│   │       └── Shared/                   ← Tile / CommandPalette / Interaction / …
│   └── Widget/                           ← WidgetKit 扩展（ClaudeBarWidget / WidgetViews / …）
├── docs/
│   ├── README.md
│   ├── design/                           ← 产品设计文档（本目录）
│   ├── technical/
│   └── CHANGELOG.md
├── Makefile                              ← 薄封装，调用 Sources/build.sh
└── .build/                               ← 本地构建产物（gitignore）
    ├── ClaudeBar.app                     ← 编译输出
    └── dist/                             ← 发版产物（仅 CLAUDEBAR_PACKAGE=1）
        ├── ClaudeBar-x.y.z-macOS-arm64.dmg
        ├── ClaudeBar-x.y.z-macOS-arm64.zip
        └── *.sha256
```

## `Sources/build.sh`

开发者与 CI 使用的构建入口，**不是**终端用户安装方式。用户应从 GitHub Releases 下载 DMG（见 [09-build-and-distribution.md](09-build-and-distribution.md)）。

| 命令 / 环境变量 | 行为 |
|-----------------|------|
| `bash Sources/build.sh` | 编译 → ad-hoc 签名 → 安装到 `/Applications/ClaudeBar.app` |
| `CLAUDEBAR_SKIP_INSTALL=1` | 仅编译，产出 `.build/ClaudeBar.app`（CI 默认） |
| `CLAUDEBAR_PACKAGE=1` | 额外打包 `.build/dist/*.dmg`、`.zip` 及 `.sha256` 校验和 |
| `MACOS_MIN` | 部署目标，默认 `15.0` → `arm64-apple-macos15.0` |

脚本通过 `find … -name "*.swift"` 自动发现源文件，用 `swiftc` 编译主 app 与 Widget 扩展，无 Xcode 工程依赖。

## 构建产物

| 路径 | 何时生成 | 用途 |
|------|----------|------|
| `.build/ClaudeBar.app` | 每次构建 | 本地开发与 CI 冒烟 |
| `.build/dist/ClaudeBar-*-macOS-arm64.dmg` | `CLAUDEBAR_PACKAGE=1` | GitHub Release 分发（拖放到 Applications） |
| `.build/dist/ClaudeBar-*-macOS-arm64.zip` | `CLAUDEBAR_PACKAGE=1` | 备用压缩包分发 |
| `.build/dist/*.sha256` | `CLAUDEBAR_PACKAGE=1` | 产物校验和 |
