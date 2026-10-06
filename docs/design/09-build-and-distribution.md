# 构建与分发

> ClaudeBar 设计文档 · §9
> 相关：技术文档 [技术栈与构建](../technical/01-tech-stack.md) · [构建与签名](../technical/07-build-and-signing.md)

## 分发模型

```
终端用户          →  GitHub Releases  →  ClaudeBar-x.y.z-macOS-arm64.dmg
贡献者 / 维护者   →  Sources/build.sh / Makefile  →  .build/<channel>/<name>.app
CI (tag v*)       →  release.yml  →  DMG + zip + GitHub Release
```

- 用户不运行 build.sh。DMG 内含 `ClaudeBar.app` 与指向 `/Applications` 的符号链接，拖放安装。
- 开发构建：`make build` 默认 dev（`CLAUDEBAR_CHANNEL=dev CLAUDEBAR_SKIP_INSTALL=1`），生成独立身份的 ClaudeBar Dev，只编译、不安装、不启动。
- CI 构建：`ci.yml` 以 matrix 分别编译 dev / release（`runs-on: macos-26`，`CODESIGN_IDENTITY=-`），只构建；dev job 运行全部回归。
- 发版打包：`make package` 使用 release 身份且跳过安装，另产出 `.build/dist/ClaudeBar-<version>-macOS-arm64.dmg`、`.zip` 及各自的 `.sha256`。
- GitHub Release：`main` 上打 tag `vMAJOR.MINOR.PATCH`；[release.yml](../../.github/workflows/release.yml) 校验 tag 与 `VERSION` 一致后上传。版本号约定见 [VERSIONING.md](../VERSIONING.md)，步骤见 [RELEASING.md](../RELEASING.md)。

完整开发／测试／正式版命令与隔离边界见 [开发环境](../DEVELOPMENT.md)。

## 运行

`open /Applications/ClaudeBar.app` — `NSApp.setActivationPolicy(.regular)` 给出 Dock 图标与主窗口，菜单栏 status item 与刘海灵动岛（偏好默认开启）在启动时一并建立。

## 平台

- 最低系统：macOS 15，arm64 only（`Sources/build.sh` 定 `MACOS_MIN=15.0`、目标 `arm64-apple-macos15.0`，同一值写入两个 Info.plist 的 `LSMinimumSystemVersion`）。
- macOS 26+：命令面板结果区启用 Liquid Glass 容器（`GlassEffectContainer`，`CommandPalette.swift` 的 `#available(macOS 26.0, *)`）；按钮不按系统版本分支，一律走自绘控件（`ActionButton` / `ActionPlateButtonStyle` / `IconChip`，`InstrumentControls.swift`、`Interaction.swift`）。
- Widget：`systemLarge` 单一尺寸；安装后 `lsregister` + `pluginkit`，桌面右键添加 ClaudeBar 小组件。
- VPN 内核：构建脚本把 mihomo 打成 `Resources/mihomo-core.xz`（13 MB，首次启动用 `XZArchive` 在应用内解压）；见 [technical/11](../technical/11-vpn.md)。
- 签名：本机构建用 `ensure-dev-cert.sh` 生成并信任的自签 `ClaudeBar Dev` 证书（ad-hoc 没有证书可依，指定要求退化为整包二进制 hash，每次重编译都会被 TCC 当成新应用、重复索要屏幕录制权限）；CI 与显式 `CODESIGN_IDENTITY=-` 用 ad-hoc。两者都无公证，适合本机或受信任环境。

详细签名与 Widget 注册见 [构建与签名](../technical/07-build-and-signing.md)。
