# VPN（mihomo sidecar）

> ClaudeBar 技术文档 · §11
> 相关：设计文档 [产品概述](../design/01-product-overview.md) · [文件结构](../design/07-file-structure.md) · 技术文档 [构建](01-tech-stack.md)

VPN 页把 **mihomo**（Clash Meta）作为本机 sidecar：生成 runtime YAML → `mihomo -d <dir> -f config.yaml` → 用 REST 控制器切节点、测延迟、读流量。订阅 token 只写用户目录，不要提交到仓库。

## 进程与端口

| 项 | 值 |
|----|----|
| 内核 | 构建时拷入 `Resources/mihomo-core.xz`（13 MB，原始二进制 54 MB），`VpnManager.extractBundledCoreIfNeeded` 首次启动时用 `XZArchive` 解压到工作目录 `mihomo`；完成标记 `core.stamp` 存压缩档大小，内核没变则不重解 |
| 工作目录 | `~/Library/Application Support/ClaudeBar/vpn/`（跟随 `BuildChannel.appName`，开发版是 `ClaudeBar Dev`） |
| mixed-port | `AppPreferences.vpnMixedPort`，默认取 `BuildChannel.vpnMixedPort`：正式版 7890 / 开发版 17890 |
| 控制器 | `127.0.0.1:9097`（`BuildChannel.vpnControllerPort`；开发版 19097），`secret` 来自偏好（空则随机生成 24 字符） |
| 日志 | `vpn.log`（应用）· `core.log`（内核 stdout/stderr） |
| 订阅列表 | `vpn/subscriptions.json`（列表与 profile YAML 在 `vpn/profiles/`） |

`VpnManager` 启动：写配置 → spawn → 15s 内轮询 `/version` 直至就绪 → 开 `/traffic` NDJSON 流 + `/connections` 快照（有可见窗口时 2s 一次，全隐藏时 10s；`/traffic` 是推送流、不降频）。系统代理与 TUN DNS 由 `VpnSystemProxyController` / `VpnTunDnsHelper` 处理，不在内核进程内完成。

副作用入口以 `BuildChannel.allowsSystemIntegration` 为闸：`startCore`、`applySystemProxyNow`、`setSystemDNSNow` 在开发版直接返回限制说明，不启动内核、不写系统代理或 DNS。

## HTTP 客户端

`VpnHTTP.session()` 不走系统代理。控制器 API 若再经 mixed-port 转发会死锁。控制器请求的默认 UA 是 `clash-verge/v2.4.3`；订阅下载直连，另按 `mihomo` / `clash.meta` / `ClashforWindows` / `clash-verge` 依次尝试：节点数 ≥ 8、且不比磁盘上的 profile 少 2 个以上的那份响应即采用（无旧节点数时只看 ≥ 8），都达不到时保留节点最多的一份；若它低于 `max(2, 旧节点数的五分之一)` 则按错误处理、不覆盖原文件，单节点占位响应一律丢弃。机场对不同 UA 下发不同的节点规模与 `subscription-userinfo`。

## 配置生成（`VpnConfigBuilder`）

`VpnSubscriptionStore` 拉订阅 YAML 后：

1. 去掉与 ClaudeBar 冲突的顶层键（`mixed-port`、`external-controller`、`ipv6`、`tun`、`listeners`、`authentication`、`skip-auth-prefixes` 等，含整块跳过），避免 YAML 重复键导致内核 fatal。
2. 写入固定 header：`ipv6: false`、`unified-delay: false`、`tcp-concurrent: true`、`keep-alive-interval: 15`、`keep-alive-idle: 600`、本机控制器（端口 + secret + CORS）。
3. `tuneForStability`：把 url-test 的 `gstatic` 换成 `http://cp.cloudflare.com/generate_204`；按固定缩进替换 `interval` 180→600、300→900 与 `ipv6: true`→`false`；删掉 `2001:4860:4860::8888` / `2400:3200::1` 两行，`8.8.8.8` 改 `223.5.5.5`。替换是文本级的，缩进与这些字面量不一致的 profile 不会命中。
4. 非 TUN（或不允许系统集成）时把 `listen: :53` / `0.0.0.0:53` 等改到 `127.0.0.1:53553`（免 root）。

`skip-auth-prefixes` 在去重与 sanitize 两处都被剔除，因此无效 CIDR（如 `[127.0.0.1]`）不会进入运行时配置。

## 延迟与主代理

- 测速 URL：`http://cp.cloudflare.com/generate_204`，超时 10s（与 Clash Verge 默认一致）。
- 主选择器优先名：`主代理`、`GLOBAL`、`PROXY`/`Proxy`、`代理`、`节点选择`、`🚀 节点选择`，都没有时退回第一个 `Selector` 组（`VpnManager.primaryGroupNames`）。
- 大组（叶子超过 12 个）分批 6 个逐个测速，避免一次打满出口导致假超时；不超过 12 个时走 `GET /group/<name>/delay` 一次完成。

