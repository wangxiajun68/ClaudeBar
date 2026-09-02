# Axon (ClaudeBar) — 常见问题

## 供应商 / 切换

**Q: 切换供应商后 Claude Code 没生效？**
Claude Code 在已启动的会话里缓存 env——切换只影响**新启动**的 `claude` 进程。重启终端会话即可。

**Q: 余额显示 "—"？**
余额按 baseURL host 分发（目前支持 DeepSeek 等）；自建中转站没有标准余额接口时不显示，属正常。

## 会话监控

**Q: 会话列表里没有我的 Cursor / Codex？**
- Cursor：需要 Cursor 至少运行过一次且存在 composer 记录；Axon 读 `state.vscdb` 是只读的。
- Codex：按文件 mtime 判活（30 天内），且要能从 transcript 头部解析出 cwd。
- 全部工具只监控**本机用户目录**下的标准路径（`~/.claude`、`~/.cursor`、`~/.codex`），自定义 `CLAUDE_CONFIG_DIR` 等暂不支持。

**Q: 会话状态一直 idle？**
Claude Code 的 busy 状态来自 `~/.claude/sessions/<pid>.json` + transcript 尾部是否有未闭合的 tool_use。若你用非官方分支改变了这些文件格式，识别会失效。

**Q: 空闲通知不弹？**
1. 设置页确认「空闲通知」开关已开；2. 系统设置 → 通知 → Axon 允许通知；3. 首次触发时 macOS 会请求授权，请允许。

## 用量统计

**Q: 统计慢/不准？**
- 日/月扫描有增量缓存（mtime+size 键控），首次冷扫 0.6s 左右，后续命中缓存近零开销。
- 口径：input + cache_read + cache_creation + output 全计入；`<synthetic>` 模型行已过滤。
- Cursor 的 token 记录在 ~2026-03 后停写，其数值是历史全量而非按日数据。

**Q: Token 单位想用 M/B？**
设置页 → 显示 → Token 单位，切「万 / 亿」或「K / M / B」，主 app 与 Widget 同步生效。

## Widget

**Q: Widget 一直空白 / 没有数据？**
主 app 至少运行并完成一次刷新后会写入快照。若一直空白：移除 Widget 重新添加；或确认主 app 已安装到 `/Applications`（Widget 按 bundle id 找 appex，从 .build 目录直接启动会注册失败）。

**Q: Widget 数据多久刷新？**
快照由主 app 轮询驱动（2.5s），数据变化时写入并触发 `WidgetCenter.reloadAllTimelines`；系统实际渲染节流由 WidgetKit 决定。

## 构建 / 运行

**Q: build.sh 报 SDK 不存在？**
需要 Xcode 26.x 及其 macOS 26 SDK（`xcode-select` 指向正确版本）。编译目标是 `arm64-apple-macos26.0`。

**Q: 改了代码但界面没变？**
旧进程还在跑：`killall ClaudeBar; open /Applications/ClaudeBar.app`。

**Q: Gatekeeper 拦截？**
app 是 ad-hoc 签名（无 Team ID）。`xattr -cr /Applications/ClaudeBar.app` 清除隔离属性。
