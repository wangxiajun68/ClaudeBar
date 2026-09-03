# 技术栈与构建

> ClaudeBar 技术文档 · §1
> 相关：设计文档 [构建与分发](../design/09-build-and-distribution.md) · 技术文档 [构建与签名](07-build-and-signing.md)

## 技术选型

| 类别 | 选择 | 说明 |
|------|------|------|
| 语言 | Swift 5.9+ | 随 Xcode / Command Line Tools 提供 |
| UI | SwiftUI + AppKit 混合 | SwiftUI 渲染面板与主窗口内容；AppKit 管理 `NSStatusItem`、`NSPanel`、`NSWindow` |
| 表面 | 半透明填充 + 发丝线描边 | `panelCard()` / `.tile()` 为静态半透明白填充与细边框，**非** `glassEffect`；macOS 26+ 上部分工具栏按钮经 `adaptiveGlassButton()` 使用原生 Liquid Glass |
| Widget | WidgetKit | `systemLarge` 尺寸，`StaticConfiguration` |
| 数据 | Foundation Codable + JSONSerialization | 模型编码用 Codable；`settings.json` 读写用 JSONSerialization 以保留未知字段 |
| 数据库 | SQLite3（系统库） | 只读访问 Cursor 的 `state.vscdb` |
| 依赖 | **零第三方依赖** | 仅链接 `libsqlite3` 与系统框架（SwiftUI、AppKit、WidgetKit、CryptoKit、CoreServices、IOKit） |
| 构建 | `swiftc` + `bash` 脚本 | 无 Xcode 工程、无 SPM |
| 最低系统 | macOS 15+，arm64 | 仅 Apple Silicon；`build.sh` 默认编译目标 `arm64-apple-macos15.0`（可用 `MACOS_MIN` 覆盖） |
| 分发 | GitHub Releases **DMG** | 终端用户从 DMG 拖放安装；`Sources/build.sh` 仅供开发者与 CI |

## 构建脚本 `Sources/build.sh`

**开发者 / CI 专用**，不是面向终端用户的安装器。完整流程：读取根目录 `VERSION` → 编译主 app → 编译 Widget appex → 生成 Info.plist → ad-hoc 签名 →（默认）安装到 `/Applications` 并注册 Widget。

| 环境变量 | 行为 |
|----------|------|
| （默认） | 编译、签名、安装到 `/Applications/ClaudeBar.app`，执行 `lsregister` / `pluginkit` |
| `CLAUDEBAR_SKIP_INSTALL=1` | 仅产出 `.build/ClaudeBar.app`；不 `pkill`、不写 `/Applications`、不跑 `pluginkit`（**CI 必用**） |
| `CLAUDEBAR_PACKAGE=1` | 在跳过安装前提下，额外打包 `.build/dist/ClaudeBar-{version}-macOS-arm64.dmg`（主发行物）、`.zip` 及 `.sha256` 校验和 |

**主 app 编译（摘录）：**

```bash
MACOS_MIN="${MACOS_MIN:-15.0}"
MACOS_TARGET="arm64-apple-macos${MACOS_MIN}"

swiftc -o "$MACOS_DIR/ClaudeBar" \
  -sdk macosx -target "$MACOS_TARGET" \
  -framework SwiftUI -framework AppKit -framework WidgetKit \
  -framework CryptoKit -framework CoreServices -framework IOKit \
  -lsqlite3 \
  -Xlinker -rpath -Xlinker /usr/lib/swift \
  -Xlinker -rpath -Xlinker "$SDK_PATH/System/Library/Frameworks" \
  $(find Sources/ClaudeBar -name '*.swift')
```

`-lsqlite3` 用于 `CursorSessionMonitor` / `CursorUsageStats` 直接调用的 C SQLite API。

**Widget appex 编译（摘录）：**

```bash
swiftc -o "$APPEX_CONTENTS/MacOS/ClaudeBarWidget" \
  -module-name ClaudeBarWidget -parse-as-library \
  -sdk macosx -target "$MACOS_TARGET" \
  -framework SwiftUI -framework WidgetKit \
  -Xlinker -application_extension \
  -Xlinker -e -Xlinker _NSExtensionMain \
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
    │   ├── AppIcon.icns
    │   └── MenuBarIcon.png
    └── PlugIns/
        └── ClaudeBarWidget.appex/
            └── Contents/
                ├── Info.plist     (NSExtension: widgetkit-extension)
                └── MacOS/
                    └── ClaudeBarWidget
```
