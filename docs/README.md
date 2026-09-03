# ClaudeBar 文档中心

> 本仓库文档的唯一入口。最后更新：2026-09-03

ClaudeBar 的文档按 **设计（为什么）** 与 **技术（怎么做）** 两层组织。先读设计建立产品上下文，再按需查阅技术实现。

---

## 快速导航

| 我是… | 从这里开始 |
|--------|------------|
| **用户** | [README](../README.md) → [Releases](https://github.com/wangxiajun68/ClaudeBar/releases) 下载 DMG |
| **排障** | [FAQ.md](FAQ.md) |
| **贡献者** | [CONTRIBUTING.md](../CONTRIBUTING.md) → [technical/10-extension-guide.md](technical/10-extension-guide.md) |
| **维护者 / 发版** | [VERSIONING.md](VERSIONING.md) → [RELEASING.md](RELEASING.md) |
| **安全报告** | [SECURITY.md](../SECURITY.md) |

---

## 目录结构

```
docs/
├── README.md                 ← 本文件
├── FAQ.md                    使用与排障
├── RELEASING.md              维护者发版步骤
├── VERSIONING.md             版本号、tag、CHANGELOG 约定
├── CHANGELOG.md              用户可见的版本变更
├── screenshots/              README 界面截图
├── design/                   产品设计（做什么、怎么交互）
│   ├── README.md
│   └── 01–09 *.md
└── technical/                技术实现（代码如何工作）
    ├── README.md
    └── 01–10 *.md
```

---

## 设计文档（`design/`）

回答：**产品是什么、为谁做、边界在哪、界面如何组织。**

| # | 文档 | 摘要 |
|---|------|------|
| 01 | [product-overview](design/01-product-overview.md) | 定位、目标用户、非目标 |
| 02 | [architecture](design/02-architecture.md) | 顶层架构与核心取舍 |
| 03 | [data-models](design/03-data-models.md) | Provider、会话、用量等数据模型 |
| 04 | [popup-layout](design/04-popup-layout.md) | 菜单栏 popup 布局 |
| 05 | [main-window-and-theme](design/05-main-window-and-theme.md) | 主窗口、Theme 与设计 token |
| 06 | [interactions](design/06-interactions.md) | 切换、轮询、通知等交互流程 |
| 07 | [file-structure](design/07-file-structure.md) | 仓库文件树 |
| 08 | [error-handling](design/08-error-handling.md) | 失败场景与降级 |
| 09 | [build-and-distribution](design/09-build-and-distribution.md) | 构建、分发与平台要求 |

完整索引：[design/README.md](design/README.md)

---

## 技术文档（`technical/`）

回答：**模块职责、数据流、构建签名、如何扩展。**

| # | 文档 | 摘要 |
|---|------|------|
| 01 | [tech-stack](technical/01-tech-stack.md) | 技术选型与构建命令 |
| 02 | [app-launch-and-windows](technical/02-app-launch-and-windows.md) | 启动、主窗口与菜单栏面板 |
| 03 | [provider-store](technical/03-provider-store.md) | `ProviderStore` 状态中枢 |
| 04 | [data-access-layer](technical/04-data-access-layer.md) | 文件 I/O、监控与用量索引 |
| 05 | [view-layer](technical/05-view-layer.md) | 视图层与 Theme 用法 |
| 06 | [data-migration](technical/06-data-migration.md) | 数据格式兼容与迁移 |
| 07 | [build-and-signing](technical/07-build-and-signing.md) | 签名、Entitlements、Widget 注册 |
| 08 | [performance](technical/08-performance.md) | 轮询、缓存与性能策略 |
| 09 | [file-index](technical/09-file-index.md) | Swift 文件职责速查 |
| 10 | [extension-guide](technical/10-extension-guide.md) | 扩展功能步骤清单 |

完整索引：[technical/README.md](technical/README.md)

---

## 按任务查阅

| 任务 | 推荐阅读 |
|------|----------|
| 改 popup / 主窗口 UI | [04](design/04-popup-layout.md) · [05](design/05-main-window-and-theme.md) · [technical/05](technical/05-view-layer.md) |
| 改数据采集 | [03](design/03-data-models.md) · [technical/04](technical/04-data-access-layer.md) |
| 改状态与刷新 | [technical/03](technical/03-provider-store.md) |
| 构建 / 签名 / 发版 | [09](design/09-build-and-distribution.md) · [technical/07](technical/07-build-and-signing.md) · [VERSIONING](VERSIONING.md) · [RELEASING](RELEASING.md) |
| 性能优化 | [technical/08](technical/08-performance.md) |
| 边界与错误 | [08](design/08-error-handling.md) |
| 新功能扩展 | [technical/10](technical/10-extension-guide.md) |
| 定位某个文件 | [design/07](design/07-file-structure.md) · [technical/09](technical/09-file-index.md) |

---

## 文档约定

- 每篇设计/技术文档顶部有面包屑：`> ClaudeBar 设计/技术文档 · §N`，并链到相关章节。
- 跨文档引用使用相对路径 Markdown 链接。
- 用户安装方式统一表述为：**GitHub Releases → DMG**；`Sources/build.sh` 仅用于开发与 CI。
- 最低系统版本：**macOS 15+**，**Apple Silicon (arm64)**。
- 技术文档中的 `B1`–`B11`、`D1`–`D3` 指 [CHANGELOG](CHANGELOG.md) `[1.5.0]` 段的审查项编号。
