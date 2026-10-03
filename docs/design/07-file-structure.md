# 文件结构

> ClaudeBar 设计文档 · §7
> 索引：[设计文档](README.md) · 相关：[顶层架构](02-architecture.md) · [构建与分发](09-build-and-distribution.md)

```
ClaudeBar/
├── Sources/
│   ├── build.sh                          ← 开发者 / CI 构建脚本（非终端用户安装器）
│   ├── build-config.sh                   ← 构建身份 / 通道 / 输出与安装路径的单点
│   ├── Shared/BuildChannel.swift         ← 主应用与 Widget 共享的编译期版本身份与系统集成策略
│   ├── AppIcon.icns / AppIcon-1024.png   ← 应用图标（dev 通道另有 AppIcon-Dev.icns / AppIcon-Dev-1024.png）
│   ├── ProviderIcons/                    ← 厂商品牌图标（LobeHub Icons，随包内置；见其 README）
│   ├── BrandAssets/                      ← 三家客户端 + ClaudeBar 自己的图标底片（由 Tools/gen-brand-marks.py 生成）
│   ├── batteryctl/                       ← 电池控制 C 辅助进程（`batteryctl.c` + `policy.h`）
│   ├── fanctl/                           ← 风扇控制 C 辅助进程（`fanctl.c`）
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
│   │   │   ├── CursorUsageFetcher.swift ← Cursor 额度（读它的账号 token；两个命名池 + Grok 周窗口）
│   │   │   ├── PermissionCenter.swift   ← 权限清单与系统授权状态（见 §10）
│   │   │   ├── CurrentLocation.swift    ← 问候卡天气的单次定位 fix（「当前位置」开关）
│   │   │   ├── WeatherAmapFetcher.swift / WeatherCNFetcher.swift / CNWeatherCityTable.swift ← 两家国内天气源（免代理）
│   │   │   ├── WeatherFetcher.swift     ← 天气源链：高德 → 中国天气网 → Open-Meteo → wttr.in
│   │   │   ├── VpnDomainLog.swift       ← 内核连接行 → 域名 / 规则 / 出口（VPN 页的「流量日志」）
│   │   │   ├── CursorLedger.swift / CursorLedgerStore.swift ← Cursor 的实际扣费（真金额，与估算并列不相加）
│   │   │   ├── SystemThroughput.swift   ← 各网卡字节计数；隧道关闭时菜单栏 ↓/↑ 的来源
│   │   │   ├── TerminalLauncher.swift / SessionHost.swift / OttyBridge.swift ← 回到会话
│   │   │   ├── NotchGeometry.swift      ← 刘海尺寸（见 §10）
│   │   │   ├── BatteryHelperInstaller.swift ← 电池辅助进程的安装与校验
│   │   │   ├── UsageStats.swift / ProcessSampler.swift / …
│   │   │   └── …
│   │   └── Views/
│   │       ├── MainWindowView.swift      ← 顶栏 tabs + detail（9 页）
│   │       ├── MenuBarView.swift         ← popup 组合壳
│   │       ├── Island/                   ← 灵动岛形状、根视图、会话行、用量卡（见 §10）
│   │       ├── Pages/                    ← Dashboard / Sessions / Providers / Connectors / Usage / Traffic / VPN / Settings / Help
│   │       ├── Shared/                  ← Tile / ConnectionCard / CodexModelMark / ProviderDirectory / PermissionsSection / SettingsControls / 问候卡的 Atmosphere 系列 / …
│   │       └── Popup/                    ← PanelHeader / SessionsPanel / UsagePanel / PanelState
│   ├── Fonts/                             ← 问候的 49 款随包手写体（SIL OFL / Apache 2.0）+ 各自的许可证；build.sh 复制进 Resources/Fonts
│   └── Widget/
├── vendor/mihomo/                        ← `.version` + README；原始二进制不进 Git，由 build.sh 按 `.version` 拉取
├── docs/
│   ├── README.md
│   ├── design/                           ← 产品设计文档（本目录）
│   ├── technical/
│   └── CHANGELOG.md
├── Makefile                              ← 薄封装，调用 Sources/build.sh（`make test` 跑 Tests/）
├── Tests/                                ← 源码切片回归（Python + 临时 swiftc）
└── .build/                               ← 本地构建产物（gitignore）
    ├── dev/ClaudeBar Dev.app             ← dev 通道输出（默认；`make install-dev` 才安装）
    ├── release/ClaudeBar.app             ← release 通道输出（`make install-release` 才安装）
    └── dist/                             ← 发版产物（仅 CLAUDEBAR_PACKAGE=1）
        ├── ClaudeBar-x.y.z-macOS-arm64.dmg
        ├── ClaudeBar-x.y.z-macOS-arm64.zip
        └── *.sha256
```

