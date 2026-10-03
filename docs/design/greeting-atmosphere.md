# Greeting Atmosphere — 问候卡天空实现说明

Scope：问候卡（`Views/Shared/GreetingCard.swift`）与它的 Metal 大气
（`Views/Shared/Atmosphere/`：`AtmosphereView` / `AtmosphereRenderer` /
`AtmosphereShader` / `SkyScene` / `GreetingScript`）、
`Views/Shared/GreetingInstruments.swift`、`Views/Shared/SettingsControls.swift`
（Dashboard 顶部卡片）。设计验收在 [DESIGN.md › Greeting sky window](../../DESIGN.md)。
本文只记录**已实现**的机制与常量，不写未落地的设计构想。
数据层（`WeatherReading`、`SkyAstronomy`、`GreetingPhrase`、`MachineIdentity`）保持不变。
`SkyGreeting.swift` 与 `WeatherBackdrop.swift` 的 Canvas 天空是这一轮取代掉的实现：
前者已删除，`WeatherBackdrop.swift` 只留下 `SkyPalette` 供金属视图不可用时的回落调色板，
旧实现的验证背景见 [weather-observatory.md](weather-observatory.md)。

---

## 1. 设计理念

> **"一扇会呼吸的窗"——把实时天空当作画布，把问候写在光里，其余一切退居为窗框上的铭文。**

关键取舍：

| 取舍 | 选择 | 放弃 | 理由 |
| --- | --- | --- | --- |
| 信息密度 vs 氛围 | 首屏问候 + 一行气象 + 一条窗台 | 常驻 6 日预报、大号温度、三块 dock 卡 | 细节全部可通过悬停 / 点击展开，首屏不需要 |
| 手写体 vs 编辑体 | 问候由 `GreetingScript` 用 **CoreText 轮廓**写出所选字体（默认寒蝉圆黑 · 粗体，共 53 款） | 算法生成单线字形 | Apple 发布会的 "hello" 是人工为单个词画的矢量作品，不是字体；见 §3.1 |
| 渲染技术 | **运行时编译的 MSL 片元着色器（`MTKView` + `AtmosphereShader`）** | SceneKit / RealityKit | 与 SwiftUI 文字同一渲染通道，问候语可以折射天空；SceneKit 已被软弃用，RealityKit 过重 |
| 3D 真实感 | 体积云用 2.5D 光线步进（fBm 密度场 + Beer-Lambert 向光采样） | 真 3D 模型 | 卡片是固定视角，2.5D 视差即可给出纵深，成本低一个数量级 |
| 视差输入 | 指针（`AtmosphereMTKView` 自带跟踪区） | 陀螺仪 / 窗口位置 | macOS 无可用陀螺仪；窗口位置会让"天空"随窗口移动而漂移，实测不自然 |
| 失败态 | 天气失败时 `FallbackSky` 仍按太阳高度画推算晴空（金属视图可用时 `SkyScene` 一直有值） | 灰白中性底 | 天体位置不依赖网络（只要有坐标缓存或时区推算） |

---

## 2. 布局与信息架构

### 2.1 尺寸比例

`GreetingCard.Metrics` 的真实取值：

| 项 | 值 |
| --- | --- |
| 卡片宽 `W` | 自适应（窗口宽减页面内边距） |
| 天空区高 `sky` | `min(430, max(380, W × 0.38))` |
| 窗台（Sill）高 | `sill = 56`（固定，`total = sky + sill`） |
| 安全边距 | `W ≥ 900`：32pt；否则 24pt |
| 外圆角 | 32pt continuous |
| 顶 / 底让位 | `topClear = top + (W ≥ 900 ? nowHeight : 156) + 6`；`bottomClear = chartTop - 6`（问候语在两块仪表之间的自由带里排版） |

### 2.2 模块定位

```
┌──────────────────────────────────────────────────────────────── 32pt 圆角 ┐
│ 16:15  9月28日 周一                           广州 · 29° 多云   ◐ ☼     │ ← 左上时钟，右上实时天气
│                                               体感 32° · 湿 78% · 东南 3级│
│                                                                          │
│   good afternoon,                                                         │ ← 问候语在 topClear/bottomClear 之间
│                                  Xiajun Wang                              │ ← 名字，右对齐到问候语右端，可下落到下一行
│ ☀ 日落 18:21 · 拖动天空，漫游一天 / 手动控制台                              │ ← 左下日轨；手动时换成控制台
├──────────────────────────────────────────────────────────────────────────┤
│ [Λ ds-v4.1] [◎ gpt-6] [▣ Cursor 48% · Other 60%] [◎ 5小时 18% · 7天 50%]  7.7亿 ↑33% │ ← 窗台 56pt
└──────────────────────────────────────────────────────────────────────────┘
```

- 问候语由 `GreetingTypesetter.layout` 在自由带内最大化排布（短句按高度增长、长句按宽度收缩），名字可落在问候语下方。
- 气象铭文右上，时钟左上，两者共享同一条边距。
- 窗台胶囊悬停有一个 140ms 的驻留再展开（`SillChip`），避免指针扫过时依次弹开。

---

## 3. 问候语设计

### 3.1 字体

> **实现结论（2026-09-28）**：Apple 发布会的 "hello" 是为单个单词手绘的矢量作品，每个字母的连笔和收笔都是单独设计的，不是字体。问候语有十几种文案（时段 + 节日），用算法生成单线字形（曾试过 EMS Allure 单线字形加笔宽）达不到那个质量，因此放弃计算，改用现成字体。

| 用途 | 字体 | 理由 |
| --- | --- | --- |
| 问候 | 默认 **寒蝉圆黑 · 粗体（`chillRoundBold`，`GreetingTypeface.standard`）**，全小写（`computeLayout` 对文案 `lowercased()`）；设置 → 通用 → 天气与问候 → 问候字体可在 53 款间切换（`GreetingTypeface.allCases`：`chineseFaces` 14 款中文 + 39 款拉丁，其中 49 款随包、SignPainter / Snell Roundhand / Savoye LET / Zapfino 四款系统字体） | 圆头、笔画均匀，适合手写问候。只有单线字体在填充外加圆角描边（`outlineWidth = fontSize × typeface.weight × 2`；Borel `weight = 0.012`、Playwrite `0.008`、Sacramento `0.01` 等，其余为 0），均匀加粗而不填死 a / e / o 的字腔；粗细对比强的字体不描，以免糊掉发丝线。设置页默认折起，只留当前这一款的字样；展开后每张卡片用该字体写出当前问候语，可移除 / 恢复随包字体；切换后问候卡重写一遍（`controller.rewrite()`）。系统字体按 PostScript 名查找，找不到的卡片置灰 |
| 名字 | 圆角系统字体 Medium，`nameSize = min(28, max(18, 0.18 × size))`，字距 0.015em | 与手写体对比，安静的第二声部；名字是 `MachineIdentity.greetingName`（拼音化的机型名） |
| 回落 | Snell Roundhand Bold | 系统必备；仅在资源缺失时使用 |

