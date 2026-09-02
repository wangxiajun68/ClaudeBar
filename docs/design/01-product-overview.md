# 产品概述

> ClaudeBar 设计文档 · §1
> 相关：[顶层架构](02-architecture.md) · [文件结构](07-file-structure.md)

ClaudeBar 是一款 macOS 菜单栏应用，面向同时使用 **Claude Code**（CLI）与 **Cursor**（IDE）的开发者，在一个悬浮面板里集中完成三件事：

1. **配置切换** — 一键切换 Claude Code 的 Provider / Model（API 地址、密钥、模型名、上下文窗口等），并写入 `~/.claude/settings.json`。
2. **会话监控** — 实时展示本机所有活跃的 Claude Code 进程与 Cursor Composer 会话：上下文占用、当前正在执行的工具、子 Agent / Workflow 状态。
3. **用量统计** — 按日 / 月 / 年 / 自定义日期聚合各模型的 token 消耗，并在桌面 Widget 中呈现概览。

应用以 `.regular` 激活策略运行（含 Dock 图标与主窗口），同时保留菜单栏 status item 与失焦自动收起的非激活毛玻璃面板。主窗口是旗舰交互面（NavigationSplitView + 5 个宫格化页面），菜单栏 popup 仍为快速概览。会话由忙转闲时可发 macOS 系统通知（可开关）提醒用户恢复输入。

## 目标用户

- 同时配置了多家 Claude Code 兼容服务商（DeepSeek、Kimi、Anthropic 直连等），需要频繁切换的开发者。
- 希望在不离开当前终端 / 编辑器的前提下，掌握各会话上下文健康度与 token 开销的 Claude Code 重度用户。

## 非目标

- 不是 Claude Code 的替代前端，不替用户与模型对话。
- 不做模型推理。Codex 可选本机 `127.0.0.1` 协议代理（用户显式开启），不把流量发到用户未配置的第三方。
- 不支持非 macOS 平台。
