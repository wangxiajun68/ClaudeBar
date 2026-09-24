# 关键文件索引

> ClaudeBar 技术文档 · §9
> 相关：设计文档 [文件结构](../design/07-file-structure.md) · [VPN](11-vpn.md) · [电池控制](12-battery-control.md)

| 文件 | 职责 |
|------|------|
| `ClaudeBarApp.swift` | AppDelegate：激活策略、启动时序、`claudebar://`、空闲通知 Resume |
| `MenuBarController.swift` | NSStatusItem + NSPanel；`MenuBarMark` 矢量模板标；VPN 运行时 `VpnMenuBarRateView` |
| `NotchIslandController.swift` | 刘海灵动岛：`NotchIslandState`（收起 / 提醒 / 展开）、固定尺寸面板、热区与离开判定、完成提醒计时 |
| `Models/IslandLiveModel.swift` | 灵动岛数据：三家会话扁平化、忙→闲完成事件、当前路由、VPN、今日 / 本月 / 30 天用量 |
| `Utils/NotchGeometry.swift` | 从 `NSScreen` 读刘海尺寸；无刘海时的伪刘海 |
| `Views/Island/*.swift` | 灵动岛形状、根视图与 `IslandStyle`、会话行、用量卡（`Canvas` 直方图）、完成提醒 |
| `Utils/PermissionCenter.swift` | 权限清单 `AppPermission`、线程安全开关 `PermissionGate`、系统授权状态 `PermissionCenter` |
| `Views/Shared/PermissionsSection.swift` | 设置页"权限与隐私"：逐项开关、系统状态、跳转系统设置 |
| `Utils/TerminalLauncher.swift` | 继续会话：`ResumeTerminal`（自动 / Otty / Warp / 终端）选择与回退；Warp / 终端走 AppleScript（需"自动化"） |
| `Utils/OttyBridge.swift` | `otty-cli` socket IPC（`pane list`，勿用 `panes` 简写）：按 `agent_session_id` 聚焦已有窗格；活会话 `reveal` 只聚焦不新建；已结束会话才新开标签 resume |
| `Utils/SessionHost.swift` | 活会话跳转：沿父进程找到宿主 App（Otty / 终端 / iTerm2 按 tty 选中标签，Cursor / VS Code 聚焦对应文件夹窗口，其它激活）|
| `Utils/ExternalSessionMonitor.swift` | Codex 会话；`CodexProcessScan` 用 libproc 找被 `codex` 进程打开的 rollout，作为存活判定与跳转目标 |
| `Views/Shared/PowerFlowCard.swift` | 能源流向：SMC `PDTR` / `PSTR` 推出四态；按瓦数等比的色带 Sankey，彩色光波由 Core Animation 沿流向滚动 |
| `Views/Shared/InstrumentWidgets.swift` | 仪表组件；`SoftRotor` 为 Core Animation 转子（渲染服务器插值，不跑 SwiftUI 时间线） |
| `MainWindowController.swift` | 主窗口 NSWindow + vibrancy |
| `Models/ProviderStore.swift` | Claude 状态中枢；`activateModel(providerID:modelID:)` 只切换 Claude Code |
| `Models/ProviderCatalog.swift` | 内置供应商目录：按客户端的端点、协议与模型预设，注释指向 [§13](13-provider-directory.md) |
| `Models/ProviderProfileSync.swift` | 一份配置两份客户端：补链旧行、Key 仅在对面为空时复制、模型并集；基址与激活状态各留一侧 |
| `Models/ScopedStoreObservation.swift` | `StoreInvalidation`：按字段合并 store 变更，一轮事务只失效一次视图 |
| `Models/BatteryChargeController.swift` | 电池控制状态机：模式、上限、回读确认、heartbeat 与恢复 |
| `Utils/BatteryHelperInstaller.swift` | 安装 / 校验 setuid 电池辅助进程（SHA-256 + 代码签名），无 launch daemon |
| `Sources/batteryctl/batteryctl.c` | 独立 C 辅助进程：`--probe` 只读、`--serve` 需 root；固定 SMC key 白名单 |
| `Views/Shared/BatteryChargeControls.swift` | 能源卡的电池控制段：上限滑杆与四个模式按钮 |
| `Views/Shared/ProviderDirectory.swift` | 模型页供应商目录：分组、卡片、搜索与筛选 |
| `Views/Shared/ProviderQuickSetup.swift` | 新预设「连接凭据 → 模型 → 保存」弹窗，不自动激活 |
| `Views/Shared/ProviderControls.swift` | 供应商卡的状态、目标模型与激活控件 |
| `Views/Shared/ProviderModelFetchButton.swift` | 拉取模型列表（导入前需勾选确认，已存在的模型不重复添加） |
| `Views/Shared/APIKeyField.swift` | Key 输入：编辑用普通 TextField，失焦后遮蔽 |
| `Views/Shared/DecorativeMotion.swift` | `DecorativeMotion`：Core Animation 装饰动效，不跑 SwiftUI 时间线 |
| `Models/CodexProviderStore.swift` | Codex 状态中枢 + 本机代理生命周期 |
| `Models/AppPreferences.swift` | 空闲通知、代理端口、第三方上游、VPN mixed-port / 系统代理 / TUN 等 |
| `Utils/FilePaths.swift` | Claude / Codex / Cursor / App Group / `vpnDir` |
| `Utils/VpnManager.swift` | mihomo 进程、测速、流量流、超时 failover |
| `Utils/VpnHTTP.swift` | 控制器 HTTP，禁用系统代理 |
| `Utils/VpnSubscriptionStore.swift` | 订阅、YAML 合成、`tuneForStability` |
| `Utils/VpnSystemProxyController.swift` | `networksetup` + Guard + TUN DNS |
| `Utils/VpnNetProbe.swift` | 连通性探测 |
| `Utils/FanMonitor.swift` | SMC 风扇 / 温度；读取在后台队列，主线程只做去重发布 |
| `Utils/ScreenshotHotKey.swift` | Carbon 全局 ⌘⇧A |
| `Utils/ScreenshotOverlay.swift` | ScreenCaptureKit 拉框截图 |
| `Theme/Theme.swift` | 设计 token + `Theme.Ink`（作文字用的信号色，≥4.5:1） |
| `Views/MainWindowView.swift` | 8 页 `AppPage`；顶栏 tabs；流量页常驻 |
| `Views/MenuBarView.swift` | popup 壳：Header + ResourceStrip + 三区 |
| `Views/Pages/VPNView.swift` | VPN 主界面 |
| `Views/Shared/VpnTopChrome.swift` | `VpnNodeMenu` / `VpnNodePickerPanel` / `VpnDelayStyle` |
| `Views/Shared/UsageRiver.swift` | `CacheAnatomyBar`（周期 token 构成） |
| `Views/Shared/FanControlSection.swift` | 设置页风扇 |
| `Views/Shared/ProxyUpstreamPickers.swift` | 本地代理：CC/Codex 只读 + 第三方上游选择 |
| `Sources/ensure-dev-cert.sh` | 本机 ClaudeBar Dev 代码签名身份 |
| `Sources/ci/extract-changelog.py` | 切出某版本的 CHANGELOG 段，拼 Release 说明 |
| `Tests/*.py` | 源码切片回归（`make test` / CI）；不改用户配置、不联网 |
| `Tests/battery-control.c` | 电池辅助进程回归：IOKit transport 换内存模拟，不写真实 SMC |
| `Sources/Widget/*.swift` | WidgetKit |
| `Sources/build.sh` | 构建 / 签名 / 安装 / 拉取 mihomo |
