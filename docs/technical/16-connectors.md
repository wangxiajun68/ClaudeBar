# 连接器管理

> ClaudeBar 技术文档 · §16
> 相关：[视图层](05-view-layer.md) · [数据访问层](04-data-access-layer.md)

主窗口「连接器」页统一展示 Claude Code、Codex、Cursor 的本机 Skills、MCP 和插件。页面首次打开及手动刷新时扫描固定目录；选择项目后额外读取该项目的配置。扫描在后台执行，不启动 MCP 服务器、不连接网络，也不读取 `SKILL.md` 正文，只提取前言里的名称、描述与 `metadata.requires.bins` 依赖声明。

## 界面与动效

页面沿用其他主窗口页面的 `PageTitle`、冰色画布、白色卡片与石墨色深色模式。左侧按客户端筛选，并有独立的「本机共享」入口；客户端清单可按 Skills、MCP、插件筛选，搜索覆盖名称、说明和来源路径。连接器和 CLI 都使用等高自适应宫格卡片。卡片直接标出 Skill、MCP 或插件；使用稳定的系统图标，点击正文打开详情，底部保留独立的启停控件。Cursor MCP 的当前状态无法可靠读取，因此卡片直接提供「启用」「停用」两个命令，状态标为「待确认」。共享 CLI 卡片显示关联能力数量，可一键筛出它提供的 Skills 与 MCP。空清单可直接清除筛选或选择项目，后台读取与操作中有独立反馈。

详情页按类型展示：Skill 读取 `SKILL.md`，以原生 SwiftUI 排版标题、正文、列表、引用、代码块和表格；MCP 在打开详情时连接服务，按协议完成初始化并请求 `tools/list`，显示工具名、描述和参数名，支持分页和重新读取，不发送 `tools/call`；插件显示清单描述、版本、安装位置及可发现的 Skill、命令、Agent 等组成。详情页均可复制路径、在 Finder 定位并打开原文件。文档解析和插件信息读取在后台进行，MCP 请求有超时及数量上限；滚动清单仍是固定高度的懒加载宫格。

