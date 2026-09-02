# Contributing to Axon (ClaudeBar)

这是一个 **零第三方依赖、swiftc 直编** 的 macOS 应用。贡献前请先读 [docs/README.md](docs/README.md)。

## 分支

采用 GitHub Flow，默认分支是 **`main`**。

| 分支 | 用途 |
|------|------|
| `main` | 始终可构建；CI 在每次 push / PR 上跑 |
| `feature/<topic>` | 新功能 |
| `fix/<topic>` | 缺陷 |
| `docs/<topic>` | 仅文档 |
| `chore/<topic>` | 构建、CI、仓库元数据 |

不要长期分叉 `develop`。发行不从分支切，只在 `main` 上打 **annotated tag**：`vMAJOR.MINOR.PATCH`（与根目录 `VERSION` 一致）。流程见 [docs/RELEASING.md](docs/RELEASING.md)。

个人仓库里维护者可以直接推 `main`；有第二位贡献者时请走 Pull Request。

## 本地构建

```bash
# 开发：编译、签名、安装到 /Applications
bash Sources/build.sh
killall ClaudeBar; open /Applications/ClaudeBar.app

# 与 CI 相同：只出 .build/ClaudeBar.app，不碰 /Applications
AXON_SKIP_INSTALL=1 bash Sources/build.sh
```

改代码前可看 [docs/technical/10-extension-guide.md](docs/technical/10-extension-guide.md)。

## 约定

- **零第三方依赖** — 不要引入 SPM / CocoaPods。优先系统框架。
- **设计令牌** — 颜色 / 字体 / 间距 / 动画走 `Theme/Theme.swift`，视图里不写裸字号。
- **状态从 `ProviderStore` 流出** — 视图不自行开 Timer、不做文件 I/O；扫描放 `Utils/`，off-main。
- **发布克制** — `@Published` 赋值前 Equatable 比较，不变不发布。
- **用户可见文案中文**，代码标识符英文。
- SourceKit 的 “Cannot find X in scope” 多为误报，以 `bash Sources/build.sh` 为准。

## 提交

使用 conventional commits：

```
feat(ui): …
fix(sessions): …
perf(store): …
docs: …
chore(ci): …
```

一个提交保持可构建。改用户可见行为时更新 [docs/CHANGELOG.md](docs/CHANGELOG.md) 对应版本段。

## Pull Request

模板在 `.github/PULL_REQUEST_TEMPLATE.md`。合并前 CI（`macos-26` + `AXON_SKIP_INSTALL=1`）必须通过。

## 报告问题

用 [Issue 模板](https://github.com/wangxiajun68/ClaudeBar/issues/new/choose)。请附 macOS 版本、Axon 版本、复现步骤。**不要贴 API key。** 安全问题见 [SECURITY.md](SECURITY.md)。
