# ClaudeBar 设计文档

> 产品 / 交互设计。技术实现细节见 [../technical/](../technical/) 目录。

本目录是 ClaudeBar 的产品设计文档，描述"做什么"与"怎么交互"。按序号渐进阅读：

| # | 文件 | 内容 | 何时读 |
|---|------|------|--------|
| 01 | [product-overview.md](01-product-overview.md) | 产品定位、目标用户、非目标 | 先读：了解 ClaudeBar 是什么 |
| 02 | [architecture.md](02-architecture.md) | 顶层架构图 + 核心设计取舍表 | 再读：整体结构与关键决策 |
| 03 | [data-models.md](03-data-models.md) | Provider/ModelConfig/EnvConfig/迁移/WidgetSnapshot 数据结构 | 改数据层时读 |
| 04 | [popup-layout.md](04-popup-layout.md) | 菜单栏 popup 面板 560pt 布局 + Popup/ 五文件拆分 + 供应商/会话/用量宫格 | 改 popup 时读 |
| 05 | [main-window-and-theme.md](05-main-window-and-theme.md) | 主窗口 NavigationSplitView + 5 Pages 宫格 + Shared 组件层 + Theme token | 改主窗口/视觉时读 |
| 06 | [interactions.md](06-interactions.md) | 切换 Provider、会话轮询、用量统计、编辑、Widget 联动 5 大流程 | 理解行为时读 |
| 07 | [file-structure.md](07-file-structure.md) | 仓库文件树（含每个 .swift 一行职责） | 找文件时读 |
| 08 | [error-handling.md](08-error-handling.md) | 各失败场景的降级行为 | 处理边界情况时读 |
| 09 | [build-and-distribution.md](09-build-and-distribution.md) | 构建/运行/最低系统/分发 | 构建发布时读 |

**返回** [文档总索引](../README.md)
