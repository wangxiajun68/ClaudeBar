# 桌面架构深入调研与选型方案

日期：2026-10-15。状态：架构提案，未实施重写、改名或性能原型。

本文深化[首轮架构与品牌评估](architecture-and-brand-evolution-2026-10-15.md)。目标同时包含功能扩展、视觉升级与性能；跨平台作为架构目标，具体交付平台仍需产品范围确认。

## 1. 决策建议

**主线：Rust 业务核心 + React / TypeScript 工作台；近期沿用 Swift 宿主试迁，未来跨平台宿主优先采用 Tauri 2 稳定线。macOS 的菜单栏、灵动岛、Widget、权限、截图和硬件能力保留原生实现。**

**性能候选：GPUI + GPUI Kit + 同一 Rust 核心。** 它值得用等价页面认真验证，尤其适合密集数据与低延迟交互，但目前不足以仅凭框架介绍取代主线。

**视觉候选：Flutter。** 如果产品未来更偏重一致的自绘动效、移动端和跨平台视觉，而 Web 内容的重要性下降，可重新排序。

**观察项：Electrobun、Tauri 3 / CEF、Dioxus Native / Blitz、Xilem / Vello。** 允许小型研究，不将其尚未证明的特性作为当前业务的必需依赖。

这里选择的是产品的综合交付路线。没有本项目的原型测量，不能声称 Tauri、GPUI、Flutter 或 Rust 已经更快、更省电。

决策顺序：先验证必须保留的功能，再比较资源与交互，最后比较开发速度。视觉目标要贯穿原型，不能用一个空白窗口替代真实工作台。

## 2. 调研方法与证据边界

- 本轮外网检索、官方文档和发布信息读取，均经 `http://127.0.0.1:17890`，没有切换系统代理、启动 VPN 或修改其配置。
- 横向调查 17 条桌面 / UI 路线；另外检查 React、Solid、Svelte、图形与动效、IPC、存储、FFI 等组件。
- 搜索用于发现候选，结论以官方文档、仓库源码与发布记录为依据。访问失败的页面改查官方仓库；没有把搜索摘要或第三方横评当作性能证据。
- 比较了发布标签、主分支与文档，避免把开发状态混为稳定能力。附带[来源记录](desktop-architecture-selection-2026-10-15-sources.json)保存本文主要来源的地址、抓取日期与代理记录；网页缓存仅留在本地 `.build` 下。
- 本轮没有编译或运行候选框架，没有制作视觉原型，也没有获得新的性能测量。下文的优先级、适配成本与验收数值属于工程判断或建议。

## 3. 项目约束决定了什么

当前 `Sources` 中非符号链接 Swift 文件约 283 个、96,619 行，包含空行与注释。主应用视图约 41,034 行，Utils 约 38,452 行，Models 约 10,628 行；另有 CLI、Widget、C 辅助工具与现有 mihomo 归档。

| 现有能力 | 源码依据 | 架构含义 |
| --- | --- | --- |
| 代理、网关与流式转换 | `CodexProxyServer`、`CodexProxyTransform`、`StreamAssembler` | 核心适合提取，但取消、背压、报文与错误语义必须一致 |
| 会话、用量与索引 | `ProviderStore`、`UsageIndex`、各客户端扫描器 | 先分离业务与展示；保留增量、去重、日期与计费口径 |
| 原生窗口与多表面 | `MenuBarController`、`NotchIslandController`、`MainWindowController` | 普通跨平台主窗口无法直接覆盖非激活面板、多显示器与刘海行为 |
| 硬件与系统权限 | `SMCController`、充电 / 风扇辅助工具、`PermissionCenter` | 仍需平台代码，开发版限制必须在真实调用入口执行 |
| 文档与外部网页 | `FeishuOfficialDocumentView` | 需要完整浏览器能力、鉴权、iframe 和隔离；HTML 绘制器不能自动替代 |
| 可见性与能耗 | `UIWakePolicy`、当前[性能策略](../technical/08-performance.md) | 隐藏、最小化、屏外、无订阅者时应暂停或降频 |
| CLI 与 Widget | `CLIControl`、`CLISnapshot`、`WidgetSnapshotWriter` | 共享状态与版本契约；不让各界面重复扫描同一数据库 |
| 构建与分发 | `Makefile`、`build.sh`、`BuildChannel` | 必须保留 dev / release 隔离、增量缓存、签名与检查入口 |

Swift 已经具备原生绘制、Metal 和优化编译能力。真正要改善的是模块边界、数据流、组件生产力和可衡量的热点；语言迁移只是工具之一。

## 4. 版本核对：不能只看 latest

下表是本轮读取的发布快照，不是自动升级清单。原型应固定完整依赖图；正式采用前还要核对同一版本的工具链、插件和签名流程。

