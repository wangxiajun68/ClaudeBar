# 苹果 UI 与动效性能资料及第三轮审查

本轮补查 Apple 官方 SwiftUI、动画事务及 render loop 资料，对照 ClaudeBar 页面、滚动容器和原生动效，并优化能源流图层增量更新。源码审查、组件 CPU 微基准、静态像素对照和整窗口流畅度是不同证据；本报告不把前三项当作 FPS 或能耗验收。

## 官方依据

| 文档 | 对本项目的指导 |
| --- | --- |
| [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance) | 检查长时间 body 计算及频繁更新的来源；昂贵派生数据异步计算并缓存。500 / 1,000 μs 的 Instrument 标记帮助定位热点，不是整窗口帧率保证 |
| [Optimize SwiftUI performance with Instruments · WWDC25](https://developer.apple.com/videos/play/wwdc2025/306/) | 使用 SwiftUI Instrument 和 Cause & Effect Graph 检查依赖传播；按实际输入变化准备展示数据，缩小更新范围 |
| [Demystify SwiftUI performance · WWDC23](https://developer.apple.com/videos/play/wwdc2023/10160/) | 稳定身份、依赖范围和行数影响懒容器；提前准备筛选结果，避免列表行内条件迫使框架遍历内容 |
| [Explore SwiftUI animation · WWDC23](https://developer.apple.com/videos/play/wwdc2023/10156/) | 事务与可插值属性驱动动画；将动画绑定到具体交互和叶子读数，防止高频采样扩大页面的动画范围 |
| [Explore UI animation hitches and the render loop](https://developer.apple.com/videos/play/tech-talks/10855/) | 应用侧更新、布局、提交与渲染侧准备、执行各有截止时间；分别检查 commit hitch 与 render hitch |
| [Demystify and eliminate hitches in the render phase](https://developer.apple.com/videos/play/tech-talks/10857/) | 阴影、蒙版等可能增加离屏工作；需要渲染证据，不能把加 drawingGroup、光栅化缓存或改成 Core Animation 视为通用解法 |

60 / 120 Hz 的帧间隔约为 16.7 / 8.3 ms，应用不能独占整个间隔。CPU 更新变快后，绘制、合成和呈现仍需分别测量。隐藏或屏外装饰停止播放也是本项目的生命周期约束，不能只指望系统销毁视图。

## 已有实现与剩余测量范围

以下策略已存在于当前工作树，并非本轮新增。

| 区域 | 已核对的实现 | 还需测量 |
| --- | --- | --- |
| 页面状态 | ScopedStoreObservation 按字段订阅、去重及合并发布，隐藏 surface 抑制通知 | Cause & Effect Graph 下的真实页面失效数量、子树更新时间 |
| 列表与文档表格 | 连接器懒网格；表格预计算行列坐标并保持单元格 UUID；滚动 owner 门控合并采样发布 | 固定数据规模、窗口尺寸下的长帧、布局调用与峰值内存 |
| 用量与文本预览 | UsageAnalyticsSection 后台生成统计后一起发布；会话、JSON/SSE、Markdown 有后台准备及取消路径 | UsageView.providerGroups、模型目录等仍有 body 派生计算，需要真实规模的 Time Profiler 证据，尚未搬迁或缓存 |
| 读数、灵动岛、硬件卡 | 数字转场在叶子实现，避免采样值上的宽泛动画；旋翼和扫光复用图层、保持相位 | 持续采样时 hosting layout/display 归属及转场叠加 |
| 持续装饰、能源流 | 原生图层插值；局部可见性、window occlusion、拆卸及调用方 surface / Reduce Motion 门控 | 可见静止、全窗口隐藏、局部屏外的 CPU、GPU、唤醒差异 |
| 天气、问候与阴影 | Metal 滚动 hold 静帧、限制在途 drawable；交互惯性 ticker 可停止，稳定子视图等值门控；秒级时钟屏外暂停；阴影显式路径 | Render Server / GPU 时间、离屏 pass、实际呈现帧间隔 |

本轮没有改变业务刷新频率、视觉设计、动画时长或渐变遮罩，不能据此宣称所有页面已达到高性能或消除 GPU 瓶颈。

## 本轮改动：能源流增量更新

PowerFlowCard.swift 的 SankeyWaveView.apply 已对完全相同的输入提前返回，但速度、路径或明暗变化都会为全部流带重新生成颜色、位置节点、蒙版路径及渐变 frame。

现在按依赖更新：路径真正变化才提交蒙版；速度只重定时共享时钟；外观、目的节点或渐变几何变化才生成颜色；尺寸、行程变化和新流带才准备位置节点与 frame。需要颜色时先生成四个基础透明度颜色，再复用到周期性节点。流带记录目的节点，支持同 ID 更换颜色；删除和新增拓扑仍清理、初始化对应图层。

保留渐变透明度、生产蒙版曲线、0.5 秒路径插值、扫光周期及相位连续性。持续扫光依然有渲染成本，本轮针对应用侧重复准备和图层写入。

## 测量

基线为 037dc2d4eee84a81b96de2e444dd4a11cae1d04a 的 PowerFlowCard.swift，该文件此前未被前两轮修改。生产 RibbonShape、颜色和原生图层以 -O 编译到隔离探针，只创建不可见的模拟窗口，不启动 ClaudeBar，不读取用户状态。

两条流带，各场景 2,000 次更新、三个交替进程样本，中位总耗时如下。路径场景包含生产曲线输入的构造，其他场景复用输入。最终样本在全回归和构建结束后采集。

| 场景 | 修改前 | 修改后 |
| --- | ---: | ---: |
| 完全相同输入 | 0.134 ms | 0.137 ms |
| 改变速度 | 74.211 ms | 3.190 ms |
| 改变路径 | 74.051 ms | 5.964 ms |
| 改变明暗外观 | 70.450 ms | 15.697 ms |

速度场景的颜色、位置和路径写入从各 3,998 次降至 0；路径场景保留 4,000 次必要路径更新，颜色和位置写入从各 4,000 次降至 0。外观场景保留颜色更新，不再重复提交位置和未变化的路径；第一步接续路径场景，有两次必要路径恢复。

这些单次更新本来只有几十微秒：结果证明减少组件重复工作，不证明整窗口 FPS 大幅提升。没有设置易受机器负载影响的毫秒阈值。原始样本、源码哈希、基线提交及环境见 [测量 JSON](performance-ui-animation-measurements-2026-10-04.json)。

探针验证生产曲线、逐节点颜色及透明度、位置端点、尺寸和行程变化、同 ID 目的节点变更、空拓扑后新增、删除流带、图层身份、改速相位、遮挡暂停和恢复、脱离窗口及拆卸。四种明暗/目的节点/尺寸组合的 model-layer 栅格 SHA-256 在对照间一致；这项检查不覆盖真实 Render Server 的动态呈现。

```bash
make test TEST=ui-animation-performance
python3 Tests/ui-animation-performance-regressions.py --compare \
  --baseline-ref 037dc2d4eee84a81b96de2e444dd4a11cae1d04a \
  --output-json /tmp/claudebar-ui-animation.json
```

## 验证与限制

- make test：62 组全回归通过，291.90 秒；随后加强的生产曲线及目的节点夹具通过三个交替进程的完整对照。
- make build、make release：dev / release 编译及包身份、Widget、URL scheme、entitlements、签名检查通过，仅构建，没有安装或启动。
- git diff --check 通过。构建仍有已有的 duplicate rpath 警告，release 另有 VpnManager.swift 的 actor / Sendable 与非 throwing try 警告；本轮不修改其系统集成路径。
- 未运行正式版 VPN、风扇或充电控制，没有触发系统权限请求。

第三轮组件测量与构建使用 Command Line Tools；当时 xcrun --find xctrace 返回不可用，尚未采集 SwiftUI Instrument、Animation Hitches 或 Render Server 的整窗口 trace。后续在可用的 Instruments 环境，固定构建、数据、窗口、显示器及脚本，录制页面滚动、读数转场、持续天气、隐藏和屏外状态，对照 p50/p90、长帧、hitch、CPU、GPU 和唤醒数。

最后复核时系统默认 git / python3 出现 Xcode 许可尚未同意的提示；使用现有 Command Line Tools 的 git 和仓库 .venv 完成最终源码哈希、链接及 diff 检查，没有修改许可或全局工具选择。复现时需使用已经可用的工具链。

## 续查：已安装的 Instruments 与实际 trace

用户指出已安装 Instruments 后，重新检查确认 `/Applications/Xcode.app/Contents/Developer/usr/bin/xctrace` 为 **27.0 (27A266a)**。系统的 xcrun 入口仍出现许可提示，但直接调用已安装的工具成功列出模板并完成实际录制。此前将工具发现失败归为缺少安装不准确；没有接受许可、切换全局工具链或修改系统权限。

实际使用原有已签名的 dev 产物，包含第三轮能源流优化。只采样 ClaudeBarDev，未附加正式版、修改正式版配置或干预其 VPN。

| 录制 | 模板 | trace 报告时长 | 内容 |
| --- | --- | ---: | --- |
| 启动 | SwiftUI（包含 Time Profiler） | 20.995 s | 开发版启动与概览；launch 模式在时间限额结束时由 xctrace 停止其启动的开发版 |
| 页面交互 | SwiftUI | 45.868 s | 附加重新启动的开发版；概览滚动、用量切换与滚动、连接器切换与滚动。动作由 UI 自动化执行，没有严格的逐阶段时间标记 |
| 轻量卡顿录制 | Animation Hitches | 20.785 s | 附加开发版，连接器滚动及概览转场；没有同时启用完整 SwiftUI Cause Graph |

已导出非空 SwiftUI 更新表、Time Profiler 样本及 hitches 表，流式解析没有未解析的标量引用。以下是第一批热点线索，尚无相同工作负载的修改前/后对照：

| 场景 / 视图 body | 次数 | 单次中位 | 最慢一次 |
| --- | ---: | ---: | ---: |
| 启动 / GreetingCard | 10 | 0.226 ms | 39.364 ms |
| 启动 / ResourceStrip | 27 | 0.325 ms | 4.263 ms |
| 交互 / ConnectorsView | 3 | 1.023 ms | 11.041 ms |
| 交互 / ConnectorCard | 30 | 0.045 ms | 0.414 ms |

这支持优先排查问候卡首次构建、资源卡更新及连接器页初次构建，尚不足以将耗时归因于具体函数。首次初始化和后续更新需分开；框架 Other Updates 与 body 次数也不能合并解释为重绘数量。各调用耗时可能嵌套，累计值不能视为互斥 CPU 时间。

hitches 表保留原始行数、duration 和归因标签。由于导出未提供完整列说明，Instruments GUI 的两次读取均超时，没有将这些行数或 duration 转换为整窗口 FPS、掉帧率或 hitch-time ratio。Apple 将 hitch duration 定义为实际与预期 frame lifetime 的差值，不能用任意帧相关 duration 代替，见 [Understanding hitches in your app](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)。还需要在 GUI 中确认字段、定位长事件的更新/渲染阶段，并用固定动作重复对照。

此次是单次探索性采样。SwiftUI Cause Graph 和 100 μs CPU 采样会引入开销；正式版及其他应用保持运行，存在共享 GPU/系统负载。开发版的本地用量与供应商数据较少，不能外推到大历史、大供应商清单或正式版系统集成。

聚合结果及执行文件哈希见 [真实 trace 摘要](performance-xctrace-ui-2026-10-04.json)。原始三份 trace 保留在本机 `.build/performance/xctrace-2026-10-04/`，目录权限 0700，Git 忽略；未提交设备身份、完整调用栈或 trace。分析工具为 `Tools/summarize-xctrace-ui.py`，逐行清理 XML 节点，避免完整载入约 1 GB 的导出文件。

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xctrace list templates
/Applications/Xcode.app/Contents/Developer/usr/bin/xctrace record \
  --template SwiftUI --attach <开发版PID> --no-prompt --time-limit 30s \
  --output /tmp/claudebar-ui.trace
/Applications/Xcode.app/Contents/Developer/usr/bin/xctrace export \
  --input /tmp/claudebar-ui.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="swiftui-updates" or @schema="hitches"]' \
  --output /tmp/claudebar-ui.xml
.venv/bin/python Tools/summarize-xctrace-ui.py /tmp/claudebar-ui.xml --output /tmp/claudebar-ui-summary.json
```

本次仅增加测量工具与证据，没有新的应用代码改动。此前 62 组回归与双版本构建结果保持其原有范围，实际 UI 录制是另外的验证，不能描述为正式版 VPN 或硬件运行验证。

录制结束后已正常退出本次启动的开发版；正式版进程仍运行。已删除可重新导出的临时大型 XML，保留原始 trace 和聚合结果。
