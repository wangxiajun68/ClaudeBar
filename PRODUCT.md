# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos (native SwiftUI menu-bar app + main window). Not web.

## Stack

Existing: SwiftUI / AppKit, `swiftc` + `Sources/build.sh`. Visual redesign stays native. WKWebView / TS / JS not used.

## Users

AI 编程者在本机同时跑 Claude Code、Codex、Cursor，需要不停切供应商、看会话、看用量、管 VPN，而不离开当前终端。

## Product Purpose

把 VPN、本地 LLM 代理、模型切换、会话与用量收敛进一个菜单栏应用。成功 = 点一下图标就能完成刚才那件事。

## Positioning

唯一同时接管 Claude Code `settings.json`、Codex `config.toml`、本机代理抓包和 mihomo VPN 的 macOS 菜单栏工作台。

## Constraints

- 菜单栏 popup 是最高频表面。
- 不捆绑自定义字体（系统 SF Pro / Rounded / Mono）。
- 卡片不要用全屏 backdrop-filter（主窗口 GPU 成本）。
- 功能与数据模型保持不变；只换视觉语言。

## Brand commitments

- 名称 ClaudeBar；现有 Axon 应用图标。
- Claude / Codex / Cursor 三端必须可辨识，但不能靠满屏彩虹。
- 视觉世界以用户钉住的 CatStatus 面板为工艺标尺：浅冰画布、白卡片、大圆体数字、颜色只出现在图表与状态。
