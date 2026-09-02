# Security Policy

## 支持范围

请对当前 `main` 与最新 GitHub Release 报告安全问题。本应用 ad-hoc 签名、面向本机使用，不提供长期多版本补丁。

## 报告方式

请通过 GitHub 仓库的 **Security → Advisories** 私下报告，或联系仓库所有者。不要在公开 Issue 中粘贴 API key、token、会话 transcript 或 `settings.json`。

## 数据边界

- Axon 读取本机 Claude Code / Cursor / Codex 的配置与会话文件，**不把这些文件上传到任何服务器**。
- 供应商切换会写回 `~/.claude/settings.json`（Claude Code）以及 Codex 的 `~/.codex/config.toml` / `auth.json`（在用户主动切换时）。
- 可选的 Codex 本地代理只监听 `127.0.0.1`，用于本机协议桥接与抓包；请勿把该端口暴露到公网。
- 构建产物不含密钥。请勿把个人 `~/.claude`、`~/.codex` 目录提交进仓库。
