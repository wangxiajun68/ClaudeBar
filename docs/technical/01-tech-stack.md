# 技术栈与构建

> ClaudeBar 技术文档 · §1
> 相关：设计文档 [构建与分发](../design/09-build-and-distribution.md) · 技术文档 [构建与签名](07-build-and-signing.md)

## 技术选型

| 类别 | 选择 | 说明 |
|------|------|------|
| 语言 | Swift 5.10+ | 随 Xcode / Command Line Tools 提供；源码使用 `nonisolated(unsafe)`（5.10 引入） |
| UI | SwiftUI + AppKit 混合 | SwiftUI 渲染面板与主窗口内容；AppKit 管理 `NSStatusItem`、`NSPanel`、`NSWindow` |
| 表面 | 卡面实底 + 发丝线描边 | `panelCard()` / `.tile()` 为 `Theme.cardSurface` 实底 + 发丝线与内嵌白环，**非** `glassEffect`；按钮为自绘 `ActionButton`（默认 `.neutral` 铣削凹槽，`.sparkle` 深色板 / `.accent` / `.destructive` 需显式指定，见 [DESIGN.md](../../DESIGN.md) 的 Controls 表）。原生 `glassEffect` 只出现在问候卡窗台（macOS 26 用 `glassEffect`，macOS 15 退化为材质叠层）；⌘K 面板把结果列表包在 `GlassEffectContainer` 里，但行本身为普通填充 |
| Widget | WidgetKit | `systemLarge` 尺寸，`StaticConfiguration` |
| 数据 | Foundation Codable + JSONSerialization | 模型编码用 Codable；`settings.json` 读写用 JSONSerialization 以保留未知字段 |
| 数据库 | SQLite3（系统库） | Cursor `state.vscdb` 与 Codex `state_*.sqlite`（只读）；自有 `usage-index.db`、`proxy-usage.db`、`proxy-capture.db`（读写，`DiskPersistence.useDatabase` 决定是否启用）；会话迁移按事务读写 Cursor 桌面库 |
| 依赖 | **无 Swift 包管理器依赖** | 系统框架 + `libsqlite3`；VPN 内核 mihomo 以 `.xz` 归档随包（构建时注入，非 SPM） |
| 构建 | `swiftc` + `bash` 脚本 | 无 Xcode 工程、无 SPM |
| 最低系统 | macOS 15+，arm64 | 仅 Apple Silicon；`build.sh` 默认编译目标 `arm64-apple-macos15.0`（可用 `MACOS_MIN` 覆盖） |
| 分发 | GitHub Releases **DMG** | 终端用户从 DMG 拖放安装（`make package` 同时产出 zip 与 SHA-256）；`Sources/build.sh` 仅供开发者与 CI |

## 构建脚本 `Sources/build.sh`

**开发者 / CI 专用**，不是面向终端用户的安装器。流程：选择版本 → 读取 `VERSION` → 编译主 app 与 Widget → 生成版本独立的 Info.plist / entitlements → 签名 → 验证包。默认 dev，仅构建。完整操作见 [开发环境](../DEVELOPMENT.md)。

| 环境变量 | 行为 |
|----------|------|
| （默认） | 生成 `.build/dev/ClaudeBar Dev.app`，不安装、不杀进程 |
| `CLAUDEBAR_CHANNEL=release` | 正式版 `.build/release/ClaudeBar.app` |
| `CLAUDEBAR_SKIP_INSTALL=0` | 显式安装所选版本；正在运行则拒绝替换 |
| `CLAUDEBAR_PACKAGE=1` | 仅 release 且跳过安装时，额外打包 DMG / zip / sha256 |
| `MIHOMO_UPDATE=1` | 显式更新 mihomo；默认使用提交的压缩归档，不联网更新 |
| `MIHOMO_SKIP_DOWNLOAD=1` | 禁止显式更新下载，仍打包已有归档 |

**主 app 编译（摘录，flags 与 `Sources/build.sh` 的当前列表一致；dev 另加逐文件 `-output-file-map` 增量参数，release 用 `-O -whole-module-optimization`）：**

