# 苹果性能优化第二轮 · 2026-10-04

继续处理 [第一轮审查](apple-performance-audit-2026-10-03.md) 中的首次日志载入、MCP 等待与非 SQLite 用量后端。三条路径都先以隔离夹具确认基线，再调整生产逻辑并交替复测。保留仓库里其他灵动岛、用量、VPN 域名日志及风扇界面工作，不安装或启动应用，不修改真实用户配置、VPN、系统代理、硬件或 TCC。

## 苹果官方依据与本轮范围

- 再次网络检索并阅读 [Visualize and optimize Swift concurrency · WWDC22](https://developer.apple.com/videos/play/wwdc2022/110350/)：阻塞文件或 semaphore 等待放到 Dispatch，通过 continuation 使 Swift task 挂起；避免协作线程池被占满。此次直接应用于 MCP stdio 发现和代理首次请求的日志载入。
- [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)：长时间同步文件读取不能放在视图构造路径。本轮把访问日志初始化改为空状态，再由后台读取队列发布历史。
- [Optimize CPU performance with Instruments · WWDC25](https://developer.apple.com/videos/play/wwdc2025/308/)：先减少算法工作。本轮将按会话删除/替换的全汇总扫描，改为路径到键的内存索引。
- [Making changes to reduce memory use](https://developer.apple.com/documentation/xcode/making-changes-to-reduce-memory-use)：减少不必要的大对象保留。本轮不再为只展示 500 条记录加载并拆分整份常规 LF JSONL。

这些资料为方法依据；下表数值来自本项目生产函数的合成夹具。没有把微基准当作整页 FPS、实际 App 常驻内存或整机功耗。

## 生产修改及行为约束

| 路径 | 实现与边界 |
| --- | --- |
| `UsageJSONStore` | 保留原有字典、JSON/JSONL 文件格式和迁移规则，增加路径到汇总键的索引。替换/删除只处理该路径记录，单会话查询扫描路径后聚合匹配键。添加、重载、迁移、reset 同步维护索引；保留参数路径与实际 row.path 不同，以及旧复合键碰撞时的行为。所有索引操作仍在原锁下。 |
| `MCPToolDiscovery` | stdio 阻塞工作在共享 Dispatch utility 队列，异步调用通过 checked throwing continuation 挂起。独立取消状态唤醒 collector；进程锁串行化启动/停止，取消队列清理本次发现的子进程。取消前启动、初始化等待、分页等待与请求结束都检查所有权；所有分支只恢复一次 continuation。保留逐请求 10 秒预算、分页上限、运行器禁止列表与 HTTP 路径。只列元数据，不调用 tools/call。 |
| `ProxyAccessLog` | 构造不读文件。视图出现后在串行队列以 64 KiB 块倒读，找到末尾 500 个有效记录即停止。先拼接跨块片段，再做宽容 UTF-8 解码；保留 CRLF、Unicode 分隔符、损坏行跳过、无换行的完整末行和原顺序。后台读盘不持有请求状态锁。 |
| 历史与请求并发 | 代理在 `startLog` 异步等待 `prepareForRequests`，历史就绪后才分配递增 ID；不会占用协作池等待文件。同步 `begin` 保留兼容性回退，生产代理调用均先异步准备。clear 将历史标为已消费，尚在读取的旧结果不能覆盖新记录；本进程尚未使用历史 ID 时清空，可从 1 开始。每个新请求仍立即写入内存，快照沿用 100 ms 发布窗口。 |
| UI 与格式器 | `entries` 由 MainActor 隔离；请求状态使用锁，输出日期格式器只由 ioQueue 使用，历史读取使用独立格式器。`@unchecked Sendable` 基于这些所有权边界，使队列桥接无需新增并发警告。 |

VPN 节点浏览器也复核了派生路径：当前实现已经在一次 `nodeBrowserList` 构建中生成代理字典及 livePath 集合，再供节点复用。没有实际更新轨迹证明需要跨 body 的新缓存，因此本轮保留实现；真实大节点列表的帧时间仍待测量。

## 前后对照

基线为第二轮开始时的源文件快照：`MCPToolDiscovery`、`UsageJSONStore` 与 `037dc2d` 一致；`ProxyAccessLog` 已包含第一轮批量发布/尾解码，但仍同步读取整份文件。其差异归档为 [基线补丁](performance-round2-baseline-2026-10-04.patch)，重建后逐字节检查一致。

两臂均 `swiftc -O -parse-as-library`，独立进程各三次，顺序 before/after、after/before、before/after。机器 Apple M3 Pro / arm64 / Swift 6.3.2。输入为临时合成文件与本夹具自己的 Python MCP 服务；不读取真实会话、凭据、MCP 配置或代理日志。

### JSON 后端与 MCP

2,000 个路径，每个 32 个按日期/模型汇总行，共 64,000 行；替换 400 个路径两遍；查询和删除各 400 个路径。模拟 MCP 对初始化或第一页工具回复故意等待 1.2 秒，ready 文件确定已经进入等待后再取消。原始样本见 [后端测量 JSON](performance-backend-measurements-2026-10-04.json)。

| 指标 | 修改前中位数 | 修改后中位数 |
| --- | ---: | ---: |
| 800 次会话替换 | 12,912.348 ms | 50.410 ms |
| 400 次会话删除 | 5,735.770 ms | 3.973 ms |
| 400 次单会话查询 | 1,646.668 ms | 24.610 ms |
| 首次添加 64,000 行 | 104.042 ms | 134.231 ms |
| 初始化等待期间取消 | 1,200.684 ms | 0.079 ms |
| 工具分页等待期间取消 | 1,202.988 ms | 0.058 ms |
| 整段后端合成进程峰值 RSS | 77.312 MiB | 66.844 MiB |


**索引有建立成本**：首次添加变慢约 30 ms，换取之后避免多次全表过滤。RSS 是包含生成行、持久化、重载和运行库的整段合成进程峰值，不能推断每条索引的常驻内存成本。默认仍为 SQLite，本轮收益适用于关闭 SQLite 的后端。

MCP 耗时是从任务 cancel 到调用返回的时间，**不是子进程实际退出的时间**。另外检查了模拟子进程随后退出、没有等到延迟回复、预先取消不会启动进程、重复取消后仍能正常发现。没有连接真实第三方 MCP；不承诺拒绝 SIGTERM 的任意外部服务都能这样退出。

### 访问日志

50,000 条有效记录及损坏尾部，文件共 25,838,905 字节。夹具在 Python 驱动中先生成文件，测量 Swift 进程只读取日志和运行验证。原始样本见 [日志测量 JSON](performance-access-tail-measurements-2026-10-04.json)。

| 指标 | 修改前中位数 | 修改后中位数 |
| --- | ---: | ---: |
| 日志对象构造（主 actor） | 383.052 ms | 1.134 ms |
| 日志读取/解码工作 | 381.418 ms | 41.227 ms |
| 读取 payload 字节量 | 25,838,905.000 bytes | 262,144.000 bytes |
| 整段日志合成进程峰值 RSS | 66.484 MiB | 13.812 MiB |


新读取工作在后台，返回 UI 的历史快照仍需等待既有 100 ms 发布窗口。`module-performance` 现在分开记录 `log_construct_ms` 与 `log_load_ms`：后者包括后台读取和发布等待，不可与第一轮同步函数耗时直接比较。

读取字节数由夹具在生产读取点统计 payload，**不是物理磁盘 I/O**，缓存状态未受控。RSS 为整段测试进程峰值；新臂额外执行了 100 个并发首次请求的历史/ID 检查。普通 LF JSONL 可在尾部停止，但仅用 CR/Unicode 分隔符的手工文件，或极长损坏记录，可能需要读取更大范围；不声称所有损坏文件都有固定内存上限。

## 回归与构建

- `make test`：61 组全部通过，300.94 秒。Makefile 新登记 `backend-performance` 与 `access-log-tail`，CI 使用同一清单。
- MainActor 隔离收尾后补跑 `make test TEST="module-performance access-log-tail"`：两组通过，12.84 秒；这两组没有新增并发编译警告。
- `make build`、`make release`：全部成功，构建检查确认 dev/release 身份、Widget、URL scheme、entitlements 与包签名。没有安装或启动两个版本。
- JSON 回归包括桶总量守恒、重复替换、空替换、外部 row.path、复合键碰撞、save/reset/load 与删除后再载入；已有 `usage-index` 回归继续覆盖两个后端的解析、迁移、重复计费和会话关系。
- 日志回归包括跨块 Unicode、CRLF、Unicode 分隔符、180 KB 损坏尾行、无末尾换行、空/缺失文件、历史 ID 延续、100 个并发首次请求、载入暂停期间 clear+新请求及重复载入。
- MCP 回归包括初始化、两页工具、参数排序、默认描述、EOF、错误/无效回复、禁止安装型运行器、初始化/分页取消、预先取消和取消后重试。
- 保留已有 release `VpnManager` actor/无 throwing 的 try 警告及重复 rpath；不通过隐藏编译失败处理它们。签名使用现有本机证书，并非公证发布。

## 重建基线与复测

以下命令只生成临时源文件和测量结果，不应用补丁到工作仓库：

```bash
perf_baseline_dir=$(mktemp -d)
git show 037dc2d:Sources/ClaudeBar/Models/MCPToolDiscovery.swift > "$perf_baseline_dir/MCPToolDiscovery.swift"
git show 037dc2d:Sources/ClaudeBar/Utils/UsageJSONStore.swift > "$perf_baseline_dir/UsageJSONStore.swift"
git show 037dc2d:Sources/ClaudeBar/Utils/ProxyAccessLog.swift > "$perf_baseline_dir/ProxyAccessLog.swift"
patch -d "$perf_baseline_dir" -p1 -i "$PWD/docs/reviews/performance-round2-baseline-2026-10-04.patch"
make test TEST="backend-performance access-log-tail"
python3 Tests/backend-performance-regressions.py --baseline-dir "$perf_baseline_dir" \
  --output-json /tmp/claudebar-backend-measurements.json
python3 Tests/access-log-tail-regressions.py --baseline-file "$perf_baseline_dir/ProxyAccessLog.swift" \
  --output-json /tmp/claudebar-tail-measurements.json
```

测量文件包含输入规模、工具链、基线/当前源码 SHA-256 与原始三次样本。毫秒数不作为 CI 硬阈值；协议与状态断言用于回归。

## 尚未验证的性能边界

本机仍只有 Command Line Tools，不能运行 Instruments 的 SwiftUI/Hitches、Swift Concurrency、Allocations、File Activity 和 Power Profiler。全应用 FPS、可见/遮挡/隐藏时的 CPU/GPU、真实持续流量的日志体验、VPN 大节点列表和官方飞书组件仍需相同数据与窗口条件下的实际测量。本轮没有用测试通过或源码覆盖来宣称每一个模块已经最优。