| 项目 | 本轮核对结果 | 采用原则 |
| --- | --- | --- |
| Tauri | crates.io 的稳定版本字段为 **2.12.4**；发布列表另有 **3.0.0-alpha.5**，以及 CEF runtime 的 alpha 标签 | 生产候选用 2.x；3.x 和 CEF 单独研究，不能按 GitHub latest 自动决定稳定版本。[发布][S01] / [注册表][S02] |
| GPUI / GPUI Kit | GPUI README 仍提示 pre-1.0 与破坏性变更；Kit **0.7.3** 固定其匹配的 GPUI 快照 | 原型固定整套匹配版本，不任意混用 GPUI、Kit、Wry 和可选后端。[GPUI][S03] / [Kit 发布][S04] |
| Slint | 发布标签 **1.18.1**，项目说明维持 1.x API 稳定策略 | 必须以选中发布版的 renderer / feature 为准。[发布][S05] / [项目说明][S06] |
| Wails | 发布 **2.14.0**；仓库明确 v2 stable、v3 beta | 不把 v3 多窗口等能力默认算进 v2。[发布][S07] / [版本说明][S08] |
| Electrobun | 发布 **2.0.2**；该标签 README 与官网将 Cottontail 作为默认运行时，本轮 main README 却将 Bun 列为默认、Cottontail 列为实验 | 以固定标签构建并实测，不能混合官网、标签与 main 的行为承诺。[发布版 README][S09] / [架构文档][S10] |
| Dioxus / Blitz | Dioxus 发布 **0.7.10**；Dioxus 的 WGPU 路径仍标实验，Blitz 自述 beta 且仍有缺失 | 桌面 WebView 与 Native renderer 分开评价。[发布][S11] / [Blitz][S12] |
| Iced | 发布 **0.14.0**，main README 仍称实验软件 | 发布可用不等于整个系统集成与控件集合成熟。[发布][S13] / [说明][S14] |
| React | 发布快照为 **19.3.1**；Compiler 另有独立稳定版本与集成说明 | 固定 React / renderer / Compiler 的匹配组合，不盲追刚发布版本。[发布][S15] / [Compiler][S16] |
| Flutter | 当前 Impeller 页面描述了 3.47 的桌面默认路径，关联可用性表仍区分稳定版本与 main，历史信息更新时间也不同 | 本轮未确认用于原型的具体稳定 SDK 与默认 renderer；必须在选定 SDK 中核实，不能直接宣称 macOS 稳定线已统一采用该路径。[引擎说明][S17] / [可用性表入口][S18] |

版本状态尤其影响“高性能”宣传：网页中的 120 FPS、几 MB 包体或极小增量更新，通常是特定示例、组件或发行配置，不能成为 ClaudeBar 的测量结果。

## 5. 横向架构筛选

下面的“适合度”是结合本项目约束的判断，不是框架绝对排名。

| 路线 | 渲染与开发模型 | 价值 | 对本项目的主要代价 | 结论 |
| --- | --- | --- | --- | --- |
| SwiftUI / AppKit / Metal | 原生控件、视图与 GPU 混合 | 原生系统能力和已有资产最完整 | 跨平台 UI 复用少，复杂页面需整理状态边界 | 保留为基线及平台层 |
| Swift 宿主 + React | 原生窗口内局部 WebView | 可渐进迁移，不先替换生命周期 | 增加桥接、WebView 与双端调试成本 | 近期迁移方式 |
| Tauri 2 + Rust + React | 系统 WebView + Rust 核心 | 工作台生态、核心共享和平台能力边界较均衡 | WebKit 差异、IPC、原生桥接与打包 | 综合主线 |
| GPUI + GPUI Kit | Rust 自绘 GPU UI，macOS 使用 Metal | 密集数据、文本与交互值得验证 | API 快照、WebView 叠层、平台细节 | 性能候选 |
| Slint + Rust | 编译式声明 UI，多种 renderer | 稳定 1.x API、轻量 UI 与设计工具 | 文档编辑和浏览器集成需专项验证，新 UI DSL | 第二梯队候选 |
| Flutter | Dart 自绘 UI，Skia / Impeller 依 SDK 与配置 | 一致视觉、动画和移动端拓展 | 新语言 / 引擎、原生视图混合、重新构建业务桥接 | 视觉 / 移动优先时上调 |
| Qt Quick / QML | 保留场景图、RHI、Metal 等后端 | 成熟自绘 UI、图形与桌面能力 | Qt / QML / C++ 边界、分发与授权选项需评估 | 有 Qt 团队时有竞争力 |
| Electron + React | Chromium + Node 多进程 | 固定 Web 引擎、成熟 Web 内容生态 | 运行时分发、升级与总资源预算 | 需要 Chromium 一致性时采用 |
| Go + Wails | Go + 系统 WebView | Go 服务开发效率与 Web UI | v2 / v3 差异，原生集成仍需桥接 | 团队偏 Go 时替代 Rust 路线 |
| Electrobun | TS 或原生主进程、系统 WebView / CEF、可选 GPU surface | 组合方式前沿，分发与 GPU 嵌入值得关注 | 新工具链、运行时版本差异、平台与更新行为审查 | 观察 / 小原型 |
| Dioxus Desktop | Rust 声明 UI + WebView | Rust 统一业务与界面语言 | HTML/CSS 仍需学习，不能据“全 Rust”推断更轻 | Rust 团队可考虑 |
| Dioxus Native / Blitz | HTML/CSS 子集的本地 renderer | Web 布局与原生 GPU 的交叉探索 | beta / 实验，完整浏览器功能不能假定 | 研究项 |
| Iced / egui | Rust 消息驱动 / 即时模式，GPU 或软件绘制 | 工具、监控和自定义 UI 值得使用 | 品牌控件、文档、IME 和原生行为需大量验证 | 本项目不优先 |
| Xilem / Floem / Freya | Rust 响应式 UI，Vello / wgpu / Skia 等 | 新数据流与自绘架构有价值 | API、控件、工具链与平台桥接成熟度各异 | 按独立组件研究 |
| React Native macOS | React 驱动平台 UI 的独立平台实现 | React 开发体验与原生控件结合 | 与 React DOM 生态不同，仍需维护 macOS 分支和模块 | 不作为 Web 工作台平替 |
| Compose Multiplatform / Avalonia | Kotlin / .NET 的跨平台 UI | 已有团队技能匹配时成熟可行 | 引入另一套运行时、语言和平台适配成本 | 当前无明显优于主线的迁移收益 |
| Lynx / Servo | 新 UI / 浏览器引擎方向 | 多线程渲染与自定义引擎值得跟踪 | 桌面发行、系统集成、浏览器兼容需独立证明 | 暂不作为全量迁移底座 |

