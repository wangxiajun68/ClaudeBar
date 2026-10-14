# 外接屏 A · Focus deck 验证

用户选择 A 并要求凸显设计感、打磨细节。批准稿与提示词保存在 `.impeccable/mocks/external-console/a-focus.png` 及其 JSON sidecar；规格见 `docs/design/surfaces/notch-island.md`。

## 落地

440×48pt 收起条与 440×184pt 详情共用标题栏；银白外沿、深靛蓝显示面、银色用量底沿。前三个真实会话入口和全部会话菜单切换单个焦点任务，按 ID 保持用户选择。待确认数量定位等待会话，橙色动作返回原客户端处理确认。无会话、长项目名、双币费用有独立呈现。工作台入口在未激活的收起屏幕也有效。

所有文字、按钮、图形都是生产 SwiftUI。无背景模糊、装饰动画时钟、外接忙碌旋转和数字滚动；保留固定宿主窗口、缓存命中路径、共享数据模型、减少动态效果及外接点击展开后无关闭轮询的边界。

## 已验证

- 生产视图合成夹具原生渲染：收起、悬停、提醒、展开、空会话、长名称待确认和双币费用，浅深桌面背景。结果在 `.build/island-preview/`。
- 冻结源码快照的 `make test`：105 组全部通过，820.54 秒。
- 最后修复收起工作台入口后，补跑 `island-display island-coalescing waiting-notify`：3 组通过；等待提醒 31/31。覆盖工作台通知、跨屏、悬停、Esc、外部点击、透明角命中、断开转移、计时器释放。
- 最终控制器夹具测量：100000 次缓存命中约 129ms，100000 次双屏空闲指针检查约 676ms；这是隔离夹具数据，不等同于实机 CPU 或 GPU 耗电结论。
- 最终开发与正式构建均通过，包括主应用、Widget、URL scheme、entitlements 与签名检查。日志为 `.build/focus-deck-final-build-dev.log` 和 `.build/focus-deck-final-build-release.log`。
- 开发与正式构建使用 `.build/focus-deck-verification` 的冻结源码，避开其他任务同时修改源码导致的编译中断。未安装或启动正式版。

## 人工验证边界

原生渲染和隔离控制器测试不覆盖真实显示器拔插、合盖、混合 DPI、全屏 Space、VoiceOver 的完整操作与实际前台应用的焦点恢复。这些仍需实机操作；未运行 VPN、硬件或系统代理端到端测试。

## 第二轮：悬停直开与信息精调

按用户追加要求移除 peek 状态与“点击展开”引导。外接屏停留 160ms 直接进入完整详情，离开 250ms 收起；展开不夺取键盘焦点，菜单跟踪期间保留面板。原有点击入口作为键盘和辅助功能的补充路径保留。

详情调整为 440×212pt，主舞台始终显示项目与实际活动；增加真实模型及上下文占用，未知显示 —。顶栏明确显示总会话数、运行数或待确认数。选中使用灰蓝、运行使用低饱和绿，等待处理与上下文达到 80% 使用橙色；底栏降低亮度。今日 Token 与估算费用保持可读，完整统计继续放在工作台。

生产渲染覆盖收起、展开、提醒、空会话、长项目名和混合货币。相关回归 `island-display island-coalescing waiting-notify render-preview` 四组通过；新一轮完整验证日志在 `.build/focus-hover-*.log`。

底栏文字加深为 #3D4D64，在较暗银色边缘 #B3C0D0 上对比度约 4.65:1；深蓝显示面次要文字约 8.03:1。

第二轮最终验证：105 组完整回归全部通过；最终 dev/release 构建、主应用及 Widget 的身份、entitlements 与签名全部通过。对应日志 `.build/focus-hover-full-tests.log`、`.build/focus-hover-dev.log`、`.build/focus-hover-release.log`。未安装正式版，真实屏幕与菜单操作仍需实机体验。
