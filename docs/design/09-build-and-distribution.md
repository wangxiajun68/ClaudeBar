# 构建与分发

> ClaudeBar 设计文档 · §9（原 §8）
> 相关：技术文档 [技术栈与构建](../technical/01-tech-stack.md) · [构建与签名](../technical/07-build-and-signing.md)

## 分发模型

```
终端用户          →  GitHub Releases  →  ClaudeBar-x.y.z-macOS-arm64.dmg
贡献者 / 维护者   →  Sources/build.sh / Makefile  →  .build/<channel>/<name>.app
CI (tag v*)       →  release.yml  →  DMG + zip + GitHub Release
```

- **用户不运行 build.sh**。DMG 内含 `ClaudeBar.app` 与 `Applications` 快捷方式，拖放安装。
- **开发构建**：`make build` 默认 dev，生成独立身份的 ClaudeBar Dev，只编译、不安装。
- **CI 构建**：分别编译 dev / release，只构建；dev job 运行回归。
- **发版打包**：`make package` 使用 release 身份， 额外产出 `.build/dist/*.dmg`、`.zip` 及 `.sha256`。
- **GitHub Release**：`main` 上打 tag `vMAJOR.MINOR.PATCH`；[release.yml](../../.github/workflows/release.yml) 自动上传。版本号约定见 [VERSIONING.md](../VERSIONING.md)，步骤见 [RELEASING.md](../RELEASING.md)。

完整开发／测试／正式版命令与隔离边界见 [开发环境](../DEVELOPMENT.md)。

## 运行

`open /Applications/ClaudeBar.app` — Dock 图标 + 主窗口 + 菜单栏 status item。

## 平台

- **最低系统**：macOS 15，arm64 only
- **macOS 26+**：命令面板结果区启用 Liquid Glass 容器；按钮不分系统版本，一律走 `ActionButton`（`InstrumentControls.swift`）
- **Widget**：安装后 `lsregister` + `pluginkit`；桌面右键添加 ClaudeBar 小组件
- **VPN 内核**：构建脚本把 mihomo 打成 `Resources/mihomo-core.xz`（13 MB，首次启动在应用内解压成 `mihomo`）；见 [technical/11](../technical/11-vpn.md)
- **签名**：本机构建用自签 `ClaudeBar Dev`；CI 用 ad-hoc。两者都无公证，适合本机或受信任环境

详细签名与 Widget 注册见 [构建与签名](../technical/07-build-and-signing.md)。