依据：[Tauri][S19]、[GPUI Kit][S20]、[Qt 场景图][S21]、[Electron][S22]、[Wails][S08]、[Dioxus][S23]、[Iced][S14]、[egui][S24]、[Xilem][S25]、[Floem][S26]、[Freya][S27]、[React Native macOS][S28]、[Compose][S29]、[Avalonia][S30]、[Lynx][S31]、[Servo][S32]。具体成熟度按上表来源的版本范围解释。

## 6. 三条主候选深入判断

### A. Tauri + React + Rust：综合主线

适合本项目的理由是模块丰富且持续扩展：模型配置、请求详情、长会话、图表、文档和快捷搜索都能利用 Web 生态；核心仍可在 Rust 中独立运行。Tauri 的窗口和系统集成抽象不意味着所有 macOS 特色都已经具备。[S19]

需要明确接受：

1. macOS 使用 WKWebView，Windows 与 Linux 使用不同系统 WebView，渲染与 API 支持需要分平台验证。Chrome 中流畅并不证明 WKWebView 中流畅。
2. UI 不直接访问任意文件、shell 和凭据。命令接口按业务设计，远程网页与本地控制界面隔离。
3. 普通 Event 不用于报文大流量。官方明确区分其吞吐用途；大流、连续结果使用 Channel 与应用层有界队列，页面只接收需要的预览与统计。[S33]
4. 三种原生表面不必同时迁移：主工作台先迁，菜单栏和灵动岛保持轻量原生，Widget 继续使用 WidgetKit。
5. 不额外运行 Next.js SSR 或 Node HTTP 服务。生产 UI 是随包静态资源，Node 仅参与构建。

默认不选 Tauri 3 alpha：本项目的复杂度已经在业务和系统能力上，新宿主应减少不确定性。CEF 若未来成熟，可因明确的引擎一致性需求重新评估；它也会改变运行时分发与资源成本。[S01]

### B. GPUI + GPUI Kit：性能候选

GPUI 是 GPU 加速的混合 UI 模型，macOS 路径使用 Metal；Kit 在其上提供表格、虚拟列表、编辑器、布局、图表和可访问性设施。Kit 已不应仅按一个空窗口库评价，但其公开示例和商业使用说明也不能证明本项目已经能达到某一帧率。[S03][S20]

真正吸引本项目的部分：可将密集会话列表、实时队列、原生文本和业务核心放在 Rust 体系中；避免让这些页面必然经过 Web JS / DOM。实际收益仍取决于视图失效、文本布局、数据发布和 GPU 工作。

本轮确认的阻碍：

- GPUI 自身仍提示 pre-1.0 破坏性变更；Kit 发布与其 GPUI 快照紧密匹配。[S03][S04]
- Kit 的 WebView 文档将 macOS / Windows 嵌入标为实验，Linux 路径未完成。原生子 WebView 覆盖其矩形内的 GPUI 内容，GPUI 弹窗、菜单与提示不能可靠盖在其上。[S34]
- 这会直接影响飞书文档与主窗口弹层。仅把网页“打开成功”不构成功能通过。
- AccessKit 与无头测试是基础设施；还要真机验证 VoiceOver、中文输入、焦点和选区。Kit 文档也区分无头断言与平台读屏结果。[S35]

**采用条件：** 在等价会话 / 流量页面上取得足够大的实测收益，并通过文档、弹层、IME、可访问性与原生窗口验收。否则保持为单独实验，不同时长期维护两个正式工作台。

### C. Flutter：视觉一致与移动拓展候选

Flutter 的价值在于统一自绘布局与动效、跨平台视觉和移动端代码共享。Impeller 的设计包含预先编译管线等措施，但具体支持与默认行为必须以选中的 SDK 为准。[S17][S18]

本项目的主要代价：引入 Dart 与 Flutter 工具链，现有 Swift UI 大量重写；如果再把全部核心迁入 Rust，会同时增加 Dart / Rust / Swift 三套边界。没有必要为采用 Flutter 而强制 Rust 化所有逻辑。

此外，官方 macOS platform view 页面仍列出原生视图嵌入的功能限制，包括手势；飞书 WebView、文本输入、裁剪与层级必须原型验证。[S36]

产品转向移动端、统一动画工作台时提升 Flutter 优先级；当前仍深度依赖 Mac 桌面表面，综合优先级低于 A，值得作为视觉方案对照。

## 7. 前端选型：React 优先，Solid / Svelte 保留替换空间

| 方案 | 明确优势 | 对本项目的判断 |
| --- | --- | --- |
| React + TypeScript | 复杂组件、可访问性、列表、编辑器与可视化生态；支持增量接入 | 主线，优先降低复杂功能的开发和维护成本 |
| Solid | 基于细粒度响应式的数据更新模型 | 高频局部读数可以比较；不能仅由更新模型推断全应用更快。[S37] |
| Svelte | 编译式组件与 runes 响应式机制 | 适合愿意采用该生态的团队；对本项目需重新核对编辑器与组件依赖。[S38] |
| Dioxus | UI 与核心都可写 Rust | 减少语言种类不必然减少 UI 复杂度；WebView 与 Native renderer 的取舍仍存在 |

建议的最小工作台栈：

