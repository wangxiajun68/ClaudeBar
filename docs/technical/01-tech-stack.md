# 技术栈与构建

> ClaudeBar 技术文档 · §1
> 相关：设计文档 [构建与分发](../design/09-build-and-distribution.md) · 技术文档 [构建与签名](07-build-and-signing.md)

## 技术选型

| 项 | 选择 | 说明 |
|----|------|------|
| 语言 | Swift 5.9+ | 随 Xcode/Command Line Tools 提供 |
| UI | SwiftUI + AppKit 混合 | SwiftUI 渲染面板内容；AppKit 管理 `NSStatusItem`/`NSPanel`/`NSWindow` |
| 表面 | macOS 26 原生 Liquid Glass（`glassEffect`） | 主内容卡 `panelCard()` / 瓦片 `.tile()` 都基于原生玻璃 |
| Widget | WidgetKit | systemLarge 尺寸，`StaticConfiguration` |
| 数据 | Foundation Codable + JSONSerialization | 编码用 Codable，settings.json 读写用 JSONSerialization 以保留未知字段 |
| 数据库 | SQLite3（系统库） | 读 Cursor 的 `state.vscdb`，仅只读 |
| 依赖 | **零第三方依赖** | 仅链接 `libsqlite3` 与系统框架 |
| 构建 | `swiftc` + `bash` 脚本 | 无 Xcode 工程、无 SPM |
| 最低系统 | macOS 26，arm64 | 仅 Apple Silicon；`build.sh` 以 `arm64-apple-macos26.0` 为编译目标 |

## 构建脚本 `Sources/build.sh`

脚本完成「读 `VERSION` → 编译主 app → 编译 Widget appex → 生成 Info.plist → 生成 entitlements → 签名 →（默认）安装到 /Applications → 注册 Widget」全流程。`AXON_SKIP_INSTALL=1` 跳过安装；`AXON_PACKAGE=1` 额外打 zip。

**主 app 编译：**

```bash
swiftc -o "$MACOS_DIR/ClaudeBar" \
  -sdk macosx -target arm64-apple-macos26.0 \
  -framework SwiftUI -framework AppKit -framework WidgetKit \
  -lsqlite3 \
  -Xlinker -rpath -Xlinker /usr/lib/swift \
  -Xlinker -rpath -Xlinker "$SDK_PATH/System/Library/Frameworks" \
  $(find Sources/ClaudeBar -name '*.swift')
```

注意 `-lsqlite3` 用于链接 `CursorSessionMonitor` / `CursorUsageStats` 直接调用的 C SQLite API。

**Widget appex 编译：**

```bash
swiftc -o "$APPEX_CONTENTS/MacOS/ClaudeBarWidget" \
  -module-name ClaudeBarWidget -parse-as-library \
  -sdk macosx -target arm64-apple-macos26.0 \
  -framework SwiftUI -framework WidgetKit \
  -Xlinker -application_extension \
  -Xlinker -e -Xlinker _NSExtensionMain \
  $(find Sources/Widget -name '*.swift')
```

`-Xlinker -application_extension` 标记为扩展安全；`-Xlinker -e _NSExtensionMain` 指定扩展入口。Widget 源码 `import Foundation` 但**不**链接 sqlite3（它不直接访问 Cursor DB，只读快照）。

> **关键决策**：Widget 直接编译进 appex 的 `Contents/MacOS/`，而非先编译到主 app 的 MacOS/ 再 `cp`——后者会留下一个游离的 `ClaudeBarWidget` 二进制，导致 `codesign --deep` 签到多余产物。

## Bundle 结构

```
ClaudeBar.app/
└── Contents/
    ├── Info.plist                 (LSUIElement=false, com.claudebar.app)
    ├── MacOS/
    │   └── ClaudeBar              (主二进制)
    ├── Resources/
    │   └── AppIcon.icns
    └── PlugIns/
        └── ClaudeBarWidget.appex/
            └── Contents/
                ├── Info.plist     (NSExtension: widgetkit-extension)
                └── MacOS/
                    └── ClaudeBarWidget
```
