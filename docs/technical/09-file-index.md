# 关键文件索引

> ClaudeBar 技术文档 · §9
> 相关：设计文档 [文件结构](../design/07-file-structure.md)

| 文件 | 职责 |
|------|------|
| `ClaudeBarApp.swift` | AppDelegate：激活策略、启动时序、`claudebar://`、空闲通知 Resume |
| `MenuBarController.swift` | NSStatusItem + NSPanel（定位/失焦收起） |
| `MainWindowController.swift` | 主窗口 NSWindow + vibrancy |
| `ProviderEditorWindowController.swift` | 编辑器独立 NSWindow 管理者（单例） |
| `Models/ProviderStore.swift` | 状态中枢，刷新管线，心跳，空闲检测，Widget 快照 diff |
| `Models/ProviderStore+Derived.swift` | 派生量（活跃/busy 计数、用量合计、活跃 Provider/Model） |
| `Models/Provider.swift` | Provider/ModelConfig/ProvidersFile + 旧字段解码兼容 |
| `Models/Preset.swift` | EnvConfig（settings.json env 镜像） |
| `Models/ProviderEditorModel.swift` | 编辑器 @Observable 表单模型（EditableModel/校验） |
| `Models/SettingsManager.swift` | settings.json 合并读写（preserve） |
| `Models/AppConfig.swift` | 非路径配置常量（轮询间隔/心跳长度/Widget key） |
| `Models/AppPreferences.swift` | 应用偏好（空闲通知开关） |
| `Models/IdleTransitionDetector.swift` | busy→idle 边沿检测 |
| `Models/WidgetSnapshot.swift` / `WidgetSnapshotWriter.swift` | 快照模型 / 四路写入 + diff |
| `Utils/SessionMonitor.swift` | Claude 会话/transcript/子 agent |
| `Utils/CursorSessionMonitor.swift` | Cursor SQLite 会话 |
| `Utils/CursorDB.swift` | 共享 SQLite 打开 + textColumn |
| `Utils/JSONCoerce.swift` | 共享 intVal 等 JSON 强转 |
| `Utils/TerminalLauncher.swift` | 共享 resume/open 终端逻辑（Warp 优先） |
| `Utils/NotificationService.swift` | UNUserNotificationCenter：授权/分类/发通知 |
| `Utils/UsageStats.swift` | token 用量三级过滤扫描 |
| `Utils/CursorUsageStats.swift` | Cursor 历史 token |
| `Utils/BalanceFetcher.swift` | DeepSeek 余额（host 判定） |
| `Utils/FilePaths.swift` | 路径常量 |
| `Theme/Theme.swift` | 设计 token 单点（颜色/间距/字距/字体/宫格/动画/表面） |
| `Views/MenuBarView.swift` + `Views/Popup/` | popup 组合壳 + 五文件内容拆分 |
| `Views/MainWindowView.swift` + `Views/Pages/*.swift` | 主窗口 NavigationSplitView + 5 页 |
| `Views/ProviderRow.swift` | ProviderTile（宫格瓦片）+ ProviderRow |
| `Views/ProviderEditorView.swift` | 编辑视图（popup 独立窗口 / 主窗口页共用） |
| `Views/Shared/*.swift` | 共享组件层（TileGrid/MetricTile/UsageBar/SectionHeader/…） |
| `Sources/Widget/*.swift` | WidgetKit 扩展（Widget/Provider/Snapshot/Views） |
| `Sources/build.sh` | 构建/签名/安装/注册 |
