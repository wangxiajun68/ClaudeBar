# 关键文件索引

> ClaudeBar 技术文档 · §9
> 相关：设计文档 [文件结构](../design/07-file-structure.md) · [VPN](11-vpn.md)

| 文件 | 职责 |
|------|------|
| `ClaudeBarApp.swift` | AppDelegate：激活策略、启动时序、`claudebar://`、空闲通知 Resume |
| `MenuBarController.swift` | NSStatusItem + NSPanel；`MenuBarMark` 矢量模板标；VPN 运行时 `VpnMenuBarRateView` |
| `MainWindowController.swift` | 主窗口 NSWindow + vibrancy |
| `ProviderEditorWindowController.swift` | 编辑器独立 NSWindow |
| `Models/ProviderStore.swift` | Claude 状态中枢；`activateModel(..., syncPeer:)` |
| `Models/CodexProviderStore.swift` | Codex 状态中枢 + 本机代理生命周期 |
| `Models/AppPreferences.swift` | 空闲通知、代理端口、第三方上游、VPN mixed-port / 系统代理 / TUN 等 |
| `Utils/FilePaths.swift` | Claude / Codex / Cursor / App Group / `vpnDir` |
| `Utils/VpnManager.swift` | mihomo 进程、测速、流量流、超时 failover |
| `Utils/VpnHTTP.swift` | 控制器 HTTP，禁用系统代理 |
| `Utils/VpnSubscriptionStore.swift` | 订阅、YAML 合成、`tuneForStability` |
| `Utils/VpnSystemProxyController.swift` | `networksetup` + Guard + TUN DNS |
| `Utils/VpnNetProbe.swift` | 连通性探测 |
| `Utils/FanMonitor.swift` | SMC 风扇 / 温度 |
| `Utils/ScreenshotHotKey.swift` | Carbon 全局 ⌘⇧A |
| `Utils/ScreenshotOverlay.swift` | ScreenCaptureKit 拉框截图 |
| `Theme/Theme.swift` | 设计 token |
| `Views/MainWindowView.swift` | 7 页 `AppPage`；流量页常驻 |
| `Views/MenuBarView.swift` | popup 壳：Header + ResourceStrip + 三区 |
| `Views/Pages/VPNView.swift` | VPN 主界面 |
| `Views/Shared/VpnTopChrome.swift` | 仅 popup 的 VPN chrome |
| `Views/Shared/UsageRiver.swift` | 用量日柱 |
| `Views/Shared/FanControlSection.swift` | 设置页风扇 |
| `Views/Shared/ProxyUpstreamPickers.swift` | 本地代理：CC/Codex 只读 + 第三方上游选择 |
| `Sources/ensure-dev-cert.sh` | 本机 ClaudeBar Dev 代码签名身份 |
| `Sources/Widget/*.swift` | WidgetKit |
| `Sources/build.sh` | 构建 / 签名 / 安装 / 拉取 mihomo |
