**[English](README.en.md)** · **中文**

<p align="center">
  <img src="Sources/AppIcon-1024.png" alt="ClaudeBar" width="96">
</p>

<h1 align="center">ClaudeBar</h1>

<p align="center">
  面向 AI 开发工作流的原生 macOS 工作台。<br>
  在菜单栏、灵动岛与桌面之间，统一管理模型、会话、用量与网络。
</p>

<p align="center">
  <a href="https://github.com/wangxiajun68/ClaudeBar/actions/workflows/ci.yml"><img src="https://github.com/wangxiajun68/ClaudeBar/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/wangxiajun68/ClaudeBar/releases/latest"><img src="https://img.shields.io/github/v/release/wangxiajun68/ClaudeBar?include_prereleases&label=release" alt="Release"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-black?logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-black" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
</p>

<p align="center">
  <a href="https://github.com/wangxiajun68/ClaudeBar/releases/latest"><strong>下载 macOS 版</strong></a>
</p>

https://github.com/user-attachments/assets/eb0dd190-6cbf-4349-a3c6-a799a273f89e

<p align="center">
  <a href="docs/promo/claudebar.mp4">下载高清原片（1080p · 66 秒）</a>
</p>

---

ClaudeBar 为使用 Claude Code、Codex 和 Cursor 的开发者提供统一的工作视图。通过菜单栏快速查看状态与切换模型，通过灵动岛跟踪 Agent 进度，通过桌面主窗口分析会话、用量和请求。应用采用 SwiftUI 与 AppKit 构建。

## 核心能力

| 模块 | 功能 |
| --- | --- |
| 模型与供应商 | 分别管理 Claude Code、Codex 的模型配置和上游供应商，保持两套配置独立。 |
| 会话监控 | 汇集客户端会话，查看运行状态、上下文使用和工具活动；支持返回终端或 Cursor 继续工作。 |
| 用量分析 | 按日、月、年及全部查看 Token 分布、来源、构成与活跃节奏；分别呈现费用估算和 Cursor 实际扣费。 |
| 本地代理 | 提供本机 API 入口与 Chat / Responses 协议转换；启用流量记录后，可检查对话、工具调用、图片及原始报文。 |
| VPN 与网络 | 内置 mihomo，支持订阅、节点选择、延迟测试、系统代理及 TUN；查看连接域名、匹配规则与出口。 |
| 连接器 | 集中查看 Skills、MCP、插件及共享 CLI，支持详情和各客户端可用的启停操作。 |
| Mac 状态 | 查看天气、CPU / GPU、内存、磁盘、网络、风扇与能源状态；支持内置电池机型的充电上限设置。 |

## 三种界面，一套工作流

- **菜单栏 Popup**：快速查看工作状态、模型、额度和会话，减少窗口切换。
- **灵动岛**：在支持的刘海屏幕上呈现 Agent 状态、完成提醒及展开详情。
- **桌面主窗口**：提供概览、模型、会话、用量、流量、VPN 和连接器等完整工作视图，支持浅色与深色外观。

### 工作概览

天气与问候、系统负载、能源流向和活跃会话共同构成桌面入口。

[![ClaudeBar 桌面概览](docs/promo/overview.png)](docs/promo/overview.png)

### 会话与用量

会话页集中展示上下文、工具活动与运行状态；用量页按时间范围呈现来源、构成和使用趋势。

[![ClaudeBar 会话监控](docs/promo/sessions.png)](docs/promo/sessions.png)

[![ClaudeBar 用量分析](docs/promo/usage.png)](docs/promo/usage.png)

> 宣传影片与以上图片由项目源码渲染，使用固定演示数据。模型、额度及费用仅用于展示界面，不代表实际账户数据。

## 安装与使用

**系统要求：macOS 15 或更高版本，Apple Silicon（arm64）。**