书写入场：纹理 G 通道为从左到右的书写时刻（问候 0…`phraseShare` = 0.86、名字 `nameStart` = 0.90…1），着色器以约 2% 行宽的柔边推进，笔尖后方的墨带"未干"的高光——像墨迹跟着笔走，而非硬切的擦除。书写时长 `writeDuration = min(2.8, max(1.6, 0.9 + advance × 0.2))` 秒（约 0.2 s/em）。点击问候语（`rewrite()`）或按空格重写一遍。

### 3.2 排版参数

`GreetingTypesetter.computeLayout` 不套固定字号公式：在 `topClear` / `bottomClear` 之间的自由带里，对字号做 24 次二分，取「问候语宽度 + 描边」与「名字宽度」都不超过可用宽度、且两行总高（含名字下落）不超过带高的最大值。

| 参数 | 值 |
| --- | --- |
| 字号 | 二分求解（高度或宽度先触边）；问候语按 `size` 排，名字按 0.18 × size 排 |
| 追踪 | 仅名字有：`nameTracking = size × 0.015`；问候语轮廓本身无额外字距 |
| 对齐 | 左对齐，起点 `margin + size × weight - line.bounds.minX × size`（描边光学外扩） |
| 名字 | 右对齐到问候语墨迹右端（`ink.maxX - size × 0.05`，不超过卡片右边距）；`nameInline = false`，名字落在问候语下方 |
| 描边 | `fontSize × typeface.weight × 2`（仅单线字体，见 §3.1） |
| 纹理 | 问候与名字的墨迹并集外扩 `padding = size × 0.3`，整体 `integral` 对齐 |

`layout` 按参数记忆最近 8 个结果（`LayoutCache`，超过就丢最旧的一条），body 每帧命中缓存不再构建 `CTLine`。

### 3.3 问候语的绘制："天光玻璃字"

问候语不是 SwiftUI 文本，而是 `GreetingTypesetter` 用 CoreText 取出的字形轮廓，填色 + 描边后按**覆盖度 / 书写时刻**双通道烘成一张 `rg16Unorm` 纹理（G 通道是从左到右的书写时刻，见 §3.1），交给同一条 Metal 通道着色。着色器合成的是：

1. **填充**：`glass` 取自问候语位置背后的天空渐变（`skyGradient(u, uv.y + nrm.y × 0.08)`，`×1.15 + 0.1`），与 `inkLight` 混合（0.9 归向白墨，夜里转冷色）；整天没有独立折射层——字形本身是墨，不是玻璃（早先 36% 的折射率会被描边吃掉，整行读成空心管）。
2. **落影与光晕**：字形覆盖度的高等级 mip 采样作柔影，随天空亮度 `shadeAmt = 0.18 + 0.35 × smoothstep(0.25, 0.6, lum)` 加深；`u.glow` 取地平线色，写入 `textGlow`（随 twilight 增强）。
3. **边缘光**：按字形法线 `nrm` 朝光源方向的 `dot` 截断到 0…1，白色或天体色温，强度取 `rimStrength = max(sunVisibility × (0.55 + 0.45 × lowSun), moonVisibility × 0.55)`。
4. **笔尖湿墨**：书写推进时笔尖后的墨迹 `exp(-(front - g.y) × 30)` 短暂提亮。

没有 `layerEffect` / `maxSampleOffset` / SwiftUI `shadow` 路径——这些是实现前的候选，最终没有采用。

### 3.4 文案策略（`GreetingPhrase`，与代码同构）

问候语由 `GreetingPhrase.resolve(_:custom:date:calendar:language:context:)` 在三档模式里生成，文案本身带 aside：

- **Selection**：`automatic`（默认，看日期与天气）/ `everyday`、`verse`、`hello` / `morning` / `afternoon` / `evening` / `night` / `welcome` / `gentle` / `monthly` / `custom`（固定文案，中文 / 英文各一套）。
- **`automatic` 的优先序**（`forDate(..., mode: .automatic)`）：节日 → 深夜 / 夜间不套天气 → 有天气则 `weatherPhrase` → 节气诗词 → 周末诗词 → 当季诗词。同一天同一小时文案稳定（用「era 内第几天 + 小时」作种子的确定性选择），不是每次重绘都换一句。
- **`verse`** 跳过节日与天气，只用节气 / 季节的诗词；**`everyday`** 是「早上好呀」「早点休息」这一类不带诗也不带天气的日常问候。
- **语言**：`GreetingPhrase.Language.chinese` / `.english`（默认中文），aside 与主句同语言。
- **天气只修饰**：`Context(weather:temperature:windKph:)` 只影响 aside 与 `weatherPhrase` 的选用，不改 `everyday` 池里的主句——主句在一小时内稳定。

问候语与 aside 都由上面这一步产出，排版再按所选字体的真实轮廓测量（`GreetingScript.line(text, typeface:)`）：问候卡只画 `Phrase.salutation` 与名字（`GreetingPhrase` 里另一条 `aside` 供弹窗等别处使用），文案层与字形层各管一段。

---

## 4. 次要信息设计

统一图标规范：SF Symbols，`weight: .light`、`scale: .small`，视觉线宽 ≈ 1pt；自绘图形线宽 1pt、端点 round。

| 元素 | 字体 | 字号 / 字重 | 不透明度 | 间距 |
| --- | --- | --- | --- | --- |
| 时钟 `16:15` | SF Pro Display，`monospacedDigit` | 22 / Light | 90% | 与日期间距 8pt |
| 秒点 | 1.5pt 圆点，每秒呼吸一次 | — | 40% ↔ 80% | 位于分钟右上 2pt |
| 日期 `9月28日 周一` | SF Pro Text | 11 / Medium | 60% | 与时钟同基线 |
| 位置 `广州` | SF Pro Text + `location` 符号 8pt | 11 / Medium | 70% | 符号与文字 3pt |
| 温度 `29°` | SF Pro Display，`numericText` | 22 / Light | 92% | 与位置 6pt |
| 状况 `多云` | SF Pro Text | 13 / Medium | 78% | 与温度 4pt |
| 次行 `体感 32° · 湿 78% · 东南 3级` | SF Pro Text，数字 `monospacedDigit` | 11 / Regular | 58% | 与首行行距 4pt |
| 日落 / 提示 | SF Pro Text | 10 / Medium | 45% | 左下 |
| 窗台胶囊 | 文字 11 / Semibold；数字 `monospacedDigit` | — | — | 胶囊高 30pt，内边距 10 × 6，间距 8pt |

风力显示为蒲福风级（`windKph` → 级数），湿度 ≥ 85% 或体感与实温差 ≥ 4° 时对应片段提升不透明度，作为"值得注意"的唯一强调方式（不用颜色）。

