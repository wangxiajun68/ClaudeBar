# Contributing to ClaudeBar

感谢考虑为 ClaudeBar 贡献代码、文档或问题反馈。本文说明协作方式与工程约定。

---

## 开始之前

| 文档 | 用途 |
|------|------|
| [docs/README.md](docs/README.md) | 文档总索引 |
| [docs/technical/10-extension-guide.md](docs/technical/10-extension-guide.md) | 扩展功能步骤 |
| [SECURITY.md](SECURITY.md) | 安全漏洞报告方式 |

**终端用户**请从 [Releases](https://github.com/wangxiajun68/ClaudeBar/releases) 安装 DMG，无需 clone 仓库。

---

## 开发环境

| 项目 | 要求 |
|------|------|
| 系统 | macOS 15+ |
| 芯片 | Apple Silicon (`arm64`) |
| 工具链 | Xcode Command Line Tools（建议 Xcode 16+） |
| 构建方式 | `swiftc` + `Sources/build.sh`（无 `.xcodeproj`） |

```bash
git clone https://github.com/wangxiajun68/ClaudeBar.git
cd ClaudeBar
make build      # 编译、ad-hoc 签名、安装到 /Applications
```

| 命令 | 作用 |
|------|------|
| `make build` | 日常开发：安装到 `/Applications/ClaudeBar.app` |
| `make ci` | 与 CI 相同：仅产出 `.build/ClaudeBar.app` |
| `make package` | 发版验证：产出 `.build/dist/*.dmg`、`.zip`、校验和 |

等价于：

```bash
bash Sources/build.sh
CLAUDEBAR_SKIP_INSTALL=1 bash Sources/build.sh
CLAUDEBAR_SKIP_INSTALL=1 CLAUDEBAR_PACKAGE=1 bash Sources/build.sh
```

改代码后若界面未更新：`killall ClaudeBar && open /Applications/ClaudeBar.app`。

---

## 分支策略

采用 **GitHub Flow**，默认分支为 `main`。

| 分支前缀 | 用途 |
|----------|------|
| `feature/<topic>` | 新功能 |
| `fix/<topic>` | 缺陷修复 |
| `docs/<topic>` | 仅文档 |
| `chore/<topic>` | 构建、CI、仓库元数据 |

- 不维护长期 `develop` 分支。
- 发版在 `main` 上打 annotated tag：`vMAJOR.MINOR.PATCH`（与根目录 `VERSION` 一致）。见 [docs/RELEASING.md](docs/RELEASING.md)。
- 单人维护仓库可直接推 `main`；有多位贡献者时请走 Pull Request。

---

## 代码约定

### 架构

- **零第三方依赖** — 不引入 SPM、CocoaPods、Carthage 或 vendored SDK。
- **状态中枢** — 数据从 `ProviderStore` / `CodexProviderStore` 流出；视图不自行开 Timer、不做文件 I/O。
- **I/O 边界** — 文件扫描、SQLite、网络请求放在 `Utils/`，在后台队列执行。
- **发布克制** — `@Published` 赋值前做 Equatable 比较，避免无效重渲染。

### UI

- **设计 token** — 颜色、字体、间距、圆角、动画统一使用 `Theme/Theme.swift`。
- **按钮样式** — 使用 `adaptiveGlassButton()`，不要直接写 `.buttonStyle(.glass)`（macOS 26 专属）。
- **文案** — 用户可见字符串使用中文；代码标识符使用英文。

### 构建验证

SourceKit 偶发报 “Cannot find X in scope”，以 `make ci` 或 `make build` 编译结果为准。

---

## 提交规范

使用 [Conventional Commits](https://www.conventionalcommits.org/)：

```
feat(ui): 添加流量页访问日志筛选
fix(sessions): 修复 Codex rollout 路径解析
perf(store): 用量索引增量扫描
docs: 更新发版文档
chore(ci): 升级 release workflow
```

- 每个提交应保持可构建。
- 用户可见行为变更时，更新 [docs/CHANGELOG.md](docs/CHANGELOG.md) 对应版本段。

---

## Pull Request

1. 从 `main` 拉取最新代码，在功能分支上开发。
2. 填写 [.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md)。
3. 确保 CI 通过（`macos-26` runner + `CLAUDEBAR_SKIP_INSTALL=1`）。
4. 涉及 UI 时附简要说明或截图。

---

## 报告问题

使用 [Issue 模板](https://github.com/wangxiajun68/ClaudeBar/issues/new/choose)：

| 类型 | 适用场景 |
|------|----------|
| 缺陷报告 | 崩溃、数据错误、构建失败 |
| 功能建议 | 新能力、交互改进 |

请提供 macOS 版本、ClaudeBar 版本（设置 → 关于）、复现步骤。**切勿粘贴 API key、token 或完整配置文件。**

安全问题请走 [SECURITY.md](SECURITY.md)，不要开公开 Issue。