```bash
MACOS_MIN="${MACOS_MIN:-15.0}"
MACOS_TARGET="arm64-apple-macos${MACOS_MIN}"
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx)

swiftc -o "$MACOS_DIR/ClaudeBar" \
  -sdk "$SDK_PATH" -target "$MACOS_TARGET" \
  -framework Metal -framework SwiftUI -framework AppKit -framework WidgetKit \
  -framework CryptoKit -framework CoreServices -framework IOKit \
  -framework Carbon -framework ScreenCaptureKit -framework CoreLocation \
  -framework CoreWLAN -framework IOBluetooth -framework ServiceManagement \
  -lsqlite3 \
  -Xlinker -rpath -Xlinker /usr/lib/swift \
  -Xlinker -rpath -Xlinker "$SDK_PATH/System/Library/Frameworks" \
  "$PROJECT_DIR/Sources/Shared/BuildChannel.swift" \
  $(find Sources/ClaudeBar -name '*.swift')
```

`-lsqlite3` 供直接调用 C SQLite API 的文件使用：`CursorDB`（`CursorSessionMonitor`、`CursorLedgerStore` / `CursorUsageFetcher` 的 `readCredentials()` 都经它）、`ExternalSessionMonitor`、`UsageIndex`、`ProxyUsageStore`、`ProxyCaptureStore`、`MigrationCursorHistory`、`MigrationCursorDesktop`。

**Widget appex 编译（摘录，flags 与 `Sources/build.sh` 一致）：**

```bash
swiftc -o "$APPEX_CONTENTS/MacOS/ClaudeBarWidget" \
  -module-name ClaudeBarWidget -parse-as-library \
  -sdk "$SDK_PATH" -target "$MACOS_TARGET" \
  -framework SwiftUI -framework WidgetKit \
  -Xlinker -rpath -Xlinker /usr/lib/swift \
  -Xlinker -application_extension \
  -Xlinker -e -Xlinker _NSExtensionMain \
  "$PROJECT_DIR/Sources/Shared/BuildChannel.swift" \
  $(find Sources/Widget -name '*.swift')
```

`-Xlinker -application_extension` 标记为扩展安全；`-Xlinker -e _NSExtensionMain` 指定扩展入口。Widget 源码 `import Foundation` 但**不**链接 sqlite3（只读 App Group 快照，不直接访问 Cursor DB）。

> **关键决策**：Widget 直接编译进 appex 的 `Contents/MacOS/`，而非先编译到主 app 的 `MacOS/` 再 `cp`——后者会留下游离的 `ClaudeBarWidget` 二进制，导致 `codesign --deep` 签到多余产物。

## Bundle 结构

```
ClaudeBar.app/
└── Contents/
    ├── Info.plist                 (LSUIElement=false, com.claudebar.app, LSMinimumSystemVersion=15.0)
    ├── MacOS/
    │   └── ClaudeBar              (主二进制)
    ├── Resources/
    │   ├── AppIcon.icns           (dev 用 AppIcon-Dev.icns，带 DEV 标志)
    │   ├── BrandAssets/           （归一化品牌图形，主 app 与 appex 各一份）
    │   ├── ProviderIcons/         （供应商图标 *.png / *.ico + LICENSE-LobeHub.txt）
    │   ├── Fonts/                 （问候的 49 款随包手写体，按字体家族各带一份许可证文件，由 `GreetingScript` 按文件名加载）
    │   ├── Lucide.txt             （图标许可证）
    │   ├── macbook-internals-illustration.png + ASSET-LICENSES.md
    │   ├── claudebar-batteryctl   （C 辅助进程，clang 编译）
    │   ├── claudebar-fanctl       （C 辅助进程，clang 编译）
    │   └── mihomo-core.xz         （VPN 内核压缩档，build.sh 注入或复用仓库内那份）
    └── PlugIns/
        └── ClaudeBarWidget.appex/
            └── Contents/
                ├── Info.plist     (NSExtension: widgetkit-extension)
                ├── Resources/BrandAssets/
                └── MacOS/
                    └── ClaudeBarWidget
```

dev 版同一结构，只是身份不同：`ClaudeBar Dev.app` / 可执行文件 `ClaudeBarDev` / bundle ID `com.claudebar.app.dev` / URL scheme `claudebar-dev`（`Sources/build-config.sh`）。下表以 release 为例。
