# 原生前端性能：表格与文档目录

本轮从 `d6a73b8` 继续，重点验证 SwiftUI/AppKit 的视图更新、布局和文本解析。修改文档表格与目录两个生产文件，使用生产源码组成的原生 NSHostingView 夹具执行前后对照。没有安装或启动新正式版，没有操作 VPN、系统代理、硬件、外部连接器或系统权限。

苹果建议先用 Instruments 找到长 body 更新及其原因，控制视图依赖，避免在频繁更新路径重复做昂贵计算。见 [SwiftUI 性能文档](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)及 [WWDC25：Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/)。本轮据此调整依赖边界与重复工作，不改变文档功能或视觉样式。

## 生产修改

- `DocumentTableController` 保留一份布局结果。模型变化全部失效；测量高度字典变化重新计算。局部焦点、选择或编辑模式变化复用几何；行边框拖动开始也复用这份结果。原布局算法不变，新增一次输入比较及一份 O(单元格 + 行 + 列) 的缓存，不能称为内存减少。
- `DocumentTableCellText` 承载静态单元格的代码识别、HTML span 解码、AttributedString 与样式构建。输入包括单元格以及显式主题颜色；编辑模式和焦点变化不再重复解析未改变的静态内容。原生编辑器只在该单元格进入编辑分支时构建，保留焦点、导航、高度反馈和编辑回调。
- `DocumentOutlineTitle` 仅依赖标题字符串。目录状态或其他标题变化时，SwiftUI 可以跳过内容未变的标题 body。字体和颜色继续从外部视图环境获得。

没有添加全局富文本缓存、异步占位、常驻任务或新的渲染架构。

## 原生前端对照

基线是本轮修改前的生产源码；两个版本使用相同 `swiftc -O -g`、arm64/macOS 15 目标与测试容器。原生表格为 24 行 × 8 列，目录为 3,000 个富文本标题。固定宿主，利用 ObservableObject 驱动 30 次更新：切换表格编辑模式；改变目录最后一个不可见标题。没有通过只调用布局函数冒充界面更新。

三组交替执行，均观察到真实表格和目录 body 各更新 30 次。下表计数是每组固定工作量，耗时是三组中位数。

| 指标 | 修改前 | 修改后 |
| --- | ---: | ---: |
| 表格更新中的布局计算 | 30 次 | 0 次 |
| 表格更新中的静态文本解析 | 5,760 次 | 0 次 |
| 目录更新中的标题解析 | 420 次 | 0 次 |
| 表格原生更新循环 | 2,401.125 ms | 974.269 ms |
| 目录原生更新循环 | 278.056 ms | 262.249 ms |
| 500 × 8 表格的 100 次相同几何查询及结果比较 | 542.878 ms | 0.910 ms |

表格循环耗时约减少 59.4%；目录总耗时变化较小，不能把“解析归零”当作整个目录同等幅度加速。循环包含每次 6 ms 的 RunLoop 等待、SwiftUI/AppKit 更新，以及可编辑时新增的拖动手柄；这些不是每帧渲染耗时或 FPS。原生宿主的布局行为也不能视为正式窗口滚动行为。

每组前后比较 6 个渲染摘要：表格/目录浅色、表格/目录深色、表格内容变化、代码/HTML/空值/对齐/填充样例。全部像素摘要相同；可见标题修改与主题切换确实改变显示，恢复后回到初始图像。源码切片使用真实表格、目录、Markup 和原生编辑器；Theme 与少量界面外围组件是测试替身，未覆盖所有自定义主题组合。

几何回归另外覆盖内容和列宽变化、测量高度增加/删除、显式行高、插删行列、合并/拆分、整表替换及 undo/redo，逐项对比生产 `DocumentTable.layout`。原生宿主也验证 source 更新改变文本和布局。

## Instruments

两组使用 SwiftUI 模板，100 μs Time Profiler 采样，每组 120 次原生更新。该无可见窗口的宿主未产生 SwiftUI 专用事件，xctrace 明确报告 `Trace file had no SwiftUI data`；本轮没有 body 时长、hitch 或帧率结论。下表来自可用的 CPU 采样。

| 整段采样指标 | 修改前 | 修改后 |
| --- | ---: | ---: |
| 主线程 sampled CPU 权重 | 14,820.6 ms | 8,824.4 ms |
| Foundation inclusive 权重 | 8,933.0 ms | 3,084.3 ms |
| SwiftUI inclusive 权重 | 11,184.0 ms | 5,488.7 ms |
| SwiftUICore inclusive 权重 | 11,554.9 ms | 5,877.8 ms |
| AttributeGraph inclusive 权重 | 11,020.9 ms | 5,307.3 ms |

基线首个项目栈帧中 `DocumentTableView.markdownCell` 权重 857.4 ms，修改后该函数移到独立静态子视图，更新循环不再反复调用。两臂仍包含初次解析、失效验证、内容变更、图片栅格化及固定的富文本序列化，因此剩余解析采样不能认定为局部更新缓存失效。inclusive 权重互相重叠，不可相加。每臂只有一份 trace，工具有开销，机器其他进程仍在运行，不是能耗或稳定帧率基准。

录制进程使用 `env -i`，仅传 PATH、TMPDIR。没有导出环境内容；原 trace、XML、源码夹具与合成图像摘要位于 gitignored、0700 的 `.build/performance/frontend-native-2026-10-05/`。公开 [测量数据](performance-frontend-native-2026-10-05.json) 仅含源码指纹与聚合结果。

## 其他前端路径复核

本轮还复核现有天气 Canvas 的可见性/Reduce Motion/低电量闸门、DecorativeMotion 的 Core Animation 实现、EqualRowGrid 的有界布局缓存、用量图表的后台分析/Canvas 边界、JSON 树的节点预算及心率曲线的有限历史。此前测量与现有边界没有支持本轮继续改写这些部分，保留其实现。此处是源码复核，不是这些页面的新运行测量，不能宣称全模块和所有动效状态已经完成帧率验收。

## 验证

新增 `frontend-native` 回归并登记到 Makefile。聚焦 `feishu-documents` 通过；完整 **76 组回归通过（405.55 秒）**。`make build` 与 `make release` 均通过，两套产物的版本隔离、Widget、entitlements 与签名检查通过，`git diff --check` 通过。当前源码指纹与测量时一致。构建均跳过安装；本轮开始与结束核对到的正式版 PID 74536 和可执行文件哈希一致。

本轮尚未安装新代码后对正式窗口做滚动、焦点切换和 GPU 合成的帧率对照，也未重新验证实际系统集成。剩余菜单、编辑手柄及整行结构更新仍可能占用主线程，需要在对应交互下单独测量。