交互细节参考 [Uiverse 元素目录](https://uiverse.io/elements) 的分段选择、层叠按钮、输入聚焦与开关触感，使用原生 SwiftUI 绘制并保持本项目配色。滚动区域使用 `LazyVGrid`，卡片固定高度，避免滚动时反复重排和绘制；卡片有悬停描边、阴影与 2pt 抬升（悬停状态变化，不是循环动画），减少动态效果时整体停用。卡片表面走全应用同一套四个部件（底 + 强调水洗 + 角上深度环 + 内嵌白环，见 [DESIGN.md](../../DESIGN.md)），筛选走同一颗 `SegmentedCapsule`：类型筛选、平台行、供应商客户端与分类、用量周期、VPN 分组都是同一个控件，因此这页不再有"第二种筛选长得像另一种控件"的问题。**3D 倾斜只在「连接器」这一页的卡片上**（`.depthTilt()`）——它只在被悬停的那一张上生效，成本上界是一棵子树，不进任何滚动的 200 卡网格。详情才做文件存在性检查。系统开启“减少动态效果”时，非必要动效停用。

## 本机 Agent CLI

Agent CLI 单独扫描，属于本机共享环境。只按固定候选名检查常见安装目录和 `PATH` 中的可执行文件，不执行 `--version`、不读取登录信息。候选范围限于服务集成（例如 `lark-cli`、腾讯文档、`gh`、`obsidian`）、MCP 工具（例如 `mcporter`、`happy-mcp`）和 Agent/Skill 管理工具（例如 `openclaw`、`oc-skills`、`skillhub`）；不扫描 `node`、`npm`、`docker` 等通用开发环境，也不把三个客户端自己的 CLI 算作共享连接器。CLI 清单只在首次进入和手动刷新时重新扫描，切换项目或启停连接器不会重复查找。

CLI 关联能力按**显式来源**归属：Skill 的 `SKILL.md` 前言 `requires.bins` 命中已知共享 CLI，或 MCP 配置的 `command` 直接指向该 CLI，就移入「本机共享」中的关联 Skills/MCP 宫格；三个客户端页及其数量不再重复展示。多个客户端若分别配置了同一 CLI 的 MCP，仍保留各自的配置记录与启停入口，并在卡片上标明客户端。不会因为名称含有 `lark` 等字样就猜测归属。若关联 Skill 存在但 CLI 未找到，卡片显示「缺少 CLI」。当前机器的 `~/.agents/skills` 有 28 个声明依赖 `lark-cli` 的 Lark Skill；Claude 目录下对应符号链接不重复扫描。通过 `npx` 等通用运行器间接启动、无法从命令字段明确识别的 MCP 仍留在原客户端。

## 各平台启停机制

| 平台 | Skills | MCP | 插件 |
| --- | --- | --- | --- |
| Claude Code | 原生 `skillOverrides` 支持 `on` / `name-only` / `user-invocable-only` / `off`。本页对独立本地目录采用可逆移库；插件内 Skills 应随插件管理。 | `/mcp` 的开关按项目写入 `~/.claude.json` 的 `disabledMcpServers`；`.mcp.json` 还有独立的批准/拒绝机制。本页只展示来源并指引到 `/mcp`，避免改写整个状态文件。 | `claude plugin enable/disable` 是官方 CLI。本页只对用户级已安装插件调用 CLI；项目、组织和云同步插件交还客户端。 |
| Codex | 从 `.agents/skills`、`.codex/skills` 等目录发现；没有稳定的逐 Skill 配置开关。本页把独立本地目录移到 ClaudeBar 停用区。 | `config.toml` 的 `[mcp_servers.<id>] enabled = false` 可停用，`true` 可恢复。本页只改对应表的一行。 | 本地市场插件可用 `[plugins."name@marketplace"] enabled = false` 配置。本页只管理配置文件中可见的插件表；其余本机缓存标记为「状态待确认」，不当作已安装。云端或管理员分发的不在本机目录内。 |
| Cursor | 从 `.cursor/skills`、`.agents/skills` 等位置发现，也兼容 Claude / Codex 的 Skills 目录。本页移库时会显示共享影响。`disable-model-invocation` 仅关闭自动调用，仍可手动调用，因此不能当作完整停用。 | `agent mcp enable/disable <identifier>` 是官方 CLI；本页调用它处理本机 JSON 中可见的 MCP，状态仍以 Cursor 为准。 | Customize 是官方管理入口。本页展示本地插件和缓存来源，并明确标注缓存不代表已安装，不直接改写私有安装状态。 |

官方依据：[Claude Skills](https://code.claude.com/docs/en/skills)、[Claude MCP](https://code.claude.com/docs/en/mcp)、[Claude Plugins](https://code.claude.com/docs/en/discover-plugins)、[Codex Skills](https://learn.chatgpt.com/docs/build-skills)、[Codex MCP](https://learn.chatgpt.com/docs/extend/mcp)、[Codex Plugins](https://developers.openai.com/plugins/build/plugins)、[Cursor Skills](https://prod.cursor.com/docs/skills)、[Cursor MCP CLI](https://prod.cursor.com/docs/cli/mcp)、[Cursor Plugins](https://prod.cursor.com/docs/plugins)。

## 停用本地 Skill

把整个 Skill 文件夹移动到 `~/Library/Application Support/ClaudeBar/DisabledSkills/`，并把原路径与停用区路径写入该目录的 `registry.json`。恢复时若原路径已被占用则拒绝覆盖。写登记失败会尝试将文件夹移回。扫描跳过符号链接和隐藏目录，因此不会移动插件缓存、系统 Skills 或链接到外部位置的目录。共享根目录可能同时被 Codex 和 Cursor 读取，Claude Code 的目录也可能被 Cursor 读取；列表按来源显示影响平台。

## 写入与边界

- Codex TOML 只替换目标表的 `enabled` 行，其余字节保留；写入前再次读取并比对文件，避免覆盖扫描之后的更改。临时文件和原文件保持私有权限，完成后同目录原子替换。
- Skill 移库操作经过串行化，防止两个开关同时改写登记文件。
- CLI 调用只传固定子命令与扫描到的标识符，不经 shell 拼接；不输出配置内的令牌或错误正文。
- Cursor 的 CLI 开关状态无法从公开的稳定磁盘格式确定，页面以「状态待确认」显示并直接提供启用/停用命令。Claude Code 的 MCP 同样以原生 `/mcp` 状态为准。
- MCP 工具预览按 [官方生命周期](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle) 建立临时连接，按 [工具发现协议](https://modelcontextprotocol.io/specification/2025-06-18/server/tools) 请求元数据。支持直接启动的 stdio 和 Streamable HTTP；`npx` 等可能触发安装的运行器不会自动启动，旧式 SSE 或需客户端专属认证的服务会显示可恢复的错误说明。
- 本页不处理远端、企业强制、插件自带的单独 MCP/Skill，也不承诺切换影响已经运行的会话。
