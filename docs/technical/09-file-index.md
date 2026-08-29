# 关键文件索引

> ClaudeBar 技术文档 · §9
> 相关：设计文档 [文件结构](../design/07-file-structure.md)

| 文件 | 职责 |
|------|------|
| `Models/ProviderStore.swift` | 状态中枢，刷新管线，Widget 快照 diff |
| `Views/MainWindowView.swift` | 主窗口 NavigationSplitView + 5 页 |
| `MainWindowController.swift` | 主窗口 NSWindow + vibrancy |
| `Views/MenuBarView.swift` | 菜单栏 popup 面板 UI |
| `Theme/Theme.swift` | 设计 token 单点（颜色/间距/字体/动画） |
| `Utils/SessionMonitor.swift` | Claude 会话/transcript/子 agent |
| `Utils/CursorSessionMonitor.swift` | Cursor SQLite 会话 |
| `Utils/CursorDB.swift` | 共享 SQLite 打开 + textColumn（D2） |
| `Utils/JSONCoerce.swift` | 共享 intVal 等 JSON 强转（D2） |
| `Utils/TerminalLauncher.swift` | 共享 resume/open 终端逻辑（D2） |
| `Utils/UsageStats.swift` | token 用量三级过滤扫描 |
| `Views/Pages/*.swift` | 主窗口 5 个页面 |
| `Views/Shared/*.swift` | 13 个共享交互组件 |
| `Models/Provider.swift` | 数据模型 + 旧格式迁移 |
| `Sources/build.sh` | 构建/签名/安装/注册 |
| `Models/SettingsManager.swift` | settings.json 合并读写 |