---

## 5. 背景渲染方案

### 5.1 技术选型

| 方案 | 结论 | 用途 / 理由 |
| --- | --- | --- |
| **运行时编译的 MSL（`MTKView` + `AtmosphereShader`）** | ✅ 主力 | 天空渐变 / 体积云 / 雾 / 降水 / 天体 / 闪电 / 问候语 / 玻璃雨滴在**一条**渲染通道里按远近分层；着色器以 `device.makeLibrary(source:options:)` 在首次使用时编译（随系统编译器），见 §5.7 |
| `NSViewRepresentable`（`AtmosphereMetal`） | ✅ 承载 | 把 `AtmosphereMTKView` 挂进 SwiftUI；`MTKView` 自带指针跟踪区，视差与"擦掉"雨滴不会让 SwiftUI 的视图图失效 |
| `CADisplayLink`（`FrameTicker`） | ✅ 时钟 | 时刻缓动与拖动预览；与显示器刷新率同步，不像 `Task.sleep` 那样与刷新率拍频成顿挫 |
| `CAGradientLayer` | ✅ 辅助 | 扫光（`ReadingSweep`）——渲染服务器插值，不重算 SwiftUI body |
| `AtmosphereStill` | ✅ 静帧 | Reduce Motion、预览工具与 `ImageRenderer`：同一渲染器 `snapshot()` 一次出新图的 `CGImage`，输入 / 尺寸 / 缩放不变就不重绘 |
| `.periodic(by: 1)` | ✅ 时钟 | 问候卡那一枚秒点，一秒一次；**`.animation` 调度不用**（见 [技术 §8](../technical/08-performance.md)） |
| `Canvas` + `TimelineView`（`WeatherBackdrop`） | ⚠️ 回落 | 只在 Metal 视图不可用（构不出 `AtmosphereGPU`）时画的旧 Canvas 天空；`GreetingCard.makeScene()` 的金属路径是常走的 |
| SceneKit | ❌ | 2025 年起软弃用；与 SwiftUI 文字无法同通道合成 |
| RealityKit `RealityView` | ❌ | 需要独立渲染循环和实体系统，对固定视角的卡片是过度设计，内存 +40–80MB |
| MeshGradient | ❌ | 曾作为 Reduce Motion 降级方案评估，最终用同一渲染器的静帧代替 |

构建影响：**没有**离线 Metal 编译步骤。构建走裸 `swiftc`（无 Xcode 工程、无 `default.metallib`），所以着色器以字符串形式随包分发、运行时编译——运行时编译器随系统，版本与当前 OS 一致。

### 5.2 图层结构（远 → 近）

真实顺序就是 `scene()` 与 `foreground()` 两个函数里的书写顺序，视差系数是该处乘的常数（`par × 系数`）：

| 层 | 绘制内容 | 视差 | 所在函数 |
| --- | --- | --- | --- |
| 天空渐变 + 大气散射 | 三段 `skyGradient` + 地平线光晕 | 0 | `scene()` |
| 星空 / 太阳 / 月亮 | 星点（`SkyAstronomy.stars` 投影 + `s.xy` 位置）与两个天体盘 | 0.05 | `scene()` |
| 卷云 | 单层 fBm | 0.12 | `scene()` |
| 体积云 | fBm 5 octave + 4 次向光步进 | 0.25 | `scene()` |
| 雾 | fBm 3 octave | — | `scene()` |
| 闪电照亮云底 | 击发时按到闪点的距离提亮 | — | `scene()` |
| **问候语** | 纹理采样 + 边缘光（见 §3.3） | 0.4 | `foreground()` |
| 远降水 | 细底片滚动 | 0.35 | `foreground()` |
| 雪 | 细底片滚动 | 0.3 | `foreground()` |
| 闪电通道 | 屏幕空间折线，只算击发列 | — | `foreground()` |
| 彩虹 / 流星 | 弧带 / 拖尾，`effects.z` / `meteorInfo` 触发 | — | `foreground()` |
| 近降水 / 冰雹 | 粗底片滚动 | 0.7 / 0.6 | `foreground()` |
| 玻璃雨滴 | `glassDrops()`：静态水珠 + 每车道下滑的一颗 | 随卡片 | `atmosphere_fragment`（合成前） |
| 窗台 + 铭文 | SwiftUI，不是 shader 层 | — | `GreetingCard` |

问候语刻意夹在云层与近降水之间——**近景雨丝会从字的前方划过**，这是纵深感的关键来源。

### 5.3 体积云与光照模型

真实常量（`AtmosphereShader.swift`）：

- 密度：`cloudField` 在透视天花板上跑 fBm，阈值 `mix(0.64, 0.20, cover)`；`cover` 来自 `SkyScene` 的天气查询表（`look.cover`，晴 0.10 / 多云 0.46 / 阴 0.88 / 小雨 0.92 / 大雨 0.97 / 雷暴 1.0 / 雪 0.86 / 雾 0.40）。
- 光照：从云点朝光源（太阳 or 月亮，`light()` 统一选择）步进 **4** 次，步长 `i² × 7 pt` 累积 τ，透射 `T = exp(-τ × 0.42)`（Beer-Lambert），powder 项 `1 - exp(-dens × 2.5)`。
- 银边：光源附近 `prox = exp(-length(kp - lightPt) / 170)`，乘以 `(1 - dens) × 3.2 × lightVis`——天体被云挡时出现。
- 云色：`belly`（阴影）与 `crown`（受光）按 `shadeT = clamp(T × 0.85 + (1 - dens) × 0.35)` 混合；雷暴把两者都压暗。
- **没有** god rays、Henyey-Greenstein 相位函数或单独的天体遮挡盘——这些是设计前的候选，实现里没有。

### 5.4 各天气实现与粒子参数

粒子全部在 shader 里按格子哈希生成，雨雪是启动时烘焙的平铺底片（`precip_bake` / `makePlate`：`rainFine`、`rainCoarse`、`snowFine`、`snowCoarse`），播放只是按风滚动，没有 CPU 粒子数组。

| 天气 | 关键量（`SkyScene` 的 `weather` 查询表） |
| --- | --- |
| 晴 / 多云 | `rain = snow = fog = thunder = drops = 0`，只有云量与风 |
| 阴 | `fog = 0.12` |
| 小雨 / 毛毛雨 | `rain = 0.38 + chance × 0.18`（毛毛雨 0.22）；雨夹雪 `snow = 0.45`；`fog = 0.28`；`drops = 0.3 / 0.55` |
| 大雨 | `rain = 0.78 + chance × 0.22`；`fog = 0.42`；`drops = 1` |
| 雷暴 | `rain = 0.96`；`fog = 0.3`；`thunder = 1`；`drops = 1` |
| 雪 | `snow = 0.85`；`fog = 0.3` |
| 雾 | `fog = 1` |
| 冰雹 | `hail = true`（在雪的底片上叠 `snowCoarse` 高速格子） |

