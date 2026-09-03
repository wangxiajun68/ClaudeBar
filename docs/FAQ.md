# 常见问题

> 使用 ClaudeBar 时的典型问题与排障。安装请从 [Releases](https://github.com/wangxiajun68/ClaudeBar/releases) 下载 DMG，不要运行 `build.sh`。

---

## 安装与启动

### 从哪里下载？

[GitHub Releases](https://github.com/wangxiajun68/ClaudeBar/releases) 中的 `ClaudeBar-<version>-macOS-arm64.dmg`。打开 DMG，将 **ClaudeBar** 拖入 **Applications**。

### Gatekeeper 提示「无法验证开发者」

发行包为 **ad-hoc 签名**，未经 Apple 公证。在终端执行：

```bash
xattr -cr /Applications/ClaudeBar.app
open /Applications/ClaudeBar.app
```

### 系统要求是什么？

| 项目 | 要求 |
|------|------|
| 系统 | macOS 15 (Sequoia) 或更高 |
| 芯片 | Apple Silicon (`arm64`) |

Intel Mac 暂不支持。

---

## 供应商与切换

### 切换供应商后 Claude Code 没生效？

Claude Code 在**已启动的会话**里缓存环境变量。切换只影响**新启动**的 `claude` 进程。请重启终端会话或新开一个 Claude Code 窗口。

### Codex 切换后没反应？

确认设置里本地代理已按文档配置。切换会写回 `~/.codex/config.toml`；已运行的 Codex 进程可能需要重启。

### 余额显示「—」

余额按 base URL 的 host 拉取（目前支持 DeepSeek 等官方接口）。自建中转或无标准余额 API 的站点不显示，属正常。

### 能否互导 Claude Code 与 Codex 配置？

可以。供应商编辑页支持从另一套运行时导入（`ProviderBridge`）。导入后请检查 base URL 与模型名是否符合目标 API 形态。

---

## 会话监控

### 列表里没有 Cursor / Codex 会话？

| 来源 | 前提 |
|------|------|
| **Cursor** | Cursor 至少运行过一次，且 `state.vscdb` 中有 composer 记录 |
| **Codex** | `~/.codex/sessions/` 下有 rollout JSONL；按 mtime 判活（默认 30 天窗口） |
| **Claude Code** | `~/.claude/sessions/` 存在对应 PID 文件 |

所有路径均为**本机用户目录**下的标准位置（`~/.claude`、`~/.cursor`、`~/.codex`）。自定义 `CLAUDE_CONFIG_DIR` 等环境变量暂不支持。

### 状态一直显示 idle？

Claude Code 的 busy 来自 `~/.claude/sessions/<pid>.json` 与 transcript 尾部未闭合的 `tool_use`。若使用修改了文件格式的非官方分支，识别可能失效。

### 空闲通知不弹出？

1. 设置页 → 开启「空闲通知」
2. 系统设置 → 通知 → **ClaudeBar** → 允许通知
3. 首次触发时 macOS 会请求授权，请选择允许

---

## 用量统计

### 统计慢或不准确？

- 日/月聚合使用增量索引（mtime + size 键控）。首次冷扫约 0.6s，后续命中缓存接近零开销。
- 口径：`input + cache_read + cache_creation + output` 全部计入；`<synthetic>` 模型行已过滤。
- **Cursor**：约 2026-03 后 SQLite 中停止写入 token 计数，显示值为历史全量，非严格按日数据。

### 如何切换 Token 单位？

设置 → 显示 → Token 单位：「万 / 亿」或「K / M / B」。主应用与桌面 Widget 同步生效。

---

## Codex 本地代理

### 代理监听在哪里？

默认 `127.0.0.1` 上的本机端口（设置页可查看）。仅用于本机协议桥接，**请勿暴露到公网**。

### 流量页没有记录？

在对应供应商上启用「流量记录」后，Anthropic / OpenAI 形态请求会出现在检查器中。流式响应随接收进度更新。

### Codex 报 stream disconnected？

常见原因是上游 400（例如 tool call `arguments` 不是合法 JSON）。可查看访问日志与抓包页定位；必要时开新 Codex 会话。详见项目 Issue 讨论。

---

## 桌面 Widget

### Widget 空白或没有数据？

1. 主应用至少运行并完成一次数据刷新（写入 App Group 快照）
2. 移除 Widget 后重新添加
3. 确认应用安装在 `/Applications`（从 `.build` 直接启动可能导致 Widget 注册异常）

### 刷新频率？

主应用约每 2.5s 轮询；数据变化时写入快照并调用 `WidgetCenter.reloadAllTimelines()`。最终渲染节奏由 WidgetKit 系统节流。

---

## 从源码构建（贡献者）

### `build.sh` 报 SDK 不存在？

安装 Xcode Command Line Tools（建议 Xcode 16+）。默认部署目标 `arm64-apple-macos15.0`。详见 [CONTRIBUTING.md](../CONTRIBUTING.md)。

### 改了代码但界面没变？

旧进程仍在运行：

```bash
killall ClaudeBar
open /Applications/ClaudeBar.app
```

---

## 仍未解决？

1. 查阅 [文档索引](README.md)
2. 搜索 [已有 Issue](https://github.com/wangxiajun68/ClaudeBar/issues)
3. 使用 [缺陷报告模板](https://github.com/wangxiajun68/ClaudeBar/issues/new/choose) 提交（**不要粘贴 API key 或完整 settings.json**）