| 层 | 选择 | 使用边界 |
| --- | --- | --- |
| 语言与构建 | TypeScript strict + Vite，固定 Node 与包管理器版本 | 不加 SSR，不新增生产 Node 常驻进程 |
| 基础控件 | React Aria 无样式能力 + 自有样式与 tokens | 复用键盘、焦点、交互语义，不直接套一整套通用后台视觉。[S39] |
| 大列表 | TanStack Virtual；确需排序 / 列管理再加 Table | 数据仍在核心分页，不把百万行一次塞进浏览器。[S40] |
| 页面数据 | 初期使用薄查询适配器与局部状态 | 核心拥有业务真相，不同时引入全局状态、查询缓存和多个事件总线 |
| 实时数据 | 按模块的外部 store / selector 订阅 | 快照保持稳定引用，避免每次刷新重建所有对象。[S41] |
| 编译优化 | 评估 React Compiler | 辅助消除无效重算，不能替代字段订阅、虚拟列表或算法优化。[S16] |
| 动效 | CSS / Web Animations；需要编排时选 Motion | 避免多套动效系统同时驱动同一节点。[S42] |
| 读数与时序图 | 首先 SVG / Canvas，密集时序图可评估 uPlot | uPlot 的作者基准仅用于发现候选，仍测本项目数据。[S43] |
| 文档与代码 | 按实际编辑需求选择单一编辑器；纯展示按需加载 | 不默认把完整 IDE 编辑器装进每个详情面板 |

框架主线只选一套；Solid / Svelte 不作为“某张卡片更快”的局部混入方案，以免形成多个 UI 运行模型。

## 8. 高视觉架构：按内容选择渲染层

“高端”首先来自信息层级、字体、材质一致性与交互反馈；持续渲染的 3D 背景可能增加能耗，却不能改善表格和文档的使用体验。

| 场景 | 默认路径 | 升级条件 |
| --- | --- | --- |
| 表单、表格、文档、快捷面板 | DOM / CSS / SVG 或原生控件 | 保持选择、复制、IME、读屏和键盘路径 |
| 趋势、用量与网络读数 | 有界数据的 SVG / Canvas | 数据规模和交互实测要求更高吞吐时才加专门图表库 |
| 2D 粒子、复杂精灵与图形 | 可选 PixiJS | 明确需要大量 2D 图元时采用；不与 Three.js 重复承担同一场景。[S44] |
| 品牌角色、状态机动效 | 可选 Rive | 设计资产与运行时确有复用价值；计入 wasm、纹理与加载成本。[S45] |
| Agent / 网络空间拓扑 | 可选 Three.js + React Three Fiber | 3D 关系比二维图更易理解时采用；保留二维 / 文本替代 |
| 当前天气与氛围 | 先保留现有 Metal 实现 | 只有跨平台需求和对照结果成立时迁移 shader |

Three.js 的 WebGPURenderer 可按能力选择 WebGPU / WebGL2 后端。回退不代表所有自定义 compute / shader 效果语义等价；目标场景仍需降级设计。[S46]

WebKit 已宣布 Safari 26 的 WebGPU 支持，但最低系统仍是 macOS 15；必须在实际 WKWebView 环境中检查适配器、上下文、驱动和功能，不能直接按 Safari 或 Chrome 的版本名推断。[S47]

视觉实现约束：

- 动画优先更新 transform / opacity；布局、模糊、阴影和大面积透明层要单独测，不能因使用 GPU 就视为免费。[S42]
- 3D / 粒子采用按需渲染、交互期间提升帧率、屏外暂停；资源在离开页面时可释放。R3F 官方也提供按需渲染和自适应性能策略。[S48]
- 业务采样与动画时钟分开；网络读数不需要以 120 Hz 发送，显示插值也不应触发全局 React 状态更新。
- 主题 tokens 同时生成 CSS 与原生常量，统一颜色语义、字体尺度、间距和动效时长。先统一契约，不维护三套独立品牌主题。
- 主窗口、菜单栏与灵动岛共享视觉语义，但按各自空间和交互目的设计，不把桌面页面缩小塞入 popup。

不建议全应用 Canvas / WebGPU 化。文本选择、表单、读屏、链接和复杂输入需要的语义不会因改用 GPU 而消失。

## 9. Rust 核心与模块边界

### 为什么核心优先 Rust，而不是同时加入 Go / Node

| 核心选择 | 优势 | 代价与适用判断 |
| --- | --- | --- |
| Rust | 所有权管理内存，可构建可共享原生库；与 Tauri / GPUI 主线衔接 | 所有权、异步与 FFI 学习成本高；错误的克隆、锁与队列仍会慢。适合本项目长期共享核心。[S60] |
| Go | 网络、并发与服务开发直接，适合 Wails 路线 | GC 存在 CPU 与内存预算权衡，但不能据此称其不适合高性能。Go 1.26 已默认采用 Green Tea GC；需测本项目分配模式，不套用旧横评。[S56][S57] |
| Node / TypeScript | 协议生态和开发速度，适合连接器编排 | 大 JSON 解析与同步工作可能阻塞事件循环；CPU 工作可用 worker，但需管理任务池和传输。网络 I/O 并不因搬到 worker 就更快。[S58][S59] |
| 继续 Swift | 已有实现、ARC、系统能力与优化编译 | 最小迁移成本，仍是有效基线；Rust 不会仅因“没有 GC”就自然胜出，因为当前 Swift 本身也不是追踪式 GC 运行时。[S61] |

因此优先 Rust 的理由是**可复用的原生业务边界及与候选宿主的匹配**，而非宣称 Go / Node / Swift 不够快。若团队熟练 Go 且缺乏 Rust 经验，Go + Wails 的综合成本可能更优；不要为技术名称强行逆转团队能力。

### 代码组织与职责

业务先拆成模块化单体，初期仍在应用进程内。先保持宿主与退出所有权清楚；没有独立生命周期需求，不拆成本机微服务或常驻 daemon。

