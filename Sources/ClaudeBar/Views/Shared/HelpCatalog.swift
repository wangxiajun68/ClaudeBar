import Foundation

// MARK: - Chapters

/// The help page's six chapters. Order is the reading order, not alphabetical.
enum HelpChapter: String, CaseIterable, Identifiable {
    case start, proxy, sessions, vpn, keys, faq

    var id: String { rawValue }

    var label: String {
        switch self {
        case .start: return "上手"
        case .proxy: return "本地代理"
        case .sessions: return "会话与用量"
        case .vpn: return "VPN"
        case .keys: return "快捷键"
        case .faq: return "排障"
        }
    }

    var icon: String {
        switch self {
        case .start: return "flag"
        case .proxy: return "network"
        case .sessions: return "rectangle.stack"
        case .vpn: return "globe"
        case .keys: return "command"
        case .faq: return "stethoscope"
        }
    }
}

// MARK: - Blocks

/// One run of article body.
///
/// An enum rather than Markdown: the app has no Markdown rendering path at all
/// (`AttributedString`, `Markdown` — zero hits), and a shortcut line needs the
/// keycap component, which Markdown cannot express. Five cases cover every
/// article here.
enum HelpBlock {
    case para(String)
    case bullets([String])
    /// Copyable command.
    case code(String)
    /// Individual keys + what they do (`["⌘", "⇧", "A"]`).
    case keys([String], String)
    /// Path + what the app does with it.
    case paths([(path: String, note: String)])
}

// MARK: - Entry

/// One collapsible article. `id` doubles as the accordion's open-set key, so it
/// must stay stable across edits.
struct HelpEntry: Identifiable {
    let id: String
    let chapter: HelpChapter
    let title: String
    /// The one line shown while collapsed — should stand alone as an answer.
    let summary: String
    let body: [HelpBlock]
    /// Extra search terms: English names, paths, error strings a user might
    /// paste in. Not displayed.
    let keywords: String
    /// Flattened, lowercased text the page searches. Built once here rather
    /// than per keystroke — `recompute()` runs on every character typed, and
    /// re-flattening 35 articles each time is the same shape of mistake
    /// `ProxyLogView` documents. (A `lazy var` would be the obvious way to
    /// express that, but its getter is mutating and the filter closure only has
    /// a `let` entry.)
    let haystack: String

    init(id: String, chapter: HelpChapter, title: String, summary: String,
         body: [HelpBlock], keywords: String = "") {
        self.id = id
        self.chapter = chapter
        self.title = title
        self.summary = summary
        self.body = body
        self.keywords = keywords

        var parts: [String] = [title, summary, keywords, chapter.label]
        for block in body {
            switch block {
            case .para(let t):
                parts.append(t)
            case .bullets(let items):
                parts.append(contentsOf: items)
            case .code(let t):
                parts.append(t)
            case .keys(let keys, let caption):
                parts.append(keys.joined())
                parts.append(caption)
            case .paths(let rows):
                for row in rows {
                    parts.append(row.path)
                    parts.append(row.note)
                }
            }
        }
        self.haystack = parts.joined(separator: "\n").lowercased()
    }
}

// MARK: - Catalog

/// Static help content. No store, no observable state — the page reads this
/// once and filters it in `onChange`, never in `body`.
enum HelpCatalog {

    static let entries: [HelpEntry] = start + proxy + sessions + vpn + keys + faq

    // MARK: 上手