1. 从 [Releases](https://github.com/wangxiajun68/ClaudeBar/releases/latest) 下载 DMG。
2. 打开 DMG，将 ClaudeBar 拖入「应用程序」，随后启动应用。
3. 在模型页配置供应商与模型；按需要在设置中启用会话集成、代理和系统功能。

Claude Code 与 Codex 的模型切换分别写入各自配置文件。**切换后请新开终端会话，使新配置生效。** Cursor 在本项目中提供会话、用量与额度集成。

开启本地代理后，第三方客户端可使用 `http://127.0.0.1:<端口>/v1`，默认端口为 `15721`。流量查看需要先在设置中启用流量记录。⌘K 可快速跳转页面、会话和模型；启用区域截图后，可使用 ⌘⇧A。

安装拦截、权限及集成问题请参阅 [FAQ](docs/FAQ.md)。

## 数据与权限

ClaudeBar 从各客户端的本地数据中读取会话和用量。模型切换、连接器启停等操作会按对应客户端的机制更新配置；连接器支持范围见 [技术说明](docs/technical/16-connectors.md)。

| 数据来源或功能 | 主要路径与行为 |
| --- | --- |
| Claude Code | 读取 `~/.claude/`；切换模型时更新 `~/.claude/settings.json`。 |
| Codex | 读取 `~/.codex/`；切换模型时更新 `~/.codex/config.toml`。 |
| Cursor | 读取 `~/.cursor/projects/` 及 `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`；额度和账单通过 Cursor 接口获取。 |
| 代理记录 | 启用记录后写入 `~/Library/Application Support/ClaudeBar/logs/`。 |
| VPN | 内核、订阅与配置保存在 `~/Library/Application Support/ClaudeBar/vpn/`。 |

ClaudeBar 本身不执行模型推理。本地代理将请求转发至配置的上游；天气、额度、账单及订阅等功能会访问对应服务。连接器清单扫描不启动 MCP 服务，打开 MCP 详情时会连接服务并读取工具列表，不调用工具。

需要系统权限的功能在设置中配置，并按 macOS 提示授权。代理记录可能包含对话和请求内容，应按项目的数据管理要求使用。

**费用口径：** 模型费用按 Token 与刊例价估算，不能作为实际账单。Cursor 接口返回的实际扣费单独显示，并标明适用窗口；不同口径、时间范围和币种的金额不合并。

## 开发与构建

使用 macOS、Xcode Command Line Tools（含 Swift 编译器）及 Python 3。构建细节与依赖参见 [构建与签名](docs/technical/07-build-and-signing.md)。

```bash
git clone https://github.com/wangxiajun68/ClaudeBar.git
cd ClaudeBar
make ci
```

| 命令 | 结果 |
| --- | --- |
| `make ci` | 编译应用至 `.build/ClaudeBar.app`，不安装。 |
| `make build` | 编译、签名并安装至 `/Applications`。 |
| `make test` | 运行项目回归检查。 |
| `make package` | 在 `.build/dist/` 生成发布包。 |

宣传片的分镜、动效及生成流程见 [宣传片制作说明](docs/promo/prompt.md)。本地运行 `python3 Tools/serve-promo.py` 后，可访问 `http://127.0.0.1:8808/docs/promo/film.html` 查看章节播放器。

## 文档与贡献

[文档索引](docs/README.md) · [FAQ](docs/FAQ.md) · [更新日志](docs/CHANGELOG.md) · [贡献指南](CONTRIBUTING.md) · [安全报告](SECURITY.md) · [版本管理](docs/VERSIONING.md) · [发布流程](docs/RELEASING.md)

提交问题时请提供系统版本、应用版本、复现步骤及相关日志，并移除密钥、账号和对话中的敏感内容。

## 许可证

ClaudeBar 项目代码采用 [MIT License](LICENSE)。第三方组件与素材遵循各自许可证：界面图标使用 Lucide（ISC），其声明位于 [Lucide.txt](Sources/Licenses/Lucide.txt)；字体及其他素材声明见 [ASSET-LICENSES.md](Sources/ClaudeBar/Resources/ASSET-LICENSES.md)；VPN 内核的打包方式见 [mihomo 说明](vendor/mihomo/README.md)。
