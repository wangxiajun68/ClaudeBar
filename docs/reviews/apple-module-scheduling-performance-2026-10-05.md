# 连接器、迁移历史与文档目录性能审查 · 2026-10-05

从 `a75f9b4` 继续检查其他模块，修改五个生产文件。本轮找到并复现了连接器重复扫描、迁移历史取消后继续读取及文档目录点击重新扫描全文的问题。[测量与逐文件哈希](performance-module-scheduling-audit-2026-10-05.json)记录 17 个重点入口；这份清单代表源码检查范围，不代表全部运行场景已测量。此前的全模块入口及页面观察见 [上一轮报告](apple-frame-performance-2026-10-05.md)。

## 苹果依据与修改

苹果建议减少无关的 SwiftUI 数据更新，并及时完成视图更新。[SwiftUI 性能](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)。后台工作仍会争用 CPU，应减少不必要的并行工作，而不是只把它移出主线程。[CPU 工作调度](https://developer.apple.com/documentation/xcode/scheduling-cpu-work-efficiently)。大文本处理应避免阻塞交互路径。[应用响应性](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)。Task 取消是协作式的，需要工作本身检查取消状态。[Task 文档](https://developer.apple.com/documentation/swift/task)。

| 路径 | 原问题 | 修改 |
| --- | --- | --- |
| `ConnectorManager.refresh` | 每次请求启动一个 detached 扫描；generation 仅丢弃旧结果，没有减少旧扫描的 I/O。过期完整扫描的 CLI 发现结果也可能被后续项目扫描丢弃。 | 同时只运行一轮扫描，将期间的新请求合并为最新项目路径；合并 CLI 发现需求，保留已完成的 CLI 结果。所有调用者等待同一个 runner 完成。相同路径在修改后仍重新扫描，不引入持久缓存。 |
| `SessionMigrationModel.refresh` | 重复发布相同历史，旧请求的成功或错误可能覆盖新请求，取消后仍可能发布。 | 发布前检查取消和刷新代次，只发布有变化的记录。过期错误及 CancellationError 不显示为业务错误。 |
| `MigrationStorage.records` | 一旦进入目录遍历，即使任务取消也继续读取所有 manifest。 | 在入口、每个有大小限制的读取前后、排序前检查取消，保留原有格式、UUID、文件大小和排序校验。 |
| 飞书编辑器目录 | 点击时在主线程重新拆分全文、扫描标题和运行正则；文档越大，点击越慢。 | 在原有 350ms 后台解析中保留 `LocatedBlock`，点击复用原始 UTF-16 范围。回调检查缓存文本、当前草稿 ID 和文本，拒绝过期草稿或过期范围。 |

文档定位保持重复标题、Unicode、代码围栏、pre、嵌套 HTML 与表格中的有效定位，并修复原定位器对 CRLF Setext 标题返回空、front matter 中同名标题干扰、h7/h9 已解析标题无法跳转的问题。解析器本身没有另起实现；旧全文扫描函数已移除，冻结实现只作为测试对照。

共享连接器库存工作有独立生命周期，单个页面任务取消不会终止正在运行的扫描；本次保证不重叠并合并待处理请求，不保证强行中断文件系统调用。迁移取消检查也不能打断当前正在执行的同步读取或排序。文档保留范围数组与解析对应文本，未证明内存降低；点击的文本身份检查仍可能有字符串比较成本。

## 可复现对照

使用优化编译 `-O -g`、arm64/macOS 15 目标。连接器探针运行真实生产调度逻辑，库存与 CLI 枚举替换为临时目录传输，每轮模拟读取 200 个 JSON 文件；迁移探针运行真实读取、校验与发布逻辑，使用 300 个临时 manifest。没有访问或修改真实连接器配置。

| 同一夹具工作量 | 基线 | 修改后 |
| --- | ---: | ---: |
| 第一轮阻塞期间追加 100 个请求，实际扫描次数 | 101 | 2 |
| 观察到的峰值并行扫描 | 12 | 1 |
| 同一批请求的 loading 发布次数 | 102 | 2 |
| 相同迁移历史再次刷新的记录发布次数 | 1 | 0 |
| 调用前已取消，实际 manifest 读取次数 | 300 | 0 |
| 首个读取开始后取消，实际 manifest 读取次数 | 300 | 1 |

扫描次数不代表真实目录 CPU 耗时，峰值 12 依赖当次调度。回归另外覆盖最新项目胜出、CLI 需求合并与结果保留、同路径修改后重扫、空项目范围、所有调用者等待、旧成功/错误丢弃和无效 manifest 拒绝。

文档探针使用真实解析器、定位函数和生产编辑器点击回调。每个尺寸测量 20 次定位函数调用；基线为冻结前的生产源码，新代码与解析器原始范围及旧实现的有效定位对照：

| 文档大小 / 标题数 | 基线单次定位中位耗时 | 修改后 |
| --- | ---: | --- |
| 15,390 bytes / 100 | 0.524ms | 低于单次计时的有效分辨率 |
| 154,890 bytes / 1,000 | 4.262ms | 低于单次计时的有效分辨率 |
| 466,890 bytes / 3,000 | 12.527ms | 低于单次计时的有效分辨率 |

探针返回的 0 不表示零耗时，因此不计算提速倍数。表中仅计定位函数，不包含解析、整个视图 body 或点击回调中的草稿文本检查。全部文档低于现有 512,000-byte 上限；没有通过缩小文档能力达到优化。

Time Profiler 另对三种尺寸各固定执行 1,000 次查询。主线程 sampled CPU 权重为 **17,660ms → 71ms**，总 sampled CPU 为 **17,660ms → 72ms**，Foundation inclusive 为 **13,599ms → 43ms**。旧定位器栈包含约 17,534ms sampled 权重，修改后新定位器没有被采样命中；不能解释为其成本为零。基线 self 热点包含 ICU 正则、UTF-16 复制和字符集处理。

两组均包含启动、解析准备、正确性对照与旧定位器 oracle，解析准备在这个 CLI 探针的主线程执行；实际应用保留后台解析。两组各录制一次，其他系统工作与 Instruments 有开销。inclusive 权重重叠，不能相加。该对照验证删除重复全文扫描的 CPU 收益，未测量新代码在已安装正式版中的实际帧率、GPU 或整页点击延迟。

## 其他重点入口

| 本轮源码复核 | 结论与测量边界 |
| --- | --- |
| 连接器页面与插件详情 | 既有懒网格、过滤/计数缓存、后台详情读取及取消保留；修改扫描调度。没有执行外部连接器变更。 |
| 会话迁移服务与历史页面 | 读取 actor 和真实迁移的隔离边界保留；修改历史读取与发布。没有执行真实迁移或终端恢复。 |
| Skill Markdown、DocumentMarkup、飞书编辑器 | 512KB 边界、后台解析、取消与 debounce 保留；目录跳转复用解析结果。没有进行飞书网络写入。 |
| 设置、字体准备与终端探测 | 字体准备已有单任务保护和后台工作，终端列表已有生命周期缓存；没有足够运行归因支持再次改写。未请求权限或改动设置。 |
| 模型价格卡片与 catalog | 当前清单规模较小，初始化同步缓存读取仍存在；没有依据未经测量引入第二套缓存。未测巨大价格清单。 |
| 内存详情与进程读取 | 原有 detached worker 和取消转发保留；底层同步进程读取不能立即取消，尚无本轮测量证据支持改动。 |
| ProviderControls 图片缓存 | 既有 NSCache 保留，未以一次冷资产读取为由重写 UI 架构。未做图片大规模加载或内存压力测试。 |

本轮没有全面实机遍历每个页面与动效状态。天气、热图、流量、KDE、原生动画等上一轮结果不计入本轮收益；其范围和缺口仍以各自报告为准。

## 验证与复现

- 全回归 **74 组通过，383.70 秒**。新增 `module-scheduling`、`document-navigation` 登记在 Makefile，并适配既有飞书目录定位回归。
- dev / release 构建通过，两种宿主/Widget 身份、URL scheme、App Group、entitlements、签名门禁通过；仅构建，未安装。
- Python 编译检查与 `git diff --check` 通过。
- 正式构建仍报告本轮未修改的 `VpnManager.swift` 既有 actor 隔离及多余 try 警告，以及 linker 重复 rpath 警告；构建通过不表示无警告。
- WidgetSnapshot 仍指向 `../ClaudeBar/Models/WidgetSnapshot.swift`；没有更改版本身份或副作用入口。
- 本轮没有安装、启动、退出或重启正式版，没有运行 VPN/硬件控制测试。首次只读核对与最后核对的正式版 PID 均为 41396，执行文件 SHA-256 均为 `e3304aff5e51f7b9eeaaad30d0b69948cd87d754bc7e334e73b6e92eab7edd08`；这不是与上一轮进程状态的比较。
- 原始 trace、临时探针及日志保留在 gitignored 的 `.build/performance/module-scheduling-audit-2026-10-05/`，目录 0700。录制使用清空并显式设置的最小环境；只导出 time-profile 表，公开 JSON 仅包含合成输入、源码哈希与聚合结果。

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
make test TEST="module-scheduling document-navigation feishu-documents"

DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
python3 Tests/module-scheduling-regressions.py \
  --baseline-ref a75f9b4 --probe --output-json /tmp/claudebar-scheduling-before.json
```
