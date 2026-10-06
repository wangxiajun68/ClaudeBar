# Apple 官方性能规范摘录：前端渲染与后端运行时

本文是 Apple 官方性能文档（developer.apple.com 文档与 WWDC / Tech Talks 文字稿）的调研摘录，用于指导本项目 **ClaudeBar**（macOS 15+ / arm64 / SwiftUI + AppKit + Metal 的常驻菜单栏应用）的性能工作。每条规则按「祈使句 + 为什么 + 怎么验证」组织，并给出处链接；文中数值均为 Apple 原文口径，本项目的实测数据不在此重复（见 `docs/reviews/` 相邻报告与 `docs/DEVELOPMENT.md` 的命令约定）。

- 本次工作流提供的笔记 JSON 为空数组，正文全部条目直接取自下列官方来源，未做二手转述。
- 引用核对时间：2026-10-05 至 2026-10-06；链接均为 developer.apple.com。
- Instruments 模板名已与本机 `xcrun xctrace list templates` 输出（xctrace 27.0）核对，包含 `SwiftUI`、`Animation Hitches`、`Time Profiler`、`Game Performance`、`Game Memory`、`App Launch`、`File Activity`、`Network`、`Power Profiler`、`CPU Counters`、`Leaks`、`Allocations` 等；`VM Tracker`、`Hangs`、`Hitches`、`Points of Interest`、`Filesystem Activity`、`Disk Usage`、`Disk I/O Latency` 是 instrument 名而非模板名（见 `xcrun xctrace list instruments`）。
- 录制命令示例：`xcrun xctrace record --template 'Time Profiler' --attach <pid> --time-limit 30s --output /tmp/tp.trace`；模板列表用 `xcrun xctrace list templates`。

## 口径速查（Apple 原文数值）

