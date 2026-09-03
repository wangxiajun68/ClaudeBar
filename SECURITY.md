# Security Policy

## 支持范围

| 范围 | 说明 |
|------|------|
| 代码分支 | 当前 `main` |
| 发行版本 | [最新 GitHub Release](https://github.com/wangxiajun68/ClaudeBar/releases/latest) |

本应用为 ad-hoc 签名、面向本机使用，**不对历史版本提供长期安全补丁**。请始终使用最新 Release。

---

## 报告漏洞

请通过以下方式**私下**报告安全问题：

1. GitHub 仓库 **Security → Advisories → Report a vulnerability**
2. 或联系仓库所有者

**请勿**在公开 Issue、PR 或讨论区粘贴：

- API key、access token、session cookie
- 完整 `~/.claude/settings.json`、`config.toml`、`auth.json`
- 会话 transcript 或代理抓包中的敏感正文

报告时请尽量包含：受影响版本、复现步骤、影响范围、建议修复思路。

---

## 数据边界

ClaudeBar 是**纯本地**应用：读取本机配置与会话文件，**不上传**到任何远程服务器。

| 数据 | 访问方式 | 说明 |
|------|----------|------|
| Claude Code 配置与会话 | 只读（切换时写 `settings.json`） | `~/.claude/` |
| Cursor 状态库 | 只读 | `state.vscdb`、项目目录 |
| Codex rollout | 只读（切换时写 `config.toml` / `auth.json`） | `~/.codex/` |
| 供应商列表 | 读写 | `~/.claude/claude-bar-*.json` |
| 用量索引 / 日志 | 读写 | `~/Library/Application Support/ClaudeBar/` |
| Codex 本地代理 | 仅 `127.0.0.1` | 用户显式开启；勿暴露到公网 |

构建产物（DMG / zip）**不包含**任何用户密钥。请勿将个人 `~/.claude`、`~/.codex` 目录提交进 Git 仓库。

---

## 依赖与供应链

- **零第三方运行时依赖**，仅链接 Apple 系统框架与 `libsqlite3`。
- CI 使用 GitHub Actions 官方 `macos-26` runner；依赖项见 [dependabot.yml](.github/dependabot.yml)。

---

## 披露时间线

我们会在确认漏洞后尽快修复，并在修复版本发布后通过 GitHub Security Advisory 公开说明（致谢报告者，除非您要求匿名）。
