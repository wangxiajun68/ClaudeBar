# 性能源码入口清单 · 2026-10-05

生成命令：`python3 Tools/performance-inventory.py --date 2026-10-05 --include-native-build`。只扫描源码中的入口标记；不代表逐文件运行测量或 Instruments 验证。空标记也不代表没有性能成本。

共 244 个源码路径，其中 238 个 Swift 路径（包括 Widget 快照符号链接）。

| 文件 | 行数 | 检查入口 |
| --- | ---: | --- |
| `Sources/ClaudeBar/ClaudeBarApp.swift` | 265 | 观察/发布、异步/后台 |
| `Sources/ClaudeBar/MainWindowController.swift` | 210 | 异步/后台 |
| `Sources/ClaudeBar/MenuBarController.swift` | 1114 | 调度、观察/发布、异步/后台、缓存/去重 |
| `Sources/ClaudeBar/Models/AppConfig.swift` | 98 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Models/AppPreferences.swift` | 340 | 观察/发布、异步/后台、派生/解析 |
| `Sources/ClaudeBar/Models/BatteryChargeController.swift` | 475 | 调度、同步 I/O/等待、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Models/CodexProvider.swift` | 152 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Models/CodexProviderStore.swift` | 634 | 调度、观察/发布、同步 I/O/等待、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Models/CodexProxyState.swift` | 119 | 缓存/去重 |
| `Sources/ClaudeBar/Models/ConnectivityTestCenter.swift` | 56 | 观察/发布、异步/后台 |
| `Sources/ClaudeBar/Models/ConnectorManager.swift` | 1216 | 观察/发布、同步 I/O/等待、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Models/CursorUsageStore.swift` | 121 | 调度、观察/发布、异步/后台、缓存/去重 |
| `Sources/ClaudeBar/Models/DocumentMarkup.swift` | 697 | 派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Models/DocumentTable.swift` | 207 | 派生/解析 |
| `Sources/ClaudeBar/Models/FeishuDocumentStore.swift` | 579 | 观察/发布、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Models/IdleTransitionDetector.swift` | 275 | 派生/解析 |
| `Sources/ClaudeBar/Models/IslandLiveModel.swift` | 477 | 调度、观察/发布、异步/后台、派生/解析 |
| `Sources/ClaudeBar/Models/MCPToolDiscovery.swift` | 282 | 异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Models/ModelUsage.swift` | 180 | 派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Models/Preset.swift` | 43 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Models/Provider.swift` | 159 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Models/ProviderBridge.swift` | 357 | 同步 I/O/等待、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Models/ProviderCatalog.swift` | 299 | 派生/解析 |
| `Sources/ClaudeBar/Models/ProviderProfileSync.swift` | 318 | 派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Models/ProviderStore+Derived.swift` | 144 | 派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Models/ProviderStore.swift` | 1357 | 调度、观察/发布、同步 I/O/等待、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Models/ScopedStoreObservation.swift` | 133 | 观察/发布、异步/后台、缓存/去重 |
| `Sources/ClaudeBar/Models/SessionMigration.swift` | 168 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Models/SettingsManager.swift` | 144 | 同步 I/O/等待、派生/解析 |
| `Sources/ClaudeBar/Models/WidgetSnapshot.swift` | 135 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Models/WidgetSnapshotWriter.swift` | 94 | 异步/后台、缓存/去重 |
| `Sources/ClaudeBar/NotchIslandController.swift` | 575 | 调度、观察/发布、缓存/去重 |
| `Sources/ClaudeBar/Theme/Theme.swift` | 630 | 缓存/去重、原生绘制/桥接 |
| `Sources/ClaudeBar/Utils/AgentProtocolBridge.swift` | 354 | 派生/解析 |
| `Sources/ClaudeBar/Utils/AudioAccessoryMonitor.swift` | 1147 | 调度、同步 I/O/等待、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/BalanceFetcher.swift` | 129 | 异步/后台、派生/解析 |
| `Sources/ClaudeBar/Utils/BatteryHelperInstaller.swift` | 119 | 同步 I/O/等待、缓存/去重 |
| `Sources/ClaudeBar/Utils/CNWeatherCityTable.swift` | 367 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Utils/CaptureJSONStore.swift` | 260 | 同步 I/O/等待、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/CaptureMedia.swift` | 195 | 派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/CaptureTranscript.swift` | 511 | 派生/解析 |
| `Sources/ClaudeBar/Utils/CodexAppServerClient.swift` | 218 | 派生/解析 |
| `Sources/ClaudeBar/Utils/CodexConfigWriter.swift` | 623 | 同步 I/O/等待、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/CodexModelCatalog.swift` | 89 | 同步 I/O/等待、派生/解析 |
| `Sources/ClaudeBar/Utils/CodexProxyServer.swift` | 1359 | 调度、同步 I/O/等待、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/CodexProxyTransform.swift` | 1425 | 派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/CodexQuotaFetcher.swift` | 493 | 调度、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/ConnectivityProbe.swift` | 143 | 异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/ConversationMedia.swift` | 50 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Utils/CurrentLocation.swift` | 121 | 异步/后台 |
| `Sources/ClaudeBar/Utils/CursorDB.swift` | 125 | 同步 I/O/等待、派生/解析 |
| `Sources/ClaudeBar/Utils/CursorLedger.swift` | 303 | 异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/CursorLedgerStore.swift` | 314 | 观察/发布、同步 I/O/等待、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/CursorSessionMonitor.swift` | 495 | 同步 I/O/等待、派生/解析 |
| `Sources/ClaudeBar/Utils/CursorUsageFetcher.swift` | 548 | 同步 I/O/等待、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/ExchangeRate.swift` | 244 | 观察/发布、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/ExternalSessionMonitor.swift` | 913 | 同步 I/O/等待、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/FanHelperInstaller.swift` | 149 | 同步 I/O/等待、异步/后台 |
| `Sources/ClaudeBar/Utils/FanMonitor.swift` | 193 | 调度、异步/后台 |
| `Sources/ClaudeBar/Utils/FeishuCLI.swift` | 168 | 调度、同步 I/O/等待、异步/后台、派生/解析 |
| `Sources/ClaudeBar/Utils/FeishuComponentAuthentication.swift` | 55 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Utils/FeishuComponentHost.swift` | 134 | 调度、异步/后台、缓存/去重 |
| `Sources/ClaudeBar/Utils/FilePaths.swift` | 203 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Utils/GreetingPhrase.swift` | 318 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Utils/HardwareSensors.swift` | 409 | 缓存/去重 |
| `Sources/ClaudeBar/Utils/HelperSignature.swift` | 99 | 同步 I/O/等待、缓存/去重 |
| `Sources/ClaudeBar/Utils/JSONCoerce.swift` | 17 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Utils/JSONLineCollector.swift` | 67 | 同步 I/O/等待、派生/解析 |
| `Sources/ClaudeBar/Utils/LaunchAtLogin.swift` | 113 | 观察/发布 |
| `Sources/ClaudeBar/Utils/MachineIdentity.swift` | 168 | 派生/解析 |
| `Sources/ClaudeBar/Utils/MigrationBridgeConfiguration.swift` | 85 | 派生/解析 |
| `Sources/ClaudeBar/Utils/MigrationCursorDesktop.swift` | 266 | 同步 I/O/等待、缓存/去重 |
| `Sources/ClaudeBar/Utils/MigrationCursorHistory.swift` | 447 | 同步 I/O/等待、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/MigrationHistory.swift` | 630 | 派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/MigrationStorage.swift` | 248 | 派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/ModelListFetcher.swift` | 272 | 异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/ModelPriceCatalog.swift` | 523 | 观察/发布、同步 I/O/等待、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/ModelPriceSources.swift` | 599 | 异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/ModelPriceTable.swift` | 172 | 缓存/去重 |
| `Sources/ClaudeBar/Utils/ModelPricing.swift` | 732 | 派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/NotchGeometry.swift` | 34 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Utils/NotificationService.swift` | 232 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Utils/OttyBridge.swift` | 181 | 调度、同步 I/O/等待、异步/后台、派生/解析 |
| `Sources/ClaudeBar/Utils/PermissionCenter.swift` | 274 | 调度、观察/发布、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/PrivateFileWriter.swift` | 43 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Utils/ProcessMemoryRow.swift` | 38 | 同步 I/O/等待、派生/解析 |
| `Sources/ClaudeBar/Utils/ProcessSampler.swift` | 1013 | 调度、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/ProxyAccessLog.swift` | 569 | 调度、观察/发布、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/ProxyCaptureStore.swift` | 1150 | 调度、观察/发布、同步 I/O/等待、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/ProxyInflight.swift` | 137 | 异步/后台 |
| `Sources/ClaudeBar/Utils/ProxyUsageStore.swift` | 342 | 同步 I/O/等待、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/SMCController.swift` | 334 | 缓存/去重 |
| `Sources/ClaudeBar/Utils/ScreenshotHotKey.swift` | 243 | 观察/发布、异步/后台 |
| `Sources/ClaudeBar/Utils/ScreenshotOverlay.swift` | 1279 | 异步/后台、派生/解析、原生绘制/桥接 |
| `Sources/ClaudeBar/Utils/SessionHost.swift` | 149 | 异步/后台、缓存/去重 |
| `Sources/ClaudeBar/Utils/SessionMigrationService.swift` | 239 | 同步 I/O/等待、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/SessionMonitor.swift` | 857 | 同步 I/O/等待、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/SessionTitle.swift` | 218 | 缓存/去重 |
| `Sources/ClaudeBar/Utils/ShellQuote.swift` | 13 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Utils/SkyAstronomy.swift` | 128 | 缓存/去重 |
| `Sources/ClaudeBar/Utils/SolarTerm.swift` | 388 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Utils/StreamAssembler.swift` | 387 | 派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/SystemThroughput.swift` | 122 | 调度、观察/发布 |
| `Sources/ClaudeBar/Utils/TerminalLauncher.swift` | 271 | 异步/后台 |
| `Sources/ClaudeBar/Utils/UIWakePolicy.swift` | 84 | 观察/发布、异步/后台、缓存/去重 |
| `Sources/ClaudeBar/Utils/UsageAnalysis.swift` | 192 | 派生/解析 |
| `Sources/ClaudeBar/Utils/UsageClaims.swift` | 195 | 同步 I/O/等待、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/UsageFSWatcher.swift` | 89 | 调度、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/UsageIndex.swift` | 1292 | 同步 I/O/等待、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/UsageJSONStore.swift` | 337 | 同步 I/O/等待、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/UsageModelInventory.swift` | 89 | 派生/解析 |
| `Sources/ClaudeBar/Utils/UsageProviderInventory.swift` | 81 | 派生/解析 |
| `Sources/ClaudeBar/Utils/UsageStats.swift` | 162 | 缓存/去重 |
| `Sources/ClaudeBar/Utils/VPNPreferences.swift` | 38 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Utils/VpnDomainLog.swift` | 681 | 调度、观察/发布、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/VpnDomainQuery.swift` | 90 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Utils/VpnHTTP.swift` | 69 | 异步/后台、缓存/去重 |
| `Sources/ClaudeBar/Utils/VpnLiveRates.swift` | 121 | 调度、观察/发布、异步/后台、缓存/去重 |
| `Sources/ClaudeBar/Utils/VpnManager.swift` | 1433 | 调度、观察/发布、同步 I/O/等待、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/VpnNetProbe.swift` | 290 | 调度、观察/发布、异步/后台、派生/解析 |
| `Sources/ClaudeBar/Utils/VpnProviderDirect.swift` | 178 | 同步 I/O/等待、派生/解析 |
| `Sources/ClaudeBar/Utils/VpnSubscriptionStore.swift` | 964 | 调度、观察/发布、同步 I/O/等待、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/VpnSystemProxyController.swift` | 325 | 调度、同步 I/O/等待、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/WeatherAmapFetcher.swift` | 118 | 异步/后台、派生/解析 |
| `Sources/ClaudeBar/Utils/WeatherCNFetcher.swift` | 51 | 异步/后台 |
| `Sources/ClaudeBar/Utils/WeatherFetcher.swift` | 907 | 观察/发布、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/WeatherForecastFetcher.swift` | 185 | 异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/WiFiNameAuthorization.swift` | 65 | 调度、观察/发布、异步/后台、缓存/去重 |
| `Sources/ClaudeBar/Utils/WorkflowMonitor.swift` | 235 | 派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Utils/XZArchive.swift` | 85 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Island/IslandComponents.swift` | 545 | 调度、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Island/IslandShape.swift` | 40 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Island/NotchIslandView.swift` | 682 | 观察/发布 |
| `Sources/ClaudeBar/Views/MainWindowView.swift` | 477 | 派生/解析、缓存/去重、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/MenuBarView.swift` | 256 | 调度 |
| `Sources/ClaudeBar/Views/Pages/ConnectorDetailSheet.swift` | 304 | 同步 I/O/等待、异步/后台、派生/解析 |
| `Sources/ClaudeBar/Views/Pages/ConnectorsView.swift` | 1134 | 观察/发布、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Views/Pages/CursorTokenUsageCard.swift` | 108 | 观察/发布、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Views/Pages/DashboardView.swift` | 349 | 派生/解析 |
| `Sources/ClaudeBar/Views/Pages/FeishuDocumentsView.swift` | 746 | 调度、观察/发布、异步/后台、派生/解析、缓存/去重、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Pages/FeishuOperationSheet.swift` | 282 | 观察/发布、异步/后台、派生/解析 |
| `Sources/ClaudeBar/Views/Pages/HelpView.swift` | 262 | 派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Views/Pages/ProvidersView.swift` | 458 | 调度、观察/发布 |
| `Sources/ClaudeBar/Views/Pages/ProxyLogView.swift` | 300 | 调度、观察/发布、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Views/Pages/SessionsView.swift` | 1069 | 派生/解析 |
| `Sources/ClaudeBar/Views/Pages/SettingsView.swift` | 615 | 观察/发布、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Views/Pages/TrafficView.swift` | 1282 | 调度、观察/发布、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Views/Pages/UsageView.swift` | 513 | 观察/发布、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Views/Pages/VPNSubscriptionSection.swift` | 289 | 观察/发布、异步/后台、缓存/去重 |
| `Sources/ClaudeBar/Views/Pages/VPNView.swift` | 1145 | 调度、观察/发布、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Views/Pages/VpnDomainLogSection.swift` | 760 | 调度、异步/后台、缓存/去重 |
| `Sources/ClaudeBar/Views/Popup/PanelHeader.swift` | 706 | 观察/发布 |
| `Sources/ClaudeBar/Views/Popup/PanelState.swift` | 17 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Popup/SessionsPanel.swift` | 108 | 派生/解析 |
| `Sources/ClaudeBar/Views/Popup/UsagePanel.swift` | 159 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/APIKeyField.swift` | 59 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/AgentSwarmView.swift` | 401 | 派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Views/Shared/Atmosphere/AtmosphereRenderer.swift` | 1004 | 异步/后台、缓存/去重、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/Atmosphere/AtmosphereShader.swift` | 767 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/Atmosphere/AtmosphereView.swift` | 474 | 调度、异步/后台、缓存/去重、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/Atmosphere/GreetingScript.swift` | 434 | 派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Views/Shared/Atmosphere/SkyScene.swift` | 378 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/BatteryChargeControls.swift` | 128 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/BrandMark.swift` | 21 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/CodeBlock.swift` | 110 | 调度、异步/后台 |
| `Sources/ClaudeBar/Views/Shared/CodexCleanupDialog.swift` | 42 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/CodexModelMark.swift` | 58 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/CodexQuotaGauges.swift` | 182 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/CommandPalette.swift` | 335 | 派生/解析 |
| `Sources/ClaudeBar/Views/Shared/ConnectionCard.swift` | 360 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/ContextBar.swift` | 26 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/CursorSessionCardView.swift` | 103 | 派生/解析 |
| `Sources/ClaudeBar/Views/Shared/DecorativeMotion.swift` | 342 | 调度、缓存/去重、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/DiskUsagePanel.swift` | 56 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/DocumentInlineEditor.swift` | 319 | 异步/后台、缓存/去重、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/DocumentTableView.swift` | 238 | 调度、观察/发布、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Views/Shared/ExchangeRateTile.swift` | 101 | 观察/发布、异步/后台 |
| `Sources/ClaudeBar/Views/Shared/ExternalSessionCardView.swift` | 113 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/FanInternalsPanel.swift` | 126 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/FeedbackToast.swift` | 42 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/FeishuOfficialDocumentView.swift` | 193 | 调度、异步/后台、缓存/去重、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/GlassCard.swift` | 30 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/GreetingCard.swift` | 1580 | 调度、观察/发布、异步/后台、缓存/去重 |
| `Sources/ClaudeBar/Views/Shared/GreetingInstruments.swift` | 992 | 原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/HardwareDetailPanel.swift` | 471 | 调度、观察/发布、派生/解析、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/HardwareIllustration.swift` | 480 | 派生/解析、缓存/去重、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/HeartbeatSparkline.swift` | 35 | 原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/HelpCatalog.swift` | 539 | 缓存/去重 |
| `Sources/ClaudeBar/Views/Shared/InstrumentControls.swift` | 1315 | 调度、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/InstrumentGlyph.swift` | 214 | 原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/InstrumentSearchField.swift` | 68 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/InstrumentWidgets.swift` | 79 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/Interaction.swift` | 562 | 调度、异步/后台、缓存/去重、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/JSONTreeView.swift` | 427 | 观察/发布、异步/后台、派生/解析 |
| `Sources/ClaudeBar/Views/Shared/LucideHardwareGeometry.swift` | 140 | 缓存/去重 |
| `Sources/ClaudeBar/Views/Shared/LucideHardwarePaths.swift` | 68 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/LucideRotor.swift` | 253 | 缓存/去重、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/MachineKpiStrip.swift` | 370 | 原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/MemoryDetailPanel.swift` | 65 | 异步/后台 |
| `Sources/ClaudeBar/Views/Shared/ModelImportSheet.swift` | 116 | 派生/解析 |
| `Sources/ClaudeBar/Views/Shared/ModelPriceCard.swift` | 656 | 观察/发布、异步/后台、派生/解析 |
| `Sources/ClaudeBar/Views/Shared/PermissionsSection.swift` | 124 | 观察/发布 |
| `Sources/ClaudeBar/Views/Shared/PlainDumpView.swift` | 67 | 原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/PowerFlowCard.swift` | 766 | 派生/解析、缓存/去重、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/ProductBrandMark.swift` | 227 | 缓存/去重 |
| `Sources/ClaudeBar/Views/Shared/ProviderConnectionEditor.swift` | 360 | 派生/解析 |
| `Sources/ClaudeBar/Views/Shared/ProviderControls.swift` | 374 | 派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Views/Shared/ProviderDirectory.swift` | 525 | 派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Views/Shared/ProviderModelFetchButton.swift` | 60 | 异步/后台 |
| `Sources/ClaudeBar/Views/Shared/ProviderQuickSetup.swift` | 122 | 派生/解析 |
| `Sources/ClaudeBar/Views/Shared/ProxyCurlExample.swift` | 30 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/ProxyUpstreamPickers.swift` | 84 | 观察/发布 |
| `Sources/ClaudeBar/Views/Shared/ResourceStrip.swift` | 487 | 派生/解析 |
| `Sources/ClaudeBar/Views/Shared/SectionHeader.swift` | 112 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/SessionCardView.swift` | 195 | 派生/解析 |
| `Sources/ClaudeBar/Views/Shared/SessionMigrationDialog.swift` | 357 | 观察/发布、异步/后台、派生/解析 |
| `Sources/ClaudeBar/Views/Shared/SessionStatusViews.swift` | 65 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/SettingsControls.swift` | 87 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/SignatureGlyph.swift` | 72 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/SkillMarkdownPreview.swift` | 636 | 同步 I/O/等待、异步/后台、派生/解析、缓存/去重 |
| `Sources/ClaudeBar/Views/Shared/SourceRing.swift` | 96 | 派生/解析 |
| `Sources/ClaudeBar/Views/Shared/StandbyEmptyState.swift` | 83 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/Tile.swift` | 505 | 缓存/去重、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/UiverseKit.swift` | 227 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/UiverseSurfaces.swift` | 586 | 调度、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/UsageAnalytics.swift` | 316 | 异步/后台、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/UsageHeatmap.swift` | 318 | 缓存/去重、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/UsageModelCard.swift` | 295 | 观察/发布、缓存/去重 |
| `Sources/ClaudeBar/Views/Shared/UsageViz.swift` | 77 | 缓存/去重 |
| `Sources/ClaudeBar/Views/Shared/VPNSurface.swift` | 11 | 输入/事件/纯值路径 |
| `Sources/ClaudeBar/Views/Shared/VpnTopChrome.swift` | 233 | 观察/发布 |
| `Sources/ClaudeBar/Views/Shared/WeatherBackdrop.swift` | 629 | 调度、原生绘制/桥接 |
| `Sources/ClaudeBar/Views/Shared/WeatherReadingSky.swift` | 32 | 输入/事件/纯值路径 |
| `Sources/Shared/BuildChannel.swift` | 66 | 输入/事件/纯值路径 |
| `Sources/Widget/ClaudeBarWidget.swift` | 16 | 输入/事件/纯值路径 |
| `Sources/Widget/WidgetProvider.swift` | 102 | 同步 I/O/等待、派生/解析 |
| `Sources/Widget/WidgetSnapshot.swift` | 135 | 输入/事件/纯值路径 |
| `Sources/Widget/WidgetViews.swift` | 653 | 派生/解析、缓存/去重 |
| `Sources/batteryctl/batteryctl.c` | 234 | 调度 |
| `Sources/batteryctl/policy.h` | 36 | 输入/事件/纯值路径 |
| `Sources/build-config.sh` | 39 | 输入/事件/纯值路径 |
| `Sources/build.sh` | 595 | 缓存/去重 |
| `Sources/ensure-dev-cert.sh` | 163 | 输入/事件/纯值路径 |
| `Sources/fanctl/fanctl.c` | 272 | 调度、缓存/去重 |
