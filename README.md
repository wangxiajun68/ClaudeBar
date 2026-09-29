**[English](README.en.md)** · **中文**

<p align="center">
  <img src="Sources/AppIcon-1024.png" alt="ClaudeBar" width="96">
</p>

<h1 align="center">ClaudeBar</h1>

<p align="center">
  菜单栏里的 AI 工作台。<br>
  同时跑着 Claude Code、Codex 和 Cursor 时，切模型、看会话、量 Token、管隧道，都在 macOS 顶栏。
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

<p align="center">
  <a href="docs/promo/claudebar.mp4">
    <img src="docs/promo/claudebar.gif" alt="ClaudeBar 介绍影片" width="920">
  </a>
</p>

<p align="center">
  <a href="docs/promo/claudebar.mp4">观看完整影片</a>
</p>

---

Claude Code、Codex、Cursor 一起开着的时候，旁边通常还挤着 VPN、抓包代理和模型切换器。每个占一个托盘图标，每次切换都把你拉出终端。

ClaudeBar 把这些收成一个菜单栏应用。顶栏常驻，主窗口按需打开。点一下做完刚才那件事，再回到代码里。

## 能力

| | |
| --- | --- |
| **切换** | Claude Code 与 Codex 各有一份供应商。激活分别写回 `~/.claude/settings.json` 和 `~/.codex/config.toml`，互不覆盖。菜单栏三格是 CC、Codex、Cursor 额度；VPN 节点是状态行上的一颗药丸。 |
| **会话** | Claude Code、Cursor、Codex 和其他 CLI 收成一张牌：上下文、当前工具、心跳、CPU 与内存。双击卡片，在终端或 Cursor 里接上。 |
| **用量** | 只统计模型 Token。日 / 月 / 年 / 全部热力，以及输入、缓存命中、写入、输出。花费按刊例价估算，人民币与美元分列；**Cursor 那一行是它自己接口回传的实际扣费**，与估算分开，永不相加。 |
| **转发** | 本机代理听 `127.0.0.1`（默认 15721），Chat / Responses 互转。Claude Code 与 Codex 跟当前模型走；第三方客户端可另选上游。流量页留下对话、工具调用、图片和原始报文。 |
| **隧道** | 捆绑 mihomo。订阅、选节点、测延迟、系统代理或 TUN。菜单栏显示实时速率。VPN 页把内核的每条 TCP 连接收成域名、命中规则和出口。 |
| **连接器** | 一个页面看清三家客户端装了哪些 Skills、MCP 和插件。只读扫描，不启动服务。 |
| **本机** | 概览是冰面或石墨宫格：负载、温度、磁盘、网络、两只风扇，以及能源流向。浅色 `#EEF3F8`，深色 `#16181C`，不跟系统外观走。有内置电池的机器可以设充电上限。 |

另外：⌘K 跳页面、会话或模型；⌘⇧A 区域截图；桌面小组件看当日 Token；有刘海的屏幕上，灵动岛收着正在跑的 Agent。

## 界面

主窗口是仪表盘。菜单栏是同一套事实的压缩版。

<p>
  <img src="docs/screenshots/main-window.png" alt="主窗口概览" width="920">
</p>

<p>
  <img src="docs/screenshots/menubar-popup.png" alt="菜单栏" width="420">
</p>

## 安装

需要 **macOS 15+**，Apple Silicon。从 [Releases](https://github.com/wangxiajun68/ClaudeBar/releases/latest) 下载 DMG，拖进「应用程序」。

Gatekeeper 拦住时：

```bash
xattr -cr /Applications/ClaudeBar.app && open /Applications/ClaudeBar.app
```

| 你想… | 走这里 |
| --- | --- |
| 换模型 | 菜单栏 CC / Codex 格，或主窗口 **模型**。新开一个终端会话后生效。 |
| 换节点 | 菜单栏 VPN 格，或 **VPN** 页。 |
| 看对话有没有打到代理 | 设置 → 本地代理 → 打开流量记录 → **流量** |
| 让第三方走同一条上游 | Base URL `http://127.0.0.1:<端口>/v1`，设置里另选供应商 |
| 接上刚才那次会话 | **会话** 页，或菜单栏里的卡片 |
| 截一块屏幕 | ⌘⇧A（设置里可关） |

## 它碰哪些文件

只读优先。除了你主动切换模型，不会改各工具自己的数据。ClaudeBar 不做推理，代理只转发到你已经配置的上游。

| 谁 | 路径 | 权限 |
| --- | --- | --- |
| Claude Code | `~/.claude/` | 读；切换时写 `settings.json` |
| Codex | `~/.codex/` | 读；切换时写 `config.toml` |
| Cursor | `~/Library/.../state.vscdb` | 只读 |
| 代理抓包 | `~/Library/Application Support/ClaudeBar/logs/` | 打开流量记录才写 |
| VPN | `~/Library/Application Support/ClaudeBar/vpn/` | 订阅与内核配置，只留本机 |

会向系统要权限的能力（小组件、通知、截图、自动化、蓝牙、Wi-Fi 名称、定位、Cursor 会话）默认关闭，在设置里逐项打开。

## 从源码构建

```bash
git clone https://github.com/wangxiajun68/ClaudeBar.git
cd ClaudeBar
make build
```

[贡献](CONTRIBUTING.md) · [版本](docs/VERSIONING.md) · [发版](docs/RELEASING.md) · [更新日志](docs/CHANGELOG.md) · [FAQ](docs/FAQ.md)

## License

[MIT](LICENSE)

界面图标取自 [Lucide](https://lucide.dev)（ISC），随应用打包于 `Resources/Lucide.txt`。VPN 内核 [mihomo](https://github.com/MetaCubeX/mihomo) 以 `.xz` 压缩档内置，首次启动时在应用内解压。
