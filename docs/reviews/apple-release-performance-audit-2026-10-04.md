# 正式版 Instruments 审查与热点优化 · 2026-10-04

本轮附加正在运行的正式版 1.15.0，取得 CPU、SwiftUI body、Animation Hitches、Metal 与短时内存数据，再修改实际热点。完成 Codex 历史回溯和用量供应商汇总优化，保留业务状态、Token 归属规则、视觉与动效。新代码仅构建，尚未安装到正式版，因此下面的优化收益来自相同输入的生产源码探针，不能视为正式版整机 CPU 或 FPS 已改善。

完整脱敏数值见 [测量 JSON](performance-release-audit-2026-10-04.json)。此前的 [模块审查](apple-performance-audit-2026-10-03.md)、[后端优化](apple-performance-followup-2026-10-04.md)、[UI 与动效优化](apple-ui-performance-2026-10-04.md)继续保留各自的测量范围。本轮新增一个生产 Swift helper；历史入口清单的数量属于当时的源码快照。

## 苹果文档与执行方式

- [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)：通过长 body 和更新频率定位问题；昂贵计算异步准备、缓存结果，避免每次视图更新都重复执行。本轮将归属计算从 body 移到依赖实际输入的后台任务。
- [Instruments Tutorials](https://developer.apple.com/tutorials/instruments)：先分析真实热点，再减少工作或移出主线程，并验证修改。本轮先定位大日志扫描，再用同一规模输入对照两个优化编译的实现。
- [Optimize SwiftUI performance with Instruments · WWDC25](https://developer.apple.com/videos/play/wwdc2025/306/)：检查依赖传播、更新原因与开销。本轮保留所有观察到的项目视图类型和 CPU 栈，避免只查看排名前 25 的组件。
- [Improving your app’s rendering efficiency](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency)：应用更新、渲染和呈现需要分别测量。本轮另外取得 Metal 和 Animation Hitches 数据，没有把 body 时长转换成帧率。

正式版身份：bundle ID `com.claudebar.app`，原进程 PID 732；可执行文件 SHA-256 `efa154a82fbbb9d8686f6f5bb2e27a183200cd1e1bca0b452000cb9eb79bd523`。录制前与原 `.build/release` 产物字节一致，源码基线为 `c708081247eaace7275a8f9e8c35c92d1ca69d1b`。工具为 Instruments/xctrace 27.0 (27A266a)。本轮构建与优化探针使用 Command Line Tools Swift 6.3.2、macOS 15 arm64 目标；没有切换全局开发工具链。

原始 trace 和 XML 保存在权限 0700、git 忽略的 `.build/performance/release-audit-2026-10-04/`，不发布可能含私有数据的录制、日志或截图。对正式版使用 `--attach 732`，没有使用会在录制结束时终止目标的 `--launch`。后者只用于本轮自行编译的隔离命令行探针。

## 运行覆盖与观察

SwiftUI 三组录制分别约 90.93、120、80 秒，共观察到 **145 种项目视图类型**。前两组请求 layout tracing 时收到不支持提示，但留下有效 body、CPU 等数据；设置录制关闭 layout tracing 后正常结束。没有把前两组的部分成功标成 layout 测量成功。

| 页面／模块 | 实际覆盖 | 观察与边界 |
| --- | --- | --- |
| 概览、硬件与天气 | 页面展示、部分滚动；DashboardView、GreetingCard、ResourceStrip、BatteryChargeControls 等 | GreetingCard 最大 body 2.084 ms，DashboardView 0.531 ms；未执行充电、风扇写入 |
| 会话 | 页面展示，ExternalSessionGridCard、SessionTitleLine、SessionActionChips 等 | Time Profiler 定位后台历史回溯；未续聊、迁移或清理真实会话 |
| 模型／供应商 | ProvidersView、供应商目录、图标与模型选择组件展示 | ProvidersView 最大 0.831 ms，ProviderIdentityMark 1.802 ms；未切换供应商或写客户端配置 |
| 连接器 | ConnectorsView、ConnectorCard、筛选与工具按钮展示、滚动 | ConnectorsView 最大 0.424 ms；未启停真实连接器或启动发现子进程 |
| 用量 | UsageView、统计图、热图、平台／供应商／模型卡 | UsageView 最大 4.417 ms，UsageAnalyticsSection 3.280 ms；本轮优化供应商归属准备 |
| 流量 | TrafficView 展示和滚动 | 最大 body 8.104 ms，三次样本中位约 0.614 ms；尚不能证明慢样本来自详情重建，不据此重写 UI |
| VPN | VPNView、节点与订阅列表、速度图展示、滚动 | VPNView 最大 0.826 ms，VpnSpeedChart 1.916 ms；未连接、断开、切节点或改网络配置 |
| 设置 | 通用、外观与天气、灵动岛、用量与计费、权限与隐私、本地代理，含长模型价格目录滚动 | SettingsGroup 最大 1.634 ms，ModelPriceCard 1.552 ms，PermissionsSection 0.965 ms；没有操作权限授权或配置开关 |
| 帮助 | HelpView、HelpBlockView 展示和滚动 | HelpBlockView 最大 3.349 ms；冷展示的 Markdown 解析仍可后续细分测量 |
| 菜单栏、灵动岛、Widget | 结合前轮源码审查与已有隔离回归 | 本轮未完成每个弹层、交互状态及 Widget 生命周期的实际录制，不能宣称全运行路径已覆盖 |
| 持久化、MCP、代理协议、捕获、迁移、天气请求等后台模块 | 前轮生产源码对照与本轮全量隔离回归 | 不是对每个真实账号、网络请求、VPN／硬件副作用的端到端测量 |

`body` 最大值是带录制开销的个别样本，不是稳定耗时、主线程完整工作量或帧截止时间。长帧仍可能发生在 AttributeGraph、布局、提交、Render Server 或 GPU，部分组件低 body 开销也不代表整窗口没有成本。

另取两次 25 秒轻量 Time Profiler，避免将 SwiftUI 录制开销作为正式版常态 CPU：

| 状态 | 全进程采样 CPU 权重 | 主线程权重 |
| --- | ---: | ---: |
| 窗口隐藏 | 2,399 ms | 198 ms |
| 概览可见并确认窗口已恢复 | 15,509 ms | 10,088 ms |

权重除以 25 秒只能近似表示单核 CPU 占用，且两段不是同时的受控能源对照。曾有一条命名为 visible 的录制实际仍隐藏窗口，已排除。可见段仍有明显框架主线程工作，需要以后固定数据、窗口与动画状态细分，不能用本轮局部优化宣称已消除。

隐藏段 `Substring` 切片、字符串索引占据热点；第一项目帧 `0x1030e1f48` 的权重为 1,654 ms，约占全进程 69%。正式版已 strip，不能把最近的重编译符号地址直接套用。为此仅在私有目录重新编译未 strip 的基线：整个 `__text` 不完全一致，故没有进行全局自动符号映射；该热点通过独特函数入口及 **965 条机器指令的归一化逐项比对**定位到 `ExternalSessionMonitor.recoverBeforeTail`，仅忽略链接修正的地址字段，寄存器与非地址指令保持一致。独立生产函数重放也复现了相同的字符串热点。

## 代码修改与相同输入对照

### Codex 会话历史回溯

`ExternalSessionMonitor.swift` 原先读取最多 24 MiB 后，先构造完整 String，再 `split` 所有行，最后才跳过超过 65,536 字节的工具输出。大型工具记录因此支付了无用的 Unicode 遍历、切片与字符串复制成本。

现在在 Data 的字节边界倒序扫描，超过行上限的记录直接跳过，只有短候选才解码和解析 JSON。找到最新的有效生命周期状态和最新非空工具名后停止。保留 24 MiB 上限、部分首行排除、非法 UTF-8 的替换解码、失败返回和文件关闭；接受 CRLF 记录。没有改变会话是否运行、完成或停滞的判定时限，也没有读取更多真实数据。

### 用量供应商汇总

`UsageView.swift` 原先在 body 计算 `providerGroups`，为每个配置重复规范化模型名，并把 Codex provider 投影成完整显示模型。每次排序和卡片读取还会重新 reduce 分组 totals。

新增 `UsageProviderInventory.swift` 复用原归属算法，只接收来源、供应商名和模型名，不传入凭据或供应商配置对象。每次准备中，相同原始模型名只规范化一次；分组总量保存为值；相同 Token 数按名称稳定排序，避免相同输入的字典顺序使 UI 无谓重排。

页面按区间、已发布用量、供应商模型配置及有效官方归属启动后台任务。等待新结果时保留已有分组；取消传递给工作任务，计算循环检查取消；主 actor 只有在请求仍一致且任务未取消时发布，等值结果不重复写状态。Claude/Codex 分别匹配各自供应商，第三方查二者并集，多重匹配仍为“未归属”；官方用量继续按每个 Token 桶夹紧，Cursor 账单保持独立。

两臂用 `-O` 编译生产函数切片，三轮交替进程，结果为中位总耗时：

| 固定工作量 | 基线 | 优化后 | 耗时减少 |
| --- | ---: | ---: | ---: |
| 8 次回溯，生命周期与工具名埋在 12 MiB 输出之前 | 1,303.282 ms | 40.710 ms | 96.9% |
| 10 次归属汇总，40 个供应商 × 100 个配置模型、300 条来源用量 | 65.369 ms | 10.860 ms | 83.4% |

第二项基线夹具只投影必要名称，省略凭据等配置字段的复制，因此不夸大消除完整显示投影的额外收益。结果证明固定热点工作更少、更快；不会等同于真实页面整体改善同样比例。模型明细目录仍有 body 派生计算，本轮没有把它作为供应商汇总一起宣称已移出主线程。

还实际使用 Time Profiler 启动两臂命令行探针。相同 32 次历史回溯，在录制下从约 5,805 ms 降至 179 ms；完整探针采样 CPU 权重从 8,020 ms 降至 696 ms，包含夹具准备、功能检查与其他测试工作，不能只归属这 32 次扫描。基线首要 self 符号为 String 下标和索引；优化后首要工作转为有限字节扫描、拷贝与读取。原始重放 trace 仍只保存在私有目录。

## UI 动效、GPU 与内存

Animation Hitches 录制约 70.65 秒，目标表全部属于 ClaudeBar：1,924 条记录，p50 8.333 ms、p95 16.667 ms、最大 58.333 ms。多数 issue 字段为空；471 条标记潜在昂贵应用更新，另有 13 条包含渲染提示。这段录制只覆盖有限导航与静止状态，未完成所有页面的循环。没有转换为 FPS、hitch ratio 或所有页面的评级。

Metal 录制约 25.72 秒，按 ClaudeBar 进程过滤：150 次 command buffer 提交，CPU 提交时长 p95 0.328 ms，encoder 时长 p95 0.164 ms；Metal 已分配资源约 39.97–41.55 MiB。613 个 GPU 执行区间的时长 p95 4.031 ms、最大 6.579 ms；不同硬件通道的区间会重叠，不能相加当作 GPU 利用率，也不是独立帧耗时。保留既有天空半分辨率、帧率/在途 drawable 限制、滚动静帧及遮挡/Reduce Motion 门控，没有未经归因就降低动效品质。

Activity Monitor 的 68 个短时样本：physical footprint 约 504.30–758.41 MiB，首尾约 540.14/542.47 MiB。驻留与足迹受缓存、系统回收和录制影响；首尾接近不能证明没有泄漏。Allocations 附加 hardened release 失败；没有重签、重启正式版或绕过安全保护，因此本轮不提供对象分配归因或泄漏结论。

## 验证、复现与交付边界

- `make test`：63 组全登记回归通过，317.64 秒。之后补充取消路径的最终改动再次通过 `measured-performance usage-analysis usage-index` 三组回归。
- `make build`、`make release`：最终源码 dev/release 编译及包身份、Widget、URL scheme、entitlements 和签名验证通过，仅构建。一次进行中补充源码的 release 编译被编译器拒绝，已按最终源码完整重建；失败产物没有安装或作为通过证据。
- 新回归验证最新有效事件、完成/中止、空工具名、JSON 内伪标记、超大 Unicode 记录、回溯边界、部分记录、非法 UTF-8、CRLF、官方用量夹紧、来源隔离、归属歧义、同名供应商、总 Token 守恒和预取消。计时只作诊断，没有机器负载敏感的毫秒门槛。
- xctrace 汇总工具增加全项目视图、时间分箱和 CPU 栈统计，纠正把 `main` 当作已符号化业务热点的分类；采用流式 XML 读取，避免把巨大的 Metal/SwiftUI 表整体读入内存。
- 结束时正式版原 PID 与可执行文件 SHA-256 未变，页面停留 VPN。没有退出、安装或启动另一份正式版，没有操作 VPN、SMC、权限、登录项或外部客户端配置。用户的 AGENTS.md 修改保留。

可复现的安全命令：

```bash
make test TEST="measured-performance codex-session usage-analysis usage-index"
python3 Tests/measured-performance-regressions.py --compare \
  --baseline-ref c708081247eaace7275a8f9e8c35c92d1ca69d1b \
  --output-json /tmp/claudebar-measured-performance.json
make build
make release
```

后续真实版本对照应使用这次构建产物，固定输入、窗口和动作脚本，再测可见/隐藏 CPU、流量页冷展示、帮助文本、模型目录与滚动提交成本。需要可附加的优化构建或独立测试机做 Allocations，并单独覆盖菜单弹层、灵动岛与 Widget。当前证据不支持“所有模块和所有交互均已达到高性能”的保证。
