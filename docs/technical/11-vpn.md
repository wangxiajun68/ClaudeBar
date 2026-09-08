# VPN（mihomo sidecar）

> ClaudeBar 技术文档 · §11
> 相关：设计文档 [产品概述](../design/01-product-overview.md) · [文件结构](../design/07-file-structure.md) · 技术文档 [构建](01-tech-stack.md)

VPN 页把 **mihomo**（Clash Meta）作为本机 sidecar：生成 runtime YAML → `mihomo -d <dir> -f config.yaml` → 用 REST 控制器切节点、测延迟、读流量。订阅 token **只写用户目录**，不要提交到仓库。

## 进程与端口

| 项 | 值 |
|----|----|
| 内核 | 构建时拷入 `Resources/mihomo-core`，运行时复制到工作目录 `mihomo` |
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
| 菜单栏 popup | `VpnChromeCluster`（仅 popup：启停、选节点、测速/连通）；VPN 运行时 status item 显示双行 ↓/↑（`VpnMenuBarRateView`） |
| 主窗口 | **不**重复 popup 的 VPN chrome |

菜单栏模板图标由 `MenuBarMark` 矢量绘制。仓库里的 `MenuBarIcon.png` 带不透明底，`isTemplate` 后会整块变白，status item **不要**再当模板 PNG 用。

## 构建

见 `Sources/build.sh`：`vendor/mihomo/` 拉取 darwin-arm64，拷为 `Resources/mihomo-core`。

| 变量 | 行为 |
|------|------|
| （默认） | 尝试下载最新 / 钉版本内核 |
| `MIHOMO_SKIP_DOWNLOAD=1` | 不访问 GitHub，使用已有 `vendor/mihomo/mihomo` |
