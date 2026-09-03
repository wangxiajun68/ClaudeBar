<div align="center">

<img src="Sources/AppIcon-1024.png" width="96" alt="ClaudeBar">

# ClaudeBar

**macOS 菜单栏应用 — 统一管理 Claude Code、Cursor 与 Codex 的供应商、会话与用量。**

[![CI](https://github.com/wangxiajun68/ClaudeBar/actions/workflows/ci.yml/badge.svg)](https://github.com/wangxiajun68/ClaudeBar/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/wangxiajun68/ClaudeBar?include_prereleases&label=release)](https://github.com/wangxiajun68/ClaudeBar/releases)
[![macOS](https://img.shields.io/badge/macOS-15%2B-black?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift&logoColor=white)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[**Download latest release**](https://github.com/wangxiajun68/ClaudeBar/releases/latest)

</div>

<p align="center">
  <img src="docs/images/overview.png" alt="ClaudeBar overview" width="920">
</p>

ClaudeBar 面向同时运行多家 AI 编程 Agent 的开发者：在菜单栏完成供应商切换，在主窗口查看会话状态、token 消耗与本机资源占用，并通过本地代理桥接 Codex 协议。

## 安装

从 [Releases](https://github.com/wangxiajun68/ClaudeBar/releases) 下载 `ClaudeBar-<version>-macOS-arm64.dmg`，打开后将 **ClaudeBar** 拖入 **Applications**。

| | |
|---|---|
| 系统 | macOS 15 (Sequoia) 或更高 |
| 架构 | Apple Silicon (`arm64`) |

应用为 ad-hoc 签名，未经 Apple 公证。若 Gatekeeper 拦截：

```bash
xattr -cr /Applications/ClaudeBar.app
open /Applications/ClaudeBar.app
```

每个 Release 附带 `.sha256` 校验文件。zip 包仅供脚本/自动化场景，日常使用请选 DMG。

## 功能

| | |
|---|---|
| **供应商切换** | 管理 Claude Code 与 Codex 配置（base URL、模型、密钥），激活时写回 `settings.json` / `config.toml`；支持两套配置互导。 |
| **会话监控** | Claude Code（PID + transcript）、Cursor（`state.vscdb`）、Codex（rollout JSONL）统一展示：状态、上下文水位、当前工具、busy→idle 通知。 |
| **用量统计** | 持久化日聚合索引，按模型分解；桌面 Widget 展示当日概览。 |
| **Codex 代理** | 本机 `127.0.0.1` 协议桥接，流量检查器与访问日志。 |
| **系统资源** | 整机 CPU / GPU / 内存，按 ClaudeBar、Claude Code、Cursor、Codex 归因。 |
| **命令面板** | `⌘K` 模糊搜索页面、会话与供应商。 |

## 数据与隐私

所有数据保留在本机，不上传配置、会话或 API 密钥。

| 来源 | 路径 | 访问 |
|------|------|------|
| Claude Code 会话 | `~/.claude/sessions/`、`~/.claude/projects/` | 只读 |
| Claude Code 用量 | `~/.claude/projects/**/*.jsonl` | 只读（索引） |
| Cursor | `~/Library/.../state.vscdb`、`~/.cursor/projects/` | 只读 |
| Codex | `~/.codex/sessions/**/*.jsonl` | 只读 |
| 当前供应商 | `~/.claude/settings.json`、`~/.codex/config.toml` | 切换时写入 |

## 从源码构建

面向贡献者与高级用户。普通安装请用 [Releases](https://github.com/wangxiajun68/ClaudeBar/releases) 中的 DMG。

```bash
git clone https://github.com/wangxiajun68/ClaudeBar.git
cd ClaudeBar
make build    # 编译并安装到 /Applications
```

详见 [CONTRIBUTING.md](CONTRIBUTING.md) 与 [docs/RELEASING.md](docs/RELEASING.md)（维护者发版流程）。

## 文档

| | |
|---|---|
| [Contributing](CONTRIBUTING.md) | 本地开发、分支与 PR |
| [文档索引](docs/README.md) | 设计与技术参考 |
| [FAQ](docs/FAQ.md) | 常见问题 |
| [Security](SECURITY.md) | 漏洞报告 |

## License

[MIT](LICENSE)