雨丝倾角 `slant = min(18, windKph × 0.6)°`（按风向取符号）；雷暴雨速 `mix(210, 340, amt) × (1 + thunder × 0.16)`。闪电：`nextFlash` 以 1/3 概率紧跟 1.1–2.5 s、否则 2.5–8 s；`bolt` 占 60%，通道周期 `(46, 15, 4.5) pt`，2–3 次回击间隔 40–130 ms，每次约 30 ms 峰值后 `exp(-(a - 0.03) × 22)` 衰减；云底照亮 `sky = (bolt ? 1 : 0.75) × min(1, age / 0.02)`，保持到末次回击后按 `exp(-(age - hold) × 6)` 衰减——闪间不回暗，相邻两次 ≥ 1.1 s，一秒内 ≤ 3 次闪烁（WCAG 2.3.1）。预览：`Tools/render-greeting-preview.py` 的雷暴档。

### 5.5 天体随时间联动

- **位置**：`SkyScene.project(position, center:)`：方位角相对当天中心方位折叠到 ±180°，除以 `fieldOfView = 220°` 映射到 x；高度角按 `y = horizonLine(0.80) - altitude / 90 × altitudeSpan(0.72)` 映射。
- **大小**：太阳 `sunRadius = 19 × (1 + 0.35 × lowSun)`；月亮 `moonRadius = 15 × (1 + 0.3 × lowMoon)`；`lowSun` / `lowMoon` 是高度角 15° → 0° 的 smooth 放大（地平线错觉）。
- **色温**：`sunColor` 带宽按高度角插值——`−2° #F37A5C`、`0° #FF8A4C`、`5° #FFB86B`、`15° #FFE3A8`、`40° #FFF6E0`。月亮盘 0.96–1.0 的近白，接近地平线时转 `#FFE7C2`。
- **月相**：`moonPhase`（轨道角 `sky.x × 2π`）驱动 `dot(n, L)` 明暗分界，月海用 fBm 加暗，边缘 `smoothstep(1.0, 0.93, r²)`；无云的满月附近有一圈 `exp(…× 1.3)` 光晕。
- **星空**：`starVisibility = smooth(-5, -15, sunAlt) × look.starClarity`；星点大小 0.6–2.2px（`s.z`），只有 `fract(s.w × 7.13) > 0.86`（约 **14%**）的这一部分星在闪烁，闪烁频率 0.8–2.4 Hz；`sky.z` 的星野旋转由 `SkyAstronomy.sidereal` 提供。
- **连续性**：`skyDate` 每分钟刷新一次，`SkyScene.mix` 对连续量做 smoothstep 淡变（见 §5.6），太阳不跳（`clock` 由 `SkyTimeline` 平滑推进）。

---

### 5.6 手动天空（自动 / 手动）

时钟下方的 `SkyModeToggle` 在 **自动**（跟随实时天气与时间）和 **手动** 之间切换；天气渲染关掉时第一格变成 **贴图**（点一下重新打开渲染）。进入手动时，从当前天空出发（切换本身画面不变）；回到自动时，时刻先经 `returnToNow()`（0.75 s 三次缓出，`FrameTicker` 驱动）缓动回"现在"，天气由渲染器交叉淡变。

手动时，左下日轨就地换成控制台（窄卡片同时让出预报区），不遮挡问候语：

- **天气**：晴 / 少云 / 阴 / 小雨 / 大雨 / 雷雨 / 雪 / 雾（`SkyConsole.weathers`），图标经 `PinnedSky` 取自 `WeatherReading.Sky.symbol(night:)`，选中项以滑动圆角块标示。
- **时段**：黎明 / 日出 / 上午 / 正午 / 下午 / 日落 / 黄昏 / 夜晚（`SkyConsole.bands` 的 `SkyScene.Band` 八档），放在一条分段轨道里。点选后经 `glide(to:)` 滑到该时段的代表时刻（按当天真实日出日落推算），走钟面上较短的一侧，时长 `min(1.4, 0.45 + |Δ| / 720 × 0.95)` 秒、三次缓入缓出。
- **时间轴**：24 小时（`SkyTimeline`），轨道用所选天气下当天每小时的天空色绘制，刻度标出日出 / 日落，滑块带太阳 / 月亮与时刻，`snap` 5 分钟吸附，←/→ 每次 15 分钟；直接拖动天空也能调整时刻。

平滑渲染：时刻连续变化时天空按太阳高度连续插值；天气切换时 `AtmosphereRenderer` 记下 `fadeFrom` / `shownScene`，在 `weatherFade = 1.2` 秒内对调色、云量、降水、雾、星光等连续量做 smoothstep 淡变（`SkyScene.mix`），连续多次切换从屏幕上的当前状态起步，淡变期间 `AtmosphereView.boost(for:)` 让 Metal 视图按显示器满帧率运行。

**天气渲染关掉后（`AppPreferences.greetingWeatherRendering`）**，`GreetingCard.makeScene()` 改画一层按太阳高度连续插值的晴空——调色、日月与云量都在，只是没有雨雪、雾、闪电和玻璃雨滴，星层收掉（星点从真实坐标投影，而这一档不再声称那是所在与此刻）。这不是「另一种天气」，所以右侧不再读实时天气（`liveWeather == false` 时右上、预报带与体感行都让位，日轨改从本机时区推算），`WeatherStore` 也不再被这张卡刷新。

### 5.7 帧率与主线程策略

天空是同一渲染通道里的两次绘制：云层（渐变、天体、卷云、体积云、雾）先画进半分辨率的 `skyTexture`（`skyPixelFormat = .rgba16Float`），合成帧再把这张纹理与雨雪底片、问候语纹理、玻璃雨滴合成到屏幕上。云层按 `skyDue` 走 30 Hz（低电量 / 热压力 15 Hz，闪电或截图时立即重画）；雨雪是启动时烘焙的平铺底片（`makePlate`），播放就是按风滚动，所以静止的卡停在 30 Hz 也是连续的。实测量（`Tools/bench-atmosphere.py`，M3 Pro）与帧率策略见下。

| 场景 | 帧率（`AtmosphereMTKView.retime()`） |
| --- | --- |
| 书写中、天气淡变、指针在天空上（视差）、拖动漫游 | 显示器上限（`boostedUntil` / `writing`）。云层仍是 30 Hz，只有合成在跟手；指针视差最高 60 Hz |
| 静止的雨 / 雪 / 冰雹 / 雷暴（`restingRate` 判 falling） | 30 Hz。闪电照亮云底的那一下，云层跟着走 |
| 静止的晴 / 多云 / 雾（非 falling） | 15 Hz——云飘、星呼吸、流星都远小于每帧 1px，画两倍频率没有画面对应 |
| 低电量模式 / 热压力（`constrained`） | 交互（笔 / 淡变）时 30 Hz，否则 `min(resting, 15)` |
| 不可见、被遮挡、Reduce Motion | `isPaused`；Reduce Motion 走 `AtmosphereStill` 的一次性快照 |

