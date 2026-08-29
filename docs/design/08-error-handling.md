# 错误处理

> ClaudeBar 设计文档 · §8（原 §7）
> 相关：技术文档 [数据访问层](../technical/04-data-access-layer.md)

| 场景 | 行为 |
|------|------|
| `~/.claude/settings.json` 缺失 | 面板显示 "No settings.json found" 警告，提示先运行 Claude Code |
| `providers.json` 缺失或解析失败 | providers 置空，可手动添加 |
| 写 settings.json 失败 | `errorMessage` 提示，面板反馈 |
| 无活跃会话 | 会话区显示 "No active sessions" |
| Cursor 未安装 / DB 不存在 | Cursor 区显示 "none"，不影响 Claude 区 |
| DeepSeek 余额请求失败 / 非 DeepSeek | `balanceText = nil`，不显示余额 |
| Widget 读不到快照 | 先试 UserDefaults → App Group 文件 → `~/.claude` → Widget 沙盒容器，全部失败则显示诊断信息（`UD:nil F:N/-1B`） |
