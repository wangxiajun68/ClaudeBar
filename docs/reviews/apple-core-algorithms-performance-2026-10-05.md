# 核心用量算法：家族归属与日期范围查询 · 2026-10-05

本轮修改 `UsageIndex` 与 `UsageJSONStore` 两条核心数据路径，消除批量会话查询中的重复全库遍历和父链查找，并为 JSON 日期查询建立范围索引。此前的调度、目录跳转等工作保留；本报告只记录本轮算法收益。[生产源码哈希、测量与验证](performance-core-algorithms-2026-10-05.json)。

苹果建议先依据测量选择重要的 CPU 工作，再通过算法和数据结构减少成本；缓存还需要考虑失效与内存代价。[WWDC25 CPU 性能](https://developer.apple.com/videos/play/wwdc2025/308/)。后台执行不能代替算法效率，数据结构复用与高效算法同样重要。[CPU 工作调度](https://developer.apple.com/documentation/xcode/scheduling-cpu-work-efficiently)。本轮使用优化源码探针与 Time Profiler 验证，未把合成 CPU 收益换算成实机 FPS。

## 会话家族归属算法

`IslandLiveModel` 按客户端批量查询会话费用。`UsageIndex.fetchSessionFamilies` 虽然只取一次数据库/JSON 快照，之后仍逐个查询 ID 遍历所有 transcript。Codex 对每个 ID、每个文件重新沿 parent 链查找，使用 visited Set 防环；批次越大、父链越深，重复工作越多。

令 Q 为查询 ID 数，P 为文件数，h 为父链深度。在路径长度有界时，原 Claude 匹配约为 O(QP)，Codex 约为 O(QPh)，随后还需合并模型行。

新实现将“对每个 ID 搜全部文件”改为“每个文件计算所属的查询 ID”：

1. Claude 单次拆分路径，查询文件 ID 和各个 `/id/subagents/` 边界，不为每个请求重新执行 contains/hasSuffix。
2. Codex 用迭代遍历解析父链，缓存每个节点的已解析归属；遇到已解析节点直接复用，遇到环则让环内节点共享同一组查询 ID。
3. 归属使用共享、不可变的祖先链接。若每个节点都查询，将完整祖先 Set 复制到每个节点会产生二次方内存；共享链接把图缓存本身控制在 O(H+Q)，H 为访问到的图节点数。
4. 每个文件按所属 ID 直接累加模型计数，避免先构造每个家族的巨大行数组再合并。文件名 fallback 与 metadata 归属做集合并集，同一文件在一个家族中只计一次。

新实现不保证所有输入都是简单的 O(P)：仍需处理路径字符串、遍历实际命中的查询祖先、为各家族合并模型。若一个文件属于很多被查询的祖先，就必须产生相应归属结果。它消除的是未命中 ID 的整库扫描、重复走过的非查询父节点，以及逐节点复制完整祖先集合。

保留未知 ID 的空结果、重复 ID 合并、归档文件、零用量中间父节点、缺失父节点、环/自环、文件名与元数据 ID 不同、带连字符 ID、多级 workflows、嵌套 subagents 和 Unicode 路径。SQLite/JSON 的快照读取与 header mtime/size 失效规则保留，Token 归属和已有调用去重规则没有改变。

## JSON 日期范围索引

原 `fetch`、`fetchByPath`、`fetchDaily`、`fetchDailyModels` 不论查询一天还是全部，都遍历 rollup 的 R 行。

增加 `day → rollup keys` 索引，日期成员变化时才失效排序缓存。查询用两次二分查找定位包含端点的字符串范围，再访问匹配日期的行。暖索引窄范围约为 O(log D + Rwindow)，D 为日期数；首次排序为 O(D log D)。日期仍采用原来的字符串比较，保留空边界、非标准日期、倒置范围与模型/来源过滤。

逐行哈希查找并非总比扫描快。查询覆盖较多行时，先按日期桶计数，达到总行数的 1/16 后改为扫描；全部历史直接扫描。这个阈值来自本机窄/宽窗口夹具，不是所有机器的最优值。宽范围仍为 O(R)，不宣称所有查询都加速。

索引由原有锁保护，新增行、删除、替换、旧 composite-key 碰撞转移、读取持久化、迁移清理与 reset 同步维护。已有行的同键增量计数不重建索引；同一天的 Token 追加不重新排序日期。磁盘格式、schema、parser generation 和版本身份保持原样。

## 固定输入对照

Command Line Tools Swift，arm64/macOS 15，`-O -g`。旧生产函数冻结为测试 oracle；修改后的生产算法直接抽取执行。临时目录与合成数据不访问真实账号、rollout 或用户配置。

| 核心计算 | 基线 | 修改后 |
| --- | ---: | ---: |
| Claude：4,000 文件，8 ID | 39.335ms | 4.651ms |
| Claude：4,000 文件，64 ID | 302.572ms | 4.847ms |
| Claude：4,000 文件，256 ID | 1,214.842ms | 5.339ms |
| Codex：4,000 文件、16 层链，8 ID | 47.974ms | 7.410ms |
| Codex：同数据，64 ID | 310.391ms | 6.982ms |
| Codex：同数据，256 ID | 1,244.022ms | 7.554ms |
| Codex：12,000 层链、全部 ID、仅叶子有用量 | 7,360.696ms | 11.024ms |
| JSON：128,000 行、128 日期，20 次单日查询 | 22.286ms | 1.959ms |
| JSON：同数据，20 次十日查询 | 30.164ms | 31.669ms |
| JSON：同数据，20 次全部历史查询 | 112.445ms | 124.627ms |

除深链和保存外，每组是单进程五次观测的中位数；深链是一次观测。256 个查询 ID 中有六个缺失根。JSON 查询测量前已完成日期排序。全历史样本约慢 11%，十日窗口没有改善；保留这些结果，不推广窄窗口收益。全历史路径仍直接遍历原字典，后续需更多交替录制归因，不能凭这两次进程运行证明稳定回退或稳定提速。

最终源码定向复测中，20 次单日/十日/全部历史查询分别为 2.420 / 33.898 / 114.630ms；家族查询和深链收益仍保持。该复测说明宽窗口与全历史读数有波动，未用于选择或覆盖上表的初始对照。

回归覆盖 60 组固定种子的随机函数图，对全部 ModelUsage 字段与旧算法比较；另验证 12,000 层遍历没有计算递归，密集祖先查询输出 12,000 个正确家族。四种 JSON 查询与独立逐行 oracle 对比，覆盖来源、范围、删除/替换/增量、新增/消失日期、碰撞、保存、重新载入及 reset。耗时不作为 CI 门槛。

## Instruments 与内存取舍

Time Profiler 独立使用相同固定工作量：4,000 Codex 文件、16 层链，每批 64 ID 共十批；随后初始化 128,000 条 Claude 行，再执行 1,000 次单日查询。两组 checksum 都为 16,163,840。

| sampled CPU 权重 | 基线 | 修改后 |
| --- | ---: | ---: |
| 总权重（CLI 主线程） | 4,271ms | 440ms |
| 家族归属 inclusive | 2,877ms | 68ms |
| JSON fetch inclusive | 1,163ms | 91ms |
| JSON addRollup inclusive | 141ms | 170ms |

两组各录制一次，包含初始化与种子写入；inclusive 有重叠，不可相加。真实 Island 调用已在 utility worker，这个 CLI 主线程权重不能当作应用 UI 主线程阻塞时间。归属探针不包含 SQLite GROUP BY、获取完整快照或真实 header I/O；没有安装新代码后的整页延迟/FPS 对照。

同一较小驱动程序另在无 Instruments 的独立进程执行，峰值 RSS 为 **72.25MiB → 80.69MiB**。这是整个驱动的单次 high-water 观察，包含准备与临时对象，不是精确索引分配。完整正确性夹具的峰值为 180.02MiB → 220.77MiB，包含 oracle、密集链和大量临时参考字典，不能当作应用常态内存。本次明确用额外日期索引空间和写入维护成本换取窄范围查询效率；图缓存不再二次方复制，但也不宣称应用整体内存降低。

## 验证和剩余范围

- 全回归 **75 组通过，403.05 秒**，新组 `core-algorithms` 登记在 Makefile；既有 usage-index 的 SQLite/JSON 真实索引、解析、迁移与会话家族验证通过。
- 定向 usage-index、backend-performance、usage-analysis 三组通过，30.97 秒；新算法的基线/修改后夹具均通过。
- 最终源码的 core-algorithms 再次通过，14.90 秒；实验性强制 inline 未显示收益，已移除，生产代码保持完整回归与构建验证的实现。
- dev / release 构建与宿主/Widget 身份、URL scheme、App Group、entitlements、签名门禁通过；仅构建，未安装。
- Python 编译检查与 `git diff --check` 通过。正式构建仍有本轮未修改的 VpnManager actor 隔离/多余 try 和 linker 重复 rpath 警告。
- 原始 trace、探针、对照源码及日志在 gitignored `.build/performance/core-algorithms-2026-10-05/`，目录 0700；录制使用最小环境，只导出 time-profile 表。公开报告没有进程环境或用户数据。

本轮另外筛查会话 tail 解析、用量 claim/index 更新、统计分位数与日期解析、会话标题和页面派生入口，没有因源码出现 filter/sorted 就改写。日期解析、SQLite 全快照、JSON 全库保存、tail 中多次 JSON 解码、密集多模型输出仍是后续独立归因对象；没有声称这些算法均已彻底优化。没有运行真实 VPN、系统代理、DNS、TUN、硬件、权限或外部连接器控制。

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
make test TEST="core-algorithms usage-index backend-performance"
```
