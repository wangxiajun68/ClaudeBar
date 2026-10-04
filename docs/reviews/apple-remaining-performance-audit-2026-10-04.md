# 后续模块性能与生命周期审查 · 2026-10-04

本轮继续检查上一轮尚未闭环的命令面板、帮助文本、Widget、Cursor 额度和流量页生命周期，完成六项代码改动。源码入口清单覆盖 **244 个路径：238 个 Swift 路径（包括 Widget 快照符号链接）、2 个 C 文件、1 个头文件、3 个构建脚本**，共 83,390 行。清单是范围核对；不把入口扫描、隔离生产函数回归或历史实机观测等同于每条路径都已运行验证。

[逐文件清单](performance-remaining-source-2026-10-04.md) 与 [源码哈希和入口行号](performance-remaining-source-2026-10-04.json) 用于核对遗漏；[测量、实机摘要及验证结果](performance-remaining-audit-2026-10-04.json) 保留实验口径。之前的全模块审查、后端、动效与正式版记录见 [审查索引](README.md)。

## 苹果建议与本轮改动

- [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)：保持 body 快速，缓存昂贵计算，减少无关更新。本轮让命令结果只在查询或条目变化时准备，帮助页复用固定文本的 inline Markdown 属性。
- [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)：缩短主线程工作。已有 Widget 编码和写入仍由 utility 串行队列执行，取消后的异步回写增加请求所有权检查。
- [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)：刷新消耗系统资源，应仅请求必要更新，时间线条目间隔建议至少约五分钟。Widget 的 fallback 从请求 30 秒改为五分钟；宿主内容变化仍触发 reload。系统实际调度由 WidgetKit 决定。

| 模块 | 原问题 | 完成的改动与验证 |
| --- | --- | --- |
| 命令面板 | 每次 body、方向键、提交都重新筛选排序 | 缓存结果；稳定线性分区保持前缀优先及同组原序。验证 Unicode、大小写、空查询、标题/副标题匹配、选择保留与删除后的重选。 |
| 帮助页 | 重绘时重复解析固定 Markdown | 有 count/cost 限制的 NSCache 复用 AttributedString；主题样式继续由视图应用。全部真实帮助段落及粗体、代码、链接、转义、空白和损坏 markup 与原输出完全相等；并发读取、缓存填充后重读通过。首次解析仍需执行。 |
| Widget 发布 | JSON 对象键顺序不稳定，时间戳归零后仍可能误判内容改变 | 编码器启用 sortedKeys。1,000 次仅时间戳变化只发布一次；嵌套字段变化、force、权限开关、dev 闸和完整快照往返均通过。 |
| Widget 时间线 | 无新内容时仍请求 30 秒 fallback | 改为五分钟请求；真实 getTimeline 方法在隔离 provider 中验证 placeholder 与目标日期；未宣称系统实际刷新频率降低十倍。 |
| Cursor 额度 | 已允许访问时没有安装撤销观察；取消完成可回写旧值、清除新任务句柄、允许重叠请求 | start 始终观察权限变化；请求代次保护发布及 defer；完成时再检查取消与权限。可控 transport 复现旧请求晚到、新请求仍在途、撤销与重新授权，旧实现违反四项断言，新实现全部通过。 |
| 流量页 | 滚动结束回调可能在离开或离开后重进页面时回写旧流并重新解析 | 回调检查 mounted 和 loadGen。隔离执行真实回调，验证卸载、快速重挂载、当前批次与相同批次；旧实现违反两项断言，新实现通过。 |

Widget 编码开销并未变小：稳定排序带来少量 CPU 成本，收益是消除误触发的持久化和系统 reload。权限、版本隔离、原快照字段、生产业务刷新和安全 watchdog 均保留。

## 同输入生产函数对照

基线为 `1e186ea`，两臂 `swiftc -O`，交替执行三次，输入均为合成条目和快照；帮助正文来自仓库固定手册。无真实网络或配置，Widget 持久化与系统 reload 被替身截获。

| 指标 | 基线中位数 | 改后中位数 | 变化 |
| --- | ---: | ---: | ---: |
| 命令：10,000 条，3 次准备，每次 60 次选择更新、每次两次读结果 | 10,311.69 ms | 28.44 ms | 减少约 99.72% |
| 手册：所有正文 20 次热重绘的格式化准备 | 30.22 ms | 1.25 ms | 减少约 95.86% |
| Widget：1,000 次相同内容串行提交的编码/调度，模拟写入 | 9.56 ms | 10.39 ms | 增加约 8.6% |
| Widget：上述提交的发布次数 | 4 | 1 | 消除重复发布 |

