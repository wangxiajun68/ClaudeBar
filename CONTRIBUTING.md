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
make setup
make doctor
make build      # 仅生成开发版，不覆盖正式版
make run        # 启动开发版
```

| 命令 | 作用 |
|------|------|
| `make build` / `make dev` | 调试编译 → `.build/dev/ClaudeBar Dev.app` |
| `make ci` | ad-hoc 签名的同一开发测试版 |
| `make test-fast` / `make test TEST=core` | 快速单元烟测／单组验证，不编译 App |
| `make release` | 正式版 → `.build/release/ClaudeBar.app`；仅构建 |
| `make package` | 正式版 DMG、zip、校验和 → `.build/dist/` |
| `make test` | 已登记源码切片和版本隔离回归 |
| `make install-dev` | 显式安装开发测试版到 `~/Applications` |
| `make install-release` | 显式覆盖 `/Applications/ClaudeBar.app`，必须先正常退出正式版 |

增量编译、缓存复用与完整隔离边界、签名、脚本接口和集成验证流程见 [开发环境](docs/DEVELOPMENT.md)，代码协作规范见 [AGENTS.md](AGENTS.md)。默认构建不安装、不杀进程。开发测试版不会接管正式版 VPN，也不会修改系统代理、DNS、TUN 或硬件控制。

`Tests/` 使用 Python 提取生产 Swift 源码并在临时目录编译运行；不用启动 App。测试清单只在 Makefile 维护。图像检查依赖 Pillow / numpy，由 `make setup` 安装到 `.venv`。默认使用提交的 mihomo 压缩归档，离线构建不需要下载内核；更新须显式设置 `MIHOMO_UPDATE=1`。

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

- **零 Swift 包依赖** — 不引入 SPM、CocoaPods、Carthage。VPN 内核 mihomo 在构建时下载，但**进仓库的是压缩后的 `.xz`**（13 MB，构建时复用；54 MB 的原始二进制才不进 Git，见 `vendor/mihomo/README.md`）。
- **状态中枢** — 数据从 `ProviderStore` / `CodexProviderStore` 流出；VPN 状态在 `VpnManager`。视图不自行开 Timer 做文件 I/O。
- **I/O 边界** — 文件扫描、SQLite、网络请求放在 `Utils/`，在后台队列执行。
- **发布克制** — `@Published` 赋值前做 Equatable 比较，避免无效重渲染。

### UI

- **设计 token** — 颜色、字体、间距、圆角、动画统一使用 `Theme/Theme.swift`。
- **按钮样式** — 动作按钮一律 `ActionButton`，按**用途**传参：`tone:` 说这是什么控件（默认 `.sparkle` 深色板；`.neutral` 用在不能让卡片破洞的地方；`.accent` 是本页主操作；`.destructive` 只给销毁性动作），`emphasis: .primary` 表示它是本页的默认动作。不要再用已删除的 `adaptiveGlassButton()`，也不要写 `.buttonStyle(.glass)` / `.bordered`。页头带里的控件用 `.buttonStyle(.plain)` + `.headerControl()`。
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
- 用户可见行为变更时，更新 [docs/CHANGELOG.md](docs/CHANGELOG.md) 的 `[Unreleased]` 段（约定见 [docs/VERSIONING.md](docs/VERSIONING.md)）。

---

## Pull Request

1. 从 `main` 拉取最新代码，在功能分支上开发。
2. 填写 [.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md)。
3. 确保 CI 通过（`macos-26` runner + `CLAUDEBAR_SKIP_INSTALL=1`，含 `make test`）。
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
