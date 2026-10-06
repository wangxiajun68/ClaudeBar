# 扩展指南

> ClaudeBar 技术文档 · §10
> 相关：技术文档 [数据访问层](04-data-access-layer.md) · [视图层](05-view-layer.md)

## 新增一个 env 字段
1. `Preset.swift` 的 `EnvConfig` 加属性（合成 `Codable`，无手写 `CodingKeys`；字段多了要同时改 `init` 与 `SettingsManager.readSettings`）。
2. `SettingsManager.swift` 的 `readSettings` 加读取（`writeSettings` 走 `managedEnvKeys` + 非空写回，新键要加进 `managedEnvKeys` 才会被清除语义覆盖）。
3. `ProviderStore.buildEnv` 赋值。
4. 若需 UI 编辑，加在用户真正会打开的编辑器上：`ProviderConnectionModel`（`Views/Shared/ProviderConnectionEditor.swift`）+ `ProviderConnectionDraft` 的读写、`ProvidersView.connectionDraft` / `saveConnection` 的往返。只改这条路 —— 源码里曾有一套同名近似的 `ProviderEditorModel` / `ProviderEditorView`（无挂载点），已删除，见 [审查证据](../reviews/ui-audit-backlog.md) §3。

## 新增一个 Provider 级余额源
1. `BalanceFetcher.Source` 加 case 与端点 URL。
2. `BalanceFetcher.source(for:)` 按 baseURL host 分发（`ProviderStore.refreshBalance` 只调用 `supports` / `fetch`，按 token + baseURL 分组去重，不自己认 host）。

## 新增 Widget 尺寸
1. `ClaudeBarWidget.swift` 的 `supportedFamilies` 加项（当前只有 `.systemLarge`）。
2. `WidgetViews` 按 `widgetFamily` 分支布局（目前不读 `widgetFamily`，只有一档布局）。

## 新增 Cursor 之外的第二 IDE 监控
1. 新建 `Utils/<Ide>SessionMonitor.swift` + 数据模型（现例：Codex 走 `Utils/ExternalSessionMonitor.swift`）。
2. `ProviderStore` 加 `@Published var` 会话数组 + `refreshXxxSessions()`（照 `refreshCursorSessions` 的 detached-task 模式）。
3. popup 加 `Views/Popup/` 区段、主窗口 `SessionsView` 加 section，`writeWidgetSnapshot` 加字段；若属于 `ExternalAgentKind`，两处都按 `ExternalAgentKind.allCases` 自动铺开。
4. `WidgetSnapshot` 加对应 summary 类型（`Widget/WidgetSnapshot.swift` 是指向主模型目录的符号链接，同步即可）。

## 新增 VPN 探测站点或切换策略

见 [11-vpn.md](11-vpn.md)。探测列表在 `VpnNetProbe`；failover 阈值在 `VpnManager.tickFailover`。不要把订阅 URL 写进仓库。

## 新增一类空闲通知
1. `NotificationService` 加 `notifyIdle(...)` 变体与 category（如需独立动作；现例：`IDLE_SESSION` 与 `NEEDS_INPUT`）。
2. `ProviderStore` 为该来源加一个 `ConfirmedCompletionDetector<ID>` 实例，在刷新回调里喂入 `(id, isBusy, turnKey, fresh)` 四元组——`turnKey` 必须是「这一轮交付了什么」的本地权威键（见 `ProviderStore.detectIdleTransitions` 里三家各自取什么）。
3. `AppDelegate` 的 `.resumeSession` 处理器补对应恢复逻辑（当前按 `userInfo["agent"]` 分 claude / cursor / codex 三路）。
4. 若该来源还会「停在用户身上」而 `isBusy` 仍为真，用 `WaitingStateDetector<ID>` 走 `NEEDS_INPUT` 那条边（Claude / Cursor 已有；Codex 目前不报告该状态）。
