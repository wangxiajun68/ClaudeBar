# VPN 图表与性能审查 — 2026-10-11

范围是 VPN 页：实时速率、连接快照、日志查询、历史分析、节点与订阅面板。
保留原生 SwiftUI / Charts、冰白与石墨表面。全部数据来自合成夹具；没有
启动应用、VPN、系统代理或硬件控制，也没有读取正式版配置。

方法遵循 Apple 的 [SwiftUI 性能说明](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance)
与 [WWDC25 Instruments 会话](https://developer.apple.com/videos/play/wwdc2025/306/)：
先减少无关更新，再移出主线程上的非 UI 工作，使用生产源码测量。

## 实际发现和处理

| 严重性 | 发现 | 改动与证据 |
| --- | --- | --- |
| P1，已修复 | 趋势日期及小时选点状态属于整个分析页，每次鼠标移动都会重新构建全部兄弟区域 | 移入独立图表 View。120 次合成选点，累计、流向比较、小时图与排行原各执行 120 次；修改后均为 0，仅趋势图执行 120 次 |
| P1，已修复 | `/connections` 的 JSONSerialization 解码仍在 MainActor；注释声称后台处理，但后台只覆盖了行映射 | 从控制器取回 Data，在可取消 detached task 中执行完整解码、行映射和旧内核计数，返回 Sendable 快照。5,000 条 / 805,333 字节，原解码中位数约 7.37 ms 退出主线程 |
| P2，已修复 | 连续指针位置频繁写状态，即使仍在同一个时间桶 | 二分查找最近桶，仅桶改变时写入。千桶随机日期、边界、空集合及等距选择与线性独立 oracle 核对 |
| P2，已修复 | 选点后插入额外读数，使图表下方布局改变 | 检视读数始终占 24pt 固定高度，平时显示时段合计，选点时显示该桶 |
| P2，已修复 | 200pt 曲线只有很淡的填色，标题、图例和坐标主要用小号 caption | 260pt 蓝绿面积图，18pt 标题、13pt 图例、12pt 坐标，40pt 总量；138pt 配对条形与174pt渐变小时柱形。宽／窄与浅／深主题原生离屏检查 |

时间测量是诊断数据，不是 CI 速度门禁。相同离屏 NSHostingView、30 个趋势桶、
168 个小时桶和 3,000 个域名，120 次选点的初始测量为中位数 13.54 ms / P95
15.67 ms，修改后一次测量为 7.46 ms / P95 11.54 ms；测量包含 1ms 的
调度等待，且构建负载会影响结果。独立计数复核确认只有趋势自身更新。
**这些数值不能换算为实际显示帧率，也没有宣称前台 120fps。**

完整后台 decode + map 中位数约 32.32 ms；主线程最终 accumulator + equality
publication 在相同 5,000 条夹具上约 4.64 ms。后者保留同步所有权，避免清空、
停机及迟到快照的状态竞态；常见规模与真实前台帧截止线仍需 Instruments 实机
记录。数据刷新率与屏幕帧率独立，没有为提高数字而新增 60/120Hz 业务计时器。

## 检查过的其余路径

- `/traffic` 行解析已有后台泵；`VpnLiveRates` 4Hz 上限、单个等待任务、全零窗口
  停止发布。速率订阅隔离在实时条，`VPNView` 不观察速率对象；没有倒退成整页刷新。
- 日志使用 2,000 条固定 FIFO；每页最多 200 行。诊断查询、域名折叠和排序后台
  执行，查询取消、150ms 输入 debounce 与隐藏工作区 gating 已存在并保持。
- 节点和规则行使用 LazyVStack；分组排序缓存、文件预览后台读取、面板阴影
  Core Animation shadowPath 已存在。节点搜索和代理索引仍按节点面板更新构建，
  不由流量秒表驱动；未在没有测量证据的地方引入另一套列表／缓存架构。
- 历史读写和排序属于 archive actor，排行只绘制前20条；累计存储不因展示上限
  截断。历史刷新通过自己的 revision；隐藏流量工作区不请求新 report。
- 原始请求中所需的“流畅高帧率”最终要以真实显示器、前台滚动和面板转场测量；
  离屏 QA 覆盖本次依赖隔离和布局，不覆盖 WindowServer / GPU 帧呈现。

## 重现

```sh
python3 Tools/measure-vpn-ui.py --baseline-ref a56a4e2
python3 Tools/measure-vpn-ui.py
make test TEST=vpn-domain-log
make test TEST=vpn-traffic-history
python3 Tools/render-vpn-preview.py
```

快照解码回归还覆盖根计数、旧内核回退、显式空连接、坏 JSON、缺失连接数组、
负计数、Int64 饱和与取消。使用临时目录，不访问真实控制器。

完整回归和 dev / release 构建结果见本次交付记录；构建均禁止安装和启动。