## 出口超时自动切换

`startPolling` 把 failover 偏移重置为 `core.log` 当前 EOF，每 2s 从该偏移前进读一次（日志轮转后按 generation 重新从 0 同步）。25s 内对当前叶子节点 `server` 出现 ≥6 次 `i/o timeout`，则把主代理切到延迟最好的 HY2，其次 KR；60s 冷却。

## 流量日志（域名）

`log-level: info` 是固定写入 header 的，所以每条新建连接（内核以 `[TCP]` / `[UDP]` 标记）都会写一行，VPN 页的「流量日志」把这一行变成域名、规则与出口。`core.log` 里这三种形状（前两种在解析器与回归夹具里逐字保留）：

```
level=info    msg="[TCP] 127.0.0.1:49701 --> api2.cursor.sh:443 match Match using 🐟 漏网之鱼[1 官网 tcp.bet]"
level=warning msg="[TCP] dial 🎯 Direct (match GeoSite/CN) 127.0.0.1:49287 --> wetype.weixin.qq.com:443 error: dns resolve failed: …"
level=info    msg="[UDP] 127.0.0.1:63977 --> 39.108.156.189:6688 match GeoIP(cn) using 🎯 Direct[DIRECT]"
```

- 入口是管道不是文件：`spawnProcess` 的 `readabilityHandler` 把同一份字节同时给 `CoreLogWriter` 和 `VpnDomainLog`。读文件要自己管偏移，而 `CoreLogWriter` 到 8 MB 会把文件重写成尾部 —— 流式回调天然没有这个问题，也让页面是实时的。
- 必须同时有 `time="` 与 `level=info`/`warning`：这个文件里还有内核自己的启动诊断（`extractFatal` 认的 `listen tcp … address already in use` 是 `level=error` 且没有时间戳），只看 `[TCP]` 会把它们当成连接。
- 出口末段决定归类：`[DIRECT]`（含 `🎯 Direct[DIRECT]`）→ 直连，`[REJECT]` → 拒绝，其余→ 已代理；没有方括号时看最后一个空格分隔的词（裸 `DIRECT` / 裸 `🎯 Direct`）。有方括号时只认方括号，否则名字里带 REJECT 的节点会被误判成拦截。
- 按字节缓冲、只在 `\n` 切断：分块边界可能落在多字节字符中间，所以 `VpnDomainFeed` 收 `Data`、解码只在行完整时做。
- 解析在管道线程，主线程只收 ≤1 Hz 的合并发布；环形保留最近 2,000 行（`VpnDomainLog.limit`），明细 / 汇总 / 实时连接每页最多渲染 200 行（`VpnDomainQuery.pageSize`），只在内存（`core.log` 本身仍是磁盘上的记录，到 8 MB 轮转、保留尾部 512 KB）。时间戳按位置切 `HH:mm:ss`，不建每行 `DateFormatter`（校验失败的兜底行才用管道线程的 `clockFormatter`），排序用到达序 —— 跨午夜不会让昨天的行排到今天后面。
- 两个口径分开写：明细 / 汇总来自上面的日志行（没有字节数；UDP 行实际会解析，因此有记录但没有按 UDP 单列的统计）；多出来的「实时连接」模式读内核 `/connections`，有上传 / 下载与进程名，但只列此刻还开着的连接——短连接会在两次采样之间结束，所以它是快照不是账本。面板里两张说明各写各的，不把 `—` 冒充成 0。`VpnManager.pollConnections` 落进 `VpnDomainLog.updateConnections`，隧道停时清空。
- 搜索和路由计数在后台计算；页面只订阅当前模式的 revision。暂停跟随或翻到历史页时固定阅读快照，避免新连接和环形淘汰移动正在阅读的行；复制仍覆盖完整筛选结果。
- 内核重启（改端口 / TUN / 换订阅）只丢掉死管道留下的半行（`resetCarry`），已解析的表保留 —— 那正是用户在看的。

## 系统代理

`networksetup` 写 HTTP / HTTPS / SOCKS → `127.0.0.1:<mixed-port>`。

