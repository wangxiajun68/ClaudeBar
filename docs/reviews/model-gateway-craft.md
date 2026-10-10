# Auto 模型池原生工艺审阅

日期：2026-10-10。独立 Impeccable finish reviewer；普通细化，继承系统圆体和冰色／石墨身份。未编辑产品源码、构建、启动应用或执行网络／VPN／真实配置操作。

审阅依据：PRODUCT.md、DESIGN.md、docs/design/surfaces/providers.md、C 路由拓扑参考 `.impeccable/mocks/gateway/map.png`、指定八个生产／预览源码，以及 `.impeccable/review/gateway-craft` 的 19 张原生截图、native.log 和 evidence.json。未提供单独 QUALITY BAR 卡，按现有设计规范判断。原生界面无 HTML/CSS detector。

## 初次审阅

Disposition: **fix**。

### persistence

Pass。产品、视觉身份、用户选定的 C 拓扑、请求驱动动画和导入流程均有持久文档；截图明确标记示例数据。八个源码哈希与提供证据匹配。

### fidelity

| 元素 | 判定 | 依据 |
| --- | --- | --- |
| TYPE | match | 系统圆体标题、系统正文、模型 ID 等宽字体符合既有身份。 |
| MATERIAL | match | 原生卡面、凹槽控件、连接端口、Core Animation 流动符合既有语言。 |
| GROUND | match | 浅冰／石墨画布符合 DESIGN.md。 |
| 请求 → 档位 → 模型 | match | 固定档位、实际成员连线、选中检查器和分页成立。 |
| C 图密集检查器／表格 | adaptation | 表面规范明确使用紧凑检查器和懒加载列表，保留功能与阅读顺序。 |
| 导入／发现／编辑 | match | 选择状态、上下文核对、固定提交区、保存成功才关闭有对应生产逻辑。 |
| 元数据可读性 | contradicted | 不支持能力整体淡化；发现卡小字与凹槽底色对比不足。 |

### ceiling

端口不位移、选择框与整行联动、统一档位控件、紧凑发现网格及深色主要按钮文字均达到本次局部精度要求；元数据对比度阻挡交付。

### material_fixes

1. 修正能力和发现卡元数据对比度：不支持能力原 50% 透明度约为浅色白卡 2.01:1／深色卡 2.71:1，属于信息而非禁用控件。发现卡 `#6E6E73` 小字在 `#E6ECF4` 上约 4.27:1。保留不支持语义、帮助和辅助功能标签，文字达到 4.5:1，图标达到 3:1。

### keep

保留请求驱动流动、固定端口、冰色／石墨表面、紧凑网格、明确选择状态及成功保存才关闭的边界。

## 修正后的 verdict pass

### verdict

- **Resolved：元数据对比度。** 同一 19 张截图已重截并逐张检查有效性；最终八个源码哈希再次匹配。能力图标／文字不再整体淡化，不支持图标有可见斜线，文字保留删除线，help 和 accessibilityLabel 保留。发现卡模型 ID／“上下文”采用相同局部文字色。`Theme.textPrimary.opacity(0.72)` 的标准 sRGB 混合对比度为浅色凹槽 6.16:1、白卡 6.72:1、深色凹槽 9.19:1、深色卡 7.61:1，满足所列文字与图标阈值。
- 修正批次未引入可见布局／语义回归。此轮仅评分上述一个材料修正，未重新搜索其他问题。

### remaining

Clear。Disposition: **ship**，覆盖本次列出的元数据对比度修正。

## 验证证据与范围

- 修正前：隔离快照 `make test` 的 100 个回归组通过，770.31 秒；dev／release 构建、bundle／Widget／URL scheme／entitlements／签名检查通过，未安装或启动。
- 修正后：19 张当前源码 NSHostingView 合成截图；原生探针再次通过空闲、流动、输出返向、完成／失败脉冲、减少动态效果及 detach 生命周期；200 模型 viewport 挂载 3 个 row body，12 次输出更新重绘 0 个列表 row body。最终 dev／release 构建均已通过，bundle／Widget／URL scheme／entitlements／签名再次验证；网关专项 `make test TEST=free-model-gateway` 通过，71.33 秒。未安装或启动。
- 截图是原生生产组件配合合成数据的离屏渲染。真实推理、键盘运行时、VoiceOver 运行时及完整应用窗口操作未验证；构建／探针通过不代表这些流程已通过。未运行 VPN、硬件控制或读取真实凭据用于截图。

文档核对完成：局部供应商表面规格与最终源码一致，八个源码指纹匹配；保留既有 DESIGN.md 与原先缺失的 sidecar，本次普通细化未修改全局视觉系统。