主线程约束：

- **问候语纹理离主线程栅格化**。`rasterQueue` 是串行队列，一次一件；窗口缩放时只做"正在做的 + 最新的"，中间尺寸不做；新纹理就绪前旧纹理按它自己的 frame 继续画，不会被拉伸到新位置。静帧（Reduce Motion、预览工具）仍同步生成。
- **时间动画与显示器同步**：回到现在（0.75 s，`pow(1 - p, 3)`）与手动时段滑动（`min(1.4, 0.45 + |Δ| / 720 × 0.95)` 秒，三次缓入缓出）由 `FrameTicker`（`CADisplayLink`）驱动；`Task.sleep` 会与刷新率拍频成顿挫。
- **拖动 / 滑动时只重算随时间变化的部分**：天空、时钟、日轨 / 控制台。窗台、预报带、右上"此刻"用 `Unchanged(key:)` + `.equatable()` 固定，key 必须覆盖其读取的全部值；三者带闭包，SwiftUI 自己无法判等。
- `GreetingTypesetter.layout` 按参数记忆最近 8 个结果，body 每帧调用不再构建 CTLine（`LayoutCache`）。
- 着色器只省必然为零的计算：星点距像素 > 24 pt 直接跳过（核与星芒此时都 < 1/255），地平线以下不采样卷云 / 云层噪声（原本采样后乘 0）。
- **问候卡不在概览的显示周期里**：时钟是 `.periodic(by: 1)`，概览页上**没有** `.animation` 调度的时间线（见 [技术 §8](../technical/08-performance.md) 的 2026-09-29 记录）。天空是 `MTKView`，自带渲染循环与帧率策略、不经过 SwiftUI 的布局——所以卡片再贵也只在它自己的线程上贵。
- **设置页字体预览在后台加载**：折叠时不读字体文件、不构造预览（`fontBrowserExpanded`），展开后才 `await prefs.prepareGreetingFonts()`。

页面滚动：

- **滚动时天空定帧**。概览页的 `onScrollPhaseChange` 在滚动（拖动、惯性、动画）期间让天空停在当前帧，合成器只平移一张静止图层，不再每个滚动步都混合新帧、重新模糊上面的玻璃窗台。卡片滚出视口（`onScrollVisibilityChange`）后同样定帧。停下后从当前时刻继续。
- **不经 SwiftUI 传递**：滚动状态放在 `PageScrollActivity` 这个引用里，直接通知 `MTKView`。每次滚动的开始和结束都会变，若经 `@State` / 环境值传递，就会在滚动最需要主线程的那一刻重算整个概览页和卡片的闭包。
- **不在主线程等 drawable**：`currentDrawable` 在所有 drawable 都被占用时会阻塞主线程，而这恰好发生在合成器落后的滚动中。现在最多两帧在途（`pending >= 2`）就跳过一帧；若 presented 回调超过 0.25 s 未到，则复位计数以免天空永久停住。
- 静帧（预览工具、`AtmosphereStill`）与截图用固定闪电（`lightning(still:)` 直接返回一个定值），雷暴静帧每次一致。

## 6. 配色系统

### 6.1 天空渐变（时段 × 天气）

- 方向：**竖直线性渐变，天顶 → 地平线**，中间节点 55%（`skyGradient`：`t < 0.55` 时 zenith→mid，之后 mid→horizon）。
- 时段按**太阳高度角**划分而非钟点（`SkyScene.band(altitude:rising:)`）：

| 时段（Band） | 太阳高度角 |
| --- | --- |
| `night` | < −18° |
| `dawn` / `dusk` | −18° ~ −4°（上升 / 下降） |
| `sunrise` / `sunset` | −4° ~ 8°（上升 / 下降） |
| `morning` / `afternoon` | 8° ~ 35°（上升 / 下降） |
| `noon` | ≥ 35° |

- 相邻关键帧之间按高度角平滑插值（`interpolate`，`t²(3−2t)`），关键帧是 `risingKeys` / `settingKeys` 各 5 档（−18° / −11° / 2° / 20° / 42°），`dayness` 同表插值。
- 颜色生成：每个时段一组三段停靠色（`clearBands`，见下方逐时段表），天气再叠加自己的 `dayTint` / `nightTint` 与 `amount[0/55/100]`：`stop = exposure × mix(clearStop, mix(nightTint, dayTint, dayness), amount)`。地平线节点的 amount 较小，所以阴雨天在日出日落时仍会**透出暖色**。

| 天气 | dayTint | nightTint | amount（0% / 55% / 100%） | exposure |
| --- | --- | --- | --- | --- |
| 晴 | — | — | 0 / 0 / 0 | 1.00 |
| 多云 | `#A9B9CC` | `#1E2738` | 0.22 / 0.26 / 0.18 | 0.98 |
| 阴 | `#8C99A8` | `#1A2029` | 0.66 / 0.70 / 0.58 | 0.92 |
| 小雨 | `#61758A` | `#131B26` | 0.66 / 0.72 / 0.62 | 0.86 |
| 大雨 | `#415166` | `#0C121A` | 0.78 / 0.82 / 0.74 | 0.74 |
| 雷暴 | `#2E3350` | `#0A0C18` | 0.84 / 0.84 / 0.72 | 0.66 |
| 雪 | `#C7D2E0` | `#26303F` | 0.62 / 0.66 / 0.60 | 1.04 |
| 雾 | `#C3C9D0` | `#2E343C` | 0.76 / 0.84 / 0.88 | 1.00 |

#### 晴

| 时段 | 0%（天顶） | 55% | 100%（地平线） |
| --- | --- | --- | --- |
| 深夜 | `#050A1C` | `#0B1634` | `#17264C` |
| 黎明 | `#0E1C4A` | `#34427F` | `#8A77A8` |
| 日出 | `#27427F` | `#9A86B4` | `#FFB48A` |
| 上午 | `#2A6FD1` | `#63A5EA` | `#C4E3FA` |
| 正午 | `#1D62D8` | `#4E9CF2` | `#AAD8FF` |
| 午后 | `#2C66C2` | `#72A8DE` | `#EFDFC4` |
| 日落 | `#2B3A7A` | `#C4668A` | `#FF9656` |
| 黄昏 | `#141A46` | `#3E3070` | `#A6566E` |

#### 多云

| 时段 | 0%（天顶） | 55% | 100%（地平线） |
| --- | --- | --- | --- |
| 深夜 | `#0A1021` | `#101A34` | `#182547` |
| 黎明 | `#17244B` | `#344172` | `#796C96` |
| 日出 | `#354C7F` | `#8B80A6` | `#E0A687` |
| 上午 | `#457DCC` | `#73A7DE` | `#BBD7ED` |
| 正午 | `#3B73D1` | `#64A0E3` | `#A6CEF1` |
| 午后 | `#4676C0` | `#7EA9D5` | `#DED4C1` |
| 日落 | `#38467B` | `#A96887` | `#E08E5D` |
| 黄昏 | `#1C2348` | `#3C3467` | `#905167` |

