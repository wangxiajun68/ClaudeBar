<div align="center">

# Axon (ClaudeBar)

**一款 macOS 菜单栏应用，把多供应商切换、Agent 会话监控与 token 用量统计装进一块 Liquid Glass 面板。**

监控 Claude Code · Cursor · Codex · WorkBuddy · OpenClaw —— 五路 Agent 信号，一个入口。

[![macOS](https://img.shields.io/badge/macOS-26%2B%20(Tahoe)-black?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift&logoColor=white)](https://swift.org)
[![Architecture](https://img.shields.io/badge/arch-arm64--apple--silicon-blue)](#系统要求)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

</div>

---

## 它解决什么问题

同时使用多家 Claude Code 兼容服务商（DeepSeek / Kimi / GLM / Anthropic 直连…）并开着一堆 Agent 会话的开发者，每天要回答三个问题：

1. **现在用的哪个供应商？切换要改 JSON？** → Axon 一键切换并写回 `~/.claude/settings.json`，余额直接显示。
2. **哪个会话还在跑？上下文还剩多少？Claude 跑完了吗？** → 五个来源的会话实时同屏：上下文水位、正在执行的工具、子 Agent 树、busy→idle 系统通知。
3. **今天烧了多少 token？在哪个模型上烧的？** → 按日/月/年聚合所有工具的 token 消耗，按模型分解，桌面 Widget 常驻概览。

## 功能一览

| 能力 | 说明 |
|------|------|
| 🔌 **供应商切换** | 一键切换 Provider / Model，写入 `settings.json`；余额拉取（DeepSeek 等）；供应商/模型编辑器带校验 |
| 📡 **五源会话监控** | Claude Code（PID 文件 + transcript tail）、Cursor（state.vscdb）、Codex / WorkBuddy / OpenClaw（rollout JSONL）——统一为状态点 + 上下文水位 + 活动行 |
| 📊 **用量统计** | 日/月/年/自定义区间，全部工具按模型并集聚合；增量文件缓存 + mtime 预过滤 + 并行解析；Cursor 9.9GB DB 走 header 指纹零 I/O 快路径 |
| 🔔 **空闲通知** | 任一会话 busy→idle 边沿触发系统通知（按工具区分标题），点按直接在终端恢复该会话 |
| 🧩 **桌面 Widget** | WidgetKit systemLarge：当日 token、供应商/模型、余额、会话列表（App Group 快照驱动） |
| 🎨 ** Liquid Glass UI** | macOS 26 原生 `glassEffect` 宫格瓦片；楷体系古典显示字体（内置霞鹜文楷 GB + Palatino）；⌘K 命令面板 |
| ⚡ **性能克制** | 不变数据不发布（Equatable 跳过）、动画按需挂载、零第三方依赖、二进制直编（无 Xcode 工程） |

## 界面

- **菜单栏 popup** — 毛玻璃快速面板：供应商宫格、会话卡（含心跳波形）、用量分解，失焦自动收起。
- **主窗口** — 顶部导航 + 五个页面：概览 / 会话 / 供应商 / 用量 / 设置，全部宫格化瓦片。
- **Widget** — 桌面常驻当日概览。

## 快速开始

```bash
git clone https://github.com/wangxiajun68/ClaudeBar.git
cd ClaudeBar
bash Sources/build.sh        # 编译 → 签名 → 安装到 /Applications → 注册 Widget
open /Applications/ClaudeBar.app
```

### 系统要求

- macOS 26 (Tahoe) 或更高，Apple Silicon (arm64)
- Xcode Command Line Tools（swiftc；无需打开 Xcode 工程——本项目没有工程文件）

### 首次使用

1. 菜单栏点击 Axon 图标 → 供应商区添加你的服务商（名称 / baseURL / API key / 模型列表）。
2. 一键设为默认 —— `~/.claude/settings.json` 立即更新，Claude Code 下次调用即生效。
3. 会话与用量无需配置，自动发现本机的 Claude Code / Cursor / Codex / WorkBuddy / OpenClaw。

## 数据来源（全部只读）

| 来源 | 路径 | 方式 |
|------|------|------|
| Claude Code 会话 | `~/.claude/sessions/`、`~/.claude/projects/` | PID 文件 + transcript tail 扫描 |
| Claude Code 用量 | `~/.claude/projects/**/*.jsonl` | 增量缓存 + 并行聚合 |
| Cursor | `~/Library/.../state.vscdb` + `~/.cursor/projects/` | 只读 SQLite + transcript tail |
| Codex | `~/.codex/sessions/**/*.jsonl` | rollout 解析 |
| WorkBuddy | `~/.workbuddy/projects/**/*.jsonl` | providerData.usage 解析 |
| OpenClaw | `~/.openclaw/agents/*/sessions/*.jsonl` | message.usage 解析 |

Axon **从不写入**上述任何路径；唯一的写入目标是 Claude Code 自己的 `settings.json`（供应商切换，保留未知字段）。

## 项目结构

```
Sources/
├── ClaudeBar/
│   ├── ClaudeBarApp.swift          # 入口 + AppDelegate（字体注册、通知路由）
│   ├── MenuBarController.swift     # NSStatusItem + 非激活玻璃面板
│   ├── MainWindowController.swift  # 主窗口
│   ├── Models/                     # ProviderStore（状态中枢）、配置、快照、通知
│   ├── Utils/                      # 五源监控器、用量聚合、终端拉起
│   ├── Views/
│   │   ├── Pages/                  # 主窗口五页
│   │   ├── Popup/                  # 菜单栏面板分区
│   │   └── Shared/                 # Tile 宫格体系、卡片、命令面板
│   └── Theme/                      # 设计令牌：色彩/字阶/间距/玻璃/动画
├── Widget/                         # WidgetKit appex（独立编译）
└── build.sh                        # swiftc 直编全流程
docs/                               # 设计文档（为什么）+ 技术文档（怎么做）
```

## 文档

文档分两层，入口在 [docs/README.md](docs/README.md)：

- **设计层**（[docs/design/](docs/design/)）— 产品定位、架构取舍、交互与视觉规范
- **技术层**（[docs/technical/](docs/technical/)）— 数据访问、状态管理、构建签名、性能、扩展指南
- **变更记录** — [docs/CHANGELOG.md](docs/CHANGELOG.md)

## 构建

`Sources/build.sh` 一条命令完成：主 app 编译 → Widget appex 编译 → Info.plist / entitlements 生成 → ad-hoc 签名（自底向上，不用 `--deep`）→ 安装 `/Applications` → Widget 注册。

常用变体：

```bash
bash Sources/build.sh               # 全量构建 + 安装
killall ClaudeBar; open /Applications/ClaudeBar.app   # 重启到新构建
```

技术细节见 [docs/technical/07-build-and-signing.md](docs/technical/07-build-and-signing.md)。

## 设计决策

- **零第三方依赖** — 仅系统框架 + libsqlite3；供应链面为零。
- **swiftc 直编，无 Xcode 工程** — 构建即一个 bash 脚本，可读可审计。
- **轮询驱动但发布克制** — 2.5s 轮询全部 off-main；Equatable 不变即不发布；空闲时 UI 零失效。
- **原生 Liquid Glass** — 不自绘模糊，直接用 macOS 26 `glassEffect`。

## License

[MIT](LICENSE)
