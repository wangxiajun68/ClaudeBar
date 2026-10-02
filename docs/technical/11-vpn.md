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

## 流量日志（域名）

`log-level: info` 是固定写入 header 的，所以**每条新建 TCP 连接内核都会写一行**，VPN 页的「流量日志」把这一行变成域名、规则与出口。两种形状（`core.log` 实测 13 898 行中的 11 760 走代理 / 2 138 直连 / 0 拒绝，直连里 443 次是 dial 失败）：

```
level=info    msg="[TCP] 127.0.0.1:49701 --> api2.cursor.sh:443 match Match using 🐟 漏网之鱼[1 官网 tcp.bet]"
level=warning msg="[TCP] dial 🎯 Direct (match GeoSite/CN) 127.0.0.1:49287 --> wetype.weixin.qq.com:443 error: dns resolve failed: …"
```

- **入口是管道不是文件**：`spawnProcess` 的 `readabilityHandler` 把同一份字节同时给 `CoreLogWriter` 和 `VpnDomainLog`。读文件要自己管偏移，而 `CoreLogWriter` 到 8 MB 会把文件重写成尾部 —— 流式回调天然没有这个问题，也让页面是实时的。
- **必须同时有 `time="` 与 `level=info`/`warning`**：ClaudeBar 自己的诊断也写进这个文件（`extractFatal` 认的 `listen tcp … address already in use` 就是 `level=error` 且没有时间戳），只看 `[TCP]` 会把它们当成连接。
- **出口末段决定归类**：`[DIRECT]`（含 `🎯 Direct[DIRECT]`）→ 直连，`[REJECT]` → 拒绝，其余→ 已代理；没有方括号时看最后一个空格分隔的词（裸 `DIRECT` / 裸 `🎯 Direct`）。有方括号时**只认方括号**，否则名字里带 REJECT 的节点会被误判成拦截。
- **按字节缓冲、只在 `\n` 切断**：分块边界可能落在多字节字符中间（真实日志里就有一条被切成 `官网 tcp.bet]"` 的残行），所以 `VpnDomainFeed` 收 `Data`、解码只在行完整时做。
- 解析在管道线程，主线程只收 ≤4 Hz 的合并发布；环形 1000 行，**只在内存**（`core.log` 本身仍是磁盘上的记录）。时间戳按位置切 `HH:mm:ss`，不建 `DateFormatter`，排序用到达序 —— 跨午夜不会让昨天的行排到今天后面。
- **两个口径分开写**：明细 / 汇总来自上面的日志行（没有字节数、不记 UDP，实测 0 条）；多出来的**「实时连接」**模式读内核 `/connections`，**有**上传 / 下载与进程名，但只列**此刻还开着**的连接——短连接会在两次采样之间结束，所以它是快照不是账本。面板里两张说明各写各的，不把 `—` 冒充成 0。`VpnManager.pollConnections` 落进 `VpnDomainLog.updateConnections`，隧道停时清空。
- 内核重启（改端口 / TUN / 换订阅）只丢掉死管道留下的半行（`resetCarry`），已解析的表保留 —— 那正是用户在看的。

## 系统代理

`networksetup` 写 HTTP / HTTPS / SOCKS → `127.0.0.1:<mixed-port>`。

- 先关 PAC / 自动发现，再 `setwebproxy … off`（无认证）。
- 回读看 **Wi-Fi / Ethernet**（`preferredServices`），不用 `listallnetworkservices` 第一行（常为 Thunderbolt Bridge）。
- `VpnProxyGuard` 每 10s 检查，被别的 App 清掉则重写。
- **绕过列表不是只有默认项**：`bypassDomains()` 在 clash-verge 那串默认值（全是地址与网段，**绕不过域名**）之外追加 `VpnProviderDirect.hosts()` —— 见下。

## 自建供应商的直连钉（`VpnProviderDirect`）

本机配置的供应商端点若是自建 / 只挂着自己域名的，它**在国内却命不中 `GEOSITE,CN`**，于是落进规则链末尾的 `MATCH`、走节点绕出国再绕回来。实测本机一条这样的端点每轮 26–41 MB 上下文全都这么走，而本机没有任何信号说这件事：内核的日志行写的是 `Direct`（写在 geosite 载入完成之前），端点 IP 也确实在中国——错的是**路由**，不是目的地。

