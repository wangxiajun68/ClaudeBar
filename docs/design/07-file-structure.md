# 文件结构

> ClaudeBar 设计文档 · §7（原 §6）
> 相关：[顶层架构](02-architecture.md)

```
ClaudeBar/
├── Sources/
│   ├── build.sh                          ← 构建 + 签名 + 安装脚本（find … -name "*.swift" 自动发现源文件）
│   ├── AppIcon.icns / AppIcon.iconset/   ← 应用图标
│   ├── ClaudeBar/                        ← 主 app 源码
│   │   ├── ClaudeBarApp.swift            ← @main, AppDelegate（.regular 激活策略）
│   │   ├── MenuBarController.swift       ← NSStatusItem + NSPanel（菜单栏 popup）
│   │   ├── MainWindowController.swift    ← NSWindow 主窗口（1120×720, .underWindowBackground vibrancy）
│   │   ├── Theme/
│   │   │   └── Theme.swift               ← 设计 token（颜色/间距/圆角/字体/动画/阴影/玻璃卡）单点
│   │   ├── Models/
│   │   │   ├── Provider.swift            ← Provider/ModelConfig/迁移
│   │   │   ├── Preset.swift              ← EnvConfig/Preset(旧)
│   │   │   ├── ProviderStore.swift       ← 状态中枢（刷新管线 + Widget 快照 diff）
│   │   │   ├── SettingsManager.swift     ← settings.json 读写（readSettings → EnvConfig?）
│   │   │   └── WidgetSnapshot.swift      ← Widget 快照模型
│   │   ├── Utils/
│   │   │   ├── FilePaths.swift           ← 路径常量 (Claude/Cursor/AppGroup)
│   │   │   ├── BalanceFetcher.swift      ← DeepSeek 余额 API（host 判定）
│   │   │   ├── SessionMonitor.swift     ← Claude Code 会话/transcript/子 agent
│   │   │   ├── CursorSessionMonitor.swift← Cursor SQLite 会话
│   │   │   ├── UsageStats.swift         ← token 用量扫描
│   │   │   ├── CursorUsageStats.swift    ← Cursor 历史 token
│   │   │   ├── CursorDB.swift            ← 共享：SQLite 只读打开 + textColumn（B3/B 去重）
│   │   │   ├── JSONCoerce.swift          ← 共享：intVal 等 JSON 类型强转（D2 去重）
│   │   │   └── TerminalLauncher.swift    ← 共享：resume/open 终端逻辑（D2 去重，Warp 优先 + osascript + Terminal 回退）
│   │   └── Views/
│   │       ├── MenuBarView.swift         ← 菜单栏 popup 面板
│   │       ├── MainWindowView.swift      ← 主窗口 NavigationSplitView（sidebar 5 项 + detail）
│   │       ├── ProviderRow.swift         ← Provider 行（Theme token）
│   │       ├── ProviderEditorView.swift  ← 编辑视图（popup 独立窗口 / 主窗口页面共用）
│   │       ├── Pages/                    ← 主窗口 5 个页面
│   │       │   ├── DashboardView.swift   ← 概览（stat cards + pulse graph + activity feed）
│   │       │   ├── SessionsView.swift    ← 会话（全宽行 + 子 agent 树 + 双击恢复）
│   │       │   ├── ProvidersView.swift   ← 供应商（嵌入 ProviderEditorView）
│   │       │   ├── UsageView.swift       ← 用量（周期 chips + 条形图）
│   │       │   └── SettingsView.swift    ← 设置
│   │       └── Shared/                   ← 共享交互层（popup 与主窗口复用）
│   │           ├── Interaction.swift     ← PressableStyle/HoverState/IconChip/ActionChip
│   │           ├── PointerFX.swift       ← TiltOnHover/SpecularSheen/CursorSpotlight
│   │           ├── RadarBackdrop.swift   ← 雷达刻度背景（graticule + 扫描光）
│   │           ├── LiveRadar.swift       ← 签名组件：实时雷达（光点/扫描/ping）
│   │           ├── CommandPalette.swift   ← ⌘K 模糊搜索
│   │           ├── LivePulseGraph.swift   ← 信号历史脉冲图
│   │           ├── StatusBadge.swift     ← 信标状态点（脉冲）
│   │           ├── ActivityLine.swift    ← 活动描述行
│   │           ├── SessionCardView.swift ← Claude 会话卡片（popup 用）
│   │           ├── CursorSessionCardView.swift ← Cursor 会话卡片（popup 用）
│   │           ├── UsageRowView.swift    ← 用量行（popup 用）
│   │           └── ContextBar.swift      ← 遥测细条
│   └── Widget/                          ← WidgetKit 扩展源码
│       ├── ClaudeBarWidget.swift         ← @main Widget
│       ├── WidgetProvider.swift          ← TimelineProvider
│       └── WidgetViews.swift             ← Widget 视图
├── docs/
│   ├── README.md                        ← 文档索引（agent 入口）
│   ├── design/                          ← 产品/交互设计文档（本目录）
│   ├── technical/                       ← 技术架构文档
│   └── CHANGELOG.md                     ← 更新日志
├── ClaudeBar.pen                        ← Pencil 原型
└── .build/                              ← 构建产物
```
