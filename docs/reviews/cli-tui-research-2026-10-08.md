# MTX 持续展示与交互式 TUI 调研

调研日期：2026-10-08。外部资料通过 `http://127.0.0.1:17890` 获取；只读取官方文档、项目源码和 GitHub 发布元数据。未安装框架、启动 VPN 或改动应用实现。

## 判断

MTX 当前的 watch 是基础实时面板：每次清屏重画，内容超过终端高度时裁剪，没有读取键盘或鼠标事件，也没有独立的滚动与选择状态。`-p` 追加输出解决的是终端历史查看，适合日志和管道。

更适合持续监控与操作的是交互式 TUI：固定状态栏、可滚动主体、稳定的选中项、搜索筛选和详情区域。底层仍可用终端备用屏幕；滚动由应用维护自己的视口。关键的体验指标是数据更新时不抢浏览位置，以及输入不必等待下一次采样。

## 方案比较

| 方案 | 已核实能力 | 接入 MTX 的成本与判断 |
| --- | --- | --- |
| Bubble Tea v2 + Bubbles | 声明式 View、单元格渲染、键盘与鼠标事件；viewport 组件有滚轮和滚动偏移；渲染器在终端支持时使用同步输出 | Go 实现，需要增加 Go 构建链并维护与 Swift 后端的边界；交互模式很值得参考 |
| Ratatui | 布局与组件；绘制到双缓冲，比较前后帧后仅输出差异；逻辑上每次生成界面不等于物理清屏 | Rust 原生实现，需要额外构建链；适合需要较多复杂组件时使用 |
| Textual | 滚动容器、固定栏、表格、焦点、鼠标与键盘；终端与浏览器均可运行 | 直接采用会引入 Python 部署与运行环境；可参考交互设计，本项目不优先采用 |
| SwiftTUI | SwiftUI 风格状态、ScrollView、焦点、颜色和基础组件 | README 使用 Swift Package 集成；GitHub 元数据本次返回的最近 push 是 2024-07-09，活跃度及组件完整性需进一步核对，不建议直接作为默认依赖 |
| 现有 Swift CLI 演进 | 保留现有模型、CLIFrame、终端宽度与字符清洗逻辑，增加事件循环、视口状态和差异绘制 | 最符合目前无 Swift Package、无新增运行依赖的项目约束；需自行验证输入、Unicode 和终端兼容性 |

本次 GitHub latest-release 接口返回：Bubble Tea **v2.0.10**（2026-09-24）、Ratatui **ratatui-v0.30.2**（2026-06-19）、Textual **v8.2.8**（2026-06-30）。这是调研时的发布信息，不表示未来自动追踪这些版本。

来源：[Bubble Tea](https://github.com/charmbracelet/bubbletea)、[v2 升级说明](https://github.com/charmbracelet/bubbletea/blob/main/UPGRADE_GUIDE_V2.md)、[viewport API](https://pkg.go.dev/charm.land/bubbles/v2/viewport)、[同步输出源码](https://github.com/charmbracelet/bubbletea/blob/main/cursed_renderer.go)、[Ratatui Terminal](https://docs.rs/ratatui/latest/ratatui/struct.Terminal.html)、[Textual 布局](https://textual.textualize.io/guide/layout/)、[Textual 输入](https://textual.textualize.io/guide/input/)、[SwiftTUI](https://github.com/rensbreur/SwiftTUI)。

发布依据：[Bubble Tea v2.0.10](https://github.com/charmbracelet/bubbletea/releases/tag/v2.0.10)、[Ratatui 0.30.2](https://github.com/ratatui/ratatui/releases/tag/ratatui-v0.30.2)、[Textual v8.2.8](https://github.com/Textualize/textual/releases/tag/v8.2.8)。

## 推荐的 MTX 交互

建议默认继续使用 Swift，将 `mtx -w 1` 升级为有状态的交互式面板。保留现有 CLI 指令、JSON 和纯文本路径，后台模型与私有控制通道继续复用。

- 顶部固定：MTX 标识、简洁问候、天气、时间、模式、数据时效及 CPU / GPU / 内存摘要。小终端折叠大字，给主体更多空间。
- 主体分页：总览、会话、模型、VPN、连接器；每个页面独立保存滚动位置和选择。
- 会话表以稳定 ID 锚定选中项。新数据到来时保持当前浏览行，移除的记录选择相邻行；用户主动操作时才跟随新记录。
- `↑↓ / j k` 移动，`PgUp/PgDn` 翻页，支持时用滚轮或触控板滚动；`Tab` 切换区域，`/` 搜索，`Enter` 打开终端内详情。
- 空格冻结当前视图，后台仍继续采样；恢复时显示最新快照。底栏明确标记冻结状态，不能把冻结数据当成实时值。
- CPU、网络等保存有界的内存历史并绘制微型曲线，避免无限追加或引入常驻数据库。
- 数据采样与输入响应独立调度。1 秒数据间隔不应让按键等待 1 秒，也无需让整个界面无条件以高帧率持续绘制。
- 只输出变化的行或单元格。终端支持同步输出时可将一帧更新原子呈现，不支持时走普通差异绘制。
- 模型切换、VPN 和连接器操作复用已有控制通道，异步执行并显示结果；watch 的周期刷新本身不重复任何写操作。
- `q / Ctrl-C` 退出 TUI并恢复终端；SIGTERM、错误退出和缩放也必须恢复光标、输入模式与鼠标报告。

视觉上保留 Matrix 的深色基调和青蓝、琥珀、紫色状态色，用固定层级、选中行和细微状态变化组织信息；控制装饰性动画，避免影响滚动与资源监控。

## 兼容性与验证

SGR 鼠标报告与滚轮编码是现有终端协议能力，但能否得到鼠标事件取决于终端及配置。必须保留完整键盘操作，并提供鼠标开关以便恢复终端原生选择和复制。不能承诺所有终端都具备相同的触控板、鼠标或同步输出体验。协议依据：[XTerm 控制序列](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)。

本机 SDK 存在 ncurses 头文件与链接接口；ncurses 的虚拟屏幕及 `doupdate` 可以做差异更新，但 SDK 接口存在并不等于已经验证滚轮、emoji 或所有终端兼容。若选择该底层，需要先做小型验证。依据：[ncurses 刷新机制](https://invisible-island.net/ncurses/man/curs_refresh.3x.html)、[鼠标接口](https://invisible-island.net/ncurses/man/curs_mouse.3x.html)。

实施前建议验证：Terminal.app、iTerm2、Ghostty 和 tmux；中文/emoji 宽度、窄窗口、缩放、数据更新时锚点保持、鼠标报告开关、Ctrl-C/SIGTERM 恢复、输出闭管，以及 dev/release 控制限制。资源成本需要测量后评估，本调研没有进行框架运行性能对比。