两个入口都要堵，因为它们彼此独立：系统代理绕过列表（`setproxybypassdomains` 是 macOS 上唯一吃域名的绕过面，缺口正好在这里）与规则链（TUN 模式完全不理系统代理，任何自带代理设置的客户端也直接指向 mixed port）。两处读的是**同一份**从两份供应商表推出来的 host 列表，所以 UI 里新加的供应商在下次启动 VPN 时自动覆盖。

- 规则写成 `DOMAIN,<host>,DIRECT`（精确 host，不是 `DOMAIN-SUFFIX`：那是贴着一个虚拟域名的所有兄弟子域一起拖直连）。
- **插在 `rules:` 下第一条**，缩进抄 profile 自己第一条规则那一列——机场 profile 写列 0、手写 profile 缩进两格，假设任一种都会让内核在启动时死于 `Parse config error: yaml`（本机 1195 条规则的订阅实测过）。插在 `GEOIP,CN` 之后就是死文本，因为吞掉它的 `MATCH` 在链尾。
- **拒绝名单**：认不出的 host 一律钉直连——出问题的正是 geosite 没听过的自建 / 虚拟域名，形状和「一个假想的境外中转」无法区分。只有 `anthropic.com` / `openai.com` / `x.ai` / `openrouter.ai` / `googleapis.com` / `nvidia.com` / `lmstudio.ai` 被排除在外，因为把这几家钉直连会**直接把它们弄坏**。IP 字面量、`localhost` / `.local` / `.lan` / `.internal` 也跳过（前者已被 profile 的 IP 规则覆盖，后者是 macOS 本地解析、不经过内核 DNS）。
- 注入发生在 `tuneForStability` **之前**：那个函数改的是规则正文（bootstrap DNS、url-test 间隔），要让 pin 永远不是它可能匹配到的目标。

## 连通性

`VpnNetProbe`：Apple / GitHub / Google / YouTube，以及 ChatGPT / Claude / Gemini。探测请求同样不走会绕回自身的错误代理会话。

## UI

| 表面 | 内容 |
|------|------|
| 主窗口 **VPN** 页 | `VPNView`：开关、节点宫格、测速、订阅（`VPNSubscriptionSection`）、日志、流量日志（`VpnDomainLogSection`） |
| 菜单栏 popup | `PanelHeader` **状态行**的 VPN 药丸 `VpnStatusPill`（节点 + 延迟，点击切到主窗口 VPN 页选节点、测速）——它是一条连接状态而不是一种模型，所以不占切换行的格子；status item 上常驻图标 + 双行 ↓/↑ + 电池格（`VpnMenuBarRateView`，宽度由布局常量推导；电池格是 34×21 的无正极头胶囊，φ²∶1 ≈ 1.618∶1，比例见 `batteryGlyphWidth` 的注释） |

status item 上三种读数都**不依赖隧道**：电池是这台机器的电量，↓/↑ 是这台机器的吞吐（`SystemThroughput`，读各网卡 `if_data`），两者隧道关闭时照常显示。隧道改变的是**速率来自谁、画成什么颜色**：运行时用 mihomo `/traffic` 自己的计数并画成绿色（绿=「走隧道」），停止时用系统总吞吐画成静息的白色（白色数字配绿顶会声称有流量在走代理）。工具提示写明「隧道速率 / 系统速率」。见 `tickVpnRate` 的注释。
| 主窗口 | **不**重复 popup 的 VPN chrome |

菜单栏模板图标由 `MenuBarMark` 矢量绘制（`MenuBarController.swift` 里用贝塞尔现画，不需要图片资源）。

## 构建

见 `Sources/build.sh`：`vendor/mihomo/` 拉取 darwin-arm64，打成 `.xz` 拷进包内。压缩档同时**提交在仓库里**
（`Sources/ClaudeBar/Resources/mihomo-core.xz` 与同目录的 `.version`），发布构建直接复用、不再跑一遍 LZMA；
版本对不上时自动重打（打出来的一定是当前 vendored 的内核），打完会提示提交。没有 `xz` 且没有归档时退化为内置原始二进制（文件名不带 `.xz`，`VpnManager` 会按扩展名走直接复制那条路径）。

| 变量 | 行为 |
|------|------|
| （默认） | 尝试下载最新 / 钉版本内核 |
| `MIHOMO_SKIP_DOWNLOAD=1` | 不访问 GitHub，使用已有 `vendor/mihomo/mihomo` |
