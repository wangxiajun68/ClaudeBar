# 构建与分发

> ClaudeBar 设计文档 · §9（原 §8）
> 相关：技术文档 [技术栈与构建](../technical/01-tech-stack.md) · [构建与签名](../technical/07-build-and-signing.md)

- **开发构建**：`bash Sources/build.sh`，用 `swiftc` 编译主 app + Widget appex，ad-hoc 签名（`codesign -s -`），安装到 `/Applications/ClaudeBar.app`。版本号来自仓库根目录 `VERSION`。
- **CI / 发包构建**：`AXON_SKIP_INSTALL=1` 只产出 `.build/ClaudeBar.app`，不 `pkill`、不拷 `/Applications`。`AXON_PACKAGE=1` 额外打出 `.build/dist/Axon-<version>-macos-arm64.zip`。
- **GitHub Release**：在 `main` 上打 annotated tag `vMAJOR.MINOR.PATCH`；[`.github/workflows/release.yml`](../../.github/workflows/release.yml) 在 `macos-26` runner 打包并上传。步骤见 [RELEASING.md](../RELEASING.md)。
- **运行**：`open /Applications/ClaudeBar.app`，Dock 图标 + 主窗口出现，同时菜单栏出现 status item（点击弹出 popup）。
- **最低系统**：编译/运行目标 macOS 26，arm64 only（主内容表面用原生 `glassEffect`，Liquid Glass）；依赖 15.0+ API（`symbolEffect` / `sensoryFeedback` / `onGeometryChange`）。
- **Widget 启用**：安装流程会 `lsregister -f` + `pluginkit -e use`；首次需在桌面右键添加 "Axon / ClaudeBar"（systemLarge）小组件。
- **分发范围**：本机或受信任环境（ad-hoc 签名，无 Developer Team ID，不经公证）。

详细的签名陷阱与 Widget 注册细节见 [技术架构文档](../technical/07-build-and-signing.md)。
