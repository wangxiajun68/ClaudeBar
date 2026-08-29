# 文件结构

> ClaudeBar 设计文档 · §7
> 相关：[顶层架构](02-architecture.md)

```
ClaudeBar/
├── Sources/
│   ├── build.sh                          ← 构建 + 签名 + 安装脚本（find … -name "*.swift" 自动发现源文件）
│   ├── AppIcon.icns / AppIcon.svg        ← 应用图标
│   ├── ClaudeBar/                        ← 主 app 源码
│   │   ├── ClaudeBarApp.swift            ← AppDelegate（.regular 激活策略；@main App 壳）
│   │   ├── MenuBarController.swift       ← NSStatusItem + NSPanel（菜单栏 popup）
│   │   ├── MainWindowController.swift    ← NSWindow 主窗口（1120×720, .underWindowBackground vibrancy）
│   │   ├── ProviderEditorWindowController.swift ← 编辑器独立 NSWindow 管理者
│   │   ├── Theme/
│   │   │   └── Theme.swift               ← 设计 token（颜色/间距/圆角/字距/字体/宫格/动画/表面）单点
│   │   ├── Models/
│   │   │   ├── Provider.swift            ← Provider/ModelConfig/ProvidersFile/MigrationHelper
│   │   │   ├── Preset.swift              ← EnvConfig/Preset(旧)
│   │   │   ├── ProviderStore.swift       ← 状态中枢（刷新管线 + 心跳 + 空闲检测 + 快照 diff）
│   │   │   ├── ProviderStore+Derived.swift ← 派生量（活跃会话/busy 数/用量合计/活跃 Provider）
│   │   │   ├── ProviderEditorModel.swift ← 编辑器 @Observable 模型（EditableModel）
│   │   │   ├── SettingsManager.swift     ← settings.json 读写（readSettings → EnvConfig?）
│   │   │   ├── AppConfig.swift           ← 非路径配置常量（轮询间隔/心跳长度/Widget key）
│   │   │   ├── AppPreferences.swift      ← 应用偏好（空闲通知开关，UserDefaults 持久化）
│   │   │   ├── IdleTransitionDetector.swift ← busy→idle 边沿检测（驱动空闲通知）
│   │   │   ├── WidgetSnapshot.swift      ← Widget 快照模型
│   │   │   └── WidgetSnapshotWriter.swift ← 快照四路写入 + diff
│   │   ├── Utils/
│   │   │   ├── FilePaths.swift           ← 路径常量 (Claude/Cursor/AppGroup)
│   │   │   ├── BalanceFetcher.swift      ← DeepSeek 余额 API（host 判定）
│   │   │   ├── SessionMonitor.swift      ← Claude Code 会话/transcript/子 agent
│   │   │   ├── CursorSessionMonitor.swift← Cursor SQLite 会话
│   │   │   ├── UsageStats.swift          ← token 用量扫描
│   │   │   ├── CursorUsageStats.swift    ← Cursor 历史 token
│   │   │   ├── CursorDB.swift            ← 共享：SQLite 只读打开 + textColumn
│   │   │   ├── JSONCoerce.swift          ← 共享：intVal 等 JSON 类型强转
│   │   │   ├── NotificationService.swift ← UNUserNotificationCenter（空闲通知 + Resume 动作）
│   │   │   └── TerminalLauncher.swift    ← 共享：resume/open 终端逻辑（Warp 优先 + osascript + Terminal 回退）
│   │   └── Views/
│   │       ├── MenuBarView.swift         ← popup 组合壳（内容在 Popup/）
│   │       ├── MainWindowView.swift      ← 主窗口 NavigationSplitView（sidebar 5 项 + detail）
│   │       ├── ProviderRow.swift         ← ProviderTile（供应商宫格瓦片，popup/主窗口共用）+ ProviderRow
│   │       ├── ProviderEditorView.swift  ← 编辑视图（popup 独立窗口 / 主窗口页面共用）
│   │       ├── Popup/                    ← 菜单栏 popup 五文件拆分
│   │       │   ├── PanelHeader.swift     ← 头部（brand + 折叠 + 刷新）
│   │       │   ├── ProvidersPanel.swift  ← 当前配置条 + 供应商宫格 + 反馈 toast
│   │       │   ├── SessionsPanel.swift   ← Claude/Cursor 会话卡 2 列宫格
│   │       │   ├── UsagePanel.swift      ← 周期 chips + 日期导航 + 用量瓦片
│   │       │   └── PanelState.swift      ← popup UI 状态（折叠/反馈消息）
│   │       ├── Pages/                    ← 主窗口 5 个页面
│   │       │   ├── DashboardView.swift   ← 概览（指标瓦片 + 会话总览 + 用量 Top）
│   │       │   ├── SessionsView.swift    ← 会话（宫格瓦片 + 子 agent 树 + 双击恢复）
│   │       │   ├── ProvidersView.swift   ← 供应商（宫格 + 嵌入 ProviderEditorView）
│   │       │   ├── UsageView.swift       ← 用量（周期 chips + 用量瓦片宫格）
│   │       │   └── SettingsView.swift    ← 设置（settings.json / 空闲通知开关 / 版本）
│   │       └── Shared/                   ← 共享交互层（popup 与主窗口复用）
│   │           ├── Tile.swift            ← TileGrid（宫格容器）/ MetricTile / .tile modifier
│   │           ├── UsageBar.swift        ← UsageBarRow / UsageModelTile / ProportionBar / MetricText
│   │           ├── SectionHeader.swift   ← 频道区头（图标+标题+徽标）
│   │           ├── Interaction.swift     ← PressableStyle/HoverState/ActionChip/IconChip
│   │           ├── HoverActionChips.swift ← hover 揭示 action chips
│   │           ├── GlassCard.swift       ← GlassCard / SelectionTint
│   │           ├── StatusDot.swift / StatusBadge.swift ← 状态点（busy 脉冲）
│   │           ├── HeartbeatSparkline.swift ← busy/idle 心跳轨迹
│   │           ├── SessionCardView.swift ← Claude 会话卡片（popup 用）
│   │           ├── CursorSessionCardView.swift ← Cursor 会话卡片（popup 用）
│   │           ├── ContextBar.swift      ← 上下文健康条
│   │           ├── ActivityLine.swift    ← 活动描述行
│   │           ├── FeedbackToast.swift   ← 操作反馈 toast
│   │           ├── StandbyEmptyState.swift ← 统一空态
│   │           └── CommandPalette.swift  ← ⌘K 模糊搜索
│   └── Widget/                           ← WidgetKit 扩展源码
│       ├── ClaudeBarWidget.swift         ← @main Widget
│       ├── WidgetProvider.swift          ← TimelineProvider
│       ├── WidgetSnapshot.swift          ← 快照解码（与主 app 对应）
│       └── WidgetViews.swift             ← Widget 视图
├── docs/
│   ├── README.md                        ← 文档索引（agent 入口）
│   ├── design/                          ← 产品/交互设计文档（本目录）
│   ├── technical/                       ← 技术架构文档
│   └── CHANGELOG.md                     ← 更新日志
├── ClaudeBar.pen                        ← Pencil 原型
└── .build/                              ← 构建产物
```
