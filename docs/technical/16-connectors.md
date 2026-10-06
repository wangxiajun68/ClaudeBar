# 连接器管理

> ClaudeBar 技术文档 · §16
> 相关：[视图层](05-view-layer.md) · [数据访问层](04-data-access-layer.md)

主窗口「连接器」页统一展示 Claude Code、Codex、Cursor 的本机 Skills、MCP 和插件。页面首次打开及手动刷新时扫描固定目录；选择项目后额外读取该项目的配置。扫描在后台执行，不启动 MCP 服务器、不连接网络，也不读取 `SKILL.md` 正文，只提取前言里的名称、描述与 `metadata.requires.bins` 依赖声明。

## 界面与动效

页面沿用其他主窗口页面的冰色画布、白色卡片与石墨色深色模式。页首是一条常驻工具栏（搜索、刷新、项目选择、批量管理），下面是类型与平台两行筛选：类型分插件、Skills、MCP、本机 CLI 四类，平台筛选把当前类型收窄到某个客户端；搜索覆盖名称、平台与共享 CLI 归属。连接器和 CLI 都使用等高宫格卡片。卡片直接标出 Skill、MCP 或插件；使用稳定的系统图标，点击正文打开详情，底部保留独立的启停控件。Cursor MCP 的当前状态无法可靠读取，因此卡片直接提供「启用」「停用」两个命令，状态标为「待确认」。CLI 卡片显示关联能力数量，但不提供跳转到这些能力的筛选入口。空清单可直接清除筛选或选择项目，后台读取与操作中有独立反馈。

详情页按类型展示：Skill 读取 `SKILL.md`，以原生 SwiftUI 排版标题、正文、列表、引用、代码块和表格；MCP 在打开详情时连接服务，按协议完成初始化并请求 `tools/list`，显示工具名、描述和参数名，支持分页和重新读取，不发送 `tools/call`；插件显示清单描述、版本、安装位置及可发现的 Skill、命令、Agent 等组成。详情页均可复制路径、在 Finder 定位并打开原文件。文档解析和插件信息读取在后台进行，MCP 请求有超时及数量上限；滚动清单仍是固定高度的懒加载宫格。