    private static let start: [HelpEntry] = [
        HelpEntry(
            id: "start-first-run",
            chapter: .start,
            title: "第一次打开",
            summary: "菜单栏出现图标；主窗口是仪表盘。",
            body: [
                .para("点菜单栏图标开 popup，点里头的「主窗口」开大窗口。第一次启动时会弹出屏幕录制授权——**只在你用 ⌘⇧A 区域截图时才会真正用到**，不需要截图可以拒绝。"),
                .para("主窗口顶部是导航：概览 / 会话 / 模型 / 用量 / 流量 / VPN / 设置 / 帮助。⌘K 可以直接跳。"),
            ],
            keywords: "onboarding first launch 第一次 授权 permission"
        ),
        HelpEntry(
            id: "start-add-provider",
            chapter: .start,
            title: "加第一个供应商",
            summary: "「模型」页 → 新建 → 填 Base URL 与 API Key → 保存并激活。",
            body: [
                .para("Claude Code 与 Codex 各有一份供应商列表，互不覆盖。加完之后把其中一个设为活跃。"),
                .bullets([
                    "Claude Code 的切换写回 `~/.claude/settings.json`",
                    "Codex 的切换写回 `~/.codex/config.toml`",
                    "两份文件在改动前都会先留一份 `.bak`",
                ]),
                .para("菜单栏 popup 顶部也有切换格，不用开主窗口。"),
            ],
            keywords: "provider 供应商 添加 activate settings.json config.toml"
        ),
        HelpEntry(
            id: "start-restore-official",
            chapter: .start,
            title: "还原为官方配置",
            summary: "「模型」页的「还原官方」会清掉第三方覆盖，Claude Code / Codex 各自走官方登录。",
            body: [
                .para("切过中转之后想回到 Anthropic / OpenAI 官方，不要手改配置文件。在「模型」页选好 Claude Code 或 Codex，点「还原官方」。菜单栏 popup 底部同一按钮可以两边分别还原。"),
                .bullets([
                    "Claude Code：从 `settings.json` 的 `env` 删掉 Base URL、令牌、模型覆盖；`permissions` 等其它字段不动",
                    "Codex：清掉中转供应商表，改指向 `openai_http`（`name = \"OpenAI\"`、`supports_websockets = false`）。已登录的 `auth.json` 不重写；只有单独的第三方 API Key 才会删掉",
                    "供应商列表不删，再点瓦片就会重新写回中转",
                    "已经在跑的会话不会中途改道，需要新开一个",
                ]),
            ],
            keywords: "还原 官方 official restore anthropic openai chatgpt 中转 relay settings.json config.toml"
        ),
        HelpEntry(
            id: "start-switch-timing",
            chapter: .start,
            title: "切换之后为什么没生效",
            summary: "新开一个会话才生效。",
            body: [
                .para("Claude Code 与 Codex 都在**进程启动时**读取配置。切换只影响之后新启动的会话，已经在跑的窗口不会中途改道。"),
                .para("所以：切完 → 新开一个终端会话。Codex 桌面版则需要重启那个会话窗口。"),
                .bullets([
                    "Claude Code：`claude` 进程读 `~/.claude/settings.json` 的环境变量",
                    "Codex：读 `~/.codex/config.toml` 的 `model_provider` 与 `base_url`",
                ]),
            ],
            keywords: "切换 生效 不生效 restart 重启 new session 新会话"
        ),
        HelpEntry(
            id: "start-balance",
            chapter: .start,
            title: "供应商卡片没有余额",
            summary: "只有官方公开了余额接口的平台才会显示。",
            body: [
                .para("模型页的供应商卡片会显示余额。目前能查的是 DeepSeek、Kimi 开放平台、硅基流动和 OpenRouter。Coding Plan、按订阅计费的入口，以及没有公开余额接口的平台不显示数字，不影响对话。"),
            ],
            keywords: "余额 balance 无数据 dash 中转 relay"
        ),
    ]

    // MARK: 本地代理

