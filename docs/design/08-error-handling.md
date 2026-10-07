# 错误处理

> ClaudeBar 设计文档 · §8
> 相关：技术文档 [数据访问层](../technical/04-data-access-layer.md)

| 场景 | 行为 |
|------|------|
| `~/.claude/settings.json` 缺失 | 仅当 Codex 供应商列表也为空时，popup 显示「未找到 settings.json」警告卡（副行「请先运行 Claude Code，然后刷新。」），替代会话与用量两区；任一存在 → 正常显示 |
| `claude-bar-providers.json` 缺失或解析失败 | `ProviderStore.loadProviders()` 将 providers 与 activeProviderID 置空，可手动添加；`claude-bar-codex-providers.json` 同理 |
| 写 settings.json 失败 | `ProviderStore.errorMessage` 写入「写入设置失败：…」，供应商页顶部以可关闭的 `messageBanner` 显示，关闭即清除；`restoreOfficial()` 失败也写入同一 `errorMessage`（文案见下行） |
| 写供应商文件 / 启动本地代理失败 | 保存与还原分别写入「保存供应商失败：…」「还原官方配置失败：…」；Codex 侧还有「写入 Codex 配置失败：…」「启动本地代理失败：…」「本地代理未启动，已保留直连配置：…」 |
| 无活跃会话 | 会话区显示 `StandbyEmptyState`「暂无会话」 |
| Cursor 未安装 / DB 不存在 | Cursor 段整段省略（空族不占一行），不影响 Claude 段 |
| 余额请求失败 / 无可用读数 | `ProviderStore.balanceAmounts` 留空、`balanceText = nil`（只有 DeepSeek / Kimi / 硅基流动 / OpenRouter 有官方余额接口，其余不显示数字） |
| 通知权限被拒 | `NotificationService.requestAuthorizationIfNeeded()` 仅在 `.notDetermined` 时请求，被拒后不再请求：完成横幅静默降级（`idleNotifyEnabled` 仍记录用户意图）；停在用户身上的兜底横幅以授权状态为准，被拒时不发，其余功能不受影响。发送与授权失败均记入 `Notifications` 日志类别 |
| Widget 读不到快照 | 依次试 UserDefaults → App Group 文件 → `~/.claude`（仅 `allowsSystemIntegration` 时）→ Widget 沙盒容器，全部失败或解码失败则回退 `WidgetEntry.placeholder`，视图显示「暂无数据」 |
| mihomo 二进制缺失 | VPN 状态 `missingCore`；VPN 页给出内核缺失提示（内含放置路径 `FilePaths.vpnCoreBin`）与「打开目录」按钮（打开 `FilePaths.vpnDir`） |
| 内核启动失败 | `VpnError` 经 `fail(_:)` 写入 `VpnLogStore`（VPN 页控制台）与 vpn.log，内核自身输出进 core.log；常见为 YAML 重复键、非法 `skip-auth-prefixes`、或端口被占导致的 `address already in use` |
| 系统代理看起来没写上 | `applySystemProxyNow` 对 `networkServices()` 的每个服务写入并逐个回读，不是只看列表第一行；写入前先关 PAC 与自动发现，再开 HTTP / HTTPS / SOCKS 代理。写不进去时守卫按指数退避重试并把 networksetup 的失败计数带进消息 |
