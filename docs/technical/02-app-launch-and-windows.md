# 应用启动与窗口管理

> ClaudeBar 技术文档 · §2
> 相关：设计文档 [顶层架构](../design/02-architecture.md) · [主窗口与设计系统](../design/05-main-window-and-theme.md) · 技术文档 [视图层](05-view-layer.md)

ClaudeBar 以 `.regular` 激活策略运行：Dock 图标 + 主窗口（`MainWindowController`）+ 菜单栏 status item popup（`MenuBarController`）。两个 UI 面共享同一个 `ProviderStore` 状态中枢。

## 入口 `ClaudeBarApp.swift`

```swift
@main
struct ClaudeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}
```

使用 `@NSApplicationDelegateAdaptor` 而非 SwiftUI `MenuBarExtra`，因为面板需要自定义毛玻璃、居中定位、失焦收起等行为，`MenuBarExtra` 无法满足。

`AppDelegate.applicationDidFinishLaunching`：
1. `NSApp.setActivationPolicy(.regular)` — 含 Dock 图标与主窗口，仍是完整应用。
2. 构造 `ProviderStore`（单例状态中枢，`init()` 留空，不在此处 refresh）。
3. 构造 `MenuBarController(providerStore:)` 并 `setup()` 创建菜单栏图标。
4. 构造 `MainWindowController(providerStore:)` 并 `showWindow()` 显示主窗口。
5. 注册两个通知观察者：`.showMainWindow`（popup 的"打开主窗口"按钮 post）与 `.resumeSession`（空闲通知的 Resume 动作，携带 `userInfo["pid"]`，经 `TerminalLauncher.resumeClaudeSession` 恢复）。
6. `store.refresh()` 触发首次全量刷新（此时窗口/状态栏均已就绪，时序可控）。

> **设计取舍（B7）**：`ProviderStore.init()` 不调 `refresh()`，统一由 AppDelegate 启动时调用——若 `init()` 内刷新会先于窗口/状态栏就绪跑文件 I/O 与后台任务，而 AppDelegate 又会再调一次造成重复。`init` 只做空初始化。

其余生命周期入口：

- `application(_:open:)` 处理 `claudebar://` URL scheme —— Widget 点击时经由此入口唤起菜单栏 popup（`showPanel()`）。
- `applicationShouldHandleReopen` — Dock 图标被再次点击时若主窗口已关闭则重开主窗口。
- `applicationShouldTerminateAfterLastWindowClosed` 返回 `false` —— 关闭主窗口/编辑窗口不应退出 app（status item 保活）。

## `MainWindowController` — 主窗口

主窗口的承载与生命周期：

- **NSWindow**：1120×720，`contentRect`，`.underWindowBackground` vibrancy（`NSVisualEffectView` material = `.underWindowBackground`，`blendingMode: .behindWindow`），`styleMask` 含 `.titled`/`.fullSizeContentView`/`.closable`/`.miniaturizable`，`titlebarAppearsTransparent = true`，`titleVisibility = .hidden`。
- **内容宿主**：`NSHostingView(rootView: MainWindowView().environmentObject(providerStore))` —— `ProviderStore` 通过 environment 注入，popup 与主窗口共享同一实例。
- **生命周期**：`showWindow()` 调 `makeKeyAndOrderFront` + `NSApp.activate(ignoringOtherApps: true)`。窗口持有为强引用保活；`applicationShouldHandleReopen` 在窗口被关后重新 `showWindow()`。

## `MainWindowView` — 主窗口内容

`NavigationSplitView`，sidebar + detail（`.frame(minWidth: 900, minHeight: 600)`）：

- **Sidebar**（`Theme.sidebarFill` + 玻璃背景）：brand 头（`BrandMark` 应用图标 + "ClaudeBar"）+ 5 项 `AppPage`（概览/会话/供应商/用量/设置）。每项 `SidebarRowButton`：图标 + 标签 + 实时计数 badge（会话/供应商页，`contentTransition(.numericText())`）；选中项为 accent 填充（`Theme.claude.opacity(0.18)`），hover 变亮。底部 footer：状态圆点（busy 蓝闲灰）+ "N 运行中/空闲"。
- **Detail**：按 `selectedPage` 切换 `DashboardView` / `SessionsView` / `ProvidersView` / `UsageView` / `SettingsView`，纯 opacity 过渡（`Theme.Motion.page`）。
- **CommandPalette**（⌘K）：跨页面模糊搜索导航（隐藏 Button 承载 keyboardShortcut）。

## `MenuBarController` — 面板的承载与定位

核心职责：维护 `NSStatusItem`、创建并复用一个 `NSPanel`、处理显示/隐藏、点击外部收起。

**面板特性（`makePanel`）：**
- 类型 `KeyablePanel: NSPanel`，`canBecomeKey = true` / `canBecomeMain = false` —— 可成为 key window（SwiftUI Alert/控件需 key）但不激活应用。
- `styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView]` —— 非激活面板，隐藏标题栏按钮。
- `backgroundColor = .clear` + `NSVisualEffectView(material: .menu, blendingMode: .behindWindow)` —— 毛玻璃背景，材质与系统菜单栏下拉一致。
- `appearance = .vibrantDark`、`collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]` —— 全空间可见、全屏辅助。
- `hidesOnDeactivate = false`、`isFloatingPanel = true` —— 悬浮且不因失焦隐藏（自行用事件监听收起）。

**定位逻辑（`sizeAndPosition`）：**
- 宽度 `max(560, fittingSize.width)`，高度上限为屏幕可见区高度 -8。
- 水平：以状态项图标的**全局 x 中心**对齐面板中心（`globalIconX = windowOriginX + btnInWindow.midX`），再 clamp 到屏幕内。
- 垂直：`y = screen.visibleFrame.maxY - height - 4`，即紧贴菜单栏下方。
- 使用 `NSScreen.screens.first`（主屏）而非 `NSScreen.main`，因为后者可能是负 origin 的副屏。

**收起监听（`installMonitors`）：**
- `localMonitor`：本 app 内的鼠标按下若不在 panel.frame 内则 `hide()`。
- `globalMonitor`：其他 app 的鼠标按下一律 `hide()`（切回主线程执行）。

> 单例面板被复用（`panel ?? makePanel()`），`isReleasedWhenClosed = false`，避免反复创建。
