# 技术文档

> ClaudeBar 实现细节，与 `Sources/` 代码对应。产品设计见 [../design/](../design/)。

本目录描述 **怎么做**。建议先读设计文档了解意图，再按章节或任务索引查阅实现。

---

## 文档列表

| # | 文件 | 内容 | 何时读 |
|---|------|------|--------|
| 01 | [tech-stack.md](01-tech-stack.md) | 技术选型、构建命令、Bundle 结构 | 了解技术栈 / 改构建 |
| 02 | [app-launch-and-windows.md](02-app-launch-and-windows.md) | 启动、主窗口、菜单栏面板 | 改窗口 / 启动时序 |
| 03 | [provider-store.md](03-provider-store.md) | `ProviderStore`、刷新管线、空闲通知 | 改状态与轮询 |
| 04 | [data-access-layer.md](04-data-access-layer.md) | 文件路径、监控、用量索引、余额 | 改数据采集 |
| 05 | [view-layer.md](05-view-layer.md) | Theme、视图组件、Popup / Pages | 改 UI |
| 06 | [data-migration.md](06-data-migration.md) | 数据格式兼容 | 改持久化格式 |
| 07 | [build-and-signing.md](07-build-and-signing.md) | 签名、Entitlements、Widget 注册 | 改签名 / 发布 |
| 08 | [performance.md](08-performance.md) | 轮询、缓存、性能策略 | 优化性能 |
| 09 | [file-index.md](09-file-index.md) | Swift 文件职责速查 | 快速定位代码 |
| 10 | [extension-guide.md](10-extension-guide.md) | 扩展功能检查清单 | 加新能力前 |

---

## 推荐阅读顺序

1. [01 技术栈](01-tech-stack.md)
2. [02 启动与窗口](02-app-launch-and-windows.md)
3. [03 ProviderStore](03-provider-store.md)
4. [04 数据访问层](04-data-access-layer.md)
5. [05 视图层](05-view-layer.md)
6. 其余按需查阅

**返回** [文档中心](../README.md) · [设计文档](../design/README.md)