## `Sources/build.sh`

开发者与 CI 使用的构建入口，**不是**终端用户安装方式。用户应从 GitHub Releases 下载 DMG（见 [09-build-and-distribution.md](09-build-and-distribution.md)）。

| 命令 / 环境变量 | 行为 |
|-----------------|------|
| `bash Sources/build.sh` | 编译 → ad-hoc 签名；身份为 dev（`ClaudeBar Dev.app`），**不安装**（`CLAUDEBAR_SKIP_INSTALL` 默认 1） |
| `CLAUDEBAR_CHANNEL=release bash Sources/build.sh` | release 身份（`ClaudeBar.app`）；日常经 `make release` / `make package` 使用 |
| `CLAUDEBAR_SKIP_INSTALL=0` | 编译后安装到 `$INSTALL_DIR`（dev → `~/Applications`，release → `/Applications`）；`make install-dev` / `make install-release` 已封装 |
| `CLAUDEBAR_PACKAGE=1` | 额外打包 `.build/dist/*.dmg`、`.zip` 及 `.sha256` 校验和；要求 release 且 skip-install=1 |
| `MACOS_MIN` | 部署目标，默认 `15.0` → `arm64-apple-macos15.0` |
| `MIHOMO_UPDATE=1` | 显式更新内核：访问 GitHub 取最新版并重写 `vendor/mihomo/` 与 `Resources/mihomo-core.xz`（显式维护操作，需提交） |
| `MIHOMO_SKIP_DOWNLOAD=1` | 仅在 `MIHOMO_UPDATE=1` 时生效：跳过下载，改用已 vendored 的内核 |

默认路径（未设 `MIHOMO_UPDATE=1`）不解压、不下载，直接把随提交的 `Resources/mihomo-core.xz` 复制进包，构建因此离线且可复现。安装脚本发现同版本正在运行会拒绝替换，不杀进程。

脚本通过 `find … -name "*.swift"` 自动发现源文件，用 `swiftc` 编译主 app 与 Widget 扩展，无 Xcode 工程依赖。

因为编译靠 glob，脚本在签名前会**断言关键源文件存在**（`Models/WidgetSnapshot.swift`、`Theme/Theme.swift`、Widget 侧同名的符号链接指向同一 inode 等）：漏一个文件只会静默少编译一个功能，不会报错。每个通道的输出与缓存标记各自独立（`.build/<channel>/`），身份由 `Sources/build-config.sh` 集中定义。

## 构建产物

| 路径 | 何时生成 | 用途 |
|------|----------|------|
| `.build/dev/ClaudeBar Dev.app` | 每次 dev 构建（默认通道） | 本地开发与 CI 冒烟 |
| `.build/release/ClaudeBar.app` | 每次 release 构建 | 发版前验证与打包输入 |
| `.build/dist/ClaudeBar-*-macOS-arm64.dmg` | `CLAUDEBAR_PACKAGE=1` | GitHub Release 分发（拖放到 Applications） |
| `.build/dist/ClaudeBar-*-macOS-arm64.zip` | `CLAUDEBAR_PACKAGE=1` | 备用压缩包分发 |
| `.build/dist/*.sha256` | `CLAUDEBAR_PACKAGE=1` | 产物校验和 |
