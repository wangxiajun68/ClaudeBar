# 技术文档索引（technical/）

> ClaudeBar 文档 · [返回总索引](../README.md) · [设计文档索引](../design/README.md)

本目录描述 ClaudeBar 的**实现细节**，与 `Sources/` 代码一一对应。按章节编号渐进阅读，或按「何时读」按需查阅。

| # | 文件 | 内容 | 何时读 |
|----|------|------|--------|
| 01 | [tech-stack.md](01-tech-stack.md) | 技术选型表、build.sh 编译命令、Bundle 结构 | 了解技术栈/改构建时读 |
| 02 | [app-launch-and-windows.md](02-app-launch-and-windows.md) | 入口 AppDelegate、MainWindowController、MainWindowView、MenuBarController 面板定位 | 改窗口/启动时序时读 |
| 03 | [provider-store.md](03-provider-store.md) | ProviderStore 状态中枢、refresh() 管线、空闲通知、loadProviders 探测、activateModel 写入 | 改状态/刷新逻辑时读 |
| 04 | [data-access-layer.md](04-data-access-layer.md) | FilePaths、SettingsManager、Widget 快照四路写入、SessionMonitor、CursorSessionMonitor、UsageStats、BalanceFetcher | 改数据采集/读写时读 |
| 05 | [view-layer.md](05-view-layer.md) | Theme token、MenuBarView + Popup/、ProviderTile、ProviderEditorView、Widget 视图 | 改 UI 视图时读 |
| 06 | [data-migration.md](06-data-migration.md) | 数据格式现状、Provider Decodable 旧字段兼容 | 改数据格式时读 |
| 07 | [build-and-signing.md](07-build-and-signing.md) | codesign 自底向上流程、Entitlements、签名陷阱、Widget 注册 | 改签名/发布时读 |
| 08 | [performance.md](08-performance.md) | 轮询/心跳/DB/transcript/用量各点性能策略表 | 优化性能时读 |
| 09 | [file-index.md](09-file-index.md) | 关键 Swift 文件→职责速查表 | 找文件时读 |
| 10 | [extension-guide.md](10-extension-guide.md) | 新增 env 字段/余额源/Widget 尺寸/IDE 监控/空闲通知的步骤 | 扩展功能时读 |

## 推荐阅读顺序

**先读设计文档**（`../design/README.md`）了解「为什么」，再读本目录了解「怎么做」：

1. [01-tech-stack.md](01-tech-stack.md) — 整体技术骨架
2. [02-app-launch-and-windows.md](02-app-launch-and-windows.md) — 启动到双窗口
3. [03-provider-store.md](03-provider-store.md) — 状态如何流动
4. [04-data-access-layer.md](04-data-access-layer.md) — 数据从哪来
5. [05-view-layer.md](05-view-layer.md) — 如何渲染
6. 其余按需查阅
