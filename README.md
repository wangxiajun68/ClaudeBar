**[English](README.en.md)** · **中文**

<h1>
  <img src="Sources/AppIcon-1024.png" alt="ClaudeBar" width="64" height="64" align="middle">
  ClaudeBar
</h1>

<p align="center">
  <strong>一个菜单栏，装下你的整个 AI 工作台。</strong><br>
  VPN · 本地 LLM 代理 · 多 Agent 模型切换 · 会话与用量监控 — 常驻 macOS 顶栏，即点即用。
</p>

![CI](https://github.com/wangxiajun68/ClaudeBar/actions/workflows/ci.yml/badge.svg)![Release](https://img.shields.io/github/v/release/wangxiajun68/ClaudeBar?include_prereleases&label=release)![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple&logoColor=white)![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift&logoColor=white)![MIT](https://img.shields.io/badge/license-MIT-green)

**[下载最新版](https://github.com/wangxiajun68/ClaudeBar/releases/latest)**

## 为什么需要 ClaudeBar

AI 编程工作流正在被越来越多的独立工具割裂：VPN 客户端、抓包代理、模型切换器、会话查看器……每个都有自己的窗口、托盘图标和启动成本，而它们服务的其实是同一段工作流。

**ClaudeBar 把这些工具收敛进一个菜单栏应用。** 常驻顶栏、零窗口占用，任何时刻点击图标即可：切换 Claude Code / Codex 的供应商与模型、拉起或检查 VPN 隧道、查看本机代理转发的每一帧对话、浏览三端会话与 Token 用量 —— 全部不需要单独启动任何工具，也不打断当前终端里的工作。

一句话：**让基础设施退到菜单栏，把注意力还给工作本身。**

## 它能做什么

- **VPN** — 捆绑 mihomo：订阅、选节点、测延迟、系统代理；菜单栏显示实时速率。
- **LLM 本地代理** — `127.0.0.1` 转发请求，Chat / Responses 协议桥接。Claude Code 与 Codex 各走当前供应商；第三方可另选上游。开启流量记录后可检查对话、工具调用、图片与原始报文。
- **区域截图** — ⌘⇧A 拉框复制 / 保存 / 钉住。
- **模型切换** — Claude Code 与 Codex 各自维护供应商与模型，互不同步；一键激活分别写回 `settings.json` / `config.toml`。需要拷贝时到管理页手动导入。
- **会话 · 用量 · 资源** — 三端会话聚合、Token 日/月统计、CPU / GPU / 内存归因。
- **菜单栏 Popup** — 模型切换、会话巡检、资源概览与用量，无需打开主窗口。
- **桌面 Widget** — 当日 Token 总量与活跃会话一览。

## 界面

![流量检查器](docs/screenshots/traffic.png)

*流量检查器 · 简洁视图：连续工具调用与系统提示默认折叠，可按关键词搜索对话。*

| 主窗口                                      | 菜单栏 Popup                                  | 桌面 Widget                           |
| ---------------------------------------- | ------------------------------------------ | ----------------------------------- |
| ![主窗口](docs/screenshots/main-window.png) | ![菜单栏](docs/screenshots/menubar-popup.png) | ![小组件](docs/screenshots/widget.png) |

## 快速上手

| 场景        | 路径                                                        |
| --------- | --------------------------------------------------------- |
| **VPN**   | **VPN** 页添加订阅并开启系统代理；菜单栏可切换节点 |
| **抓包调试**  | 设置 → 本地代理 → 模型卡开流量记录 → **流量**                             |
| **切换模型**  | **模型** 页分栏选择 Claude Code / Codex，或菜单栏 popup 点击激活 → 新开终端会话 |
| **恢复会话**  | **会话** 页或 popup 点击卡片                                      |
| **全局跳转**  | 任意页面 `⌘K` 搜索页面 / 会话 / 模型                                  |
| **第三方接入** | Base URL → `http://127.0.0.1:<port>/v1`；设置 → 本地代理 可另选第三方上游          |
| **区域截图**  | ⌘⇧A（设置里可关） |

## 安装

需要 **macOS 15+**、Apple Silicon (`arm64`)。从 [Releases](https://github.com/wangxiajun68/ClaudeBar/releases) 下载 DMG，拖入 Applications。

Gatekeeper 拦截时：

```bash
xattr -cr /Applications/ClaudeBar.app && open /Applications/ClaudeBar.app
```

## 数据与隐私

ClaudeBar 以「只读优先」原则访问你的配置：除切换模型时的显式写回外，不修改任何工具的数据。

| 来源          | 路径                                              | 访问                       |
| ----------- | ----------------------------------------------- | ------------------------ |
| Claude Code | `~/.claude/`                                    | 只读（切换时写 `settings.json`） |
| Codex       | `~/.codex/`                                     | 只读（切换时写 `config.toml`）   |
| Cursor      | `~/Library/.../state.vscdb`                     | 只读                       |
| 代理抓包        | `~/Library/Application Support/ClaudeBar/logs/` | 流量记录时写入                  |
| VPN         | `~/Library/Application Support/ClaudeBar/vpn/`  | 订阅与内核配置（仅本机）             |

## 从源码构建

```bash
git clone https://github.com/wangxiajun68/ClaudeBar.git && cd ClaudeBar && make build
```

贡献指南见 [CONTRIBUTING.md](CONTRIBUTING.md) · 版本与发版见 [docs/VERSIONING.md](docs/VERSIONING.md)、[docs/RELEASING.md](docs/RELEASING.md) · 更新日志见 [docs/CHANGELOG.md](docs/CHANGELOG.md) · 排障见 [FAQ](docs/FAQ.md)

## License

[MIT](LICENSE)