| 口径 | 数值 | 出处 |
| --- | --- | --- |
| 离散交互延迟（hang） | 超过 100 ms 开始可感知；工具默认约 250 ms 起报告（这一类较短的 hang 称 micro hang）；约 500 ms 以上视为正式 hang | [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)、[Understanding hangs](https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app)、[Analyze hangs with Instruments](https://developer.apple.com/videos/play/wwdc2023/10248/) |
| 连续动效帧截止 | 120 Hz 每 8.3 ms、60 Hz 每 16.7 ms 需要新帧；主线程每帧工作低于 5 ms 时通常能赶上 | [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness) |
| hitch rate（ms/s） | 现行文档分级：≤10 好、≤25 警告、≤50 严重、>50 立即处理；2020-12 Tech Talk（“Explore UI animation hitches”，比文档早）旧口径：目标 0，<5 好、5–10 可察觉、>10 需处理。两套口径不一致，以现行文档分级为准。注意：hitch rate 数据仅 iOS/iPadOS 提供，macOS 无此面板（hang rate 覆盖 iOS/macOS） | [Understanding hitches](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)、[Explore UI animation hitches](https://developer.apple.com/videos/play/tech-talks/10855/)、[Analyzing responsiveness issues](https://developer.apple.com/documentation/xcode/analyzing-responsiveness-issues-in-your-shipping-app) |
| 内存计费粒度 | 页粒度约 16 KB，写 1 字节也可能新增 16 KB（Apple 文档为 iOS 口径，macOS 页大小随硬件）；被压缩/换出的脏页按压缩前大小计入 footprint | [Reducing memory use](https://developer.apple.com/documentation/xcode/reducing-your-app-s-memory-use)、[Detect and diagnose memory issues](https://developer.apple.com/videos/play/wwdc2021/10180/) |
| 内存碎片目标 | 长驻进程 malloc 区碎片建议 ≤25% | [Detect and diagnose memory issues](https://developer.apple.com/videos/play/wwdc2021/10180/) |
| 启动路径 | pre-main 静态初始化中任何可能超过几毫秒的工作都应移出（含 I/O、网络） | [Link fast](https://developer.apple.com/videos/play/wwdc2022/110362/)、[Reducing launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time) |
| 磁盘写粒度 | 磁盘按块（常见 4 KB，随磁盘控制器而定）写入，单字节改动也会写 4 KB；创建/删除文件约 8 KB 元数据、改名/移动约 16 KB（后两项为 Apple 原文 iOS 口径） | [Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes) |
| 网络往返 | 从 TLS 1.2/TCP 的 4 个 RTT 可降到 HTTP/3 的 2 个 RTT（QUIC 早期数据可再减到 1 个，需服务端支持）；Apple 测量中 RTT 有时会飙到 600 ms，4 个 RTT 意味着约 2.4 s 的首字节等待 | [Reduce network delays](https://developer.apple.com/videos/play/wwdc2021/10239/) |

## 第一部分：前端渲染（视图树、布局、动画、合成、Canvas/Metal 绘制）

本部分面向 SwiftUI / AppKit 界面代码。总原则先于具体规则：先测量再优化（Profiling 用真机或本机真实构建，不在模拟器里评估性能），改动后重新测量验证。[Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)、[Creating performant scrollable stacks](https://developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks)

### 1. 视图树与依赖：让更新只发生在真正依赖的数据上

- **让每个视图只依赖它渲染所需的字段；把大结构体拆成只接收所需值的子视图。** 为什么：body 的依赖面越宽，模型变化触发的重算越多；SwiftUI 在视图的值或其动态属性变化时才重新运行 body。验证：调试期在 body 里加 `let _ = Self._printChanges()`（带下划线的调试设施，Apple 不保证长期存在且有运行时开销，不得提交到发布构建），观察日志里的 `@self`/属性名；用 SwiftUI 模板（WWDC25 起）的 Cause & Effect 图确认一次手势引发的 body 数量。[Demystify SwiftUI performance（WWDC23）](https://developer.apple.com/videos/play/wwdc2023/10160/)、[Optimize SwiftUI performance with Instruments（WWDC25）](https://developer.apple.com/videos/play/wwdc2025/306/)
- **用 `@Observable` 宏按属性粒度建立依赖，避免视图读取整个集合或对象的全部属性。** 为什么：`@Observable` 只追踪 body 实际读取的属性；WWDC25 案例中视图经 `isFavorite(landmark)` 间接读取整个收藏数组，导致点一个收藏按钮时所有列表项 body 都重跑；改成按条目的 view model 后只剩 2 次更新。验证：Cause & Effect 图中从 `@Observable` 节点指向 body 的边数；对比一次交互前后的 body 更新计数。[Optimize SwiftUI performance with Instruments（WWDC25）](https://developer.apple.com/videos/play/wwdc2025/306/)
- **不要把频繁变化的值放进 Environment（几何数据、计时器进度等）。** 为什么：读取 environment 的视图都对整个 `EnvironmentValues` 建立（检查性）依赖，即使值未变、body 被跳过，检查本身也有成本，视图一多会累积。验证：Cause & Effect 图中 External Environment / EnvironmentWriter 节点与「body 未跑」的暗色图标数量。[WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306/)
- **不要在视图里存捕获 `self` 或宽依赖状态的闭包；接收的子视图构建闭包应在初始化器里调用、只存返回值且不要标 `@escaping`。** 为什么：闭包捕获的状态变化会强制其结果重新计算；action 闭包与 `ForEach` 参数闭包可以不套用这条，但仍可能引起过量更新，需要单独核查。验证：源码复核 + Cause & Effect 图。[SwiftUI 性能文档](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)
- **把耗时计算从 `body`、视图初始化器、`onAppear`、`onChanged` 及任何会改视图状态的 modifier 中移出。** 为什么：body 在主线程运行，慢 body 会错过帧截止；应异步计算并缓存结果供后续复用。验证：SwiftUI 模板的 Long View Body Updates 轨（或 View Body Updates 子轨；长更新有橙/红标记，红色优先看），配合 Time Profiler 在时间线上「Set Inspection Range and Zoom」后看调用树/火焰图。[SwiftUI 性能文档](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)、[WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306/)
- **不要每次 body 求值时新建 formatter、做字符串插值或查 bundle；在模型层一次性构造并缓存字符串。** 为什么：WWDC25 案例中 `NumberFormatter`/`MeasurementFormatter` 的创建与格式化是 body 里最重的调用；改为在数据层预计算并缓存后长更新消失。验证：Time Profiler 中 body 调用栈里最重帧；修复后 Long View Body Updates 摘要中该视图条目消失（启动最初几帧的长更新属正常，见文档说明）。[WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306/)、[WWDC23 10160](https://developer.apple.com/videos/play/wwdc2023/10160/)
- **同时治理「更新太频繁」而不只是「单次太慢」。** 为什么：一串短更新叠加同样会错过帧截止，而且比单次长更新更隐蔽。验证：SwiftUI 模板的 Update Groups 轨 / Summary: All Updates 找存活过久的更新组；「Show Causes」查看因果图，优先降低出现最多的那类事件的频率，并注意因果图每条边只显示一个变化属性。[SwiftUI 性能文档](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)
- **消除「自己触发、自己响应、由 SwiftUI 中介」的更新回路。** 为什么：因果图起点与终点都是自己的代码（蓝色节点）时，说明可以减少引发事件的频率；例如几何变化驱动布局的场景应先比较变化幅度是否超过阈值再更新。验证：Cause & Effect 图 + 阈值过滤前后的更新计数对比。[SwiftUI 性能文档](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)

### 2. 布局：控制布局读取与失效范围

- **限制布局读取器（`GeometryReader`、`ScrollViewReader`、`onGeometryChange`）的作用域，并对几何变化设置阈值过滤；把状态依赖但不影响布局的视图移出同一子树。** 为什么：布局读取器观察父视图布局变化并重算，滚动几何在无实际滚动变化时也会触发回调，重复计算不产生可见变化。验证：SwiftUI 模板时间线聚焦该更新，配合 Time Profiler；用 Flash Updated Regions 检查「刷新但视觉无变化」的区域。[SwiftUI 性能文档](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)、[Improving rendering efficiency](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency)
- **在动画路径上不要做昂贵操作：keyframe 动画每帧都会给视图提供插值后的新值，phase 动画的过渡同样逐帧应用。** 为什么：逐帧的插值更新会把任何附加计算乘以帧数（Apple 原文：keyframe 动画下“updates happen on every frame”，应避免昂贵操作）。验证：Time Profiler 对动画区间采样；必要时降低动画细节或改由准备层驱动。[Wind your way through advanced animations（WWDC23）](https://developer.apple.com/videos/play/wwdc2023/10157/)
- **AppKit/自绘代码：只在需要时 `setNeedsLayout`，避免 `layoutIfNeeded` 提前强制布局，约束数量保持最小，布局失效只影响自身或子视图、不牵连兄弟或父视图。** 为什么：commit 事务内布局按父到子逐层执行，递归失效会放大工作量；`layoutIfNeeded` 会延长当前事务生命周期，可能直接造成 hitch。验证：Animation Hitches 模板 + Time Profiler 看 commit 调用树（本机命令：`xcrun xctrace record --template 'Animation Hitches' --attach <pid> --time-limit 30s --output /tmp/hitches.trace`）。[Find and fix hitches in the commit phase（Tech Talks）](https://developer.apple.com/videos/play/tech-talks/10856/)
- **自定义 `draw(_:)` 只画传入矩形范围内的内容，使用预先准备的数据，绝不做 I/O 或复杂计算；不要提供空的 `draw(_:)` 实现。** 为什么：空实现也会让系统在事务中为它安排额外工作；只画脏矩形避免对不显示到屏幕的部分做解码、配色和绘制计算。验证：Animation Hitches + Time Profiler；对照 `draw(_:)` 的调用栈与矩形范围。[Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)、[Tech Talks 10856](https://developer.apple.com/videos/play/tech-talks/10856/)
- **视图/图层只在需要时重绘，且向系统传最小更新区域（AppKit 用带矩形的 `setNeedsDisplay(_:)`）；不要让一个图层的更新迫使重叠图层一起重绘。** 为什么：无变化的重绘只消耗 CPU/GPU 与屏幕能耗。验证：Xcode 运行中选 Debug > View Debugging > Rendering > Flash Updated Regions，闪烁但视觉无变化即无效更新。[Improving rendering efficiency](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency)

### 3. 滚动容器与惰性加载：只构建该出现的视图

- **需要滚动的大量重复视图，先用普通 `VStack`/`HStack`，确认出现性能问题后再换 `LazyVStack`/`LazyHStack`；先测量再决定。** 为什么：普通栈一次加载全部子视图，布局快且尺寸可靠；惰性栈按需加载换取性能、但牺牲部分布局精确性（几何随可见性计算）。验证：SwiftUI 模板（含 View Body 等 instrument）观察初始加载的视图实例数（Apple 示例：HStack 一次 1,000 个 `ProfileView`，换 LazyHStack 后初始仅 4 个可见）。[Creating performant scrollable stacks](https://developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks)
- **惰性容器要放到真正出问题的层级；外层懒容器不能覆盖内部整段构建的普通容器（例如 `Grid` 会急切计算全部内容）。** 为什么：WWDC23 案例中 sheet 里 `Grid`/`GridRow` 急切计算，`BackgroundThumbnailView` 的 body 执行 70 次、平均约 50 ms、累计超过 3 秒 hang（首屏只需 6 张图）；换成 `LazyVGrid` 后 body 执行降到 8 次。验证：View Body instrument 统计 body 执行次数与平均时长；确认惰性化后首屏构建数量。注意：急切变体在渲染相同内容时占用内存更少，仍然默认用急切式，只在发现「提前做太多工作」时惰性化。[Analyze hangs with Instruments（WWDC23）](https://developer.apple.com/videos/play/wwdc2023/10248/)
- **在 `List`/`Table` 中，让 `ForEach` 内容对每个元素产出恒定数量的视图：避免 `AnyView`、避免单边条件（if 只有一支没有 else）；必要时用显式栈，但注意 `listRowBackground` 等修饰符要加在栈之后而不是栈内部；尽量压平嵌套 `ForEach`，section 化的嵌套是推荐用法。** 为什么：List/Table 会急切收集全部行 ID；每个元素的视图数不恒定时，SwiftUI 必须额外构建视图才能取到标识符。验证：View Body 计数；行数公式「元素数 × 每元素视图数」与实际构建对照。WWDC25 补充：macOS 上超过 10 万项的列表加载快 6 倍、更新快 16 倍，嵌套 ScrollView 里的 lazy stack 也获得了延迟加载行为。[WWDC23 10160](https://developer.apple.com/videos/play/wwdc2023/10160/)、[What's new in SwiftUI（WWDC25）](https://developer.apple.com/videos/play/wwdc2025/256/)
- **列表标识符要廉价：不要在构造 List 时反复做线性过滤；过滤提前在模型层缓存。** 为什么：行 ID 被频繁、急切地收集，标识符生成成本直接放大到加载和更新；把过滤移到数据集合后每元素视图数恢复恒定，但内联过滤是集合上的线性操作，规模上来仍会拖慢更新。验证：Time Profiler 对照过滤前后的调用树；固定数据量下重复构建列表的计数。[WWDC23 10160](https://developer.apple.com/videos/play/wwdc2023/10160/)

### 4. 动画与合成：每帧都要来得及

- **以 hitch 与帧预算为准绳：连续动效要求每帧（120 Hz 为 8.3 ms、60 Hz 为 16.7 ms）准备好新帧，主线程每帧工作应低于 5 ms；不要以满足「<100 ms hang 预算」为目标。** 为什么：人对连续运动的延迟远比离散交互敏感，几毫秒的额外延迟就可能错过 commit deadline，形成 hitch。验证：Animation Hitches 模板录制滚动/动效，读 Hitches 表的 hitch 时长、可接受延迟与 hitch 类型（commit 还是 render）。[Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)、[Understanding hitches](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)
- **减少 commit 事务的代价：视图保持轻量，尽量使用 CALayer 上 GPU 加速的属性，避免 CPU 自绘；`drawRect` 要真的画；复用视图而不是反复增删；动画中隐藏视图用 `hidden` 属性而不是移除。** 为什么：commit 阶段的布局、显示、图像解码与打包都在主线程预算内完成；深视图树、反复重建子视图、未解码大图都会拖长事务。验证：Animation Hitches 模板选中 commit 过程，Time Profiler 取主线程调用树；对照 `prepareForReuse` 类路径在滚动中的开销。[Tech Talks 10856](https://developer.apple.com/videos/play/tech-talks/10856/)
- **图片在进入 commit 前准备好：避免 commit 阶段的首次解码与大图缩放；按显示尺寸预解码。** 为什么：prepare 阶段才解码的图像会在帧内付出可观的解码与格式转换时间（WWDC18 219《Image and Graphics Best Practices》，经 Tech Talks 10856 引用）。验证：Animation Hitches 的 commit 段 + Time Profiler；滚动时对比解码出现的帧。[Tech Talks 10856](https://developer.apple.com/videos/play/tech-talks/10856/)
- **减少离屏渲染：给阴影设置 `shadowPath`；圆角用 `cornerRadius` 与 `cornerCurve`（连续曲率）而不是 mask 图层；遮罩用 `masksToBounds` 而非自定义 mask 层，且内容不越界时干脆不用遮罩。** 为什么：阴影、mask、圆角、模糊（visual effect）都会让渲染服务器额外开离屏纹理再合成；WWDC 案例把演示 app 的离屏数从 36 次降到 0。验证：Xcode 视图调试器 Show Layers 看每层 offscreen count 与 offscreen flags，以及紫色 Optimization Opportunities 提示；Instruments 的 Renders/GPU 轨看 render count。macOS 上标准材质与 `visualEffect` 同理，属于模糊类离屏。[Demystify and eliminate hitches in the render phase（Tech Talks）](https://developer.apple.com/videos/play/tech-talks/10857/)
- **控制动画的帧率预算：高帧率更耗电；需要精细控制时用 QuartzCore 提示期望帧率与时长；动效结束就暂停/停止，不要留常启的重复动画。** 为什么：更高帧率意味着系统持续以更高频率工作。验证：Power Profiler（目前仅 iPhone/iPad iOS 26+；macOS 本机用 Xcode 的 Energy Impact 调试仪表，见 Analyzing battery use）与 GPU 轨；确认动画停止后没有持续更新。[Improving rendering efficiency](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency)
- **用 `CADisplayLink`/`CVDisplayLink` 对齐 vsync 起点调度自绘动画；不确定能否稳定在 ~5 ms 内做完一帧时，宁可选能稳定达到的较低帧率。** 为什么：每个错过的截止都是 hitch，稳定的低帧率优于偶尔掉帧的高帧率。验证：Display / Frame Lifetimes 轨与自带计时。注意：该建议针对直接与图形系统交互的自绘代码；纯 SwiftUI/UIKit/AppKit 的动画由框架适配刷新率，无需自己对齐 vsync。[Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- **Metal 自绘路径：先查 GPU 利用率（vertex/fragment 时长、渲染 pass 数、viewport 分辨率、纹理与网格规模、shader 代码效率），再看 CPU 利用率（渲染线程阻塞时间是否充足、System Load 是否有可运行线程多于核数的橙色尖峰、渲染线程优先级建议 45）。** 为什么：掉帧可能来自 shader 过载、CPU 过长或 CPU-GPU 流水等待；先分辨 GPU 还是 CPU 再动手。验证：Game Performance 模板（含 Metal System Trace；可在 Recording Options 打开 Performance Limiters 计数集），观察 display 实例是否跨多个帧间隔、shader 各阶段时长与线程状态。必要时用 Metal 调试器分析资源与 shader。[Analyzing the performance of your Metal app](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app)
- **Metal 资源内存关注 `VM: IOAccelerator`（资源）与 `VM: IOSurface`（drawable）两个类别，资源及时释放、及时标注名称。** 为什么：这两类是 Game Memory 的 Allocations 统计里定位 Metal 资源的入口（Apple 原文：Metal resource allocations are in the `VM: IOAccelerator` category, and drawables are in `VM: IOSurface`；注意 Allocations 轨不含 private storage mode 的 Metal 资源），资源标签便于在 Resource Events 中定位。验证：Game Memory 模板的 Allocations 统计与 Metal Resource Events 轨。[Analyzing the memory usage of your Metal app](https://developer.apple.com/documentation/xcode/analyzing-the-memory-usage-of-your-metal-app)
- **Canvas 只用于「不需要文字与交互元素、以动态绘制为主」的场景，且只在大量元素需要时使用；图形元素很多但需要每个元素的交互/无障碍时用 `drawingGroup`（不要包 UI 控件）；Canvas 元素级交互与无障碍需在视图整体上补足。** 为什么：Canvas 是立即模式绘制，单张图形，没有元素级交互/无障碍；`drawingGroup` 保留逐元素功能但有每元素的簿记与存储开销。验证：对照 Canvas 与 drawingGroup 的 body/CPU 采样与元素数量。[Add rich graphics to your SwiftUI app（WWDC21）](https://developer.apple.com/videos/play/wwdc2021/10021/)、[Canvas 文档](https://developer.apple.com/documentation/swiftui/canvas)
- **Canvas 内重复绘制同一内容时先解析（resolve）再复用（如 `ResolvedImage`）；绘制闭包保持纯绘制操作。** 为什么：每次绘制都让 context 依据环境重新求值同一图像是重复工作（WWDC21 演示：同一 Image 画多次，先 `context.resolve` 一次再复用）。验证：Time Profiler 采样绘制闭包；对照解析次数。[WWDC21 10021](https://developer.apple.com/videos/play/wwdc2021/10021/)
- **需要按显示节奏持续变化时用 `TimelineView`（animation/periodic schedule），它提供逐个显示的更新节奏；驱动它的模型更新尽量轻量。** 为什么：连续绘制场景里更新频率决定成本，把重计算放进每帧更新会等比放大。验证：Time Profiler 在 TimelineView 活跃区间采样，检查逐帧闭包中的热点。[WWDC21 10021](https://developer.apple.com/videos/play/wwdc2021/10021/)
- **用 Liquid Glass 时把多个玻璃效果合入 `GlassEffectContainer`，但只合并空间上相邻的视图；玻璃区域的邻近更新有额外计算。** 为什么：分散的玻璃视图各自计算且相互影响范围大；容器合并可减少重复合成，但把屏幕顶部与底部的按钮合并会让中间变化牵动两端。验证：Flash Updated Regions 观察 GlassEffectContainer 覆盖范围与更新区域。[Improving rendering efficiency](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency)

## 第二部分：后端运行时（并发、内存、能源、I/O、网络、启动）

本部分面向常驻进程、后台任务与持久化路径。先做可观测性：Xcode Organizer / MetricKit 提供上线后的真实指标（启动、内存、hang、hitch、磁盘写入、能耗），开发期用 Instruments 定位代码，二者结合形成持续改进循环。[Improving your app's performance](https://developer.apple.com/documentation/xcode/improving-your-app-s-performance)、[Analyzing the performance of your shipping app](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-shipping-app)

### 5. 并发：主线程只做 UI，任务结构决定取消与优先级

- **主线程只用于 UI；把非 UI 工作移出主线程，且不要以「异步调度到主线程」的方式安排不需要主线程的工作。** 为什么：任何落在主 run loop 上的长任务都会挡住事件处理，造成 hang；异步提交只是把 hang 推后。验证：Thread Performance Checker（Run action 默认开启——官方原文是“Xcode enables the Thread Performance Checker tool by default for the Run action”，不是仅 Debug 期；报告主线程上的非 UI 工作与优先级反转；`PERFC_SUPPRESSION_FILE` 可延后处理已知项），搭配 Time Profiler 与 Hangs instrument 查看主 run loop 忙区间（工具默认约 250 ms 起报告）。[Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)、[Diagnosing performance issues early](https://developer.apple.com/documentation/xcode/diagnosing-performance-issues-early)、[Understanding hangs](https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app)
- **区分「主线程忙」与「主线程被阻塞」两类 hang，分别优化：忙要看是单次长任务还是被调用太多次，阻塞要看在等谁。** 为什么：两者根因不同；主线程忙时长任务要拆分、高频调用要从调用方减少次数；阻塞要移除同步等待。验证：Hangs instrument 选中 hang 区间，看主线程在期间是否有 CPU 活动；用 `os_signpost`（POI）给可疑区间打点，再在 Points of Interest 轨上测量具体函数时长（Time Profiler 采样无法区分「慢一次」和「快多次」）。[Analyze hangs with Instruments（WWDC23）](https://developer.apple.com/videos/play/wwdc2023/10248/)、[Understand and eliminate hangs（WWDC21）](https://developer.apple.com/videos/play/wwdc2021/10258/)
- **不要用 `dispatch_semaphore_wait`/`dispatch_group_wait` 把异步接口伪装成同步；必须等待时，让等待线程的 QoS 不高于被等待线程的 QoS。** 为什么：QoS 不一致时系统不能自动传递优先级，会产生优先级反转，表现为「主线程被低优先级工作卡住」。验证：Thread Performance Checker 的 priority inversion 报告与 backtrace。[Diagnosing performance issues early](https://developer.apple.com/documentation/xcode/diagnosing-performance-issues-early)
- **不要在 `View.body`（@MainActor）里用普通 `Task {}` 包同步重活；把重活改成 `nonisolated async` 函数再 `await`，无法改造时用 `Task.detached`。** 为什么：`Task` 默认继承外层 actor 约束，body 的 @MainActor 会让同步重活继续在主线程执行；`.task` modifier 也继承上下文。验证：Swift Concurrency Tasks instrument 或 Swift Tasks 轨看任务是否在主线程执行，配合 Time Profiler 看任务的实际工作量。注意 `Task.detached` 不继承创建处优先级（默认 `.medium`），且视图消失不会传播取消给它；`nonisolated async` 方案的成本低于新开任务。[WWDC23 10248](https://developer.apple.com/videos/play/wwdc2023/10248/)、[Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- **优先用结构化并发（`async let`、task group、discarding task group），而不是无结构的 `Task`/`Task.detached`。** 为什么：结构化任务随作用域结束自动取消、自动传播优先级，生命周期明确；只发不需要结果的并发工作用 discarding task group 可即时释放子任务资源、减少内存占用。验证：Swift Concurrency 模板/ Swift Tasks instrument 查看任务层级与取消传播。[Beyond the basics of structured concurrency（WWDC23）](https://developer.apple.com/videos/play/wwdc2023/10170/)
- **不要因并发而爆发线程数：Swift 并发的协作线程池最多只起与 CPU 核数相当的线程，GCD 并发队列会因阻塞而扩线程；用前者（或受控队列）替代手工线程。** 为什么：线程越多，每个线程获得的调度越少，主线程也会被挤；协作池要求任务不阻塞线程（actor/await 切换是轻量 continuation 而不是线程切换）。验证：CPU Profiler/Time Profiler 看线程数与上下文切换；System Load 轨看可运行线程是否多于核数。[Swift concurrency: Behind the scenes（WWDC21）](https://developer.apple.com/videos/play/wwdc2021/10254/)、[Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- **搜索/校验类可切分的同步算法改成并行时，用固定的并行分块与有界子任务数，不要按数据量无限展开任务。** 为什么：并行只在核数范围内有收益，任务与线程的协调成本固定；无界并发只会增加调度和内存开销。验证：对照不同分块数量的 CPU Profiler 耗时曲线；单元回归用固定工作量计数而不是墙钟阈值。[Beyond the basics of structured concurrency（WWDC23，有界并发模式）](https://developer.apple.com/videos/play/wwdc2023/10170/)、[Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)

### 6. 内存：把 footprint 当作共享资源

- **控制 dirty memory（footprint = dirty + compressed），不要把「虚拟分配」当成没占用物理内存。** 为什么：写入分配页后才真正占用 RAM；系统还会把不常访问的脏页压缩，且按压缩前大小计费。验证：Xcode Organizer 的 Memory 面板 / MetricKit 的 peak memory 与 suspension 时内存；Instruments 的 VM Tracker 看 footprint 曲线与压缩/换出。[Reducing your app's memory use](https://developer.apple.com/documentation/xcode/reducing-your-app-s-memory-use)、[Analyzing the memory usage of your Metal app](https://developer.apple.com/documentation/xcode/analyzing-the-memory-usage-of-your-metal-app)
- **长驻进程要关注堆碎片，必要时用 autorelease pool 归拢生命周期；完成的活动立即拆卸（观察者、定时器、缓存），不要依赖「等一会儿就好」。** 为什么：碎片是 footprint 的乘数（Apple 经验：长驻进程碎片控制在约 25% 以下），长驻进程反复分配/释放最容易碎片化；崩溃后从零启动代价更高。验证：`vmmap -summary` 看 malloc zone 的 % FRAG（Apple 演示工具输出即 `vmmap -summary`，其在 iOS/macOS 均可用）；Instruments 的 Allocations/VM Tracker；多轮开合的泄漏测试。[Detect and diagnose memory issues（WWDC21）](https://developer.apple.com/videos/play/wwdc2021/10180/)
- **追求零泄漏：找出并修复泄漏与循环引用（必要时用 weak）；手工管理的资源（指针、CG 对象、句柄）要显式释放。** 为什么：泄漏的脏页既无法回收也无法访问，ARC 管不住循环引用与 unsafe 指针。验证：`leaks` 工具 + malloc 栈回溯；无泄漏则用 `vmmap -summary` 确认增长在堆上，再用 `heap -diffFrom` 定位增长的类，需要追引用关系时用 `leaks -referenceTree` / `malloc_history`。[WWDC21 10180](https://developer.apple.com/videos/play/wwdc2021/10180/)
- **图片与缓存的持有量要按需收敛；给缓存设置明确上限并在低内存时释放；把可再生成的数据放到可清理位置（cache/temporary）。** 为什么：解码图像缓冲是未压缩的脏页大头；系统会在低存储/内存压力下清理 cache 目录，但被 App 长期持有的对象不会自动释放。验证：前台的 Allocations 快照对照；organizer 显示的内存趋势。[Reducing memory use](https://developer.apple.com/documentation/xcode/reducing-your-app-s-memory-use)、[Monitoring storage metrics](https://developer.apple.com/documentation/xcode/monitoring-your-app-s-storage-metrics)
- **把内存与性能指标纳入回归：用 `XCTMemoryMetric` 与 `XCTClockMetric` 度量关键路径。** 为什么：内存回归往往是缓慢累积的，人工观察容易漏掉。验证：性能测试基线 + 失败时的 memgraph/ktrace（`xcodebuild` 的 `enablePerformanceTestsDiagnostics`）。[Writing and running performance tests](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests)、[Detect and diagnose memory issues（WWDC21，含该 flag 的 memgraph/ktrace 行为）](https://developer.apple.com/videos/play/wwdc2021/10180/)

### 7. 能源与硬件：少做、高效做、不误用 API

- **按三步法降能耗：少做工作 → 更高效地做 → 按 API 最佳实践使用。** 为什么：能耗来自 CPU、GPU、屏幕、网络、定位等子系统的使用时间；三阶段各有不同的收益来源。验证：Power Profiler 看进程在 CPU/GPU/display/network 各子系统的能耗归因，改动前后各录一次对比；注意不同机型数值不可横向比较（Power Profiler 目前仅 iPhone/iPad iOS 26+；macOS 本机用 Xcode 调试仪表的 Energy Impact，见 Analyzing battery use）。[Reducing battery use](https://developer.apple.com/documentation/xcode/reducing-your-app-s-battery-use)、[Measuring power use with Power Profiler](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler)
- **用高级框架替代直接访问硬件/低层 API；无法避免低层路径时先测量各方案能耗再选型（例如播放视频优先 `AVPlayer`）。** 为什么：系统框架针对硬件做了调度与功耗优化。验证：Power Profiler 的子系统分解 + 方案对照。[Reducing battery use](https://developer.apple.com/documentation/xcode/reducing-your-app-s-battery-use)、[Improving rendering efficiency](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency)
- **前台常驻的网络/硬件集成要按可见性、用户意图和低电量状态调度，避免后台轮询；不需要立即执行的工作延后到合适时机（如充电时）。** 为什么：后台执行是机会性的、受系统资源与能耗管理约束；持续轮询会把整机拖入高功耗状态并可能与前台体验竞争资源。验证：Power Profiler 的进程轨与能耗趋势（iOS 26+）；确认隐藏/失去焦点后没有持续采样。Apple 对该条给的原文是 iOS 后台任务口径（如果任务不必立即运行，考虑推迟到设备充电时，任务本身保持轻量、目的单一）；macOS 常驻进程侧对应的是 App Nap / 定时器合并等系统机制，官方没有与 iOS 同款的“后台任务”API，此条在 macOS 上按“暂停不必要工作”原则执行。[Finish tasks in the background（WWDC25）](https://developer.apple.com/videos/play/wwdc2025/227/)
- **CPU 设计层面：优先用系统框架；不要自建固定大小线程池，把 QoS 标注清楚交给系统动态调度（Dispatch 用合适的 `DispatchQoS`，后台任务用 `BackgroundTasks` 的任务类型——注意 BackgroundTasks 是 iOS/iPadOS/tvOS 框架，不覆盖 macOS；macOS 常驻进程用 `NSBackgroundActivityScheduler` 或 App Nap 友好做法）。** 为什么：静态线程池会让部分线程空转等待，系统无法按核心类型与当前负载动态分配。验证：CPU Counters 模板（CPU Bottlenecks 模式）看流水线停顿与内存访问瓶颈；Time Profiler 关联到具体代码；改动后用性能测试复测。[Addressing CPU bottlenecks](https://developer.apple.com/documentation/xcode/addressing-cpu-bottlenecks)
- **降低显示能耗：支持深色外观、降低画面平均亮度与大面积高亮区域；后台播放媒体用系统播放路径。** 为什么：像素越亮越耗电（该节为 iOS 文档口径，原理在 macOS 同样适用）。验证：Power Profiler 的 display 归因（iOS 26+ 机型）与平均像素亮度（MetricKit `MXUnitAveragePixelLuminance`，iOS/macOS 均有）。[Improving rendering efficiency](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency)、[Analyzing battery use](https://developer.apple.com/documentation/xcode/analyzing-your-app-s-battery-use)

### 8. I/O 与持久化：少写、成批写、写小

- **减少 SSD 写入次数与总量；生成可再生的文件放到 cache/temporary 位置；不要为了「稳妥」高频写盘。** 为什么：写比读慢，且同一区域写入次数有限；系统报告超过 24 小时阈值的写异常。验证：Xcode Organizer 的 Disk Writes 面板 / MetricKit 看每天逻辑写入量；Instruments 的 File Activity 模板（Filesystem Activity 与 Disk Usage/Disk I/O Latency）看系统调用、大小、时长与回溯。[Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes)
- **把连续的小改动合并成一次写（或按批提交）；对频繁编辑的数据优先用 SwiftData/CoreData/SQLite；不必每次都用原子写与 `F_FULLFSYNC`，需要写屏障时用 `F_BARRIERFSYNC`。** 为什么：重复打开-写-关闭同一文件、原子替换、强制 flush 都会放大写入与延迟；JSON/plist 等序列化格式每次改动要重写整个文件，不适合频繁更新的数据。验证：Disk Writes 报告与 File Activity 的写入次数/大小对照。[Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes)
- **避免高频创建/删除/改名文件；不要依赖大量小文件组织数据。** 为什么：创建/删除约 8 KB 元数据写入，改名/移动约 16 KB（Apple 原文为 iOS 口径，macOS 上数值不同但同样存在元数据写放大），且按块写、粒度随磁盘控制器（常见 4 KB）。验证：File Activity 与磁盘写入报告；文件计数与设备存储趋势。[Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes)、[Monitoring storage metrics](https://developer.apple.com/documentation/xcode/monitoring-your-app-s-storage-metrics)
- **SQLite 使用：事务合并相关写、为查询列建索引（含合适的 partial index）、启用 WAL、避免频繁开关连接、用 `EXPLAIN QUERY PLAN` 验证查询计划、批量删除后做增量 vacuum。** 为什么：索引缺失会让 SQLite 建临时 B 树甚至落盘；关闭连接会强制写出全部待处理变更与 journal；`VACUUM` 会重写整库。验证：`EXPLAIN QUERY PLAN` 输出中不应出现 `USE TEMP B-TREE FOR ORDER BY`；`PRAGMA journal_mode` 应为 WAL；Disk Writes 报告建议。[Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes)
- **需要度量 I/O 回归时，用 `XCTStorageMetric` 等把磁盘写入量纳入性能测试。** 为什么：写入量是可持续跟踪的量化指标，能发现「实现变了、写盘多了」这类回归。验证：性能测试与基线比较。[Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes)

### 9. 网络：减少往返与无谓流量

- **减少应用需要的网络往返次数：这是开发者能控制的最大杠杆（采用 HTTP/3、TCP Fast Open、TLS 1.3、Multipath TCP 等，按服务端支持情况推进）。** 为什么：首字节时间 = 往返次数 × 单次 RTT；Apple 测量中真实网络 RTT 可达 600 ms（空闲 20 ms、工作时飙到 600 ms，30 倍差距），从 TLS 1.2/TCP 的 4 个往返降到 HTTP/3 的 2 个往返可把 2.4 s 首字节降到约 0.5 s。验证：Instruments 的 Network 模板（Network Connections + HTTP Traffic）看会话、任务、事务状态（cache lookup、blocked、sending、waiting、receiving）；用 Network Link Conditioner 模拟弱网复测（iOS 在 Developer 设置菜单，macOS 版从 Apple 开发者网站下载）。[Reduce network delays（WWDC21）](https://developer.apple.com/videos/play/wwdc2021/10239/)、[Analyzing HTTP traffic](https://developer.apple.com/documentation/foundation/analyzing-http-traffic-with-instruments)
- **把非用户触发的预取/同步标记为 background 服务类型，让系统把前台流量排在前面。** 为什么：预取占满网络队列会把用户主动操作的响应排到队尾；后台服务类型的新拥塞控制算法能在显著降低延迟的同时保持传输时长（iOS 15 / macOS Monterey 起）。验证：HTTP Traffic 的 blocked 时长对照；前台请求的响应时间。[WWDC21 10239](https://developer.apple.com/videos/play/wwdc2021/10239/)
- **合并请求、避免轮询式重复请求；给 URLSession 设 `sessionDescription` 便于在 Instruments 中区分会话；用缓存状态定位重复请求。** 为什么：交易状态含 cache lookup 段，重复请求在会话轨上可辨认；命名会话让 HTTP Traffic 轨可读。验证：Network 模板按进程/会话/域展开，Summary: Transaction Durations 按 IP/连接/路径分组。[Analyzing HTTP traffic](https://developer.apple.com/documentation/foundation/analyzing-http-traffic-with-instruments)

### 10. 启动与生命周期：把工作推迟到真正需要时

- **延迟昂贵初始化：app 启动只准备首屏所需的最小数据；持久化、定位、大目录扫描等按首次使用初始化；在启动路径上不要做同步 I/O、数据库更新、网络同步。** 为什么：延迟直接决定启动观感，用户会感知慢启动（iOS 上 watchdog 会终止超时的启动）。验证：App Launch 模板（time profile + thread-state trace，看主线程与阻塞原因）；Xcode Organizer 的 Launch Time 面板与 MetricKit 的 TimeToFirstDraw/ApplicationResumeTime 直方图。注意：文档原文的 organizer 叙事面向 iOS，macOS 的启动量测与 `TimeToFirstDrawMetric`（MetricKit，iOS 27 / macOS 27 起）可用性需按本机 Xcode 版本核对，已列入 gaps。[Reducing launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)
- **减少启动时需要加载的动态库数量；对预主（pre-main）静态初始化里的工作保持零容忍（几毫秒以上的都移出）。** 为什么：dyld 的工作量与库数量、静态初始化代码量相关；合并动态库可在发布构建获得接近静态链接的启动表现。验证：Instruments 的 dyld Activity instrument 测量静态初始化；`dyld_usage` 查看动态链接过程（macOS 本机）。[Reducing launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)、[Link fast（WWDC22）](https://developer.apple.com/videos/play/wwdc2022/110362/)
- **启动后的额外准备阶段用 `os_signpost`（Points of Interest）打点，纳入观测。** 为什么：首帧之后用户仍在等待的准备工作不计入启动指标但计入感受，需要单独可见。验证：Points of Interest instrument 与自定义 signpost 区间。[Reducing launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)
- **常驻进程注意激活成本（macOS 上把内存从压缩/交换中调回、重渲染）；让进程保持较小 footprint，避免被系统回收后重新加载。** 为什么：macOS 不像 iOS 那样在常规使用中退出进程，但内存压力下会压缩/换出，重新激活有额外延迟。验证：VM Tracker 看常驻内存与压缩页；Organizer/MetricKit 的内存指标。[Reducing launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)

### 11. 验证与回归（运行时通用）

- **为几乎所有性能改动建立性能测试基线，用真实生产代码、固定工作量和可重复的环境；先落实「测量 → 定位 → 一次只改一件事 → 重新测量」的循环。** 为什么：未加回归门禁的性能修复会在后续变更中悄悄回退；一次改多处会污染归因。验证：`XCTClockMetric`/`XCTCPUMetric`/`XCTMemoryMetric`/`XCTStorageMetric`/`XCTOSSignpostMetric`；XCTest 默认在测得值超过基线加最大标准差时失败；测试计划使用 Release 配置、关闭调试可执行、关闭代码覆盖率与运行时消毒器。本项目的回归入口与命令以 `docs/DEVELOPMENT.md` 为准（`make test TEST=<组名>`）。[Writing and running performance tests](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests)、[Improving your app's performance](https://developer.apple.com/documentation/xcode/improving-your-app-s-performance)
- **不要在模拟器里做性能测量；在真实设备/本机真实构建、并在多代硬件上验证。** 为什么：模拟器性能与真机差异大，弱设备上的问题往往就是部分用户的真实问题。验证：固定录制命令与本机硬件对照；外部测量数据应包括机型与环境。[Creating performant scrollable stacks](https://developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks)、[Analyze hangs with Instruments](https://developer.apple.com/videos/play/wwdc2023/10248/)
- **上线后用 Organizer/MetricKit 看真实用户指标（hitch rate、hang rate、内存、磁盘写入、能耗），不要只看开发机。** 为什么：预发布测试无法覆盖所有设备与状态；回归通知帮助发现版本级退化。验证：Xcode Organizer 的 Insights 与各面板，按机型/版本/百分位过滤；MetricKit 直方图。注意覆盖范围：hitch rate 仅 iOS/iPadOS；hang rate 覆盖 iOS/macOS；Launch Time 面板面向 iOS app。[Analyzing the performance of your shipping app](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-shipping-app)、[Analyzing responsiveness issues](https://developer.apple.com/documentation/xcode/analyzing-responsiveness-issues-in-your-shipping-app)

## 值类型与引用类型（性能取向的选择）

| 需要 | 选择 | 代价与验证 |
| --- | --- | --- |
| 高频迭代、协程/并行处理纯数据（可跨线程） | 值类型（`struct`/`enum`），配合 `Sendable`/不可变 | 大结构体复制成本；用 `swift-collections` 的 `Deque` 等结构避免数组头部/中间操作（Deque 头部插入为常数时间，见视频）。验证：CPU Profiler 采样复制热点；对照容器操作次数。出处：[Meet the Swift Algorithms and Collections packages](https://developer.apple.com/videos/play/wwdc2021/10256/)、[Eliminate data races using Swift Concurrency](https://developer.apple.com/videos/play/wwdc2022/110351/) |
| 被多观察者共享、身份可变的 UI 状态 | 引用类型 + `@Observable`，但依赖按属性收敛 | 观察面过宽会造成过量 body 更新；用 Cause & Effect 图复查。出处：[WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306/) |
| 跨会话/跨进程序列化 | 稳定的 `Codable` 模型 + 版本化迁移 | 迁移成本与兼容；用迁移测试与快照回归验证。实现口径见 [会话迁移调研](session-migration-research-2026-10-03.md) |

## 任务与调度（启动与后台）

| 场景 | 首选 | 不选 | 验证 |
| --- | --- | --- | --- |
| 首屏渲染所需数据 | 同步准备最小集，其余延后 | 启动期全量扫描/网络同步 | App Launch 模板、Launch Time 面板 |
| 一次性并发（有结构化父子关系） | `async let` / task group / discarding task group | 裸 `Task` 链、手工线程 | Swift Tasks instrument / Swift Concurrency 模板 |
| 需要脱离当前 actor 的同步重活 | `nonisolated async` 包装，或 `Task.detached`（显式优先级） | `Task {}` 在 @MainActor 上下文里跑同步重活 | Time Profiler 看主线程 |
| 后台维护 | 系统后台任务机制，机会性调度、可用时延后 | 常驻定时器轮询 | Power Profiler、能耗趋势、挂起后采样归零 |
| 有界并行的可切分计算 | 固定分块 + 有界子任务数 | 按数据量展开任务 | CPU Profiler 分块数对照 |

出处：[Beyond the basics of structured concurrency](https://developer.apple.com/videos/play/wwdc2023/10170/)、[Swift concurrency: Behind the scenes](https://developer.apple.com/videos/play/wwdc2021/10254/)、[Finish tasks in the background](https://developer.apple.com/videos/play/wwdc2025/227/)、[Reducing launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)

## 本项目的系统集成边界（引用本项目规范，非 Apple 文档）

以下为 `AGENTS.md` / `docs/DEVELOPMENT.md` 已生效的仓库约束，本文件的 Apple 规则在 dev 构建上的落地不得越过这些边界：

- 开发测试版不启动 VPN 内核、不设置/清除系统代理、DNS、TUN，不写 SMC、不调用特权辅助工具、不注册登录项、不修改外部连接器、不调用真实 Codex app-server；限制在副作用入口执行。
- 开发测试版不请求任何会弹窗的系统权限，所有请求入口以 `BuildChannel.promptsForSystemPermissions` 为第一道闸。
- 禁止按名字横扫的全局进程操作；正式版安装只经 `make install-release` 显式操作。
- 测试不得修改真实用户配置、启动 VPN、写硬件或杀进程；使用临时目录与模拟进程传输，执行真实生产逻辑但无副作用。

同前文规则冲突时，以仓库约束为准，不得为了「测量完整」而越过。

## 错误写法 → 正确做法（抗模式汇总）

| 错误写法 | 正确做法 | 为什么 / 验证 | 出处 |
| --- | --- | --- | --- |
| 在 `body` 每次求值时新建 `NumberFormatter`/`MeasurementFormatter` 并格式化字符串 | 在模型层构造一次 formatter，预计算字符串并缓存 | formatter 创建与格式化会占据 body 主线程预算；SwiftUI 修复前后对照 Long View Body Updates | [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306/) |
| 视图经由函数间接读取整个集合（如 `isFavorite` 遍历收藏数组） | 依赖收敛到「本视图自己的状态」（如按条目的 view model） | `@Observable` 依赖按实际读取的属性建立，点一个按钮不应更新全部列表项 | [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306/) |
| 把计时器/几何进度等高频值放进 Environment | 改为局部状态或把读取方收窄到最小子树 | 所有读 environment 的视图都有检查成本，高频值会放大 | [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306/) |
| `Task { doLongRunningWork() }`（同步函数、在 @MainActor 的 body 中） | `nonisolated async` 包装后 `await`，或 `Task.detached` | `Task` 继承外层 actor 约束，同步重活仍上主线程，只是把 hang 推后 | [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness) |
| 用 `dispatch_semaphore_wait`/`dispatch_group_wait` 把异步接口伪装成同步 | 直接改成异步流转；必须等待时让等待方 QoS ≤ 被等待方 | 系统无法自动传播优先级，造成优先级反转 | [Diagnosing performance issues early](https://developer.apple.com/documentation/xcode/diagnosing-performance-issues-early) |
| 自建固定线程池 / 每请求起线程 | 用 Swift 并发协作池或系统框架，QoS 交给系统动态调度 | 静态池会让线程空转等待；线程太多会挤占主线程调度 | [Addressing CPU bottlenecks](https://developer.apple.com/documentation/xcode/addressing-cpu-bottlenecks)、[WWDC21 10254](https://developer.apple.com/videos/play/wwdc2021/10254/) |
| 列表行内联线性过滤（每次构建都扫一遍集合） | 过滤在模型层完成并缓存 | 行 ID 被急切收集，标识符生成成本放大到加载与更新 | [WWDC23 10160](https://developer.apple.com/videos/play/wwdc2023/10160/) |
| `ForEach` 内容用 `AnyView` 或单边 `if`（视图数不恒定） | 用显式栈/常量数量的视图，过滤放进数据源 | 视图数不恒定时 List 必须额外构建视图才能取到行 ID | [WWDC23 10160](https://developer.apple.com/videos/play/wwdc2023/10160/) |
| 在 `Grid`/普通栈里一次性构建全部缩略图 | 换成 `LazyVGrid`/惰性栈，只构建首屏所需 | WWDC23 案例：70 次 body × ~50 ms 造成数秒 hang | [WWDC23 10248](https://developer.apple.com/videos/play/wwdc2023/10248/) |
| 阴影不设 `shadowPath`；用 CAShapeLayer/mask 做圆角；不必要的 `masksToBounds` | 设置 `shadowPath`；用 `cornerRadius` + `cornerCurve`；内容不越界时去掉遮罩 | 阴影/mask/圆角/模糊各触发离屏渲染与额外合成；视图调试器可看 offscreen count | [Tech Talks 10857](https://developer.apple.com/videos/play/tech-talks/10857/) |
| 在大列表的 `prepareForReuse` 里清空数据、销毁子视图，随后重建 | 复用视图结构，只更新内容（如打开新数据覆盖而不是清空重建） | 每次复用都做昂贵的视图层级操作会进入 commit 预算（Apple 案例中该路径一次约 10 ms） | [Tech Talks 10856](https://developer.apple.com/videos/play/tech-talks/10856/) |
| 动画中删除/重建视图来「隐藏」 | 用 `hidden` 等廉价属性切换可见性 | 增删视图是昂贵的层级操作，动画期间每帧都很敏感 | [Tech Talks 10856](https://developer.apple.com/videos/play/tech-talks/10856/) |
| SwiftUI `List` 的滚动交互中同步做磁盘/网络/DB 等阻塞操作 | 后台执行 + 主线程只做 UI 更新 | 主 run loop 长忙区间直接表现为 hang；Thread Performance Checker 会报主线程非 UI 工作 | [Diagnosing performance issues early](https://developer.apple.com/documentation/xcode/diagnosing-performance-issues-early) |
| 高频重复写同一文件 / 反复原子替换 / 无必要地 `fsync`、`F_FULLFSYNC` | 合并小改动批量写；非必要时用 `F_BARRIERFSYNC` 或依赖系统缓存策略 | 写入按块放大（1 字节改动写 4 KB），还增加磨损 | [Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes) |
| 频繁编辑的数据用 JSON/plist 整文件重写；SQLite 频繁开关连接、无索引查询、全量 VACUUM | 用 SQLite/SwiftData 批量事务与索引、WAL、增量 vacuum | 序列化格式每次改动重写整个文件；索引缺失会建临时 B 树甚至落盘 | [Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes) |
| 首页面的动画/轮询在窗口隐藏、退到后台后继续跑 | 按可见性/活跃状态暂停或卸载，不需要的工作延后 | 后台执行是机会性的，持续活动会推高整机功耗并挤占前台 | [Finish tasks in the background](https://developer.apple.com/videos/play/wwdc2025/227/) |
| 启动时做同步 I/O、数据库更新、网络同步；pre-main 静态初始化里做重活 | 首屏只准备必要数据，重活延后到首次使用或用异步流程 | 静态初始化与启动同步路径直接拉长启动时间（pre-main 的任务应控制在几毫秒内） | [Link fast](https://developer.apple.com/videos/play/wwdc2022/110362/)、[Reducing launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time) |
| 在 5G/快 Wi-Fi 上测试网络就认为没问题；预取与前台请求混用默认服务类型 | 用 Network Link Conditioner 复现弱网；把非用户触发的传输标为 background | 真实网络 RTT 可达 600 ms，队列被预取占满会把用户操作排到队尾 | [Reduce network delays](https://developer.apple.com/videos/play/wwdc2021/10239/) |
| 在模拟器上评估性能 | 在真实设备/本机真实构建上测量，必要时在旧硬件上复测 | 模拟器与真机性能差异大，部分用户的真实问题只能被弱设备暴露 | [Creating performant scrollable stacks](https://developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks) |

## 本项目自检清单

逐条核对；每条都可直接用「是/否」回答。「是」表示符合规范。

**前端（视图、布局、绘制）**

1. 每个视图 body 只读取它渲染所需的字段/属性，没有读取整个集合或无关属性？
2. 没有把频繁变化的值（几何、计时进度）放进 Environment？
3. body、视图初始化器、onAppear/onChanged 中没有昂贵计算、formatter 创建、字符串插值或 bundle 查询？
4. 频繁变化的数据依赖用 `@Observable` 且粒度到属性，没有「一处变化触发全部同类视图」？
5. 长列表/网格使用惰性容器，且急切容器（如 Grid）没有把全部内容一次性构建？
6. List/Table 的 ForEach 内容对每个元素产出恒定数量视图（无 AnyView、无单边条件）？
7. 行标识符的两个环节（数据侧 id / 视图侧 identity）都没有重复计算或线性过滤？
8. 有成因图/更新组证据证明没有不必要的更新循环（自己触发、自己响应）？
9. 自绘代码只画脏矩形、不做 I/O 或复杂计算，也没有空的 draw 实现？
10. 阴影设置了 shadowPath，圆角用 cornerRadius+continuous，遮罩规模最小且必要？
11. 动画路径逐帧更新中没有附加的昂贵操作，动画结束会停止？
12. 用 Flash Updated Regions 或等价手段检查过「刷新但视觉无变化」的区域？
13. Canvas/drawingGroup 的取舍经过测量，绘制前解析复用、数据已准备好？

**后端（并发、内存、能源、I/O、网络、启动）**

14. 主线程只做 UI 与短暂状态更新，没有非 UI 同步工作？
15. 没有用 semaphore/group_wait 伪装同步调用；必须等待时 QoS 不高于被等待方？
16. View.body 里的 Task 没有继承 @MainActor 去跑同步重活？
17. 并发任务有明确结构（作用域/取消传播），不会无限展开任务数？
18. 没有自建无界线程/定时器，QoS 标注齐全？
19. 缓存、观察者、定时器都有明确数量上限与释放路径，长驻进程没有持续增长的容器？
20. 做过泄漏与碎片检查（leaks / vmmap / Allocations 快照对照）？
21. 大图/大缓冲区按需加载与释放，缓存有上限？
22. 磁盘写入没有高频重复（重复写、写放大、高频原子替换 / F_FULLFSYNC）？
23. 数据库/持久化使用批量事务与索引，SQLite 在 WAL 且不频繁开关？
24. 网络请求没有轮询与冗余往返，预取走后台服务类型？
25. 启动路径没有同步 I/O、大目录扫描、网络同步？
26. 后台/隐藏时没有持续采样或动画在跑，没有常见路径上的高频轮询？
27. 有性能测试基线（XCTest 指标或本项目回归组）覆盖本次改动的主要路径？
28. 测量在真实构建上完成，且知道本次结论的机型/环境边界？

## 无法从官方来源确认或被本次摘录省略的条目（需另行查证）

- **Instruments 模板的完整列表与 macOS 上截图的菜单名称**：本文件只核对了 `xcrun xctrace list templates`（xctrace 27.0）中的模板名；屏幕里的 lane 名与 Xcode 版本有关，需以实际录制时 Instruments 的显示为准。
- **WWDC26 的性能相关会话（2026-10-06 已核对）**：《Profile, fix, and verify: Improve app responsiveness with Instruments》（wwdc2026/268）以 Instruments 27 的 Swift Concurrency 模板、top functions 模式等为主，没有改写本文引用的阈值；另有《Dive into lazy stacks and scrolling with SwiftUI》（wwdc2026/321）、《What's new in SwiftUI》（wwdc2026/269）等未逐条纳入本文，后续如需可增补。
- **`xcrun xctrace` 在只安装 Command Line Tools 的 CI 机器上的可用性**：本机工具链检查显示 CLT 下没有 xctrace；CI 环境是否需要 Xcode 需另行确认。
- **具体数值到 ClaudeBar 本机应用（如菜单栏 NSPanel/NSStatusItem 场景）的映射**：Apple 文档给出的阈值（100/250/500 ms、5 ms/帧、hitch rate 分级）是平台通用口径；本项目各窗口与面板的验收目标需要在实测中另行设定，不能直接照搬为 CI 断言。
- **Xcode Organizer / MetricKit 数据在 ad-hoc 签名、开发构建上的可用性**：上线指标通常来自分发渠道；本地开发构建是否有等价数据需要对照。
- **macOS 上部分指标的官方可用性**：hitch rate 面板仅 iOS/iPadOS；Power Profiler 仅 iPhone/iPad iOS 26+；`TimeToFirstDrawMetric` / `ApplicationResumeTimeMetric` 的 availability 在文档 JSON 中标注为 OS 27 起（本文核对时）；这些在 macOS 15+ 目标上的可用性需按发布时 SDK 再核对。
- **`dyld_usage`、`vmmap -summary` 的 % FRAG 列**：前者的可用性随 macOS/Xcode 版本变化（本机 macOS 26.6 `/usr/bin/dyld_usage` 存在）；后者本机输出有 `% FRAG` 列，但 iOS 上的列名/行为需以对应工具版本为准。
- **WWDC 文字稿中未逐字覆盖的 macOS 特定话题**：如菜单栏应用在非活跃状态下的动画调度、多显示器 vsync、外接显示器刷新率变化下的 display link 行为等，官方文档没有统一口径，遇到时需单独立项调研。
- **Apple 未给出硬性指标的部分**：例如单次工具栏/弹窗交互的可接受延迟、常驻应用的 CPU 占用上限、每个后台模块的刷新频率上限，均无官方公开阈值；本项目用「不造成可感知 hitch、回归基线不退化」的自定义门限替代。
- **原文中「不应出现 USE TEMP B-TREE FOR ORDER BY」「PRAGMA journal_mode 应为 WAL」「部分索引」「增量 vacuum」等 SQLite 细则**：均取自 Reducing disk writes 的原文，可在本机 SQLite 上直接验证；本文未替 Apple 之外的其他来源背书。

