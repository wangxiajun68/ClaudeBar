# 应用启动与窗口管理

> ClaudeBar 技术文档 · §2
> 相关：设计文档 [顶层架构](../design/02-architecture.md) · [主窗口与设计系统](../design/05-main-window-and-theme.md) · 技术文档 [视图层](05-view-layer.md)

ClaudeBar 以 `.regular` 激活策略运行：Dock 图标 + 主窗口（`MainWindowController`）+ 菜单栏 status item popup（`MenuBarController`）+ 刘海灵动岛（`NotchIslandController`，见设计文档 [§10](../design/10-notch-island.md)）。三个 UI 面共享同一个 `ProviderStore` / `CodexProviderStore` 状态中枢。

## 入口 `ClaudeBarApp.swift`

```swift
@main
struct ClaudeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}
```

使用 `@NSApplicationDelegateAdaptor` 而非 SwiftUI `MenuBarExtra`，因为面板是一个自定义的非激活 `NSPanel`：自绘圆角与填充、以状态项图标为中心定位、失焦不自动收起而由事件监听收起、并自行处理 Escape。

`AppDelegate.applicationDidFinishLaunching`：
1. `NSApp.setActivationPolicy(.regular)` — 含 Dock 图标与主窗口，仍是完整应用。
2. `AppearanceSync.apply()`、`BatteryChargeController.shared.probe()`；同步触碰 `NotificationService.shared`，让 `UNUserNotificationCenter.delegate` 在启动返回前装好（晚于启动安装会漏掉「点横幅启动应用」那一次响应）。
3. 构造 `ProviderStore`（状态中枢，`init()` 留空，不在此处 refresh），并构造 `CodexProviderStore`、互设 `peer` / `claudePeer` 后 `load()`。
4. 恢复 VPN 运行时（上次开启则 `VpnManager.syncRuntime()`，系统代理开着则起 `VpnProxyGuard`；否则后台清一次残留代理）、`SystemThroughput.shared.start()` 启动菜单栏吞吐采样、构造 `MenuBarController` 并 `setup()` 创建菜单栏图标。
5. 构造 `NotchIslandController` 并 `start()`，再构造 `MainWindowController` 并 `showWindow()` 显示主窗口。
6. 注册两个通知观察者：`.showMainWindow`（popup 的"打开主窗口"按钮 post；`userInfo` 携带 `page` / `editor` 时直接路由到目标页）、`.resumeSession`（空闲通知的 Resume 动作，`userInfo` 携带 `agent` / `sessionId` / `cwd` / `pid` / `inDesktop`，按 agent 分派到 `TerminalLauncher` 的 Claude / Codex / Cursor 入口）。
7. `store.refresh()` 触发首次全量刷新（此时窗口/状态栏均已就绪，时序可控），随后启动并首次拉取 Cursor 额度（`CursorUsageStore.start()` / `refresh()`）、截图热键（`ScreenshotHotKey.startIfEnabled()`）、问候卡汇率（`ExchangeRate.shared.start()`，仅已选换算显示时联网）与定价覆盖检查（`ModelPriceCatalog.shared.autoCheckIfStale()`），并 `LaunchAtLogin.shared.refresh()` 对齐系统登录项状态。
8. 若 widget 点击的 URL 在冷启动时早于控制器到达（`pendingOpenURL`），此时补发 `menuBarController.showPanel()`；最后注册 `.fanPermissionNeeded` 观察者，由弹窗引导安装风扇辅助工具或打开系统设置。

> **设计取舍**：`ProviderStore.init()` 不调 `refresh()`，统一由 AppDelegate 启动时调用——若 `init()` 内刷新会先于窗口/状态栏就绪跑文件 I/O 与后台任务，而 AppDelegate 又会再调一次造成重复。`init` 只做空初始化。

其余生命周期入口：

- `application(_:open:)` 处理 `claudebar://` / `claudebar-dev://` URL scheme —— Widget 点击时经由此入口唤起菜单栏 popup（`showPanel()`）；控制器尚未构造时先记为 `pendingOpenURL`，启动末尾补发。
- `applicationShouldHandleReopen` — Dock 图标被再次点击时若主窗口已关闭则重开主窗口。窗口最小化时 `showWindow()` 走 `deminiaturize` 分支（最小化的窗口 `isVisible == false`，不能当关闭处理——那会在仍挂载的宿主上再叠一层 `NSHostingView`，丢掉 `@StateObject` 草稿与滚动位置）。
- `applicationShouldTerminateAfterLastWindowClosed` 返回 `false` —— 关闭主窗口/编辑窗口不应退出 app（status item 保活）。
- `applicationWillTerminate` — 进程还活着时必须完成的事：停电池辅助进程（`BatteryChargeController.shutdown()`）、停吞吐采样、把风扇交还系统（`FanMonitor.adoptSystemControlOnQuit()`，仅有风扇非自动时执行一次 `fanctl autoall`）、拆掉菜单栏的速率配件、VPN 开启时停内核（`VpnManager.stopCore()`）后**同步**清理系统代理并复原 TUN DNS、注销截图热键。清理系统的部分不能用异步变体——那是在和进程退出赛跑。

## `MainWindowController` — 主窗口

主窗口的承载与生命周期：

