# 历史审查与测量证据

此目录保存具体构建、机器和日期下的测量、问题清单与修复过程。内容保留实验上下文，不作为当前架构或性能保证。当前实现按模块维护在 [技术文档](../technical/README.md)；发布变更维护在 [CHANGELOG](../CHANGELOG.md)。

- [历史性能测量](performance-measurements.md)
- [苹果性能文档与模块优化审查](apple-performance-audit-2026-10-03.md)（[源码入口清单](performance-source-inventory-2026-10-03.md)、[合成测量样本](performance-module-measurements-2026-10-03.json)）
- [第二轮：日志尾读取、MCP 取消与 JSON 用量路径索引](apple-performance-followup-2026-10-04.md)（[后端样本](performance-backend-measurements-2026-10-04.json)、[日志样本](performance-access-tail-measurements-2026-10-04.json)）
- [第三轮：苹果 UI、动效与能源流增量更新](apple-ui-performance-2026-10-04.md)（[组件更新样本](performance-ui-animation-measurements-2026-10-04.json)、[实际 xctrace 采样](performance-xctrace-ui-2026-10-04.json)）
- [正式版 Instruments 审查与热点优化](apple-release-performance-audit-2026-10-04.md)（[页面、CPU、GPU、内存和生产函数对照](performance-release-audit-2026-10-04.json)）
- [后续模块：命令、帮助、Widget、额度与流量生命周期](apple-remaining-performance-audit-2026-10-04.md)（[全部源码入口](performance-remaining-source-2026-10-04.md)、[测量与验证](performance-remaining-audit-2026-10-04.json)）
- [模型库存、供应商搜索与灵动岛性能优化](apple-inventory-performance-2026-10-04.md)（[对照、Instruments 与验证](performance-inventory-audit-2026-10-04.json)）
- [原生文档、额度显示与 VPN 查询细节优化](apple-native-detail-performance-2026-10-05.md)（[生产函数对照、Instruments 与验证](performance-native-detail-audit-2026-10-05.json)）
- [概览与天气卡片性能优化](apple-weather-overview-performance-2026-10-05.md)（[生命周期、GPU 与 Instruments 对照](performance-weather-overview-audit-2026-10-05.json)）
- [连接器、迁移历史与文档目录性能优化](apple-module-scheduling-performance-2026-10-05.md)（[调度、取消、定位与 Instruments 对照](performance-module-scheduling-audit-2026-10-05.json)）
- [会话迁移深度调研及真实验证](session-migration-deep-research-2026-10-03.md)
- [会话迁移 Swift 首版实现与验收](session-migration-implementation-2026-10-03.md)（[脱敏真实续聊结果](session-migration-swift-live-results-2026-10-03.json)）
- [会话迁移第二阶段：Cursor 桌面接收与工具交接](session-migration-phase2-implementation-2026-10-03.md)（[脱敏真实续聊结果](session-migration-phase2-live-results-2026-10-03.json)）
- [刷新与渲染审查](rendering-audit.md)
- [UI 审查证据](ui-audit-backlog.md)
- [低负载与动效审查](performance-audit-2026-09-30.md)
- [天气卡视觉与 GPU 测量](weather-card-measurements-2026-09-30.md)
- [电池控制审查](battery-control-audit-2026-09-27.md)
- [问候字体研究](greeting-font-research-2026-10-01.md)
- [灵动岛会话监控审查](island-session-monitor-audit-2026-10-01.md)（复现脚本 [island-session-monitor-repro-2026-10-01.py](island-session-monitor-repro-2026-10-01.py)）
- [Codex / Claude Code 会话迁移调研](session-migration-research-2026-10-03.md)（隔离复现脚本与结果，包含当前 paginated 会话格式边界）
- [Codex / Cursor / CC 六方向深度调研与真实验证](session-migration-deep-research-2026-10-03.md)（[真实结果](session-migration-live-results-2026-10-03.json)、[嫁接原型](session-migration-lab-2026-10-03/README.md)；含官方/自定义模型切换与失败对照）
