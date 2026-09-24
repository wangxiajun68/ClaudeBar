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

只有公开了余额接口的官方平台会显示数字：**DeepSeek、Kimi 开放平台（moonshot.cn / moonshot.ai）、硅基流动、OpenRouter**。Coding Plan、按订阅计费的入口，以及自建中转、聚合站不显示，属正常，不影响转发。

### 能否互导 Claude Code 与 Codex 配置？

可以。模型页从供应商目录选预设（或导入另一套运行时的配置，走 `ProviderBridge`）。同一份配置在两侧共享名称、Key 与模型列表；Base URL 各用自己客户端的端点。导入后请检查模型名是否符合目标 API 形态。

---

## 权限与隐私

### 为什么一启动就问「访问其他 App 的数据」？

那是写入桌面 Widget 容器（App Group）触发的。设置 →「权限与隐私」→ **桌面小组件** 默认关闭；关掉后不再写快照，也不再弹窗（Widget 会没有数据）。

### 各开关关掉之后会怎样？

| 开关 | 关闭时的行为 |
|------|-------------|
| 桌面小组件 | 不写 Widget 容器 / App Group |
| 空闲通知 | 不发通知 |
| 区域截图 ⌘⇧A | 不注册热键 |
| 在终端继续会话 | 不发 Apple Event，改为复制命令 + 在目录打开终端 |
| 蓝牙与耳机电量 | 不读蓝牙控制器 |
| Wi-Fi 名称 | 不读 SSID，网络卡片显示「在设置中开启」 |
| 读取 Cursor 会话 | 不读 Cursor 数据库 |

全部默认关闭，**打开开关时才会向系统请求授权**。某项显示「系统中已拒绝」时，到「系统设置 › 对应的隐私类别」里允许 ClaudeBar。

---

## 会话监控

### 列表里没有 Cursor / Codex 会话？

| 来源 | 前提 |
|------|------|
| **Cursor** | Cursor 至少运行过一次，且 `state.vscdb` 中有 composer 记录 |
| **Codex** | `~/.codex/sessions/` 下有 rollout JSONL，且桌面索引 `state_*.sqlite` 中 `archived = 0` |
| **Claude Code** | `~/.claude/sessions/` 存在对应 PID 文件 |

所有路径均为**本机用户目录**下的标准位置（`~/.claude`、`~/.cursor`、`~/.codex`）。自定义 `CLAUDE_CONFIG_DIR` 等环境变量暂不支持。

### 状态一直显示 idle？

Claude Code 的 busy 来自 `~/.claude/sessions/<pid>.json` 与 transcript 尾部未闭合的 `tool_use`。若使用修改了文件格式的非官方分支，识别可能失效。

### 空闲通知不弹出？

1. 设置 →「权限与隐私」→ **空闲通知** 打开（默认关闭）
2. 系统设置 → 通知 → **ClaudeBar** → 允许通知
3. 首次触发时 macOS 会请求授权，请选择允许
4. 通知现在只在 **transcript 证明本轮已交付新的最终答复** 时才发——权限询问、工具暂停、被中断的一轮都不算，这是有意为之

### 灵动岛不显示 / 挡住了菜单栏图标？

- 需要在**有刘海的屏幕**上（或菜单栏所在屏幕画伪刘海）；总开关和两翼分别在 设置 →「灵动岛」。
- 两翼会盖住紧贴刘海的菜单栏图标，把它们关掉即可。
- 不想在全屏应用上看到它，关掉「全屏应用中显示」。

### 电池充电控制没反应？

- 只有内置电池机型、且检测到 SMC 充电 key 时可用；无放电 key 时只有「放电至上限」不可用。
- 首次点控制按钮会弹出管理员授权，安装随包签名的辅助工具。取消授权只会报错，不会启用控制。
- 同时只能有一个限充工具接管：若检测到其他工具已写入充电控制值，ClaudeBar 会拒绝接管并提示先关闭它们。
- 休眠期间不承诺保持上限；退出应用即恢复系统管理。
- 详见 [技术文档 §12](technical/12-battery-control.md)。

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

在对应供应商上启用「流量记录」后，Anthropic / OpenAI 形态请求会出现在检查器中。流式响应随接收进度更新。第三方请求还受设置里「记录第三方流量」控制。

### 第三方客户端和 Codex 不是同一家供应商？

设置 → 本地代理：Claude Code / Codex 只读显示「模型」页当前选择；**第三方 OpenAI / Anthropic** 可另选供应商，不会改写 `~/.codex` 或 `settings.json`。默认「与 Codex / Claude Code 相同」。

### 第三方报 model_not_found / 无可用渠道？

代理只替换上游地址和密钥，请求里的 `model` 仍以客户端为准。请把第三方上游切到实际提供该模型的渠道，或把客户端模型名改成该渠道已配置的名字。

### Codex 报 stream disconnected？

常见原因是上游 400（例如 tool call `arguments` 不是合法 JSON）。可查看访问日志与抓包页定位；必要时开新 Codex 会话。

---

## VPN

### 开启后系统设置里代理仍是关的？

ClaudeBar 对 **Wi-Fi / 以太网** 写 `127.0.0.1` + mixed-port（默认 7890），并先关掉 PAC。若只看了 Thunderbolt 等未使用的服务，会误以为没写上。

### 菜单栏图标变成白方块？

旧版把带底色的 PNG 当模板用。当前 status item 使用矢量标；请安装本次构建后再看。

### VPN 页提示没有内核？

从源码构建时需要能访问 GitHub 下载 mihomo，或本地已有 `vendor/mihomo/mihomo`。用户 DMG 应已打进 `mihomo-core`。

### 订阅流量 / 到期显示不出来？

机场需在 HTTP 头返回 `subscription-userinfo`。请求使用 Clash Verge 风格 UA。

---

## 截图

### ⌘⇧A 没反应？

1. 设置 →「权限与隐私」→ **区域截图 ⌘⇧A** 打开（默认关闭），且提示「热键已注册」。若提示被占用，先退出 iShot / PixPin 等占用 ⌘⇧A 的软件。
2. 系统设置 → 隐私与安全性 → 屏幕录制 → 允许 ClaudeBar，然后重按一次。
3. 悬停会吸附窗口边；拖拽为自定义区域。确定后用 **复制 / 保存 / 钉住**，可用红框 / 圆圈 / 箭头 / 画笔标注。Esc 取消，Return / ⌘C 复制，⌘S 保存，空格全屏。
4. 从源码反复编译时若每次都要重新授权：确认本机签名是已信任的 **ClaudeBar Dev**（`security find-identity -v` 不应出现 `CSSMERR_TP_NOT_TRUSTED`），不要用 ad-hoc。发行 DMG 换构建后仍可能问一次。

### Finder 里 ⌘⇧A 打不开「应用程序」？

ClaudeBar 运行时会占用该组合。关掉设置里的「区域截图」即可还给 Finder。

---

## 桌面 Widget

### Widget 空白或没有数据？

1. 设置 →「权限与隐私」→ **桌面小组件** 打开（默认关闭，关着就不写快照）
2. 主应用至少运行并完成一次数据刷新（写入 App Group 快照）
3. 移除 Widget 后重新添加
4. 确认应用安装在 `/Applications`（从 `.build` 直接启动可能导致 Widget 注册异常）

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