```text
工作台 UI（React；GPUI 原型读取相同业务契约）
    │ 查询、命令、按模块订阅
宿主适配器（当前 Swift；未来可选 Tauri）
    │
Rust 核心：domain / sessions / usage / gateway / connectors
    ├── 自有 SQLite / 私有文件 / 客户端格式适配
    └── 平台接口 → Swift / AppKit / IOKit / 现有 C helpers

原生菜单栏、灵动岛、Widget、CLI
    └── 读取同一核心的快照与命令；不重复扫描和独立写库
```

建议先增加一个 Rust library crate，用模块划分业务；没有独立发布或复用需要，不一开始拆成大量 crates。核心不依赖 Tauri、React 或 SwiftUI，宿主适配器依赖核心。目录可以延续现有 `Sources` 体系：

```text
Sources/
  ClaudeBar/        现有宿主、原生表面和平台集成，渐进调整
  CoreRust/        一个 Cargo library；内部按 domain / gateway / usage 等模块划分
  WorkbenchWeb/    工作台源码；features / platform / theme
  Shared/          现有身份与跨目标契约，逐步明确生成来源
  Widget/          原生 Widget
```

这是未来目录建议，本轮没有创建这些模块。Tauri 宿主仅在宿主决策通过后接入；不先生成一套与现有应用职责重复的脚手架。

| 模块 | 首先适合迁入的部分 | 暂时保留的部分 |
| --- | --- | --- |
| domain | 标识、路由、用量与错误契约 | Swift UI 状态与外观 |
| gateway | 纯协议转换、SSE 分块解析、路由策略 | 初期监听器、既有代理生命周期与 VPN 所有权 |
| sessions | 脱敏输入的解析、家族归属与状态机 | 客户端唤起、窗口定位与真实 app-server 接口 |
| usage | 聚合、去重、增量游标 | 首期沿用现有数据库结构与单写入者 |
| connectors | 清单解析、扫描与差异计算 | 外部客户端配置写入和授权边界 |
| platform | 只定义窄接口与错误类型 | 权限、硬件、系统网络与辅助工具实现 |

候选基础设施：Rust stable、Tokio、Serde、按需求选用 HTTP 客户端 / 服务库和 SQLite 绑定。选择最少的依赖，并固定版本；没有热点证据，不为 SIMD、零拷贝或换数据库引入新的复杂度。[S49]

初次 Rust / Swift 试迁建议用小范围 C ABI，明确缓冲区所有权、长度、错误与释放。API 扩大后再评价 UniFFI 的 Swift 绑定生成与异步支持，不能同时维护两条覆盖同一业务的桥接。[S50]

### 数据与并发契约

- 核心持有业务状态与凭据，前端拿展示模型。密钥编辑走专用写入接口，既有密钥不进入通用快照、事件或浏览器持久存储。
- 命令包括请求 ID、版本、channel 与取消标识；订阅包括序号和快照版本，溢出时可重取快照。调用完成与实际操作完成要区分。
- 最新值遥测可合并，审计记录和终态不能随意丢弃。为不同数据定义独立的有界队列；不能用无限缓存掩盖慢消费者。Tokio 的有界 channel 可作为实现工具。[S51]
- 流式报文的接收、持久化和 UI 预览各有上限；前端只读取有界尾部和选中详情，避免将整份大报文反复 JSON 序列化。
- 新订阅先快照后增量，切页取消订阅和后台查询，关闭窗口释放图形资源。后台提醒和代理职责按原业务契约保留。
- 整数、金额、时间和 ID 的跨语言表示明确：超出 JS 安全整数范围的值使用字符串等明确协议；费用估算与真实账单、币种和时间窗口继续分开。
- 自有 SQLite 先保留 schema、索引与 WAL；并发迁移仍只有一个写入所有者。WAL 允许读写并行不代表允许多个业务所有者竞态写入。[S52]

## 10. 原生能力与跨平台范围

| 功能 | macOS 目标 | Windows / Linux 规划 |
| --- | --- | --- |
| 工作台、模型目录、图表、请求详情 | 第一批共享界面 | 优先共享，但验证字体、输入与 WebView |
| 协议转换、路由、聚合 | 可共享核心 | 优先共享 |
| 客户端会话和连接器 | 保留现有格式适配 | 客户端路径、版本与权限独立适配，不承诺即刻等价 |
| 托盘与窗口 | 原生菜单栏与面板保持行为 | 各平台托盘能力另定义 |
| 灵动岛、Widget | 保留原生实现 | 标记为平台专属或另设计，不能自动算已支持 |
| 截图、快捷键、通知 | 保留平台权限与生命周期 | 依各系统权限与合成器能力实现 |
| VPN / 系统代理 / TUN | 沿用当前所有权与清理策略 | 单独集成、单独验证；桌面框架不替代网络权限 |
| SMC、风扇与充电控制 | 保留既有 Mac 适配 | 默认不可用，不把 Mac 硬件 API 当通用接口 |

“共享核心 + 平台能力矩阵”应成为产品承诺；不以“跨平台框架支持 Windows”推导全功能跨平台。

## 11. 构建、身份与分发