#### 阴

| 时段 | 0%（天顶） | 55% | 100%（地平线） |
| --- | --- | --- | --- |
| 深夜 | `#111722` | `#141B29` | `#172033` |
| 黎明 | `#222B3F` | `#2E364E` | `#4F4C64` |
| 日出 | `#42506B` | `#646479` | `#927A70` |
| 上午 | `#6280A7` | `#7590AD` | `#96A9BA` |
| 正午 | `#5E7CAA` | `#708EAF` | `#8CA5BC` |
| 午后 | `#637DA3` | `#7A91A9` | `#A7A8A5` |
| 日落 | `#434E69` | `#6F5C6D` | `#926F5C` |
| 黄昏 | `#242A3E` | `#31314A` | `#5A3F4E` |

#### 小雨

| 时段 | 0%（天顶） | 55% | 100%（地平线） |
| --- | --- | --- | --- |
| 深夜 | `#0C121E` | `#0E1624` | `#121B2D` |
| 黎明 | `#182237` | `#222C42` | `#403F56` |
| 日出 | `#2F3F5A` | `#4B5065` | `#74645F` |
| 上午 | `#43638B` | `#54708E` | `#74899B` |
| 正午 | `#405F8D` | `#4F6E90` | `#6B859D` |
| 午后 | `#446087` | `#58718B` | `#82878A` |
| 日落 | `#303C58` | `#56485B` | `#745A4E` |
| 黄昏 | `#192135` | `#24273F` | `#493443` |

#### 大雨

| 时段 | 0%（天顶） | 55% | 100%（地平线） |
| --- | --- | --- | --- |
| 深夜 | `#080C14` | `#090E17` | `#0B111D` |
| 黎明 | `#0F1624` | `#151B2A` | `#272837` |
| 日出 | `#1E293C` | `#2D3241` | `#483F40` |
| 上午 | `#2C415D` | `#35475D` | `#495868` |
| 正午 | `#2A3F5E` | `#32465E` | `#445669` |
| 午后 | `#2D3F5A` | `#37485B` | `#52575E` |
| 日落 | `#1F283B` | `#332E3C` | `#483A36` |
| 黄昏 | `#101623` | `#161928` | `#2C212C` |

#### 雷暴

| 时段 | 0%（天顶） | 55% | 100%（地平线） |
| --- | --- | --- | --- |
| 深夜 | `#060810` | `#070913` | `#090D19` |
| 黎明 | `#0B0E1B` | `#0F1221` | `#221F30` |
| 日出 | `#151A2C` | `#212131` | `#3D3134` |
| 上午 | `#1E2842` | `#242E45` | `#3A4254` |
| 正午 | `#1D2743` | `#222D46` | `#354055` |
| 午后 | `#1E2741` | `#262E44` | `#42414A` |
| 日落 | `#15192B` | `#251D2D` | `#3D2C2A` |
| 黄昏 | `#0C0E1B` | `#10101F` | `#271925` |

#### 雪

| 时段 | 0%（天顶） | 55% | 100%（地平线） |
| --- | --- | --- | --- |
| 深夜 | `#1A2334` | `#1E293E` | `#212E47` |
| 黎明 | `#333F5B` | `#434F6E` | `#656481` |
| 日出 | `#617294` | `#8D8DA8` | `#B9A098` |
| 上午 | `#91B3E3` | `#ACCAEC` | `#CEE1F4` |
| 正午 | `#8CAEE6` | `#A4C7EF` | `#C3DDF6` |
| 午后 | `#92B0DD` | `#B1CCE8` | `#E0E0DD` |
| 日落 | `#636F92` | `#9C8299` | `#B99482` |
| 黄昏 | `#353E59` | `#464869` | `#715669` |

#### 雾

| 时段 | 0%（天顶） | 55% | 100%（地平线） |
| --- | --- | --- | --- |
| 深夜 | `#242A34` | `#282F3B` | `#2B323E` |
| 黎明 | `#3D4556` | `#484F60` | `#535663` |
| 日出 | `#6B768A` | `#848694` | `#8F8B8D` |
| 上午 | `#9EB3D0` | `#B4C3D4` | `#C3CCD5` |
| 正午 | `#9BB0D2` | `#B0C2D5` | `#C0CBD6` |
| 午后 | `#9FB1CD` | `#B6C4D2` | `#C8CCCF` |
| 日落 | `#6C7489` | `#8B818D` | `#8F8887` |
| 黄昏 | `#3E4455` | `#4A4C5D` | `#57525C` |

### 6.2 功能色

| 角色 | 浅色模式 | 深色模式 | 说明 |
| --- | --- | --- | --- |
| 主文字（天空上） | `#FFFFFF` | `#EEF2FF` | 天空上的文字不随 App 主题反转，始终为浅色；可读性由遮罩保证 |
| 次文字 | `#FFFFFF` @ 78% | `#DCE4F5` @ 78% | |
| 辅文字 | `#FFFFFF` @ 58% | `#C9D3E8` @ 58% | |
| 强调（主色） | `#FFD58A`（天光金） | `#C9D6FF`（月光蓝） | 仅用于签名尾迹、太阳相关读数 |
| 警示 | `#FFB35C` | `#FFC27A` | 余额低、天气离线的小圆点 |
| 危险 | `#FF7A66` | `#FF8A75` | 额度 ≥ 90% |
| 窗台文字 | `#1B2331` | `#F2F5FA` | 窗台是玻璃，跟随 App 主题 |
| 外框描边 | `#FFFFFF` @ 50% → 8% | `#FFFFFF` @ 22% → 4% | 左上 → 右下 |

### 6.3 遮罩层（保证可读性）

| 遮罩 | 参数 |
| --- | --- |
| 顶部铭文遮罩 | 线性，`#0A1530` 0% → 18% @ 0–22% 高度（仅在天顶亮度 L\* > 62 时启用，即晴日正午 / 雪 / 雾） |
| 问候语局部遮罩 | 以问候语包围盒为中心的椭圆径向渐变，`#081226` @ 0.16 → 0，半径为包围盒的 1.3 倍；**只在** 文字与背景的对比度 < 3:1 时按差值启用 |
| 底部窗台遮罩 | 线性，`#081226` 0% @ 70% → 55% @ 100% |
| 深色模式整体曝光 | 天空 `exposure × 0.88`，饱和度 × 0.92（避免暗色 App 里一块刺眼的亮蓝） |

---

## 7. 材质与层次

