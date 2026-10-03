# 错误处理

> ClaudeBar 设计文档 · §8（原 §7）
> 相关：技术文档 [数据访问层](../technical/04-data-access-layer.md)

| 场景 | 行为 |
|------|------|
| `~/.claude/settings.json` 缺失 | popup 显示「未找到 settings.json」警告卡（副行「请先运行 Claude Code，然后刷新。」），会话与用量两区被替换 |
| `claude-bar-providers.json` 缺失或解析失败 | providers 置空，可手动添加 |
| 写 settings.json 失败 | `ProviderStore.errorMessage` 提示（如「写入设置失败：…」），供应商页的报错带显示，可关闭清除 |
| 无活跃会话 | 会话区显示「暂无会话」 |
| Cursor 未安装 / DB 不存在 | Cursor 段整段省略（空族不占一行），不影响 Claude 段 |
| 余额请求失败 / 无可用读数 | `balanceText = nil`，不显示余额（供应商卡上不画余额读数） |
| 通知权限被拒 | `NotificationService` 静默降级：不再请求、不发送通知，其余功能不受影响 |
| Widget 读不到快照 | 先试 UserDefaults → App Group 文件 → `~/.claude` → Widget 沙盒容器，全部失败或解码失败则回退 `WidgetEntry.placeholder`，视图显示「暂无数据」 |
| mihomo 二进制缺失 | VPN 状态 `missingCore`；VPN 页给出内核缺失提示与放置路径（`FilePaths.vpnCoreBin`） |
| 内核启动失败 | `VpnError` 写入 vpn.log / core.log；常见为 YAML 重复键或非法 CIDR |
| 系统代理看起来没写上 | 回读看 Wi-Fi / Ethernet，不是服务列表第一行；关 PAC 后再开 HTTP 代理 |