1. `make build / release / test / package` 继续作为统一入口；可以在内部编译 Cargo 与前端资源，不另外复制 CI 回归清单。
2. 只有 dev / release 两个身份。原型复用 dev 的构建选择与合成数据，不创建第三个测试应用身份，不读取真实凭据来填充演示。
3. **Cargo 的 `--release` 只表示优化构建，不表示本产品的正式版身份。** dev 的 Rust 也可以优化；业务 channel 必须独立、编译期确定，冲突时拒绝构建，缺失时安全降为 dev。
4. Rust、Swift、宿主配置、Widget 与辅助工具从明确的统一身份配置产生，检查最终包中的值。不要让几套配置各自猜测 channel。
5. 真正的系统调用入口仍各自校验编译期策略；不以 Tauri capability、网页按钮或环境变量替代。权限提示入口也遵守同样规则。[S53]
6. 保留 Swift 增量对象、Cargo target 与前端依赖缓存，按源码、工具链、编译参数与身份失效；包重建不能清空所有缓存。
7. 不直接采用候选框架的默认自动替换 / 自动重启逻辑覆盖现有安装规则。运行中的对应版本应拒绝替换；退出走应用已有清理流程。
8. 原生 helpers、Rust 产物、Widget 与主包按正确顺序签名和验证；Tauri 能打包主应用不代表已有 Widget、entitlements 与辅助工具已自动正确集成。[S54]
9. 迁移阶段每次只有一个宿主拥有生命周期。若最终采用 Tauri，Swift 退到平台能力与原生表面，避免两个完整宿主互相启动、退出或争抢后台任务。

## 12. 原型与性能验收

### 必须比较的三组

- **R0：** 当前优化原生实现，使用离线合成输入。
- **R1：** React / WKWebView 工作台，先接现有服务，再逐步接同一 Rust 试迁模块。
- **R2：** GPUI Kit 等价页面，读取相同数据和业务契约。

R1 初期只检验 Web 界面；宿主替换要另测启动、系统集成和完整进程成本。R1 / R2 不应一边实现所有业务一边同时重建整个设计系统。

### 三个等价原型

| 原型 | 内容 | 能回答的问题 |
| --- | --- | --- |
| 工作台页面 | 用量图表、日期筛选、1000 条合成会话与 1 万条分页请求记录 | 真实信息密度、长列表、筛选、中文与键盘体验 |
| 数据核心 | 固定 JSONL / SSE 语料、断块 UTF-8、错误输入、取消及 20 路模拟流 | 吞吐、尾延迟、分配、背压和行为一致性 |
| 平台与图形 | dev 内无真实权限的面板几何、明暗主题、1 个可停止的图形场景；文档层使用本地模拟页 | 多显示器 / 缩放、层级、焦点、资源暂停；不冒充真实权限验证 |

常规集再配 10 倍压力集。数据库、报文与进程都用临时目录和模拟传输。真实 VPN、硬件、TCC 和客户端写入仍只走被明确授权的正式版流程或独立测试机器。

### 测量协议

- 固定机器、系统、屏幕刷新率、窗口大小、数据、优化参数和签名方式；记录工具链与源码指纹。
- 先预热，交替执行各候选，至少 5 轮，报告中位数、p95、异常与测量噪声；不以最好一次作为结果。
- 测冷启动、热启动、可见静止、完全隐藏、长列表滚动、持续流更新、页面切换和资源释放。
- 统计宿主、WebContent、GPU 与子进程的总成本；选择清楚的物理内存口径，避免只看宿主 RSS 或重复计算共享页。
- 帧表现只在持续交互 / 动画窗口内比较。静止画面没有新帧是预期行为，不能误记为低帧率。
- 测 CPU / GPU、内存、唤醒、能耗、端到端交互延迟、长帧、吞吐和取消响应；不要只测空窗口或 HTTP hello world。

### 建议的晋级门槛

以下是原型前用于讨论的门槛，尚无本机基线，不属于已验证性能承诺。

| 项目 | 候选门槛 |
| --- | --- |
| 功能正确性 | 所有相关契约和隔离回归通过；任何错误写入或清理所有权回退均阻断迁移 |
| 常见交互 | 固定场景下 p95 输入到反馈不超过 100 ms，并不劣于 R0 |
| 滚动与动效 | 60 Hz 下以 16.7 ms / 帧为预算；120 Hz 使用 8.3 ms 的目标，分别报告，包含实际丢帧与长帧 |
| 隐藏态 | 无装饰渲染循环；空闲 CPU / 唤醒不出现超出测量噪声的持续回退 |
| Rust 热点替换 | 相同语料下，吞吐或 p95 延迟改善约 30%，或峰值内存改善约 20%，并保持语义；否则不以性能理由替换 |
| GPUI 主线挑战 | 完成功能门槛后，在至少两项关键资源 / 交互指标有约 20% 改善，且维护投入可接受，才上调为正式主线候选 |
| Web 工作台成本 | 先测整机增量，再设置可接受内存 / 启动预算；视觉收益不能掩盖未报告的后台能耗回退 |

20% / 30% 是建议的工程投入门槛，不是统计显著性的替代；若噪声大，应先修正实验。性能收益不足但有跨平台或维护价值的模块，可按该价值决策，并明确增加的资源成本。

### 自动化边界

保留 `make test` 与当前生产函数 / 状态机回归；对迁入 Rust 的实际生产模块新增对应测试，继续由 Makefile 调度，不保留一份只测旧 Swift 的“假覆盖”。

Web 组件可在浏览器中验证交互，但不能用 Chromium 的组件测试证明 WKWebView 或 macOS 窗口行为。Tauri 当前文档给出 embedded WebDriver 的 macOS 路径，同时说明直接使用 tauri-driver 的平台限制；应以固定版本和所需测试能力决定是否采用，不新增常驻测试服务。[S55]

## 13. 迁移里程碑、回退与工作量