| 部件 | 材质 | 模糊 | 填充 | 描边 | 阴影 | 圆角 |
| --- | --- | --- | --- | --- | --- | --- |
| 卡片外壳 | 无（天空即内容） | — | — | 1pt 渐变描边（§6.2）+ 内侧 0.5pt `#FFFFFF @ 10%` 内框（inset 1pt） | 浅：`#1B2A4A @ 14%, r 40, y 18` + `@ 8%, r 8, y 2`；深：`#000 @ 45%, r 48, y 20` | 32pt continuous |
| 窗台 | macOS 26：`.glassEffect(.regular.tint(...))`；macOS 15：`.ultraThinMaterial` | 系统 | 浅 `#FFFFFF @ 38%`；深 `#0A1426 @ 42%` | 顶部 0.5pt `#FFFFFF @ 35%` 高光线 | 无（依附于卡片） | 与卡片共享下圆角 32pt，上边直角 |
| 卡片表面雨滴 | 折射（`glassDrops()`，shader 内） | — | 高光点 `#FFFFFF @ 70%` | — | 底部 1px `#000 @ 18%` 接触阴影 | — |
| 问候语 | 见 §3.3 | — | — | 方向性边缘光 | 落影 + 光晕 | — |

深度规则：离观察者越近 → 模糊越少、描边越亮、阴影越短。卡片内部**只允许一层玻璃**（窗台），不再有嵌套卡片。

---

## 8. 动效设计

### 8.1 入场（`rewrite` / `replayEntrance`）

没有分层编排。入场的全部状态是 `AtmosphereRenderer` 里的三个时钟：

- `entrance = min(1, (now - sinceAppear) / 0.9)`：合成时对整幅画面做 `mix(0.3, 1.0, entrance)` 的曝光渐显（0.9 s）。
- `writeStart = appeared + 0.45`：笔落下前留 0.45 s 的天空显影时间；`rewrite()`（点问候语 / 空格 / 换字体）只把 `writeStart` 拨到 `now + 0.08`，天空不动。
- 书写推进由纹理 G 通道驱动（见 §3.1）：`reveal = (now - writeStart) / writeDuration` 对应 `0…phraseShare`（问候）与 `nameStart…1`（名字）——**没有逐字形动画、没有 `TextRenderer`、没有描边扫光**。

入场频率：`AtmosphereController.lastEntrance` 记录上次播放，30 分钟（1800 s）内切回页面只显示已完成的问候语（`skipEntrance()`）。

### 8.2 天气切换过渡

`Input.scene` 变化时，`AtmosphereRenderer` 把上一帧的场景记为 `fadeFrom`、新场景记为 `shownScene`，在 `weatherFade = 1.2 s` 内用 `SkyScene.mix`（对每个连续量做 smoothstep）插值；淡变期间 `boost(for:)` 让视图回到显示器满帧率。时刻变化不需要淡变——它本来就是连续量。

### 8.3 问候语常驻微动效

- **云影**：问候语着色直接乘 `(1 - cloud × 0.10)`，云层在字上留 10% 的影（§3.3）。
- **笔尖湿墨**：书写推进时笔后墨迹短暂提亮（`exp(-(front - g.y) × 30)`）。
- 换成字体时 `controller.rewrite()` 重写一遍（`typeface` 的 `.onChange`）。

### 8.4 视差（指针）

- 输入：`AtmosphereMTKView` 的指针跟踪区，归一化到 `pointerNormalized ∈ [−1, 1]²`（`Input.pointerNormalized`）。
- 偏移：`target = SIMD2(-x × 24, -y × 14)` pt，每帧平滑 `parallax += (target - parallax) × (1 - exp(-dt × 7))`——一阶低通，等价于约 0.14 s 的时间常数。
- 各层的视差系数见 §5.2；问候语取 `par × 0.4`，玻璃雨滴用指针位置做"擦掉"（`wipe = smoothstep(36, 80, length(pt - pointer))`）。

### 8.5 点击与键盘

| 手势 | 行为 |
| --- | --- |
| 点击问候语 / 空格 | `rewrite()`：把笔重新落下写一遍；`sensoryFeedback(.alignment)` |
| 点击天空其余位置 | `controller.ripple(at:)`：一圈光的涟漪（着色器里 `exp(-((d - R)/16)²)` 的环形偏移 + 提亮，`age` 超过 1.1 s 结束），涟漪的光色按场景（雨 / 雪 / 夜 / 日间）取一档 |
| ← / → | `adjustSky(by: ∓3600)`（自动）或 `nudgeManual(∓60)`（手动），`sensoryFeedback(.levelChange)` 按跨过的小时触发 |
| Esc | 清除 pinned day / `returnToNow()` |
| 拖动天空 | ±12 h 预览（见 §5.6），松手后 `returnToNow()` 0.75 s 三次缓出 |

预报表的悬停（`hoveredDay`）与窗台胶囊的展开各自有独立的短延迟（`SillChip` 140 ms 驻留），不在 Metal 层。

---

## 9. 状态矩阵（时段 × 天气）

表内记号：☀ 太阳可见度、☾ 月亮与星空可见度、☁ 云覆盖、✎ 问候语材质变化。每格只写实现里能指到机制的事（`SkyScene.looks` 的 cover / darkness / clarity 与 `weather` 的降水表、`sunColor` 的色温、云层的光照模型、`glassDrops` / 底片）。