交互细节参考 [Uiverse 元素目录](https://uiverse.io/elements) 的分段选择、层叠按钮、输入聚焦与开关触感，使用原生 SwiftUI 绘制并保持本项目配色。滚动区域使用 `LazyVGrid`，卡片固定高度，避免滚动时反复重排和绘制；卡片有悬停描边、阴影与 2pt 抬升（悬停状态变化，不是循环动画），减少动态效果时整体停用。卡片表面走全应用同一套部件（底 + 强调水洗 + 内嵌白环，见 [DESIGN.md](../../DESIGN.md)）；连接器卡片带类型色相但不画角上深度环，只有本机 CLI 卡片带 `DepthLens`。筛选走同一颗 `SegmentedCapsule`：类型筛选、平台行、供应商客户端与分类、用量周期都是同一个控件，因此这页不再有"第二种筛选长得像另一种控件"的问题。详情才做文件存在性检查。系统开启“减少动态效果”时，非必要动效停用。

## 本机 Agent CLI

Agent CLI 单独扫描，属于本机共享环境。只按固定候选名检查常见安装目录和 `PATH` 中的可执行文件，不执行 `--version`、不读取登录信息。候选范围限于服务集成（例如 `lark-cli`、腾讯文档、`gh`、`obsidian`）、MCP 工具（例如 `mcporter`、`happy-mcp`）和 Agent/Skill 管理工具（例如 `openclaw`、`oc-skills`、`skillhub`）；不扫描 `node`、`npm`、`docker` 等通用开发环境，也不把三个客户端自己的 CLI 算作共享连接器。CLI 清单只在首次进入和手动刷新时重新扫描，切换项目或启停连接器不会重复查找。

CLI 关联能力按**显式来源**归属：Skill 的 `SKILL.md` 前言 `requires.bins` 命中已知共享 CLI，或 MCP 配置的 `command`（含 Codex TOML 的 `command`）直接指向该 CLI，记录就带上 `sharedOwner`；卡片正文显示「由 <CLI> 提供」，CLI 卡片的「N 项关联能力」也是按这个字段统计。三个客户端的清单里这些条目仍按各自的平台归类，不做跨平台聚合面板。不会因为名称含有 `lark` 等字样就猜测归属。通过 `npx` 等通用运行器间接启动、无法从命令字段明确识别的 MCP 仍留在原客户端。

归属只影响记录上的字段与文案，不改变任何启停路径：停用与移除仍走下面那张表里各平台自己的机制。

## 各平台启停机制

| 平台 | Skills | MCP | 插件 |
| --- | --- | --- | --- |
| Claude Code | 平台视图与全部平台视图都采用可逆移库（见下）。插件内 Skills 应随插件管理。 | `/mcp` 的开关按项目写入 `~/.claude.json` 的 `disabledMcpServers`；`.mcp.json` 还有独立的批准/拒绝机制。本页把它标为「客户端管理」并只展示来源，避免改写整个状态文件。 | `claude plugin enable/disable` 是官方 CLI。本页只对用户级已安装插件调用 CLI；项目、组织和云同步插件交还客户端。 |
| Codex | 从 `.codex/skills`、`.agents/skills` 等目录发现；启停同样采用可逆移库。卡片上的平台状态来自目录本身是否在原位，不读取也不写入 `config.toml`。 | `config.toml` 的 `[mcp_servers.<id>] enabled = false` 可停用，`true` 可恢复。本页只改对应表的一行。 | 本地市场插件可用 `[plugins."name@marketplace"] enabled = false` 配置。本页只管理配置文件中可见的插件表；其余本机缓存条目标为「客户端管理」，来源说明写明安装与启用状态需在 Codex 中确认，不当作已安装。云端或管理员分发的不在本机目录内。 |
| Cursor | 从 `.cursor/skills`、`.agents/skills` 等位置发现，也兼容 Claude / Codex 的 Skills 目录；启停同样是可逆移库。`disable-model-invocation` 仅关闭自动调用，仍可手动调用，因此不能当作完整停用。 | `agent mcp enable/disable <identifier>` 是官方 CLI；本页调用它处理本机 JSON 中可见的 MCP，状态仍以 Cursor 为准。 | Customize 是官方管理入口。本页展示本地插件和缓存来源，并明确标注缓存不代表已安装，不直接改写私有安装状态。 |

官方依据：[Claude Skills](https://code.claude.com/docs/en/skills)、[Claude MCP](https://code.claude.com/docs/en/mcp)、[Claude Plugins](https://code.claude.com/docs/en/discover-plugins)、[Codex Skills](https://learn.chatgpt.com/docs/build-skills)、[Codex MCP](https://learn.chatgpt.com/docs/extend/mcp)、[Codex Plugins](https://developers.openai.com/plugins/build/plugins)、[Cursor Skills](https://prod.cursor.com/docs/skills)、[Cursor MCP CLI](https://prod.cursor.com/docs/cli/mcp)、[Cursor Plugins](https://prod.cursor.com/docs/plugins)。核查日期 2026-09-24；`learn.chatgpt.com` 与 `developers.openai.com` 三条在当前网络下不可直接访问（403 或无响应），仅按链接记录，未复核内容。

## 停用本地 Skill

- **只有一个机制：可逆移库。**按 `SKILL.md` 前言里的精确名称（没有名称时用目录名）关联同名独立安装，把对应目录或符号链接整体移入 `FilePaths.appSupportDir/DisabledSkills/`，登记写入同目录的 `registry.json`；启用就是把目录移回原位。不移动的项（目录已不在原位）显示为已停用并只能启用。
- **平台视图只决定「范围」，不决定「方式」。**平台行选中某个客户端时，联动只覆盖该平台已扫描到的同名安装；选「全部」时覆盖所有已扫描的同名安装。两种范围都走同一套移库，没有按平台写客户端配置的分支，所以不会出现「界面说停用了、客户端还在用」的状态。
- 停用登记保存名称和摘要，以便相对链接移库后仍可展示。恢复拒绝覆盖任何已占用路径，包括悬空链接；旧登记格式仍可读取。
- 只覆盖个人目录和当前所选项目的本地独立 Skills；不会自动覆盖未扫描项目、插件自带、隐藏系统、远端、管理员分发或之后新增的 Skills。同名但内容不同的安装也会联动，界面提示这一范围。
- 已运行会话可能持有旧 Skill 上下文；移库不撤回会话中已经加载的内容。用户修改更高优先级、托管或未扫描范围的客户端设置时，最终状态以客户端为准。

## 写入与边界

- Skill 启停只移动目录与写自己的 `registry.json`，不改动任何客户端配置；`~/.codex/config.toml`、`~/.claude/settings.json` 的内容在移库前后必须逐字节相同，`Tests/connector-batch-regressions.py` 对此有断言。
- 所有连接器写入都经过 `ConnectorMutationGate` 串行化（`registry.json` 是逐条读-改-写，两个开关同时移库会互相覆盖）；批量执行也逐条串行并固定目标记录与项目，不在执行时重新解释筛选。操作期间界面冻结，避免交错提交。
- 移库前先 `lstat` 判定源是否存在（悬空相对链接也要能移），并校验登记项指向停用区内部；`FileManager.moveItem` 移动的是链接本身，不递归其目标。
- Codex TOML 只替换目标表的一行 `enabled`，其余字节保留；写入前再次读取并比对文件，避免覆盖扫描之后的更改。临时文件和原文件保持私有权限，完成后同目录原子替换。Claude 的 JSON 保留无关键，移除只删对应 `mcpServers` 条目。
- CLI 调用只传固定子命令与扫描到的标识符，不经 shell 拼接；不输出配置内的令牌或错误正文。
- Cursor 的 CLI 开关状态无法从公开的稳定磁盘格式确定，页面以「状态待确认」显示并直接提供启用/停用命令。Claude Code 的 MCP 同样以原生 `/mcp` 状态为准。
- MCP 工具预览按 [官方生命周期](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle) 建立临时连接，按 [工具发现协议](https://modelcontextprotocol.io/specification/2025-06-18/server/tools) 请求元数据。支持直接启动的 stdio 和 Streamable HTTP；`npx` 等可能触发安装的运行器不会自动启动，旧式 SSE 或需客户端专属认证的服务会显示可恢复的错误说明。
- 本页不处理远端、企业强制、插件自带的单独 MCP/Skill，也不承诺切换影响已经运行的会话。