- 先关 PAC / 自动发现，再 `setwebproxy … off`（无认证）。
- 回读遍历 `networkServices()` 的每一项（含名字与 wi-fi / ethernet 无关的 USB 网卡），全部指向 127.0.0.1:mixed-port 才算写入成功；任一服务被改到别处，守卫会重写。
- `VpnProxyGuard` 每 10s 检查（受 `vpnEnabled` / `vpnSystemProxyEnabled` / `vpnGuardEnabled` 与内核运行状态门控），被别的 App 清掉则重写。写不死生效时按连续失败次数退避（10s 起倍增，上限 5 分钟），恢复一次即回到 10s；失败原因随该次写入的消息进 vpn.log。
- 系统代理的写入与清除（含退出时的同步清除）都走 `VpnSystemProxyController` 的同一条串行队列，后到的意图最后落盘 —— 快速关开不会把代理留在已停止内核的端口上。用户可在 VPN 页「网络设置」里关掉守卫。
- 绕过列表不是只有默认项：`bypassDomains()` 在 clash-verge 那串默认值（全是地址与网段，绕不过域名）之外追加 `VpnProviderDirect.hosts()` —— 见下。

## 自建供应商的直连钉（`VpnProviderDirect`）

本机配置的供应商端点若是自建 / 只挂着自己域名的，它在国内却命不中 `GEOSITE,CN`，于是落进规则链末尾的 `MATCH`、走节点绕出国再绕回来。这类端点每轮的上下文全都这么走，而本机没有任何信号说这件事：内核的日志行写的是 `Direct`（写在 geosite 载入完成之前），端点 IP 也确实在中国——错的是路由，不是目的地。

两个入口都要堵，因为它们彼此独立：系统代理绕过列表（`setproxybypassdomains` 是 macOS 上唯一吃域名的绕过面，缺口正好在这里）与规则链（TUN 模式完全不理系统代理，任何自带代理设置的客户端也直接指向 mixed port）。两处读的是同一份从两份供应商表推出来的 host 列表，所以 UI 里新加的供应商在下次启动 VPN 时自动覆盖。

- 规则写成 `DOMAIN,<host>,DIRECT`（精确 host，不是 `DOMAIN-SUFFIX`：那是贴着一个虚拟域名的所有兄弟子域一起拖直连）。
- 插在 `rules:` 下第一条，缩进抄 profile 自己第一条规则那一列——机场 profile 写列 0、手写 profile 缩进两格，假设任一种都会让内核在启动时死于 `Parse config error: yaml`。插在 `GEOIP,CN` 之后就是死文本，因为吞掉它的 `MATCH` 在链尾。
- 拒绝名单是反向的 denylist：认不出的 host 一律钉直连——出问题的正是 geosite 没听过的自建 / 虚拟域名，形状和「一个假想的境外中转」无法区分。只有 `anthropic.com` / `openai.com` / `x.ai` / `openrouter.ai` / `googleapis.com` / `nvidia.com` / `lmstudio.ai` 被排除在外，因为把这几家钉直连会直接把它们弄坏。IP 字面量、`localhost` / `.local` / `.lan` / `.internal` 也跳过（前者已被 profile 的 IP 规则覆盖，后者是 macOS 本地解析、不经过内核 DNS）。
- 注入发生在 `tuneForStability` 之前：那个函数改的是规则正文（bootstrap DNS、url-test 间隔），要让 pin 永远不是它可能匹配到的目标。

## 连通性

`VpnNetProbe`：Apple / GitHub / Google / YouTube，以及 ChatGPT / Claude / Gemini。探测请求走 `VpnHTTP.session(proxyPort:)`——隧道运行时经 mixed-port，停止时直连——不继承系统代理（系统代理可能正指向自己的 mixed-port，会绕回自身）。

## UI

| 表面 | 内容 |
|------|------|
| 主窗口 VPN 页 | `VPNView`：开关、节点宫格（「浏览节点」抽屉）、测速、订阅（`VpnSubscriptionSection`）、内核日志（`VpnLogConsole`）、流量日志（`VpnDomainLogSection`），窄窗口下左边以分段控件在 `流量日志` / `订阅管理` 之间切换 |
| 菜单栏 popup | `PanelHeader` 状态行的 VPN 药丸 `VpnStatusPill`（节点 + 延迟，点击切到主窗口 VPN 页选节点、测速）——它是一条连接状态而不是一种模型，所以不占切换行的格子；status item 上常驻图标 + 双行 ↓/↑ + 电池格（`VpnMenuBarRateView`，宽度由布局常量推导；电池格是 34×21 的无正极头胶囊，φ²∶1 ≈ 1.618∶1，比例见 `batteryGlyphWidth` 的注释） |
| 主窗口 | 不重复 popup 的 VPN chrome |

status item 上三种读数都不依赖隧道：电池是这台机器的电量，↓/↑ 是这台机器的吞吐（`SystemThroughput`，读各网卡 `if_data`），两者隧道关闭时照常显示。隧道改变的是速率来自谁、画成什么颜色：运行时用 mihomo `/traffic` 自己的计数并画成绿色（绿=「走隧道」），停止时用系统总吞吐画成静息的白色（白色数字配绿顶会声称有流量在走代理）。工具提示写明「隧道速率 / 系统速率」。见 `tickVpnRate` 的注释。