| 时段 \ 天气 | 晴 | 多云 | 阴 | 小雨 | 大雨 | 雷暴 | 雪 | 雾 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **深夜** | 满星空 + 月相；问候语按 `prefersDarkInk` 取白墨 | 星空按 `starClarity = 0.65` 减半，月亮在云隙间透光 | 无天体，云底取 `nightBellyTop` 的冷灰 | 细底片雨，玻璃雨滴 `drops = 0.55` | 粗底片 + 玻璃雨滴 `drops = 1` | 闪电照亮云体（`lit = 0.08 + …`），云底提亮 | 雪底片在暗夜空反出微光 | 月亮成柔光斑（`u.moon.w` 低），雾在下半部最浓 |
| **黎明** | 关键帧在 `night`→`dawn`（−18°→−11°）之间，地平线转紫粉 | 同关键帧，另叠 `dayTint` | 灰紫，天体被 `clarity = 0.28` 压低 | 冷灰蓝雨丝 | 深灰，雨速 `mix(210, 340, amt)` | 远处云内闪（`bolt` 未抽中 60% 时） | 雪 + 冷调地平线 | 高度雾（`fog = 1`）最浓 |
| **日出** | 太阳半径 ×(1 + 0.35 × lowSun)、色温 `#FF8A4C`→`#FFB86B`；边缘光最强 | 云边银边（`proxy` 项） | 地平线透出 `mix` 后的暖色 | 暖色被雾化（雾 0.28） | 仅地平线保留一丝暖色 | 暗色云底 + 暖色缝隙对比 | 雪花被低角度光染暖 | 太阳成橙色圆盘、无盘面细节（雾 1） |
| **上午** | 关键帧 `morning`，太阳 `#FFE3A8`→`#FFF6E0` | 云层按 5 octave 步进，银边随 `lightVis` | 均匀漫射（`darkness = 0.42`） | 近景虚焦雨丝从字前划过 | 雨速更快（`speed × (1 + thunder × 0.16)`） | 闪电通道 + 云底照亮 | 三层底片雪，`snow = 0.85` | 雾开始变薄（`fog` 由天气决定） |
| **正午** | 太阳最小最亮、`#FFF6E0`；`prefersDarkInk` 可能翻到深墨 | 云影在问候语上留 10% 影 | 最亮的灰（`exposure = 0.92`） | 雨丝最透明（细底片 α 低） | — | — | 高光雪（`exposure = 1.04`） | 雾最薄 |
| **午后** | 关键帧 `afternoon`，地平线米色 | 积云体积感最强（光线侧射） | 暖灰 | 雨后可能出现彩虹（§11） | — | 闪电通道频率与其余天气一致（无 ×1.3 一类加成） | — | — |
| **日落** | 太阳半径放大、色温 `#FFB86B`；天空粉橙 | 云被 `sunColor` 染成橙红 | 地平线一道暗红 | 暖色被雾化 | 地平线暗橙 | 橙色闪电背光 | 粉紫雪 | 太阳成暗红圆盘 |
| **黄昏** | 关键帧 `dusk`，蓝紫 | 云转为深紫剪影 | 深灰紫 | 城市光在湿底片上的冷反射 | 深 | 闪电在紫色天空中 | 蓝紫雪景 | 雾反射城市光，偏橙灰 |

---

## 10. 性能与无障碍

### 10.1 帧率与手段

帧率策略（`retime()` / `restingRate` / `skyDue`）见 §5.7。手段：

- 体积云画在**半分辨率**的 `skyTexture` 上，合成时由线性采样放大（同一 `MTKView` 的第二次绘制，不是 `.drawingGroup()`）。
- fBm 用预烘焙的 **256²** 可平铺噪声纹理（64 格）替代实时哈希；雨雪是启动时烘焙的底片；没有 CPU 粒子数组，玻璃雨滴也只是 shader 里的格子哈希（`glassDrops()`），没有每滴状态。
- 着色器只省必然为零的计算：星点距像素 > 24 pt 直接跳过，地平线以下不采样卷云 / 云层噪声。

### 10.2 降级梯度

| 条件 | 措施 |
| --- | --- |
| 窗口不可见（`occlusionState` 不含 `.visible`）或不在活跃页 | `isPaused`、`enableSetNeedsDisplay`，不绘制 |
| 低电量模式 / 热压力（`isLowPowerModeEnabled`、`thermalState ≥ .serious`） | 云层 15 Hz；交互（笔 / 淡变）时 30 Hz；静止帧率 `min(resting, 15)` |
| Reduce Motion | 走 `AtmosphereStill`（`snapshot()` 的一次性 `CGImage`，输入 / 尺寸 / 缩放不变就不重绘） |

### 10.3 Reduce Motion

- 天空改为 `AtmosphereStill` 的静帧（同一渲染器的快照，`lightning(still:)` 用固定闪电，雷暴静帧每次一致）。
- 书写入场、涟漪、视差不播放：`Input.reduceMotion` 为真是 `writing` 恒 false，`rewrite()` / `ripple()` 的调用点也先看 `reduceMotion`。
- 数字与图形过渡：`reduceMotion ? nil : …` 的 `withAnimation` 直接落到终值（`UsageAnalyticsSection` 与 `SunPath` 等同一约定）。

### 10.4 Reduce Transparency / 对比度

- Reduce Transparency：`SillGlass` 改不透明填充 `#141B28`（窗台与右上 HUD）。
- 问候语的可读性由 shader 自身的遮罩（§3.3 的 `shadeAmt` 与 `darkInk` 切换）保证：`prefersDarkInk` 在天空亮度越过 0.18 时把墨色从白转为深海军蓝（`inkDark = (0.08, 0.12, 0.2)`），不是靠外部遮罩层。

### 10.5 缩放

macOS 没有 Dynamic Type。问候语字号由 `GreetingTypesetter` 在自由带里二分求解（§3.2），卡片变窄时字号随之收缩；名字 18–28pt。文字大小辅助设置不改变这张卡的字号——它是按可用的几何空间排的。

### 10.6 VoiceOver

- 背景全部 `accessibilityHidden(true)`（`AtmosphereSurface` 与 `FallbackSky` 都如此）。
- 读序：问候语 + 名字 → 时间日期 → 天气 → 窗台各项。
- 天空上的拖动/键盘操作保留 `accessibilityAction`（"前一小时" / "后一小时" / "回到现在"，`scrub` 为真时可用）。

---

## 11. 场景联动（读数据触发的天象）

三件按真实数据 / 日期触发的事，都不是随机：

1. **彩虹**：`GreetingCard` 的 `.onChange(of: reading?.sky)` 在「上一次是雨 / 毛毛雨 / 雷暴，这一次是晴 / 少云」时置 `rainbowUntil = now + 1800`（30 分钟）；`rainbowVisible` 再要求太阳高度在 3°–42° 且当前 `scene.rain == 0`。着色器把弧心放在太阳的反方向（`anti = (1 - sun.x, …)`），主带在离弧心 `40.3°` 处（`band = (rr - 40.3) / 2.4`），只画地平线以上（`uv.y < HORIZON`）。
2. **流星雨**：`SkyEvents.meteorShower(on:in:)` 认象限仪座（1/3–4）、英仙座（8/11–13）、双子座（12/13–14）的峰值夜；命中时流星间隔从 `70–160 s` 收紧到 `12–40 s`，其余条件（晴夜、`starVisibility > 0.5`）不变。
3. **月相**：`SkyScene.moonPhase` 直接来自 `SkyAstronomy.snapshot`，驱动月亮盘的明暗分界（§5.5）；没有单独的月晕 / 满月彩蛋——`GreetingPhrase` 里 `full moon` 只作为中秋等节日的文案存在。

## 12. 实现状态

本文只覆盖已在 `Sources/ClaudeBar/Views/Shared/Atmosphere/` 与 `GreetingCard.swift` 中可验证的机制。设计早期提出但没有进入实现、也不再计划的内容——问候语印章、环境声、初雪的霜花、"时光漫游"的长按时间轴、`MeshGradient` 降级、god rays、`TiltSource` / CoreMotion 预留、逐字形入场——已从本文移除；如未来要做，应以新的设计说明重新提出。

预览验证：`Tools/render-greeting-preview.py`（静态预览，参数见脚本）与 `Tools/bench-atmosphere.py`（帧耗时）。预览只覆盖渲染出的记录与窗口尺寸，不执行应用生命周期或真实天气刷新。
