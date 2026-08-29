# ClaudeBar 文档总索引

> 本文件是 agent 与人类阅读 ClaudeBar 文档的**唯一入口**。
> 最后更新：2026-08-29

ClaudeBar 文档分为两层，按「为什么（设计）→ 怎么做（技术）」组织。每层都有独立的 README 索引与「何时读」指引，便于渐进阅读。

```
docs/
├── README.md              ← 你在这里：总索引 + 阅读路线
├── design/                设计文档（产品/交互/视觉，描述「为什么」）
│   ├── README.md          设计文档索引
│   └── 01..09-*.md
├── technical/             技术文档（实现细节，描述「怎么做」）
│   ├── README.md          技术文档索引
│   └── 01..10-*.md
└── CHANGELOG.md           版本变更记录
```

---

## 两层文档定位

| 层 | 目录 | 回答的问题 | 读者 |
|----|------|-----------|------|
| 设计 | `design/` | 这是什么、为谁做、怎么交互、边界在哪 | 想理解产品意图与行为 |
| 技术 | `technical/` | 代码怎么实现、数据从哪来、如何扩展 | 想改代码或排查实现 |

---

## 推荐阅读路线（agent 渐进读取）

### 第一站：产品与架构（设计层，必读）
1. [design/01-product-overview.md](design/01-product-overview.md) — ClaudeBar 是什么、目标用户、非目标
2. [design/02-architecture.md](design/02-architecture.md) — 顶层架构图 + 核心设计取舍
3. [design/07-file-structure.md](design/07-file-structure.md) — 仓库文件树（找文件入口）

### 第二站：技术实现（技术层，按任务选读）
4. [technical/01-tech-stack.md](technical/01-tech-stack.md) — 技术选型与构建
5. [technical/02-app-launch-and-windows.md](technical/02-app-launch-and-windows.md) — 启动与双窗口管理
6. [technical/03-provider-store.md](technical/03-provider-store.md) — 状态中枢与刷新管线

### 按任务直达
| 你要做什么 | 读这些 |
|-----------|--------|
| 改 popup / 主窗口 UI | [design/04](design/04-popup-layout.md)、[design/05](design/05-main-window-and-theme.md)、[technical/05](technical/05-view-layer.md) |
| 改数据采集/读写 | [design/03](design/03-data-models.md)、[technical/04](technical/04-data-access-layer.md) |
| 理解交互行为 | [design/06](design/06-interactions.md) |
| 改数据格式 | [technical/06](technical/06-data-migration.md) |
| 构建/签名/发布 | [design/09](design/09-build-and-distribution.md)、[technical/07](technical/07-build-and-signing.md) |
| 优化性能 | [technical/08](technical/08-performance.md) |
| 处理边界/错误 | [design/08](design/08-error-handling.md) |
| 扩展新功能 | [technical/10](technical/10-extension-guide.md) |
| 找某个文件 | [technical/09](technical/09-file-index.md) |
| 看版本变更 | [CHANGELOG.md](CHANGELOG.md) |

---

## 约定

- 每个拆分文件顶部有面包屑：`> ClaudeBar 设计/技术文档 · §N`，并标注相关文档的相对链接。
- 跨文档引用使用相对 markdown 链接，如 `[数据访问层](../technical/04-data-access-layer.md#锚点)`。
- 技术文档中的 `B1`–`B11` 指代码审查的 bug 修复项，`D1`–`D3` 指结构优化项，详见 [CHANGELOG.md](CHANGELOG.md) 的 `[1.5.0]` 段。
