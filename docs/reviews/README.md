# 历史审查与测量证据

此目录保存具体构建、机器和日期下的测量、问题清单与修复过程。内容保留实验上下文，不作为当前架构或性能保证。当前实现按模块维护在 [技术文档](../technical/README.md)；发布变更维护在 [CHANGELOG](../CHANGELOG.md)。

## 性能与渲染审查

- [Apple 官方性能规范摘录：前端渲染与后端运行时](apple-performance-docs-2026-10-05.md)（官方文档调研摘录、本项目系统集成边界与自检清单；不含本项目读数）
- [性能与并发（历史测量记录）](performance-measurements.md)
- [苹果官方性能文档与模块优化审查](apple-performance-audit-2026-10-03.md)（[源码入口清单](performance-source-inventory-2026-10-03.md)、[合成测量样本](performance-module-measurements-2026-10-03.json)）
- [第二轮：日志尾读取、MCP 取消与 JSON 用量路径索引](apple-performance-followup-2026-10-04.md)（[后端样本](performance-backend-measurements-2026-10-04.json)、[日志样本](performance-access-tail-measurements-2026-10-04.json)、[基线补丁](performance-round2-baseline-2026-10-04.patch)）
- [第三轮：苹果 UI、动效与能源流增量更新](apple-ui-performance-2026-10-04.md)（[组件更新样本](performance-ui-animation-measurements-2026-10-04.json)、[实际 xctrace 采样](performance-xctrace-ui-2026-10-04.json)）
- [正式版 Instruments 审查与热点优化](apple-release-performance-audit-2026-10-04.md)（[页面、CPU、GPU、内存和生产函数对照](performance-release-audit-2026-10-04.json)）
- [后续模块：命令、帮助、Widget、额度与流量生命周期](apple-remaining-performance-audit-2026-10-04.md)（[全部源码入口](performance-remaining-source-2026-10-04.md)、[源码哈希与入口行号](performance-remaining-source-2026-10-04.json)、[测量与验证](performance-remaining-audit-2026-10-04.json)）
- [模型库存、供应商搜索与灵动岛性能优化](apple-inventory-performance-2026-10-04.md)（[对照、Instruments 与验证](performance-inventory-audit-2026-10-04.json)）
- [原生文档、额度显示与 VPN 查询细节优化](apple-native-detail-performance-2026-10-05.md)（[生产函数对照、Instruments 与验证](performance-native-detail-audit-2026-10-05.json)）
- [概览与天气卡片性能审查](apple-weather-overview-performance-2026-10-05.md)（[生命周期、GPU 与 Instruments 对照](performance-weather-overview-audit-2026-10-05.json)）
- [连接器、迁移历史与文档目录性能审查](apple-module-scheduling-performance-2026-10-05.md)（[调度、取消、定位与 Instruments 对照](performance-module-scheduling-audit-2026-10-05.json)）
- [核心用量算法：家族归属与日期范围查询](apple-core-algorithms-performance-2026-10-05.md)（[复杂度、CPU 与内存对照](performance-core-algorithms-2026-10-05.json)）
- [全模块性能与帧工作复核](apple-frame-performance-2026-10-05.md)（[测量、源码哈希与验证](performance-frame-audit-2026-10-05.json)、[244 个源码入口清单](performance-frame-source-2026-10-05.md)、[逐文件哈希](performance-frame-source-2026-10-05.json)）
- [原生前端性能：表格与文档目录](apple-frontend-native-performance-2026-10-05.md)（[测量与源码指纹](performance-frontend-native-2026-10-05.json)）
- [逐页前端性能：会话、模型与连接器](apple-page-frontend-performance-2026-10-05.md)（[测量与源码指纹](performance-page-frontend-2026-10-05.json)）
- [低负载、滚动与动效性能审查](performance-audit-2026-09-30.md)
- [天气卡片雨效、文字与性能](weather-card-measurements-2026-09-30.md)
- [桌面、Popup 与灵动岛性能审查](rendering-audit.md)
- [UI 与交互审查记录](ui-audit-backlog.md)

## 会话迁移

- [Codex / Claude Code 会话迁移可行性调研](session-migration-research-2026-10-03.md)（[隔离复现脚本](session-migration-probe-2026-10-03.py)、[结果](session-migration-probe-results-2026-10-03.json)；不含真实模型调用，含 paginated 会话格式边界）
- [Codex、Cursor、Claude Code 会话互迁与模型切换：深度调研及真实验证](session-migration-deep-research-2026-10-03.md)（[真实结果](session-migration-live-results-2026-10-03.json)、[嫁接原型](session-migration-lab-2026-10-03/README.md)；原型使用真实客户端与模型，默认不运行真实请求）
- [会话迁移首版实现与验收记录](session-migration-implementation-2026-10-03.md)（[脱敏真实续聊结果](session-migration-swift-live-results-2026-10-03.json)）
- [会话迁移第二阶段：Cursor 桌面接收与工具交接](session-migration-phase2-implementation-2026-10-03.md)（[脱敏真实续聊结果](session-migration-phase2-live-results-2026-10-03.json)）
- [会话迁移第三阶段：实现、实测与边界](session-migration-phase3-implementation-2026-10-03.md)（[脱敏真实验收结果](session-migration-phase3-live-results-2026-10-03.json)）

## 其他专项审查

- [灵动岛会话监控深度审查](island-session-monitor-audit-2026-10-01.md)（[复现脚本](island-session-monitor-repro-2026-10-01.py)）
- [问候创意字体调研与管理](greeting-font-research-2026-10-01.md)
- [电池管理深度审查](battery-control-audit-2026-09-27.md)
- [飞书文档渲染调研与建议](feishu-rendering-research-2026-10-03.md)（官方组件、原生 TextKit 2 与 HTML 阅读层三条路线的取舍；官方组件于同日落地，其余未实施）
