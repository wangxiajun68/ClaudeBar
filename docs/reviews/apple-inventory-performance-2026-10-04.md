# 模型库存、供应商搜索与灵动岛性能优化 · 2026-10-04

本轮完成四项改动：模型库存按输入在后台准备并缓存、供应商空查询避免构建搜索文本、灵动岛会话花费查询合并、关闭灵动岛时不再重启翼栏刷新。沿用原有状态模型、视图身份、业务刷新和提醒逻辑；未安装、启动或退出正式版，未操作 VPN、硬件、真实账户或系统权限。

[三次对照、Instruments 摘要、源码哈希和验证结果](performance-inventory-audit-2026-10-04.json)保留实验口径。完整模块范围及未覆盖场景继续见[上一轮审查](apple-remaining-performance-audit-2026-10-04.md)。

## 依据与改动

苹果的 [SwiftUI 性能建议](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)要求避免在 body 反复计算昂贵结果，并异步准备、缓存。其 [Task 文档](https://developer.apple.com/documentation/swift/task/)说明取消需要任务合作检查，丢弃句柄不会自动停止任务。本轮据此处理重复准备及失效请求，未引入新的任务框架或后台服务。

| 路径 | 原问题 | 改动及实际验证 |
| --- | --- | --- |
| `UsageView.modelBreakdown` / `UsageModelInventory` | 重绘时重复合并、归一化、计价和排序，规模探针单次约 11 ms | 使用包含本地模型、来源、Cursor 账单、成本和窗口的 Equatable 请求；utility worker 准备，`.task(id:)` 仅随输入变化重启；保持上次完整结果，首次显示小型进度提示。 |
| 模型库存的取消与计费快照 | 后台工作如果取消或窗口变更仍可能继续，异步结果不能混用新账单说明 | 各阶段合作检查取消；发布时检查任务和当前请求；金额及账期说明来自同一已准备快照。回归执行真实准备方法，验证未就绪窗口、过期结果、取消、价格更新、仅结算金额变化及相等结果不重复发布。 |
| `ProviderCatalogBrowser.custom` | 空查询仍为每条配置拼接供应商、地址和全部模型，再转小写；有效查询对每条配置重复标准化关键词 | 每次过滤只标准化一次关键词，空查询直接返回原序列表。标题、地址、模型、Unicode、空白/换行和无匹配结果与原规则一致。 |
| `IslandLiveModel.reloadSessionCosts` | 每次刷新新建独立查询，代次只丢弃旧结果，未减少已排队查询 | 一个在途批次，加一个最新尾批次；批次期间的新请求合并；任务尚未开始前的突发直接使用最新输入。验证索引被阻塞时 100 次刷新、最新成本、旧会话淘汰及 Cursor-only 清空。 |
| `NotchIslandController.applyWings` | 保留后台提醒模型后，关闭岛时修改翼栏设置仍可重新启用 600 秒刷新 | 周期刷新同时要求翼栏显示和岛功能启用；提醒模型继续保留。执行真实方法验证启用、关闭、隐藏翼栏三种状态。 |

本轮五个生产文件均记录最终 SHA-256。跨目标快照字段、配置格式、默认 dev 身份及系统集成闸门没有改变。

## 可复现对照

基线 `c985f1f`，两臂均 `swiftc -O`，独立进程交替运行三次。全部数据为合成夹具，记录完整输出一致性；耗时不作为 CI 阈值。

| 指标 / 每次样本 | 基线中位数 | 改后中位数 | 解读 |
| --- | ---: | ---: | --- |
| 4,000 个本地模型、1,001 个 Cursor 模型，20 次结果读取所需准备 | 215.22 ms | 11.37 ms | 减少约 94.72%；基线每次重算，改后准备一次再读取缓存。 |
| 同输入单次库存准备 | 11.10 ms | 11.42 ms | 增加约 2.9%；合作取消检查有成本，收益来自避免重复工作及移出主线程。 |
| 4,000 配置 × 每条 20 模型，20 次空查询 | 602.61 ms | 0.00246 ms | 直接返回列表，跳过字符串构造；微小耗时受计时精度和优化器影响，不转换为 App FPS。 |
| 同配置，20 次 ` Claude ` 查询 | 667.87 ms | 638.12 ms | 减少约 4.46%；三次样本有波动，只是该夹具下的小幅收益。 |
| 首个索引查询暂停时，共 101 次刷新发起的查询 | 101 | 2 | 旧实现最多 12 个同时进入模拟索引，新实现最多 1 个。不是实际 SQLite 并发查询数或实机能耗。 |

库存对照测量的是转换与结果读取，未包含 SwiftUI 布局、diff、请求值比较或实际卡片渲染；真实准备方法另由异步回归执行。不存在“单次算法更快”或“整机 CPU 降低 94.72%”的结论。

回归还比较全部库存行的 ID、Token、来源、别名、Cursor 明细和成本行，与原实现相等；覆盖零值、缺失价格及别名合并。取消返回的空值只由任务取消/过期检查拦截，不作为有效页面结果发布。

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools make test TEST="inventory-performance island-coalescing usage-index usage-analysis island-session-alert"
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 Tests/inventory-performance-regressions.py \
  --compare --baseline-ref c985f1f --output-json /tmp/claudebar-inventory-comparison.json
```

## Instruments

使用本机 xctrace 的 Time Profiler 启动隔离生产源码探针（`-O -g`），录制 **8.096 秒**，正常结束。探针保留真实 `refreshModelRows` 的 utility worker、取消与发布代码，强制调用 500 次以观察线程调度；真实页面不会对同一输入循环 500 次。

共 7,199 个采样：库存转换相关 5,518 个后台样本、34 个主线程样本。后者来自探针开始时直接调用库存函数的正确性及微基准段；后台样本包含真实准备方法的 detached closure。后台路径已观测，不代表实际 App 的 body、GPU 或帧率前后对照。

原 trace、符号化探针及 XML 留在 gitignored 的 `.build/performance/inventory-audit-2026-10-04/`，目录 0700；报告只保留函数名和统计，不发布原始数据。所有输入合成，无真实会话、凭据、网络请求或用户文件。

## 验证与边界

- 全回归 **67 组通过，315.35 秒**；定向 5 组及最后两组通过。
- dev / release 构建成功；两版 bundle ID、执行文件、Widget 与 App Group 隔离；宿主/Widget entitlement 组一致，deep/strict 签名通过，快照符号链接正确。
- Python 编译检查、`git diff --check` 通过。
- 尚未安装本轮代码，未做实际 App 的所有卡片/窗口组合、长期内存或电池能耗对照。异步快照会额外保留已准备数据；本轮没有证明内存下降。
- 灵动岛保持一个正在执行的批次，后续请求合并；没有尝试中断正在执行的同步索引查询。安全 watchdog、VPN 与特权工具节奏保留。
