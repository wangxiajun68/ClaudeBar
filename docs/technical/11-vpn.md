# VPN（mihomo sidecar）

> ClaudeBar 技术文档 · §11
> 相关：设计文档 [产品概述](../design/01-product-overview.md) · [文件结构](../design/07-file-structure.md) · 技术文档 [构建](01-tech-stack.md)

VPN 页把 **mihomo**（Clash Meta）作为本机 sidecar：生成 runtime YAML → `mihomo -d <dir> -f config.yaml` → 用 REST 控制器切节点、测延迟、读流量。订阅 token **只写用户目录**，不要提交到仓库。

## 进程与端口

| 项 | 值 |
|----|----|
| 内核 | 构建时拷入 `Resources/mihomo-core.xz`（13 MB，原始二进制 54 MB），`VpnManager.extractBundledCoreIfNeeded` 首次启动时用 `XZArchive` 解压到工作目录 `mihomo`；完成标记存压缩档大小，内核没变则不重解 |
| 工作目录 | `~/Library/Application Support/ClaudeBar/vpn/` |
| mixed-port | 默认 `7890`（`AppPreferences.vpnMixedPort`） |
| 控制器 | `127.0.0.1:9097`，`secret` 来自偏好 |
| 日志 | `vpn.log`（应用）· `core.log`（内核 stdout/stderr） |
| 订阅列表 | `vpn/subscriptions.json` |

`VpnManager` 启动：写配置 → spawn → 轮询 `/version` 直至就绪 → 开 `/traffic` NDJSON 流 + `/connections` 快照。系统代理与 TUN DNS 由 `VpnSystemProxyController` / `VpnTunDnsHelper` 处理，不在内核进程内完成。

## HTTP 客户端

`VpnHTTP.session()` **不走系统代理**。控制器 API 若再经 mixed-port 转发会死锁。UA 对齐 Clash Verge（`clash-verge/v2.4.3`），便于机场返回 `subscription-userinfo`。

## 配置生成（`VpnConfigBuilder`）

`VpnSubscriptionStore` 拉订阅 YAML 后：

1. 去掉与 ClaudeBar 冲突的顶层键（`mixed-port`、`external-controller`、`ipv6`、`tun` 等），避免 YAML 重复键导致内核 fatal。
2. 写入固定 header：`ipv6: false`、`unified-delay: false`、`tcp-concurrent: true`、`keep-alive-interval: 15`、`keep-alive-idle: 600`、本机控制器。
3. `tuneForStability`：url-test 的 `gstatic` 改为 `http://cp.cloudflare.com/generate_204`；`interval` 180→600、300→900；DNS `ipv6` 关闭；bootstrap 去掉 Google IPv6 / `8.8.8.8`（改 `223.5.5.5`）。
4. 非 TUN 时把 `listen: :53` 改到 `127.0.0.1:53553`（免 root）。

无效 CIDR（如 `skip-auth-prefixes: [127.0.0.1]`）不得写入，内核会直接退出。

## 延迟与主代理

- 测速 URL：`http://cp.cloudflare.com/generate_204`，超时 10s（与 Clash Verge 默认一致）。
- 主选择器优先名：`主代理`，否则 `GLOBAL` / `PROXY` 等（`VpnManager.primaryGroupNames`）。
- 大组（50+ 叶子）**分批 6 个**测速，避免一次打满出口导致假超时。

## 出口超时自动切换

`startPolling` 从 `core.log` 当前 EOF 起读。约 25s 内对**当前叶子节点 `server`** 出现 ≥6 次 `i/o timeout`，则把主代理切到延迟最好的 HY2，其次 KR。60s 冷却。

## 系统代理

`networksetup` 写 HTTP / HTTPS / SOCKS → `127.0.0.1:<mixed-port>`。

- 先关 PAC / 自动发现，再 `setwebproxy … off`（无认证）。
- 回读看 **Wi-Fi / Ethernet**（`preferredServices`），不用 `listallnetworkservices` 第一行（常为 Thunderbolt Bridge）。
- `VpnProxyGuard` 每 10s 检查，被别的 App 清掉则重写。

## 连通性

`VpnNetProbe`：Apple / GitHub / Google / YouTube，以及 ChatGPT / Claude / Gemini。探测请求同样不走会绕回自身的错误代理会话。

## UI

| 表面 | 内容 |
|------|------|
| 主窗口 **VPN** 页 | `VPNView`：开关、节点宫格、测速、订阅（`VPNSubscriptionSection`）、日志 |
| 菜单栏 popup | `PanelHeader` **状态行**的 VPN 药丸 `VpnStatusPill`（节点 + 延迟，点击打开 `VpnNodePickerPanel`：选节点、测速）——它是一条连接状态而不是一种模型，所以不占切换行的格子；status item 上常驻图标 + 双行 ↓/↑ + 电池格（`VpnMenuBarRateView`，宽度由布局常量推导；电池格是 34×21 的无正极头胶囊，φ²∶1 ≈ 1.618∶1，比例见 `batteryGlyphWidth` 的注释） |

status item 上三种读数都**不依赖隧道**：电池是这台机器的电量，↓/↑ 是这台机器的吞吐（`SystemThroughput`，读各网卡 `if_data`），两者隧道关闭时照常显示。隧道改变的是**速率来自谁、画成什么颜色**：运行时用 mihomo `/traffic` 自己的计数并画成绿色（绿=「走隧道」），停止时用系统总吞吐画成静息的白色（白色数字配绿顶会声称有流量在走代理）。工具提示写明「隧道速率 / 系统速率」。见 `tickVpnRate` 的注释。
| 主窗口 | **不**重复 popup 的 VPN chrome |

菜单栏模板图标由 `MenuBarMark` 矢量绘制。仓库里的 `MenuBarIcon.png` 带不透明底，`isTemplate` 后会整块变白，status item **不要**再当模板 PNG 用。

## 构建

见 `Sources/build.sh`：`vendor/mihomo/` 拉取 darwin-arm64，打成 `.xz` 拷进包内。压缩档同时**提交在仓库里**
（`Sources/ClaudeBar/Resources/mihomo-core.xz` 与同目录的 `.version`），发布构建直接复用、不再跑一遍 LZMA；
版本对不上时自动重打（打出来的一定是当前 vendored 的内核），打完会提示提交。没有 `xz` 且没有归档时退化为内置原始二进制。

| 变量 | 行为 |
|------|------|
| （默认） | 尝试下载最新 / 钉版本内核 |
| `MIHOMO_SKIP_DOWNLOAD=1` | 不访问 GitHub，使用已有 `vendor/mihomo/mihomo` |