    private static let proxy: [HelpEntry] = [
        HelpEntry(
            id: "proxy-why",
            chapter: .proxy,
            title: "为什么需要本地代理",
            summary: "把 Codex 的私有工具协议翻译成各家后端都认的形态。",
            body: [
                .para("Codex 会说一套带 `namespace` 工具、`custom` 工具和 `additional_tools` 的私有协议。官方 api.openai.com 认，绝大多数第三方网关不认——第二轮回放历史的时候直接 400。"),
                .para("本地代理听在 `127.0.0.1` 上，把这些工具拍平成普通 function 工具，把 Chat 形态的上游再合成回 Responses 流。两类方言互转都在本机完成。"),
                .para("默认端口 \(LocalProxyAddress.port)，可在「设置 → 本地代理」改。地址："),
                .code(LocalProxyAddress.openaiRoot),
            ],
            keywords: "proxy 代理 为什么 作用 23186 namespace wire_api responses chat 协议转换"
        ),
        HelpEntry(
            id: "proxy-token",
            chapter: .proxy,
            title: "令牌鉴权",
            summary: "代理只认本机令牌；上游密钥由代理注入，客户端看不到。",
            body: [
                .para("代理是真的持有你上游 API Key 的，所以它不能对任何本机进程开放：否则一个 npm 安装脚本、一个编辑器插件，往 `127.0.0.1` 发个请求就能把你的 key 用掉。"),
                .bullets([
                    "每个连接都要带令牌：`Authorization: Bearer <token>` 或 `x-api-key: <token>`",
                    "令牌文件在 `~/Library/Application Support/ClaudeBar/proxy-token`（0600）",
                    "代理**总是**用自己的 key 覆盖上游请求的凭证——客户端带自己的 key 也不会被透传",
                    "转发给上游的请求头走白名单，客户端的 `Authorization` / `Cookie` 一概不带",
                ]),
                .para("Codex 侧的令牌写在 `~/.codex/config.toml` 里，由 ClaudeBar 自动维护。"),
            ],
            keywords: "token bearer 令牌 鉴权 401 unauthorized x-api-key 密钥安全 security"
        ),
        HelpEntry(
            id: "proxy-third-party",
            chapter: .proxy,
            title: "第三方客户端接入",
            summary: "Base URL 设成代理地址，模型名以客户端为准。",
            body: [
                .para("Cursor、各种 SDK、curl 都可以走同一个代理。把 Base URL 指过来即可："),
                .code(LocalProxyAddress.openaiRoot),
                .para("模型名**不会被替换**——请求里的 `model` 原样转发。所以要么把第三方的上游切到真的提供这个模型的渠道，要么把客户端的模型名改成那个渠道认识的名字。"),
                .para("第三方走哪家上游在「设置 → 本地代理 → 第三方 OpenAI / Anthropic」里单独选，默认跟随 Codex / Claude Code 当前供应商。这个选择**不会**改 `~/.codex` 或 `settings.json`。"),
            ],
            keywords: "第三方 third party base url cursor sdk model_not_found 无可用渠道"
        ),
        HelpEntry(
            id: "proxy-traffic",
            chapter: .proxy,
            title: "流量记录在哪",
            summary: "「流量」页：访问日志 + 请求 / 响应抓包。",
            body: [
                .para("默认只记路由元数据（谁、哪条路径、多大、多久、什么状态码）。要在「流量」页看到完整对话、工具调用、图片与原始 SSE，需要打开抓包："),
                .bullets([
                    "「设置 → 本地代理 → 记录第三方流量」管的是非 CC / Codex 客户端的请求",
                    "「流量」页顶部有抓包开关与存储方式（SQLite 或 JSONL）",
                    "抓包数据落在 `~/Library/Application Support/ClaudeBar/logs/`",
                ]),
                .para("卡包很大时可以随时关掉抓包——关掉不影响转发。"),
            ],
            keywords: "流量 traffic 抓包 capture 日志 log sse sqlite jsonl"
        ),
    ]

    // MARK: 会话与用量

