# 构建与分发

> ClaudeBar 设计文档 · §9（原 §8）
> 相关：技术文档 [技术栈与构建](../technical/01-tech-stack.md) · [构建与签名](../technical/07-build-and-signing.md)

## 分发模型

```
终端用户          →  GitHub Releases  →  ClaudeBar-x.y.z-macOS-arm64.dmg
贡献者 / 维护者   →  Sources/build.sh / Makefile  →  .build/ClaudeBar.app
CI (tag v*)       →  release.yml  →  DMG + zip + GitHub Release
```

- **用户不运行 build.sh**。DMG 内含 `ClaudeBar.app` 与 `Applications` 快捷方式，拖放安装。
- **开发构建**：`make build` 或 `bash Sources/build.sh`，ad-hoc 签名，安装到 `/Applications/ClaudeBar.app`。
- **CI 构建**：`CLAUDEBAR_SKIP_INSTALL=1`，只产出 `.build/ClaudeBar.app`。
- **发版打包**：`CLAUDEBAR_PACKAGE=1` 额外产出 `.build/dist/*.dmg`、`.zip` 及 `.sha256`。
- **GitHub Release**：`main` 上打 tag `vMAJOR.MINOR.PATCH`；[release.yml](../../.github/workflows/release.yml) 自动上传。版本号约定见 [VERSIONING.md](../VERSIONING.md)，步骤见 [RELEASING.md](../RELEASING.md)。

## 运行

`open /Applications/ClaudeBar.app` — Dock 图标 + 主窗口 + 菜单栏 status item。

## 平台

- **最低系统**：macOS 15，arm64 only
- **macOS 26+**：自动启用 Liquid Glass 按钮与命令面板玻璃容器
- **Widget**：安装后 `lsregister` + `pluginkit`；桌面右键添加 ClaudeBar 小组件
- **签名**：ad-hoc，无公证；适合本机或受信任环境

详细签名与 Widget 注册见 [构建与签名](../technical/07-build-and-signing.md)。
