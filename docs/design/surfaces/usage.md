# 用量分析

Mode: Operate。原生 macOS SwiftUI，分析已有本地记录；以明确的读数层级、整齐的共同比例尺度和可检查的真实数据为目标。

## 信息与空间

周期工具栏将前后切换、日期、周期选择和刷新放在同一行；自定义日期选择器按需出现。其后五项读数为本地 Token、有记录的天数、日用量中位数、日用量 P95、缓存命中率。每项采用标签在上、25pt 半粗体圆角等宽数字在下的排版，宽窗口横向均分，放不下时以两列排列；口径解释通过原生帮助文字提供。

分析区域保留横向两张固定 200pt 高的卡片（1×2），采用页面现有白色表面、圆角、SF Rounded 标题和 Theme 分类颜色；内边距 16pt、标题 13pt。每列最小 380pt，窄窗口改为单列。左卡多周期展示真实用量趋势；单周期没有趋势时直接展示三类来源的数量、占比和横条，移除重复总量及空白占位。右卡展示四类 Token 的数量、占比和细横条，缓存命中率放在标题行。所有横条以对应总量为共同分母，不放大小份额，零值不绘制彩色长度。移除双层环、模型排行、内部分隔线和第二层标题；模型明细由下方平台、供应商、模型卡片承担。

多周期趋势保留 108pt 画布、悬停、日期下钻和坐标尺度切换，分析卡片不加装饰动画。

## 数据口径

| 项目 | 当前实现 |
| --- | --- |
| 本地总量 | 模型记录中输入、缓存读取、缓存写入、输出之和，不包含 Cursor 官方账单 |
| 时间记录 | `DayUsage` 按日期合并；已到达且无记录的日期记零，未来日期排除 |
| 日／月／自定义 | 按日观测；单日没有小时采样 |
| 年／全部 | 按月汇总；全部周期超过 730 个已到达日期时按年汇总 |
| 全部起点 | 第一条本地日期记录；没有日期记录时从今天开始 |
| 日 P50／P95 | 包含零记录日，排序位置 `p × (n − 1)`，相邻值线性插值；显示转为整数 Token |
| 桶中位数 | 当前显示粒度的桶中位数，不等同于始终按日计算的指标 P50；分析模型保留该值，主图不绘制中位线 |
| 缓存命中率 | 缓存读取 ÷（输入 + 缓存读取 + 缓存写入）；分母为零显示破折号，输出不入分母 |
| 桶 P25／P75 | 当前显示粒度的桶分位数，包含零桶，与日 P50／P95 使用同一线性插值算法 |
| 周期分布 | 真实观测保留重复值及零桶；样本不足时按每个实际数值汇总精确频数，不划分直方图区间 |
| 核密度估计 | 至少 5 个桶且至少 3 个不同数值时计算高斯 KDE，采用 Silverman 带宽与零边界反射；密度形状明确标为样本估计 |
| ECDF（保留数据） | 当前粒度每个桶作为一次观测；`F(t) = count(Token ≤ t) / 桶数`，合并相同值的阶跃，保留零桶；界面不再显示 |
| 模型份额 | 模型总量 ÷ 所有正值模型总量；显示 Top 8 不重新归一化 |
| 模型来源关系 | 连接量为对应模型与来源的实际 Token；图形连接量与模型汇总总量保持各自数据范围 |
| Lorenz | 全部正值模型按 Token 升序，横轴累计模型比例，纵轴累计 Token 比例，从原点到 100% |
| 有效模型数 | `1 / Σp²`，p 为全部正值模型的 Token 份额；无模型为 0，等权时等于模型数 |

时间记录、模型汇总和来源汇总保持各自实际数据范围。成本估算和 `Cursor 实扣` 分别标注，不相加，不从本地 Token 推测缺失账单或节省金额。

## 两张分析卡片

多周期趋势以真实观测点与从零开始的原值坐标展示，可切换 asinh 长尾尺度，悬停查看周期读数并点击日期下钻。单周期只展示来源比例，不构造小时趋势。来源总量保持自身记录口径，不包含 Cursor 官方账单。

Token 构成的分母是全部本地模型记录，提示侧为输入、缓存读取与缓存写入之和，缓存命中率不含输出。零数据保留标签和数值，以中性空轨道呈现。分析模型中的日历、分布和 Lorenz 数据仍保留，此概览不绘制。