    private static let sessions: [HelpEntry] = [
        HelpEntry(
            id: "sessions-sources",
            chapter: .sessions,
            title: "会话从哪来",
            summary: "Claude Code / Cursor / Codex 三种来源，各有前提。",
            body: [
                .paths([
                    (path: "~/.claude/sessions/", note: "Claude Code：有对应的 PID 文件才算活着"),
                    (path: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb", note: "Cursor：至少运行过一次且有 composer 记录"),
                    (path: "~/.codex/sessions/", note: "Codex：按 rollout JSONL 的修改时间判活"),
                ]),
                .para("列表里没有某一类，通常是那个工具还没在本机跑过。自定义了 `CLAUDE_CONFIG_DIR` 之类的环境变量目前认不出来。"),
            ],
            keywords: "会话 session 来源 claude cursor codex 没有列表 找不到"
        ),
        HelpEntry(
            id: "sessions-resume",
            chapter: .sessions,
            title: "接回刚才那次会话",
            summary: "双击会话卡，在终端或 Cursor 里续上。",
            body: [
                .bullets([
                    "Claude Code：优先用 Warp（装了的话），否则 Terminal",
                    "Cursor：打开 Cursor 并切到对应项目目录",
                ]),
                .para("会话状态一直是 idle，一般是那个工具用了非官方分支、改了 session 文件结构——busy 是通过 transcript 尾部未闭合的 `tool_use` 判断的。"),
            ],
            keywords: "resume 接回 双击 终端 warp cursor idle busy 一直空闲"
        ),
        HelpEntry(
            id: "sessions-usage",
            chapter: .sessions,
            title: "用量怎么算",
            summary: "输入 + 缓存读 + 缓存写 + 输出，只统计模型 Token。",
            body: [
                .para("口径是 `input + cache_read + cache_creation + output` 四项之和，`<synthetic>` 之类的模型行会被过滤。热力图按日 / 月 / 年聚合，来源分 CC / Codex / 第三方三柱。"),
                .bullets([
                    "VPN 的剩余配额**不混进来**，留在 VPN 页",
                    "Cursor 约 2026-03 之后不再往 SQLite 写 token 计数，显示的是历史全量，不是按日数据",
                    "首次冷扫约 0.6s，之后走增量索引（mtime + size 键控），接近零开销",
                ]),
            ],
            keywords: "用量 usage token 统计 口径 cache 热力图 不准确 慢"
        ),
        HelpEntry(
            id: "sessions-units",
            chapter: .sessions,
            title: "换 Token 单位",
            summary: "设置 → 外观 → Token 单位：万/亿 或 K/M/B。",
            body: [
                .para("主窗口、popup 与桌面 Widget 同步生效。"),
            ],
            keywords: "单位 unit 万 亿 K M B 显示"
        ),
    ]

    // MARK: VPN

    private static let vpn: [HelpEntry] = [
        HelpEntry(
            id: "vpn-start",
            chapter: .vpn,
            title: "订阅 → 节点 → 接管流量",
            summary: "VPN 页加订阅、选节点，再决定走系统代理还是 TUN。",
            body: [
                .para("ClaudeBar 自己托管 mihomo 内核（随应用分发）。三步："),
                .bullets([
                    "**VPN** 页加订阅地址，拉回节点列表",
                    "选一个节点——菜单栏 popup 的 VPN 格也能切",
                    "需要接管流量时开「系统代理」（Wi-Fi / 以太网写 `127.0.0.1` + mixed-port），或在设置里开 TUN",
                ]),
                .para("菜单栏显示 ↓↑ 实时速率；出站路径写成 `日本 › 电信` 这样的面包屑。"),
            ],
            keywords: "vpn 订阅 subscription 节点 node 系统代理 tun mihomo 内核 开关"
        ),
        HelpEntry(
            id: "vpn-system-proxy",
            chapter: .vpn,
            title: "开了但系统设置里代理是关的",
            summary: "去看 Wi-Fi / 以太网，别只看没在用的那几项。",
            body: [
                .para("ClaudeBar 只给 **Wi-Fi / 以太网** 写 `127.0.0.1` + mixed-port（默认 7890），并先把 PAC 关掉。如果你在系统设置里翻的是 Thunderbolt 之类没在用的服务，会误以为没写上。"),
                .para("退出应用时若系统代理还是 ClaudeBar 设的，会被清掉——上一次会话崩了留下的残留也会在启动时清。"),
            ],
            keywords: "系统代理 system proxy 没生效 关的 networksetup pac 清掉 残留"
        ),
        HelpEntry(
            id: "vpn-quota",
            chapter: .vpn,
            title: "剩余流量 / 到期看不着",
            summary: "机场要在响应头返回 subscription-userinfo。",
            body: [
                .para("请求用 Clash Verge 风格的 User-Agent。机场不返回 `subscription-userinfo` 头，就只剩节点列表，没有配额与到期日。"),
            ],
            keywords: "订阅流量 到期 quota subscription-userinfo 机场 看不着"
        ),
    ]

    // MARK: 快捷键

    private static let keys: [HelpEntry] = [
        HelpEntry(
            id: "keys-global",
            chapter: .keys,
            title: "全局",
            summary: "任何时候都生效。",
            body: [
                .keys(["⌘", "K"], "命令面板：跳页面、会话、模型"),
                .keys(["⌘", "⇧", "A"], "区域截图（可在「设置 → 截图与通知」关掉）"),
            ],
            keywords: "快捷键 shortcut 键盘 全局 cmd command k a 截图"
        ),
        HelpEntry(
            id: "keys-screenshot",
            chapter: .keys,
            title: "截图浮层里",
            summary: "拉框、标注、复制或钉住。",
            body: [
                .keys(["拖拽"], "自定义区域；悬停会自动吸附窗口边"),
                .keys(["Return"], "确定"),
                .keys(["⌘", "C"], "确定并复制"),
                .keys(["⌘", "S"], "保存到文件"),
                .keys(["空格"], "切到全屏截取"),
                .keys(["Esc"], "取消"),
            ],
            keywords: "截图 screenshot 标注 复制 保存 钉住 取消 全屏"
        ),
        HelpEntry(
            id: "keys-editor",
            chapter: .keys,
            title: "编辑器里",
            summary: "只在供应商编辑面板内生效。",
            body: [
                .keys(["⌘", "S"], "保存供应商"),
            ],
            keywords: "编辑器 editor 保存 save cmd s"
        ),
    ]

    // MARK: 排障

    private static let faq: [HelpEntry] = [
        HelpEntry(
            id: "faq-gatekeeper",
            chapter: .faq,
            title: "「无法验证开发者」",
            summary: "发行包是 ad-hoc 签名、未公证，去一次隔离属性即可。",
            body: [
                .para("从 Releases 下载的 DMG 是自签名构建，没有经过 Apple 公证。执行一次："),
                .code("xattr -cr /Applications/ClaudeBar.app\nopen /Applications/ClaudeBar.app"),
                .para("从源码构建则不需要这一步——本地用的是受信任的 `ClaudeBar Dev` 自签身份。"),
            ],
            keywords: "gatekeeper 无法验证开发者 xattr 隔离 quarantine 打不开 安全"
        ),
        HelpEntry(
            id: "faq-switch",
            chapter: .faq,
            title: "切了模型但没变",
            summary: "新开会话才生效（见「上手」章）。",
            body: [
                .para("Claude Code 与 Codex 都在进程启动时读配置。已经在跑的会话不会中途改道——切完新开一个。"),
                .para("Codex 桌面版还要确认那个会话窗口用的是当前 provider：Codex 会把 provider 记在**每个线程**上，旧线程可能还挂在老供应商上。"),
            ],
            keywords: "切换 没生效 不生效 new session 重启 thread provider 线程 旧会话"
        ),
        HelpEntry(
            id: "faq-hotkey",
            chapter: .faq,
            title: "⌘⇧A 没反应",
            summary: "先看是不是被别的截图工具占了，再看屏幕录制权限。",
            body: [
                .bullets([
                    "「设置 → 截图与通知」必须开着，且提示「热键已注册」。",
                    "提示被占用就先退出 iShot / PixPin 等同样抢 ⌘⇧A 的工具。",
                    "系统设置 → 隐私与安全性 → 屏幕录制 → 允许 ClaudeBar，然后重按一次。",
                    "从源码反复编译时若每次都要重新授权：确认本机签名身份是受信任的 `ClaudeBar Dev`，不要用 ad-hoc。",
                ]),
                .para("顺带一提：ClaudeBar 运行时占着 ⌘⇧A，Finder 里的同名操作会被挡下。关掉这个开关就还给 Finder。"),
            ],
            keywords: "⌘⇧A 没反应 热键 占用 屏幕录制 权限 iShot PixPin finder 快捷键失效"
        ),
        HelpEntry(
            id: "faq-upstream",
            chapter: .faq,
            title: "上游报错",
            summary: "先看「流量」页那条日志的错误原文。",
            body: [
                .para("「流量」页的访问日志每条都带状态码与错误原文，比在客户端里看到的转述准。几个常见形态："),
                .bullets([
                    "**400 / 模型不存在**：代理不替换模型名，问题在渠道或客户端填的名字",
                    "**400 / tools must be set**：Codex 自动压缩那一轮不带工具，代理会替它把 `tool_choice` 一起去掉；如果还在报，说明打到的不是这个代理",
                    "**401**：令牌不对（代理侧）或上游 key 过期（上游侧），看日志里的 `provider` 字段区分",
                    "**502 / 超时**：第三方上游首字节超时，代理侧不重试，换渠道",
                ]),
                .para("需要完整报文时打开抓包，再复现一次。"),
            ],
            keywords: "报错 error 400 401 502 超时 tools must be set model_not_found 日志 upstream"
        ),
        HelpEntry(
            id: "faq-widget",
            chapter: .faq,
            title: "桌面 Widget 空白",
            summary: "主应用先跑一次写快照，再把 Widget 移除重加。",
            body: [
                .bullets([
                    "主应用至少要运行并完成一次数据刷新（写入 App Group 快照）",
                    "移除 Widget 后重新添加",
                    "确认应用装在 `/Applications`——从 `.build` 直接启动可能注册异常",
                ]),
                .para("刷新节奏：主应用约每 2.5s 轮询，数据变化时写快照并通知 WidgetKit；最终渲染由系统节流。"),
            ],
            keywords: "widget 小组件 空白 没有数据 刷新 desktop 快照 app group"
        ),
        HelpEntry(
            id: "faq-files",
            chapter: .faq,
            title: "ClaudeBar 碰哪些文件",
            summary: "只读优先；除了你主动切换，不改各工具自己的数据。",
            body: [
                .paths([
                    (path: "~/.claude/", note: "读；切换时写 settings.json"),
                    (path: "~/.codex/", note: "读；切换时写 config.toml"),
                    (path: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb", note: "只读"),
                    (path: "~/Library/Application Support/ClaudeBar/logs/", note: "开了抓包才写"),
                    (path: "~/Library/Application Support/ClaudeBar/vpn/", note: "订阅与内核配置，只留本机"),
                ]),
            ],
            keywords: "文件 files 路径 path 权限 读 写 数据 隐私 privacy 改哪些"
        ),
        HelpEntry(
            id: "faq-build",
            chapter: .faq,
            title: "改了源码但界面没变",
            summary: "旧进程还在跑。",
            body: [
                .code("killall ClaudeBar\nopen /Applications/ClaudeBar.app"),
                .para("菜单栏应用装到 /Applications 后不会自动替换正在运行的进程。"),
            ],
            keywords: "源码 build 编译 没变 重启 开发"
        ),
    ]
}
