**[English](README.en.md)** | **中文**

<div align="center">

<img src="Sources/AppIcon-1024.png" width="96" alt="ClaudeBar">

# ClaudeBar

**macOS 菜单栏 — 多 Agent 模型切换、会话监控、用量统计与本机 LLM 代理抓包。**

[![CI](https://github.com/wangxiajun68/ClaudeBar/actions/workflows/ci.yml/badge.svg)](https://github.com/wangxiajun68/ClaudeBar/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/wangxiajun68/ClaudeBar?include_prereleases&label=release)](https://github.com/wangxiajun68/ClaudeBar/releases)
[![macOS](https://img.shields.io/badge/macOS-15%2B-black?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift&logoColor=white)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[**下载最新版**](https://github.com/wangxiajun68/ClaudeBar/releases/latest)

</div>

ClaudeBar 面向同时使用 Claude Code、Cursor 与 Codex 的开发者。数据全部留在本机，不上传配置与密钥。

## 安装

| 系统 | macOS 15+ · Apple Silicon (`arm64`) |
| 方式 | [Releases](https://github.com/wangxiajun68/ClaudeBar/releases) 下载 DMG → 拖入 Applications |

```bash
# Gatekeeper 拦截时
xattr -cr /Applications/ClaudeBar.app && open /Applications/ClaudeBar.app
```

## 核心功能

<table>
  <tr>
    <td width="52%" align="center">
      <img src="docs/screenshots/main-window.png" alt="主窗口" width="100%">
    </td>
    <td valign="top">

**LLM 本地代理** — `127.0.0.1` 转发请求，Chat / Responses 协议桥接；开启流量记录后可检查对话、工具调用与原始报文。

**模型切换** — Claude Code 与 Codex 配置统一管理，一键激活写回 `settings.json` / `config.toml`。

**会话 · 用量 · 资源** — 三端会话聚合、Token 日/月统计、CPU / GPU / 内存归因。

    </td>
  </tr>
  <tr>
    <td align="center">
      <img src="docs/screenshots/menubar-popup.png" alt="菜单栏" width="88%">
    </td>
    <td valign="top">

**菜单栏 Popup** — 模型切换、会话巡检、资源概览与用量，无需打开主窗口。

    </td>
  </tr>
  <tr>
    <td align="center">
      <img src="docs/screenshots/widget.png" alt="小组件" width="72%">
    </td>
    <td valign="top">

**桌面 Widget** — 当日 Token 总量与活跃会话一览。

    </td>
  </tr>
</table>

### 快速上手

| 场景 | 路径 |
|------|------|
| **抓包调试** | 设置 → 本地代理 → 模型卡开流量记录 → **流量** |
| **切换模型** | **模型** 页或菜单栏 popup 点击激活 → 新开终端会话 |
| **恢复会话** | **会话** 页或 popup 点击卡片 |
| **全局跳转** | 任意页面 `⌘K` 搜索页面 / 会话 / 模型 |
| **第三方接入** | Base URL → `http://127.0.0.1:<port>/v1`（密钥由代理注入） |

## 数据与隐私

| 来源 | 路径 | 访问 |
|------|------|------|
| Claude Code | `~/.claude/` | 只读（切换时写 `settings.json`） |
| Codex | `~/.codex/` | 只读（切换时写 `config.toml`） |
| Cursor | `~/Library/.../state.vscdb` | 只读 |
| 代理抓包 | `~/Library/Application Support/ClaudeBar/logs/` | 流量记录时写入 |

## 从源码构建

```bash
git clone https://github.com/wangxiajun68/ClaudeBar.git && cd ClaudeBar && make build
```

贡献指南见 [CONTRIBUTING.md](CONTRIBUTING.md) · 发版流程见 [docs/RELEASING.md](docs/RELEASING.md) · 排障见 [FAQ](docs/FAQ.md)

## License

[MIT](LICENSE)
