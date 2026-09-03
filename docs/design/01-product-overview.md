# 产品概述

> ClaudeBar 设计文档 · §1
> 索引：[设计文档](README.md) · 相关：[顶层架构](02-architecture.md) · [文件结构](07-file-structure.md)

ClaudeBar 是一款 macOS 菜单栏应用，面向同时使用 **Claude Code**（CLI）、**Codex**（CLI / IDE）与 **Cursor**（IDE）的开发者。应用在一个统一界面里集中完成配置管理、会话观测与用量分析，并通过可选的本机代理打通 Codex 与多家上游协议差异。

## 定位

| 维度 | 说明 |
|------|------|
| 平台 | macOS 15+，Apple Silicon（`arm64`） |
| 分发 | 终端用户从 [GitHub Releases](https://github.com/wangxiajun68/ClaudeBar/releases) 下载 DMG 安装；见 [构建与分发](09-build-and-distribution.md) |
| 激活策略 | `.regular`（Dock 图标 + 主窗口），同时保留菜单栏 status item 与非激活 popup |
| 数据边界 | 读取本机 `~/.claude`、`~/.codex`、`~/.cursor`；不向用户未配置的上游发送流量 |

## 三大能力

### 1. 配置切换

一键切换 Claude Code 与 Codex 的 Provider / Model（API 地址、密钥、模型名、上下文窗口、推理档位等），并写入各自配置文件：

| 运行时 | 写入目标 |
|--------|----------|
| Claude Code | `~/.claude/settings.json` |
| Codex | `~/.codex/config.toml` + `~/.claude/claude-bar-codex-providers.json` |

Claude 与 Codex 供应商通过 `ProviderBridge` 联动：在主窗口「供应商」页选择预设或编辑配置时，两侧同步激活；popup 面板提供快速切换入口。

### 2. 会话监控

实时展示本机活跃会话，覆盖三条产品线：

| 来源 | 观测内容 |
|------|----------|
| Claude Code | 进程、transcript、上下文占用、当前工具、子 Agent / Workflow |
| Cursor | Composer 会话（SQLite）、上下文与活动状态 |
| Codex | 进程与工作目录、busy / idle 心跳 |

主窗口「会话」页与菜单栏 popup 均以宫格瓦片呈现；会话由忙转闲时可触发 macOS 系统通知（可在设置中开关）。

### 3. 用量统计

按日 / 月 / 年 / 自定义日期聚合各模型 token 消耗，主窗口「用量」页与桌面 Widget（`systemLarge`）共享同一份 App Group 快照。

## 本机代理（可选）

用户可在设置中显式开启 **Codex 本机协议代理**（默认 `127.0.0.1` 可配置端口）：

- Codex 始终以 Responses 协议对话；代理在上游为 Chat 或 Responses 时自动桥接、改写工具调用与流式事件。
- 其他 OpenAI 兼容客户端也可将 Base URL 指向该地址。
- 「流量」页提供请求捕获、改写对比与代理访问日志；完整抓包需在供应商上启用流量记录。

> ClaudeBar 不做模型推理。代理仅转发至用户已配置的上游，不把流量发到未授权的第三方。

## 界面形态

| 表面 | 职责 |
|------|------|
| 主窗口 | 旗舰交互面：`NavigationSplitView` + 6 个页面（概览 / 会话 / 供应商 / 用量 / 流量 / 设置），⌘K 命令面板 |
| 菜单栏 popup | 560pt 非激活毛玻璃面板，快速查看配置、会话与用量摘要 |
| Widget | 沙盒扩展，读取 App Group 快照渲染用量概览 |

## 目标用户

- 同时配置多家 Claude Code / Codex 兼容服务商（DeepSeek、Kimi、Anthropic 直连等），需要频繁切换的开发者。
- 使用 Codex CLI 或 IDE 插件、需要在 Chat 与 Responses 上游之间无缝路由的用户。
- 希望在不离开终端 / 编辑器的前提下，掌握各会话上下文健康度与 token 开销的重度用户。

## 非目标

- 不是 Claude Code、Codex 或 Cursor 的替代前端，不替用户与模型对话。
- 不做模型推理或托管 API Key；密钥仅存本机配置文件。
- 不支持非 macOS 平台。