菜单栏模板图标由 `MenuBarMark` 矢量绘制（`MenuBarController.swift` 里用贝塞尔现画，不需要图片资源）。

## 构建

见 `Sources/build.sh`：默认**不联网**，`build.sh` 直接把提交在仓库里的压缩档
（`Sources/ClaudeBar/Resources/mihomo-core.xz` 与同目录的 `mihomo-core.version`，当前 `v1.19.31`）
拷进包内；`VpnManager` 首次运行时经 `XZArchive` 解包，用 `core.stamp` 记大小，避免重复解压。
`vendor/mihomo/mihomo` 只有显式更新时才拉取：`MIHOMO_UPDATE=1` 从 GitHub 取 darwin-arm64，
版本对不上时用 `xz` 重打归档（`-9 --lzma2=dict=16MiB`）并提示提交新旧两个文件；
没有 `xz` 且没有归档时才退化为内置原始二进制（文件名不带 `.xz`，`VpnManager` 会按扩展名走直接复制那条路径）。
原始内核 54 MB（deflate 压不动），`.xz` 后 13 MB，是包内最大的非字体资源（字体目录合计约 109 MB）。

| 变量 | 行为 |
|------|------|
| （默认 / `MIHOMO_UPDATE=0`） | 使用提交的 `mihomo-core.xz`，不访问 GitHub |
| `MIHOMO_UPDATE=1` | 维护者显式更新：访问 GitHub 取最新 / 钉版本内核，重打归档并提示提交（见 [DEVELOPMENT.md](../DEVELOPMENT.md)） |
| `MIHOMO_UPDATE=1 MIHOMO_SKIP_DOWNLOAD=1` | 更新流程但不下载：用已有 `vendor/mihomo/mihomo` 重打归档；单独设 `MIHOMO_SKIP_DOWNLOAD=1` 而不设 `MIHOMO_UPDATE=1` 没有效果 |

`MIHOMO_UPDATE=1` 还会跳过一次「无变更即复用已验证包」的快速路径（`build.sh` 第 107 行同时看 `CLAUDEBAR_FORCE_REBUILD` 与 `MIHOMO_UPDATE`），确保新内核真的被压包。

## 手动域名规则

VPN 页标题栏的「域名规则」支持添加、切换直连／代理和删除规则。「包含子域名」对应 `DOMAIN-SUFFIX`，关闭则仅匹配该域名（`DOMAIN`）。输入只接受域名，不含协议、端口、路径或 IP；国际化域名使用 Punycode。

规则通过 `PrivateFileWriter` 保存到当前版本的 `FilePaths.vpnDir/domain-rules.json`（0600），不改写订阅。下次启动自动生效；运行中点击「重启并应用」重启当前 VPN，可能中断现有连接。

手动规则排在自动模型服务直连规则和订阅规则之前；更具体的域名优先，同一域名的精确规则优先于包含子域名的规则。代理目标跟随主代理组（与节点选择器使用相同的优先名称，再回退到首个 select 组／节点），无可用出口时使用 REJECT。手动代理命中的模型服务域名从系统代理自动绕过列表移除。规则匹配语义参见 [mihomo 官方规则文档](https://wiki.metacubex.one/config/rules/)。

`make test TEST=vpn-domain-rules` 在临时目录编译生产规则与私有写入逻辑，验证域名校验、优先级、YAML 缩进、保存权限及自动绕过冲突，不启动 VPN 或修改系统设置。

## 代理与直连流量

明细、汇总、实时连接共用两条流向统计：代理（本机 → 代理节点 → 目标）与直连（本机 → 目标），分别显示上传、下载和合计。域名汇总把两种流向的采样流量分开列出，混合流向不会互相覆盖；复制汇总也包含两种流量。

`VpnDomainTrafficAccumulator` 按连接 ID 的单调计数器增量累计代理和直连，拒绝连接不计入流量。重复快照、计数器回退和清空后的存量字节不会重复计算；已关闭连接保留在总量中，域名明细随日志和活动连接的保留范围裁剪。

统计仅覆盖经过 mihomo 内核且被采样到的连接。系统代理绕过、未被 TUN 接管的直连和采样间隔内结束的短连接不一定可见，页面不声称统计整台机器的流量。历史日志没有连接 ID 或可靠字节计数，明细行只显示实际路由、出口和结果，不把同域名累计字节分配给每条旧日志。

`python3 Tools/render-vpn-preview.py` 用真实 SwiftUI/AppKit 视图生成规则、空列表、明细与汇总的浅／深色截图，输出到 `.build/vpn-preview/`。所有配置、规则和流量均为合成样例；不启动 VPN、不读取真实用户配置、不写系统设置。