| 阶段 | 交付内容 | 退出条件 / 回退点 |
| --- | --- | --- |
| M0 | 性能基线、模块依赖、功能平台矩阵、视觉目标 | 能重现 R0；没有证据先不迁 |
| M1 | 展示品牌与稳定技术身份解耦 | 正式数据位置不变，身份与隔离测试通过 |
| M2 | R1 / R2 等价原型与测量报告 | 选定 UI 路线；不保留两套正式工作台 |
| M3 | 一个 Rust 生产模块接入现有宿主 | 输出对照、取消、资源限制与错误路径通过；旧实现可恢复 |
| M4 | 逐页迁主工作台并建立共享设计 tokens | 一页一验收，旧页面在该页通过后移除 |
| M5 | 视跨平台目标验证宿主替换与第二平台 | 包身份、Widget、helper、窗口与生命周期验证完成 |
| M6 | 发布门禁、兼容入口、文档与品牌分发更新 | 全回归、dev / release 编译及包签名检查完成，授权后发布 |

重写规模不能按“9.7 万行 / 每天生成行数”估算。初期可给**基线与范围确认 1–2 人日、等价双原型与初测 5–10 人日、原生桥接与打包验证 3–5 人日**的粗预算；假设开发者熟悉所选栈、只覆盖上文原型且不包含正式系统集成。未知控件、签名或输入问题可能显著增加投入。

全量迁移在 M2 / M3 后按真实模块重新估算，不承诺固定总工期。用户可见功能、平台范围和视觉重设计都会改变工作量。

回退规则：配置和数据库先保持兼容，切换模块不触发不可逆 schema 升级；每份数据始终只有一个写入者。不可逆变更另行设计备份、升级与降级策略。生产身份和凭据不因原型切换而迁到 dev。

## 14. 品牌与信息架构

品牌升级可先于宿主替换，但不宜与技术身份迁移绑定。首轮候选 **Lattio · 枢台** 继续作为讨论稿，本轮重点是技术，尚未完成品牌可用性核对。

建议定位保持“面向 AI 开发的本地工作台”，信息架构分为：

- **工作流：** 会话、等待 / 完成、模型与用量。
- **网关与连接：** 供应商、请求、路由、Skills / MCP / 文档。
- **工作环境：** 网络、设备与个性化。

这些是导航分组，不应变成三套重复的后端或独立应用。用户应能用全局搜索 / 命令快速进入具体对象，保持菜单栏和灵动岛的轻入口。

改名先分离 display name 与稳定存储字段：`FilePaths.appSupportDir` 当前取 `BuildChannel.appName`，全局替换会改变读取位置。正式版保持 `com.claudebar.app` 与既有数据路径，保留旧 URL / CLI 兼容入口；同步检查安装识别、产物、Widget、签名、helper 标识与文档。

名称的最终筛选与视觉方向可作为一个独立决策完成，不据当前候选直接改生产身份。

## 15. 最终选择与待证明事项

现在可以决定：采用模块化单体、共享业务契约、原生平台层、按需渲染、分阶段迁移；Rust 与 Go 选其一，React 与其他前端框架选其一，避免为了“前沿”增加多个平行栈。

建议主线为 **React / TypeScript + Rust + 必要 Swift；Tauri 2 是未来跨平台宿主首选**。GPUI Kit 做等价性能候选，Flutter 作为产品方向改变时的视觉 / 移动候选。

仍待证明：三个候选的真实资源与交互差异、GPUI WebView 与原生表面的可用性、固定 Flutter SDK 的引擎和嵌入行为、完整签名打包链、实际 Windows / Linux 功能范围。它们不能由本轮文档检索替代。

## 主要来源

以下均为第一方资料，访问于 2026-10-15；除发布标签外，在线文档和主分支可能继续变化。