## 记录明细

平台、供应商和模型区域直接展示，平台与供应商卡片的模型明细、Token 构成常驻显示，不再点击展开。平台列出全部模型。Cursor 与其他平台共享标题字体、缓存命中徽标、主数值、分隔线、模型列表、Token 构成条和卡片表面。Cursor 保留官方账单标识、真实统计日期、周期覆盖不足和刷新失败提示；不绘制缺失的逐日曲线、调用次数或本地平台占比。四类精确 Token 数通过构成条帮助文字提供。

供应商曲线仍是装饰，平台小曲线使用来源日记录，Cursor 不补造本地逐日记录。Cursor 刊例估算与官方实扣保持独立逻辑。

## 状态与性能

只有已发布记录区间与当前选择一致时展示统计，否则显示读取状态。输入变化时以独立任务计算分析、经验分布、核密度、Lorenz 点列、来源总量和来源总量；取消后的结果不发布。桶极值与分布参数预先缓存，悬停仅检查缓存结果，不重聚合记录。切换数据后清空日期检查选择。

## 研究来源、署名与验证

本轮图表研究参考 [Apple Charts HIG](https://developer.apple.com/design/human-interface-guidelines/charts) 与 WWDC22 [Design an effective chart](https://developer.apple.com/videos/play/wwdc2022/110340/)，采用明确摘要、可检查数量、受控轴密度和辅助功能读数。[Anthropic 官方品牌指南](https://github.com/anthropics/skills/blob/main/skills/brand-guidelines/SKILL.md) 的珊瑚色 `#D97757` 与柔和蓝 `#6A9BCC` 提供分类配色方向，原生界面仍使用 SF 字体与现有 Theme，浅深主题分别定义图形颜色。

[Nature 图形规范](https://research-figure-guide.nature.com/figures/preparing-figures-our-specifications/) 提供清晰轴线与刻度、可读标签、颜色图例及减少重叠和多余装饰的参考。[Observable Plot Dot](https://observablehq.com/plot/marks/dot) 展示以面积编码数量的圆点语法，其半径通道默认使用平方根尺度；[D3 Arc](https://d3js.org/d3-shape/arc) 说明以起止角度、内外半径构造环形分段。本实现借鉴这些数据表达方法，并按原生应用的可读性与交互调整，不宣称已符合期刊发表或导出规范。

[Matplotlib 官方 Choosing Colormaps](https://matplotlib.org/stable/users/explain/colors/colormaps.html) 说明顺序色阶适合有序值，并将 viridis 列为感知均匀色阶。[Matplotlib AsinhScale 文档](https://matplotlib.org/stable/api/scale_api.html#matplotlib.scale.AsinhScale) 提供零附近近似线性、较大数量渐近对数的尺度依据；本实现使用明确的 `asinh(Token / c)` 公式和逆变换标签。应用不引入图表研究工具的运行时依赖。

viridis 作者 Nathaniel J. Smith、Stefan van der Walt、Eric Firing 的 64 个采样颜色数据采用 CC0／公有领域奉献，署名及 BIDS 色表来源记录在 `Sources/ClaudeBar/Resources/ASSET-LICENSES.md`。应用不打包 Matplotlib 运行时。

实现依据为 `Sources/ClaudeBar/Utils/UsageAnalysis.swift`、`Sources/ClaudeBar/Views/Shared/UsageAnalytics.swift`、`Sources/ClaudeBar/Views/Shared/UsageDistributionPlot.swift`、`Sources/ClaudeBar/Views/Shared/UsageRelationshipPlot.swift`、`Sources/ClaudeBar/Views/Pages/UsageView.swift`。本文记录当前源码的布局和数据口径；数量来自记录，不补造小时趋势、缺失日期记录、账单或节省金额。离线合成记录静态预览位于 `.build/usage-redesign`，覆盖浅色、深色、窄窗口、多周期、全零与无已到达日期场景，用于检查布局、图形比例与主题。预览只覆盖所渲染的记录与窗口尺寸，不执行应用生命周期、原生菜单或悬停交互，不能视为实际运行验证。本轮最终构建、回归与预览结果以交付说明为准；未启动应用或执行 VPN、系统代理、DNS、TUN、硬件及其他系统集成验证。
