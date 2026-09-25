**[English](README.en.md)** · **中文**

<h1>
  <img src="Sources/AppIcon-1024.png" alt="ClaudeBar" width="64" height="64" align="middle">
  ClaudeBar
</h1>

<p align="center">
  <strong>点一下菜单栏，整条 AI 流水线都在手里。</strong><br>
  切模型 · 看会话 · 量 Token · 管 VPN · 拦流量 — 全部住在 macOS 顶栏。
</p>

<p align="center">
  <a href="https://github.com/wangxiajun68/ClaudeBar/actions/workflows/ci.yml"><img src="https://github.com/wangxiajun68/ClaudeBar/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/wangxiajun68/ClaudeBar/releases/latest"><img src="https://img.shields.io/github/v/release/wangxiajun68/ClaudeBar?include_prereleases&label=release" alt="Release"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-black?logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift&logoColor=white" alt="Swift 5.9+">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
</p>

<p align="center">
  <a href="https://github.com/wangxiajun68/ClaudeBar/releases/latest"><strong>下载最新版 →</strong></a>
</p>

## 界面

概览是一块仪表盘：CPU 芯片、GPU 柱、内存液面、硬盘、Wi-Fi / 蓝牙、左右风扇；下面是当前供应商、会话和 Token。菜单栏则是同一套事实的压缩版 — 三格切换 CC / Codex / VPN，再往下是活着的会话和当月热力。

**主窗口** · 冰面 / 石墨宫格。颜色只出现在图表里。

![主窗口概览](docs/screenshots/main-window.png)

**菜单栏** · 点图标即出。切模型、巡会话、看用量，不用开窗口。

![菜单栏 popup](docs/screenshots/menubar-popup.png)

## 它解决什么

Claude Code、Codex、Cursor 同时在跑的时候，工作流会被拆成一堆独立工具：VPN 客户端、抓包代理、模型切换器、会话列表。每个都占一个托盘图标，切一次就要离开终端。

ClaudeBar 把这些收进**一个**菜单栏应用。顶栏常驻，主窗口按需打开。点一下就能做刚才那件事，然后回去写代码。

## 七件事

**切换。** Claude Code 与 Codex 各有一份供应商。激活分别写回 `~/.claude/settings.json` 和 `~/.codex/config.toml`，互不覆盖。菜单栏三格：CC、Codex、VPN 节点。

**转发。** 本机代理听 `127.0.0.1`（默认 15721），Chat / Responses 互转。Claude Code 与 Codex 跟当前模型走；第三方客户端可另选上游，不改那两份配置文件。开了流量记录，对话、工具调用、图片和原始报文都在「流量」页。

**隧道。** 捆绑 mihomo。订阅、选节点、测延迟、系统代理 / TUN。菜单栏显示 ↓↑ 实时速率；出站路径是 `日本 › 电信` 这种面包屑，不是装饰线。

**现场。** 会话页把 Claude Code、Cursor、Codex 和其他 CLI 收成一张牌：上下文条、当前工具、心跳、CPU / 内存。双击卡片就能在终端或 Cursor 里接上。

**用量。** 只统计模型 Token。日 / 月 / 年热力图、CC / Codex / 第三方来源柱、输入·命中·写入·输出构成。同一周期再按厂商刊例价折算花费（56 条价目，人民币与美元分列不换算，算不出钱的模型明写原因）。VPN 剩余流量留在 VPN 页，不混进来。

**连接器。** 一个页面看清三家客户端装了哪些 Skills、MCP 服务器和插件。共享的 Agent CLI（`lark-cli`、`gh`、`mcporter`…）单独归到「本机共享」，并按 Skill 的 `requires.bins` 与 MCP 的 `command` 把关联能力挂到它名下。Codex 的 MCP 开关只改 `config.toml` 里那一行；独立的 Skill 目录做可逆移库；详情页能读 `SKILL.md`、列 MCP 工具（不发调用）。只读扫描，不启动服务。

**本机。** 概览 2×3：负载、温度写在 CPU / GPU 说明里、硬盘占用、Wi-Fi / 蓝牙 / 有线、两只可点的风扇（自动 / 最大）。浅色是冰 `#EEF3F8`，深色是石墨 `#16181C`，不跟系统外观走。

另外：⌘⇧A 区域截图（复制 / 保存 / 钉住），⌘K 跳页面 / 会话 / 模型，桌面 Widget 看当日 Token。

## 怎么用

| 你想… | 走这里 |
| --- | --- |
| 换模型 | 菜单栏 CC / Codex 格，或主窗口 **模型** 页。新开一个终端会话才生效。 |
| 换节点 | 菜单栏 VPN 格，或 **VPN** 页马赛克。 |
| 看对话有没有打到代理 | 设置 → 本地代理 → 模型卡打开流量记录 → **流量** |
| 让第三方走同一条上游 | Base URL `http://127.0.0.1:<端口>/v1`，设置里给第三方另选供应商 |
| 接上刚才那次会话 | **会话** 页或 popup 里点卡片 |
| 截一块屏幕 | ⌘⇧A（设置可关） |

## 安装

**macOS 15+**，Apple Silicon。从 [Releases](https://github.com/wangxiajun68/ClaudeBar/releases) 下载 DMG，拖进 Applications。

Gatekeeper 拦住时：

```bash
xattr -cr /Applications/ClaudeBar.app && open /Applications/ClaudeBar.app
```

## 它碰哪些文件

只读优先。除了你主动切换模型，不会改各工具自己的数据。

| 谁 | 路径 | 权限 |
| --- | --- | --- |
| Claude Code | `~/.claude/` | 读；切换时写 `settings.json` |
| Codex | `~/.codex/` | 读；切换时写 `config.toml` |
| Cursor | `~/Library/.../state.vscdb` | 只读 |
| 代理抓包 | `~/Library/Application Support/ClaudeBar/logs/` | 开了流量记录才写 |
| VPN | `~/Library/Application Support/ClaudeBar/vpn/` | 订阅与内核配置，只留本机 |

## 从源码构建

```bash
git clone https://github.com/wangxiajun68/ClaudeBar.git
cd ClaudeBar
make build
```

[贡献](CONTRIBUTING.md) · [版本](docs/VERSIONING.md) · [发版](docs/RELEASING.md) · [更新日志](docs/CHANGELOG.md) · [FAQ](docs/FAQ.md)

## License

[MIT](LICENSE)

界面图标取自 [Lucide](https://lucide.dev)（ISC），随应用打包于 `Resources/Lucide.txt`；VPN 内核 [mihomo](https://github.com/MetaCubeX/mihomo) 为构建时下载的 sidecar，不进 Git。
