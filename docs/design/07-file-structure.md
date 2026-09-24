# 文件结构

> ClaudeBar 设计文档 · §7
> 索引：[设计文档](README.md) · 相关：[顶层架构](02-architecture.md) · [构建与分发](09-build-and-distribution.md)

```
ClaudeBar/
├── Sources/
│   ├── build.sh                          ← 开发者 / CI 构建脚本（非终端用户安装器）
│   ├── AppIcon.icns / AppIcon.svg        ← 应用图标
│   ├── ProviderIcons/                    ← 厂商品牌图标（LobeHub Icons，随包内置；见其 README）
│   ├── batteryctl/                       ← 电池控制 C 辅助进程（`batteryctl.c` + `policy.h`）
│   ├── ClaudeBar/                        ← 主 app 源码
│   │   ├── ClaudeBarApp.swift            ← AppDelegate（.regular 激活策略；@main App 壳）
│   │   ├── MenuBarController.swift       ← NSStatusItem + NSPanel（菜单栏 popup）
│   │   ├── NotchIslandController.swift   ← 刘海灵动岛面板 + 收起 / 提醒 / 展开状态机（见 §10）
│   │   ├── MainWindowController.swift    ← NSWindow 主窗口（1120×720）
│   │   ├── Theme/Theme.swift             ← 设计 token 单点
│   │   ├── Models/
│   │   │   ├── Provider.swift / CodexProvider.swift
│   │   │   ├── ProviderStore.swift / CodexProviderStore.swift
│   │   │   ├── ProviderBridge.swift      ← Claude ↔ Codex 导入转换
│   │   │   ├── ProviderCatalog.swift     ← 内置供应商目录（端点 / 协议 / 模型预设）
│   │   │   ├── ProviderProfileSync.swift ← 同一份配置在两侧的同步
│   │   │   ├── ScopedStoreObservation.swift ← 按字段合并的 store 观察
│   │   │   ├── BatteryChargeController.swift ← 电池控制状态机
│   │   │   ├── IslandLiveModel.swift     ← 灵动岛数据（见 §10）
│   │   │   ├── ProviderEditorModel.swift / CodexEditorModel.swift
│   │   │   ├── CodexProxyState.swift
│   │   │   ├── SettingsManager.swift / AppConfig.swift / AppPreferences.swift
│   │   │   ├── WidgetSnapshot.swift / WidgetSnapshotWriter.swift
│   │   │   └── …
│   │   ├── Utils/
│   │   │   ├── FilePaths.swift           ← Claude / Codex / Cursor / App Group / VPN
│   │   │   ├── CodexProxyServer.swift  ← 本机 127.0.0.1 协议代理
│   │   │   ├── VpnManager.swift / VpnHTTP.swift / VpnSubscriptionStore.swift
│   │   │   ├── VpnSystemProxyController.swift / VpnNetProbe.swift
│   │   │   ├── FanMonitor.swift         ← SMC 风扇 / 温度
│   │   │   ├── SessionMonitor.swift / CursorSessionMonitor.swift / ExternalSessionMonitor.swift
│   │   │   ├── PermissionCenter.swift   ← 权限清单与系统授权状态（见 §10）
│   │   │   ├── TerminalLauncher.swift / SessionHost.swift / OttyBridge.swift ← 回到会话
│   │   │   ├── NotchGeometry.swift      ← 刘海尺寸（见 §10）
│   │   │   ├── BatteryHelperInstaller.swift ← 电池辅助进程的安装与校验
│   │   │   ├── UsageStats.swift / ProcessSampler.swift / …
│   │   │   └── …
│   │   └── Views/
│   │       ├── MainWindowView.swift      ← 顶栏 tabs + detail（8 页）
│   │       ├── MenuBarView.swift         ← popup 组合壳
│   │       ├── Island/                   ← 灵动岛形状、根视图、会话行、用量卡（见 §10）
│   │       ├── Pages/                    ← Dashboard / Sessions / Providers / Usage / Traffic / VPN / Settings / Help
│   │       ├── Shared/                  ← Tile / ConnectionCard / ProviderDirectory / PermissionsSection / …
│   │       └── Popup/                    ← PanelHeader / SessionsPanel / UsagePanel / PanelState
│   └── Widget/
├── vendor/mihomo/                        ← `.version` + README；二进制由 build.sh 下载
├── docs/
│   ├── README.md
│   ├── design/                           ← 产品设计文档（本目录）
│   ├── technical/
│   └── CHANGELOG.md
├── Makefile                              ← 薄封装，调用 Sources/build.sh（`make test` 跑 Tests/）
├── Tests/                                ← 源码切片回归（Python + 临时 swiftc）
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
| `MIHOMO_SKIP_DOWNLOAD=1` | 不下载 mihomo，使用 `vendor/mihomo/mihomo`（若存在） |

脚本通过 `find … -name "*.swift"` 自动发现源文件，用 `swiftc` 编译主 app 与 Widget 扩展，无 Xcode 工程依赖。

因为编译靠 glob，脚本在签名前会**断言关键源文件存在**（`Models/WidgetSnapshot.swift`、`Theme/Theme.swift`、Widget 侧同名的符号链接指向同一 inode 等）：漏一个文件只会静默少编译一个功能，不会报错。

## 构建产物

| 路径 | 何时生成 | 用途 |
|------|----------|------|
| `.build/ClaudeBar.app` | 每次构建 | 本地开发与 CI 冒烟 |
| `.build/dist/ClaudeBar-*-macOS-arm64.dmg` | `CLAUDEBAR_PACKAGE=1` | GitHub Release 分发（拖放到 Applications） |
| `.build/dist/ClaudeBar-*-macOS-arm64.zip` | `CLAUDEBAR_PACKAGE=1` | 备用压缩包分发 |
| `.build/dist/*.sha256` | `CLAUDEBAR_PACKAGE=1` | 产物校验和 |