原 JSON 键顺序取决于进程/编码器状态：独立预探针也出现过 1,000 次误发布，不能把“4 次”当作原实现的稳定上限。三次正式比较臂均为 4，改后均为 1。单元回归断言正确次数，不断言耗时或原版必须失败。命令数据是规模压力输入，不是用户当前实际条目数；上述收益不等于整页 FPS、整机 CPU 或电池寿命改善。

复现：

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools make test TEST="remaining-performance remaining-lifecycle"
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 Tests/remaining-performance-regressions.py \
  --compare --baseline-ref 1e186ea --output-json /tmp/claudebar-remaining-comparison.json
python3 Tools/performance-inventory.py --date 2026-10-04 --include-native-build
```

## 页面与模块范围核对

九个 AppPage 和六个设置分类全部在清单与既有审查内。下表把本轮重点复核、历史证据及仍需专门场景验证的路径分开；不以“没有新增改动”推断模块没有性能成本。

| 页面 / 模块族 | 本轮核对的入口、历史证据与处置 | 仍未闭环的真实场景 |
| --- | --- | --- |
| 概览、天气与问候 | Dashboard/Greeting、Weather/天空/Metal 与资源采样；沿用上轮 Metal、body、遮挡和原生图层证据 | 多显示器、睡眠唤醒、热降频及长时间 GPU/能耗对照 |
| 会话、三客户端、工作流和 Agent 树 | 尾扫描、恢复、标题/完成边缘、树缓存；上轮 ExternalSessionMonitor 修复及会话回归 | 真实大规模并发、全天监控和通知延迟 |
| 模型目录、连接编辑与快速配置 | ProvidersView 仅一次 facts；ProviderDirectory 的分区、过滤、稳定身份、懒布局；目录 body 历史观测及图标回归 | 巨量配置下真实搜索、导入/删除/激活及所有 sheet 的渲染；未执行真实凭据操作 |
| 用量、模型库存、价格/汇率及图表 | UsageProviderInventory 异步准备、UsageModelInventory 每次原名归一化缓存、花费/来源守恒；usage/index/analysis/价格回归 | 大量不同模型名的库存 body；网络价格更新与真实账期刷新 |
| 连接器、预览、MCP 与本地 CLI | 库存 off-main、计数缓存、串行 mutation actor；CLI 等待在 actor 工作路径，MCP 取消与 collector 回归 | 真实 MCP 工具清单、插件安装/移除和外部配置；未调用真实 app-server |
| 飞书目录、正文、表格、编辑与 WKWebView | 现有解析/表格回归；组件卸载取消 task、stopLoading、移除 handler；宿主上限 8 连接、8 KiB 头、5 秒期限；保留用户并行修改 | 真实鉴权、远端大文档、WebContent 进程内存和输入延迟 |
| 流量详情、访问日志、JSON/SSE、媒体与协议转换 | 后台解析、容量/尾行限制、单飞对话准备及 raw pane 取消；新增延迟回调卸载保护 | 大 payload 的完整渲染、持续串流与多请求滚动的实际帧时间 |
| VPN、订阅、节点、域名、速率和系统代理 | VpnHTTP 复用 session；域名分页/取消、轻量速率分离；已有 VPN 纯函数回归 | 未切换 VPN、DNS、TUN/代理或内核；频繁更换不同端口的 session 缓存规模未实测 |
| 设置六分类、偏好与权限 | 主壳仅关注必要字段，草稿/分类生命周期；BuildChannel 与权限入口闸、isolation/core 回归 | 未点击任何系统授权；外观/字体全部组合及配置落盘延迟 |
| 命令面板与帮助 | 本轮缓存及稳定结果对照；补录正式版打开、搜索、键盘移动与帮助首次文章 | 本轮新代码的已安装正式版交互复测；手册 cold parse 仍存在 |
| 菜单栏、popup 与资源仪表 | UIWakePolicy、ScopedStoreObservation、SystemThroughput 共享采样、菜单波形 detach/hidden/reduce-motion 停止；旧菜单/原生绘制证据 | 菜单栏被系统遮挡、全屏、popup 全部细节弹窗的 CPU 与 wakeup 对照 |
| 灵动岛和警报 | 展开 10 Hz tick 收起停止；鼠标捕获按变化写；卸载清 monitors；成本任务有代次、usage 单飞；保留后台提醒模型 | 真机展开/折叠、wings 设置组合、警报与后台索引的并发/能耗；成本旧任务只丢弃结果，未新增强取消 |
| CPU/内存/磁盘、联网、蓝牙与配件 | ProcessSampler 可见性订阅；PS/配件子进程后台；现有 process/audio/connection 回归 | 不触发定位/蓝牙授权；大进程表、睡眠恢复及磁盘挂载变化 |
| 充电、风扇、SMC 与 C 工具 | 模拟状态机、真实 C policy 与绘制回归；helper dev 闸、签名和独立 commandQueue；退出恢复同步等待保持原安全语义 | 未写硬件、安装 helper、运行真实充电/风扇控制；退出延迟另需专机测量 |
| 主题、按钮、阴影、字体、图标、JSON/code 与通用组件 | 源码入口全量列出；沿用原生绘制、稳定缓存、遮挡停播、七类动效生命周期与控件回归 | 所有交互/尺寸/深浅/Reduce Motion 组合和像素层面回归 |
| Widget 与共享快照 | 本轮稳定去重及时间线 spacing；旧解码兼容、palette、身份和符号链接检查 | 实际桌面 Widget 各实例的系统 reload 次数和 extension 内存 |
| 迁移、协议桥、终端、截图与通知 | 取消/容量/临时存储边界，终端 subprocess detached；迁移/桥/通知回归与历史记录 | 不复制真实凭据、不发起迁移、截图权限或通知；真实外部客户端验证另需授权场景 |
| 构建、压缩内核、签名与文件持久化 | 244 路径含 native/build；两个优化版本构建、输入指纹、固定内核、签名/entitlement/隔离检查 | 本轮仅构建，不安装或发布；发布包 gate/DMG 未运行 |

## Instruments 与验证边界

本轮开始时，用户已把正式版更新为另一二进制。重新确认 `/Applications/ClaudeBar.app` 1.15.0，单实例 PID **46863**，SHA-256 **cf251661c5aeee86f801b5617a7b89c0638c89a19620bc05a382e5d4cd0590a0**。本轮只 attach；没有退出、安装或启动该实例。历史报告中的 PID 732 / `efa154…` 是另一二进制，数据未混成前后对照。

补录 SwiftUI 65 秒，layout tracing 关闭；成功执行命令面板打开、输入合成查询、10 次方向键移动、关闭以及帮助页打开。后续文章切换遇到 CUA 检测用户改变界面，停止进一步操作；不把这次录制算作所有帮助文章、popup、灵动岛或 Widget 的测量。本轮新增修复没有安装到正式版，实机录制只补充覆盖证据。

原始 trace 和 XML 留在 gitignored 的 `.build/performance/module-audit-2026-10-04/`（目录 0700）；公开 JSON 仅保留项目视图名称与统计、合成测量和包身份。未发布会话、账户、用户会话路径、连接信息或原始 trace。上轮 hardened release 无法附加 Allocations，仍未证明没有堆泄漏；短时 footprint 也不作为长期内存结论。

- 全回归 **65 组通过，370.40 秒**；补充的最后两组定向回归通过。
- `make build` 与 `make release` 均成功；两版主程序、Widget、App Group 和执行文件身份隔离；entitlements 组一致，deep/strict 签名通过，快照符号链接正确。
- Python 编译检查、`git diff --check` 通过。最终源码 SHA-256 保存在测量 JSON，覆盖本轮七个生产文件。
- 实机补录共观察到 65 种项目视图类型：CommandPalette 38 次 body，最大 3.005 ms；CommandRow 429 次，最大 0.219 ms；HelpView 1 次 1.251 ms；HelpBlockView 2 次，最大 1.071 ms。样本包含 cold/交互场景，不能据此判断所有文章或新代码效果。hitches 表 1,435 行、p95 8.333 ms、最大 25 ms；它不是 FPS。Other Updates 计数是框架事件，不等于 App 重绘次数。
- 本轮起止正式版 PID/二进制哈希相同；未安装本轮产物、未重启应用，未调用真实系统集成。用户并行的飞书修改保留，未将其列作本轮性能改动。