- **NSWindow**：1120×720，`contentRect`，`styleMask` 含 `.titled`/`.fullSizeContentView`/`.closable`/`.miniaturizable`/`.resizable`，`titlebarAppearsTransparent = true`，`titleVisibility = .hidden`，`isMovableByWindowBackground = false`（拖动只由顶栏的 `WindowDragRegion` 发起）；`isOpaque = true` + `backgroundColor = Theme.windowNSColor` —— 不透明实填，无窗口级 vibrancy（`NSVisualEffectView` 全幅 live blur 的 GPU 纹理开销约 100 MB 量级）。恢复 `ClaudeBarMainWindow` 的保存位置，没有已存位置时才 `center()`。
- **内容宿主**：`NSHostingView(rootView: MainWindowView(initialPage:) … .environment(\.providerSource, providerStore) .environmentObject(codexProviderStore) .environmentObject(trafficState))` —— `ProviderStore` 经 `\.providerSource` 注入（字段级订阅，见 [§3](03-provider-store.md)），`CodexProviderStore` 与 `TrafficPageState` 经 environmentObject 注入。
- **生命周期**：`showWindow()` 调 `makeKeyAndOrderFront` + `NSApp.activate(ignoringOtherApps: true)`；窗口持有为强引用保活。`window.isReleasedWhenClosed = false` 保留 AppKit 外壳与自动保存的 frame，但 `willClose` 时 `releaseContent()` 把 SwiftUI 图卸掉（延迟一帧执行，避免在关闭动画中拆层）——关窗后不占显示周期，重开时在约 50–150 ms 内重建。`applicationShouldHandleReopen` 在窗口被关后重新 `showWindow()`。
- **跨面导航**：`showWindow(on:)` 先把目标写到 `ProviderStore.navigationRequest`（`@Published`，不会像通知那样错过窗口重建期间的订阅），再走 `showWindow()`。窗口可见性经 `observeVisibility(of:)` 汇报给 `UIWakePolicy`，每次重开都会先移除上一扇窗口留下的观察者。

## `MainWindowView` — 主窗口内容

顶栏 tabs + detail（`.frame(minWidth: 900, minHeight: 600)`）：

- **topBar**（背景 `Theme.bgPrimary`，另叠 `WindowDragRegion` 供标题拖动）：brand 头 + 悬浮胶囊里的 8 个 `AppPage` tab（概览 / 会话 / 模型 / 连接器 / 用量 / 流量 / VPN / 设置；`AppPage.tabs` 排除 `.help`，帮助是右侧的问号 chip，走 `helpButton` → `navigate(to: .help)`）；`ViewThatFits` 在宽度不足时只留文字（先丢字形）。
- **Detail**：`DashboardView` / `SessionsView` / `ProvidersView` / `ConnectorsView` / `UsageView` / `VPNView` / `SettingsView` / `HelpView`；`TrafficView` 只在选中时挂载，昂贵状态留在 `TrafficPageState`。页面切换用 `.transition`（入页淡化、出页 identity，流量页连入页也跳过动画）。
- **CommandPalette**（⌘K）。

## `MenuBarController` — 面板的承载与定位

核心职责：维护 `NSStatusItem`、创建并复用一个 `NSPanel`、处理显示/隐藏、点击外部收起。

**面板特性（`makePanel`）：**
- 类型 `KeyablePanel: NSPanel`，`canBecomeKey = true` / `canBecomeMain = false` —— 可成为 key window（SwiftUI Alert/控件需 key）但不激活应用。
- `styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView]` —— 非激活、无边框；圆角由 `contentView.layer` 的 22pt `continuous` 提供。
- `backgroundColor = .clear` + `isOpaque = false`，内容层直接铺 `Theme.windowNSColor` —— 不透明实填，不用 `NSVisualEffectView`（全幅 live blur 的 GPU 纹理开销约 100 MB 量级）。
- `appearance = Theme.nsAppearance`（`.aqua` / `.darkAqua`，跟随应用主题而非系统 vibrancy）、`collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]` —— 全空间可见、全屏辅助；`.appearanceDidChange` 通知会就地重刷一个已建好的面板。
- `hidesOnDeactivate = false`、`isFloatingPanel = true` —— 悬浮且不因失焦隐藏（自行用事件监听收起）。
- `Esc` 收起：`KeyablePanel` 的 `cancelOperation` 与 keyCode 53 显式处理；点击状态项本身的那一下会被 `closingFromStatusItem` 抑制，避免「先收起再立刻重开」。

**定位逻辑（`sizeAndPosition`）：**
- 宽度固定 `460`（`MenuBarView` 自己的 frame；`MenuBarController.sizeAndPosition` 里那份必须与它相等），高度取 `min(820, 屏幕可见区高度 - 8)`。
  > 早期版本用 `max(400, fittingSize.width)` + `fittingSize.height`：滚动视图没有有用的固有高度，量出来会把会话区压成一条并被裁掉，所以宽度与高度现在都是显式数字。
- 水平：以状态项图标的**全局 x 中心**对齐面板中心（`globalIconX = windowOriginX + btnInWindow.midX`），再 clamp 到屏幕内（左右各留 4pt）。
- 垂直：`y = screen.visibleFrame.maxY - height - 4`，即紧贴菜单栏下方。
- 屏幕取 `statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first`：状态项所在屏优先，所以多显示器下 popup 跟着菜单栏图标走，而不是永远开在主屏；面板打开期间屏幕参数变化（拔显示器、改分辨率）也会重新定位。

**收起监听（`installMonitors`）：**
- `localMonitor`：本 app 内的鼠标按下若**不在 panel.frame 内、也不是挂在该 panel 上的子窗口（`window.parent === panel`，即 SwiftUI popover）**则 `hide()`。旧版只测 frame，落在面板外侧的 popover（电池控制、模型切换）第一下点击就被吞掉。
- `globalMonitor`：其他 app 的鼠标按下一律 `hide()`（切回主线程执行）。

> 单例面板被复用（`panel ?? makePanel()`），`isReleasedWhenClosed = false`，避免反复创建；每次 `show()` 重建 `NSHostingView`（关掉的图不留在树上跑 2 s 风扇轮询与 1 Hz 图表）。