- [S01：Tauri 2.12.4 发布][S01]；[Tauri 3 alpha 发布](https://github.com/tauri-apps/tauri/releases/tag/tauri-v3.0.0-alpha.5)
- [S02：Tauri crates.io 元数据][S02]
- [S03：GPUI README][S03]；[GPUI 官网](https://gpui.rs/)
- [S04：GPUI Kit 0.7.3 发布][S04]
- [S05：Slint 1.18.1 发布][S05]
- [S06：Slint 项目说明][S06]
- [S07：Wails 2.14.0 发布][S07]
- [S08：Wails 稳定版与 beta 说明][S08]
- [S09：Electrobun 2.0.2 README][S09]；[本轮 main README](https://github.com/blackboardsh/electrobun/blob/main/README.md)
- [S10：Electrobun 架构][S10]；[主进程选项](https://framework.blackboard.sh/electrobun/guides/native-main-process/)；[原生 GPU 接口](https://framework.blackboard.sh/electrobun/apis/webgpu/)
- [S11：Dioxus 0.7.10 发布][S11]
- [S12：Blitz 状态与边界][S12]
- [S13：Iced 0.14.0 发布][S13]
- [S14：Iced 架构与状态][S14]
- [S15：React 19.3.1 发布][S15]
- [S16：React Compiler][S16]
- [S17：Flutter Impeller][S17]
- [S18：Flutter 官方引擎可用性表入口][S18]
- [S19：Tauri 进程模型][S19]
- [S20：GPUI Kit 0.7.3 功能说明][S20]
- [S21：Qt Quick 场景图与渲染线程][S21]
- [S22：Electron 性能指南][S22]
- [S23：Dioxus renderer 说明][S23]
- [S24：egui][S24]
- [S25：Xilem / Masonry][S25]
- [S26：Floem][S26]
- [S27：Freya][S27]
- [S28：React Native macOS][S28]
- [S29：Compose Multiplatform][S29]
- [S30：Avalonia][S30]
- [S31：Lynx][S31]；[桌面 Explorer](https://github.com/lynx-family/lynx/blob/develop/explorer/README.md)
- [S32：Servo][S32]
- [S33：Tauri Channel 与 Event][S33]
- [S34：GPUI Kit WebView 限制][S34]
- [S35：GPUI Kit 可访问性验证][S35]
- [S36：Flutter macOS 原生视图限制][S36]
- [S37：Solid 官方说明][S37]
- [S38：Svelte runes][S38]
- [S39：React Aria][S39]
- [S40：TanStack Virtual][S40]
- [S41：React 外部 store 契约][S41]
- [S42：Motion 性能指南][S42]
- [S43：uPlot][S43]
- [S44：PixiJS renderer][S44]
- [S45：Rive renderer 选择][S45]
- [S46：Three.js WebGPURenderer][S46]
- [S47：WebKit / Safari 26 WebGPU][S47]
- [S48：React Three Fiber 性能策略][S48]
- [S49：Tokio][S49]
- [S50：UniFFI Swift][S50]
- [S51：Tokio channel][S51]
- [S52：SQLite WAL][S52]
- [S53：Tauri capabilities][S53]
- [S54：Tauri macOS 分发与签名][S54]
- [S55：Tauri WebDriver 支持边界][S55]
- [S56：Go GC 的资源权衡][S56]
- [S57：Go 1.26 与 Green Tea GC][S57]
- [S58：Node 事件循环与大 JSON][S58]
- [S59：Node worker 的适用范围][S59]
- [S60：Rust 所有权与内存][S60]
- [S61：Swift ARC][S61]

[S01]: https://github.com/tauri-apps/tauri/releases/tag/tauri-v2.12.4
[S02]: https://crates.io/api/v1/crates/tauri
[S03]: https://github.com/zed-industries/zed/blob/170b2dbc96213d2fd910f0cdddf774bbb29322d1/crates/gpui/README.md
[S04]: https://github.com/longbridge/gpui-kit/releases/tag/v0.7.3
[S05]: https://github.com/slint-ui/slint/releases/tag/v1.18.1
[S06]: https://github.com/slint-ui/slint
[S07]: https://github.com/wailsapp/wails/releases/tag/v2.14.0
[S08]: https://github.com/wailsapp/wails/blob/master/README.md
[S09]: https://github.com/blackboardsh/electrobun/blob/v2.0.2/README.md
[S10]: https://framework.blackboard.sh/electrobun/guides/architecture/overview/
[S11]: https://github.com/DioxusLabs/dioxus/releases/tag/v0.7.10
[S12]: https://github.com/DioxusLabs/blitz
[S13]: https://github.com/iced-rs/iced/releases/tag/0.14.0
[S14]: https://github.com/iced-rs/iced/blob/master/README.md
[S15]: https://github.com/react/react/releases/tag/v19.3.1
[S16]: https://react.dev/learn/react-compiler
[S17]: https://docs.flutter.dev/perf/impeller
[S18]: https://flutter.dev/go/can-i-use-impeller
[S19]: https://v2.tauri.app/concept/process-model/
[S20]: https://github.com/longbridge/gpui-kit/blob/v0.7.3/README.md
[S21]: https://doc.qt.io/qt-6/qtquick-visualcanvas-scenegraph.html
[S22]: https://www.electronjs.org/docs/latest/tutorial/performance
[S23]: https://github.com/DioxusLabs/dioxus
[S24]: https://github.com/emilk/egui
[S25]: https://github.com/linebender/xilem
[S26]: https://github.com/lapce/floem
[S27]: https://github.com/marc2332/freya
[S28]: https://github.com/microsoft/react-native-macos
[S29]: https://kotlinlang.org/docs/multiplatform/compose-multiplatform-and-jetpack-compose.html
[S30]: https://docs.avaloniaui.net/docs/welcome
[S31]: https://github.com/lynx-family/lynx
[S32]: https://github.com/servo/servo
[S33]: https://v2.tauri.app/develop/calling-frontend/
[S34]: https://gpui-kit.com/docs/webview/
[S35]: https://gpui-kit.com/docs/accessibility/
[S36]: https://docs.flutter.dev/platform-integration/macos/platform-views
[S37]: https://github.com/solidjs/solid
[S38]: https://svelte.dev/docs/svelte/what-are-runes
[S39]: https://react-aria.adobe.com/
[S40]: https://tanstack.com/virtual/latest/docs/introduction
[S41]: https://react.dev/reference/react/useSyncExternalStore
[S42]: https://motion.dev/docs/performance
[S43]: https://github.com/leeoniya/uPlot
[S44]: https://pixijs.com/8.x/guides/components/renderers
[S45]: https://rive.app/docs/runtimes/choose-a-renderer/overview
[S46]: https://threejs.org/docs/pages/WebGPURenderer.html
[S47]: https://webkit.org/blog/16993/news-from-wwdc25-web-technology-coming-this-fall-in-safari-26-beta/
[S48]: https://r3f.docs.pmnd.rs/advanced/scaling-performance
[S49]: https://tokio.rs/tokio/tutorial
[S50]: https://mozilla.github.io/uniffi-rs/latest/swift/overview.html
[S51]: https://tokio.rs/tokio/tutorial/channels
[S52]: https://sqlite.org/wal.html
[S53]: https://v2.tauri.app/security/capabilities/
[S54]: https://v2.tauri.app/distribute/sign/macos/
[S55]: https://v2.tauri.app/develop/tests/webdriver/
[S56]: https://go.dev/doc/gc-guide
[S57]: https://go.dev/doc/go1.26
[S58]: https://nodejs.org/en/learn/asynchronous-work/dont-block-the-event-loop
[S59]: https://nodejs.org/api/worker_threads.html
[S60]: https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html
[S61]: https://github.com/swiftlang/swift-book/blob/main/TSPL.docc/LanguageGuide/AutomaticReferenceCounting.md
