# 原生文档、额度显示与 VPN 查询细节优化 · 2026-10-05

本轮在保留上一轮未提交改动的基础上，进一步复核 19 个生产路径，修改 3 个生产文件，完成 4 项局部优化。范围包括飞书目录/正文/表格/原生编辑、额度显示、VPN 出口查询和 HTTP 会话池，以及价格列表与进程内存详情。逐路径哈希、三次对照、Instruments 摘要和验证保存在[测量 JSON](performance-native-detail-audit-2026-10-05.json)。这些检查不等于所有页面和系统集成都已实机验证。

## 苹果依据与实现

苹果的 [SwiftUI 性能文档](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)建议识别昂贵计算和高频更新，减少不必要的工作；[Foundation DateFormatter 文档](https://developer.apple.com/documentation/foundation/dateformatter)说明相同的 FormatStyle 会由 Foundation 缓存。本轮先执行生产方法的隔离探针，再做局部修改，保留原有编辑、计费和网络业务规则。

| 路径 | 问题与修改 | 行为验证 |
| --- | --- | --- |
| `DocumentInlineEditor.makeNSView` | 首次 `applyText` 后，coordinator 未记录源文，随后的 `updateNSView` 又解析、写入一次。首次写入后同步 `published`，避免第二次赋值。 | 执行真实创建/更新方法：富文本和源码模式均只赋值一次；相同正文不重写选择；外部变更只更新一次；输入只发布一次。既有原生输入、样式和 undo 回归通过。 |
| `DocumentRichText` | 普通文本先转义整段，再修剪并重复转义；序列化每个 attribute run 都重新取整份字符串；每次排版都重建链接 detector。删除第一次无效转义，每次序列化取一次 NSString 快照，复用只读 NSDataDetector。 | 对比旧生产实现的完整 attributes、HTML、Markdown；覆盖 Unicode/组合字符、空白、粗斜体、删除线、代码、链接、非法链接、破损标记及 NSMutableAttributedString 的多 run 输入。没有缓存带 Theme 样式的正文。 |
| `CodexQuotaWindow` | `resetClock` / `resetCompact` 在每次读取时创建 DateFormatter。改用 Foundation 缓存的 VerbatimFormatStyle，保留 `HH:mm`、`M月d日 HH:mm` 与短/长窗口规则。每次读取默认时区，避免固定旧时区。 | 四个进程内默认时区、过去/当前/未来日期、0/300/1440/10080 分钟窗口及缺失日期，与旧生产输出一致。修改进程内时区后仍一致；没有修改系统时区或用户偏好。 |
| `VpnNetProbe` | reset 后旧任务的 defer 可清掉新句柄；取消等待后仍进入查询；取消 endpoint sweep 后仍继续后续服务。defer 检查请求所有权，调用者取消传给拥有的任务，等待和查询前后合作检查取消。 | 控制 transport 不响应取消，晚到旧结果不能覆盖新状态或清掉新句柄；取消的节点等待不发请求；取消的 sweep 不再询问后续端点；取消调用者不发布成功值。正常最新结果及 loading 清理通过。 |

## 同输入对照

基线 `c985f1f`；两臂 `swiftc -O -g`，独立进程交替运行三次，全部输入合成。耗时为中位数，不设 CI 时间阈值；测量早于全回归与 App 构建。

| 指标 | 修改前 | 修改后 |
| --- | ---: | ---: |
| 1,000 次两窗口显示读取：每次读取两个 clock、两个 compact | 60.91 ms | 11.89 ms |
| Unicode、转义字符和多 attribute run 的正文，20 次 Markdown 序列化 | 183.28 ms | 89.40 ms |
| 含粗斜体/代码/裸链接的正文，100 次 HTML 准备 | 32.51 ms | 16.61 ms |
| 150 次隔离原生编辑器创建 | 110.18 ms | 41.38 ms |
| 每个编辑器首次正文赋值 | 2 | 1 |
| reset 后旧请求结束、最新请求仍暂停时，重复调用累计查询数 | 3 | 2 |
| 取消节点切换等待后新增查询数 | 1 | 0 |
| 首个端点暂停期间取消，sweep 累计查询数 | 7 | 1 |
| 开始前已取消的 sweep 查询数 | 7 | 0 |

富文本规模为重复 800 次 Unicode/转义片段，按 UTF-16 每 60 单元交替属性；基准只序列化，不向真实文档写入。编辑器测量使用未挂到窗口的原生视图，包含 AppKit 创建与文本排版准备，不能外推为已安装 App 的页面首屏或输入帧率。VPN 数字来自模拟 transport，端点列表和循环来自生产代码；没有请求任何真实服务。

默认新回归使用冻结的旧生产格式化 oracle，可在浅克隆 CI 运行；只有显式 `--compare` 才读取指定 Git 基线。该 oracle 不参与 App 构建。

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools make test TEST="detail-performance vpn-probe-lifecycle quota-store feishu-documents"
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 Tests/detail-performance-regressions.py \
  --compare --baseline-ref c985f1f --output-json /tmp/claudebar-native-detail-comparison.json
```

## Instruments 与继续跟踪的路径

Time Profiler 成功启动生产源码探针，正常结束，录制 **7.955 秒**，共 7,048 个有效采样，7,017 个为主线程样本。合成 profile 循环执行原生编辑器创建、文本序列化与额度格式化，包含生产函数 `DocumentRichText.markdown`（5,081 个 inclusive 样本）、`DocumentInlineEditor.makeNSView`（1,738）及额度格式化（104）。这是刻意重复的 CPU 压力任务；原生 AppKit 工作仍在主线程。本轮减少其工作量，没有把原生视图操作移到后台。

inclusive 函数采样会重叠，不是每次调用耗时、真实 body/hitch/FPS 或能耗指标。3 个无 backtrace 的行未计入有效采样。Allocations 尝试启动同一隔离探针，但 xctrace 报告 Failed to attach，退出码 2；没有可用堆测量，也没有“无泄漏”结论。原 trace、生成探针和 XML 保留在 gitignored 的 `.build/performance/detail-audit-2026-10-04/`，目录 0700；公开报告只含聚合数据。目录沿用跨午夜开始的任务日期。

本轮另外确认以下路径，保留原实现或记录后续实机场景：

- 飞书 CLI JSON 解码仍由 Dispatch 工作队列执行，文档预览保持 512 KB 上限及 detached worker 取消。正文读取、账户隔离、分页、保存与回滚回归通过。大表格逐字输入、输入法组合文本与 WKWebView 长期内存尚未做实机压力测量。
- `VpnHTTP` 每个端口复用 session，但无端口变化后的回收策略。返回的 session 可能被用于尚未发起的请求；直接 LRU 淘汰并 invalidate 会破坏调用者。本轮没有修改会话池，没有测量真实端口变化的常驻内存成本。
- 价格目录的 slug 合并/排序仍在读取路径；默认表规模小，本轮没有足够实测证据支持增加另一份派生状态。原价格和用量回归通过。
- 进程内存详情保持后台单次 `ps`，离开后丢弃结果；同步管道读取的取消仍需等待读取结束。没有宣称其取消即时，也没有将压力探针等同于真实大进程表测量。

## 验证与交付边界

- 全回归 **69 组通过，303.81 秒**；原生文档/VPN/额度定向 3 组通过；冻结 oracle 后最后两组再次通过，5.56 秒。
- dev / release 优化构建成功，未安装；两版 bundle ID、执行文件、URL scheme、Widget 与 App Group 隔离，entitlements 与 deep/strict 签名门禁通过，WidgetSnapshot 符号链接正确。
- Python 编译检查、`git diff --check` 通过。JSON 保留本轮三个生产文件和三个测试/夹具文件的 SHA-256，以及 19 个复核路径的快照哈希。
- 未启动、退出或替换正式 App；没有操作 VPN 内核、系统代理/DNS/TUN、硬件、权限、真实账户或凭据。未做本轮新代码在已安装 App 中的交互前后对照，未发布安装包。
