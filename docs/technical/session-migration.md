# 会话迁移：当前契约

会话页可把已结束回合的用户/助手正文迁入另一个客户端的新会话，通过现有终端路由恢复，或在 Cursor 桌面的项目历史中继续。Claude Code / Codex 来源可选择包含已完成工具的输入与结果。工作目录保持原项目或 worktree；目标客户端重新加载自己的项目规则、工具、权限和账号。迁移不是移动原文件，也不是迁移模型内部状态。

## 入口与范围

会话卡片悬停操作中的分支图标打开「继续于…」。目标为 Claude Code 当前配置、Claude Code 使用已保存的 Codex 自定义模型、Codex 当前配置、Codex 官方登录、Cursor CLI Auto、Cursor 桌面项目模型。先读取预览及遗漏说明，随后「创建并打开」。会话页的「迁移记录」可继续打开目标或把目标的新回合再迁往其他客户端。

Claude Code、Codex、Cursor CLI 与 Cursor 桌面的原生正文适配器已实现。桌面目标要求此项目已在 Cursor 创建聊天，以读取其原生 workspace ID 和模型配置；没有登记时明确提示先建立项目聊天。创建后通过固定版本的本地 deep link 直接选中迁移聊天；实测已打开的窗口无需重载即可载入刚写入的聊天。此链接来自该版本私有 renderer，不能当成公开稳定 API。若客户端未响应，用户仍可在历史搜索「ClaudeBar · 迁移」。程序不自动重载窗口。会话页原有 Cursor 卡片对应桌面会话；CLI 来源通过迁移记录提供，未增加 CLI 全量会话发现器。

「包含已完成工具的输入与结果」默认关闭。开启后预览显示记录数量，并提示这些资料会发送给目标模型。迁移只携带已配对完成的工具历史，保留 CC 的错误标记；它们成为有明确归档标记的普通文本，不转换为目标可执行工具调用，不重放文件或命令。Cursor 来源的原生工具详情仍只提示遗漏。

开发版在真实历史读取、客户端版本探测、写入和终端打开入口拒绝系统集成；不会迁移真实账号或凭据。纯转换器通过临时目录和模拟进程测试，不提供环境变量绕过 App 的闸。

## 数据与事务

- `MigrationSource` 保存客户端、原生 ID、cwd、标题与运行状态。
- `MigrationPreview` 包含正文消息、来源快照 SHA-256、工具记录计数与遗漏说明；存在完成工具时指纹加入转换选项标记，防止与纯正文目标混用。不保存来源的模型思考、provider item ID 或认证。
- `MigrationRecord` 保存来源关联、目标 ID/路径、逻辑会话 ID、模型/provider、配置指纹及可执行路径；新增可选 `bridgeProviderID` 兼容旧 format 1 记录；不保存供应商密钥。状态只称「已准备」。终端打开不能证明模型已经回复。
- 记录和暂存位于 `FilePaths.sessionMigrationsDir`，随 dev/release 数据目录隔离。正文写入目标客户端自己的原生目录，不复制 auth.json、keychain 或 settings。
- 先暂存，再安装新的原生文件，最后发布记录；安装拒绝替换，记录写入失败回滚本次目标文件，来源保持不动。JSONL/记录通过 `PrivateFileWriter` 写 0600；SQLite 在 0700 暂存目录创建并收紧为 0600。
- Cursor 桌面是现有共享数据库的特例：仅 READWRITE 打开，结构校验后 `BEGIN IMMEDIATE`，在同一事务插入新 ID 的 header、composer、bubble 和 hash blob；迁移记录发布后才 COMMIT。原生 KV 表的 UNIQUE 默认为 REPLACE，必须显式 `INSERT OR ABORT`；已存在共享 blob 逐字节比对，冲突拒绝。异常回滚本次行并移除本次记录，不删除或替换数据库文件，不改其他聊天。
- SQLite 与私有记录文件不是一个原子资源。崩溃发生在记录发布和 COMMIT 之间时可能留下缺失目标的记录；打开和复用必须检查该原生 ID 的 header/composer，拒绝伪造成功。目前不自动恢复这类记录。
- 同一来源快照、目标、模型、配置和可执行路径重复准备时复用存在的目标。目标再次迁移时沿用逻辑会话 ID。不会把旧目标的真实新回合覆盖为来源历史。

来源在准备前后核对指纹。当前配置目标同时核对原生配置与 ClaudeBar 供应商列表的指纹，防止模型名字相同但供应商已经切换。继续打开时再次检查配置、可执行路径、版本、目标文件和工作目录；变化后要求重新准备。官方 Codex 单独检查本机已有 ChatGPT 登录。

## 原生适配器

`MigrationHistory` 处理 JSONL。Claude Code 按最新主分支的 parent UUID 回溯；对于同一个流式助手响应的并行工具，额外收集父节点属于所选响应的 result-only 兄弟行，按文件顺序配对，不合并兄弟助手正文、混有普通正文的结果行或其他分支结果；Codex paginated 读取 ordinal 连续的 canonical 事件，legacy 读取 response_item 投影。legacy 续聊追加 canonical 事件后仍读取完整投影，避免丢失导入前缀。

`MigrationCursorHistory` 以只读 SQLite 事务读取桌面 bubble 正文或 CLI protobuf/blob 历史；CLI 校验 blob SHA-256，并写原生 meta TEXT、blob BLOB、消息和 turn DAG。客户端返回答案可能早于历史保存完成，读取器最多等待约 3.1 秒并重新打开快照；仍未完成则提示稍后重试。

`MigrationCursorDesktop` 写入固定版本 composer_v18 / bubble_v3 和 Agent protobuf 状态。仅从项目已有聊天提取 workspace/model 白名单，其余字段全新构造；不复制系统提示、上下文、加密 key 或 checkpoint。原生读取器需要的字典和计数字段必须保留正确默认类型。项目识别使用真实路径比对，但保留已登记的 URI 与 workspace ID 配对，不能把别名 URI 改写后仍使用旧 ID。模型设置来自近期项目聊天，项目标识和模型白名单参数一起加入准备指纹；同名模型参数变化也拒绝旧准备路由的复用。这不表示桌面窗口当前焦点聊天或账号被快照冻结，目标创建后用户仍可在 Cursor 改模型。

`MigrationPath` 使用 POSIX realpath 统一 cwd 和路径归属。Cursor CLI workspace key 为真实路径 UTF-8 的 MD5；桌面 workspace ID 读取现有登记，不猜测生成。Claude Code 目录编码按 JavaScript UTF-16 单元替换非 ASCII 字符。macOS `/var` 与 `/private/var` 的别名、符号链接和未创建的子目录都按相同规则处理。

`SessionMigrationService` actor 执行 I/O、版本探测和配置核对；`SessionMigrationModel` 在主 actor 更新界面。`TerminalLauncher.openMigratedSession` 复用既有终端路由。新 Codex rollout 可能尚未进入桌面索引，因此首版通过终端恢复。

Codex 当前配置以进程参数指定现有 provider/model；官方目标使用临时 provider 名 `claudebar_migration_official`、官方认证及 Responses HTTP。不会改写全局 provider 选择或把官方 token 交给 CC。迁入 CC 当前配置目标后使用 CC 的当前配置，迁入 Cursor CLI 后使用 Auto，迁入 Cursor 桌面后使用其项目已有模型设置。

## Claude Code 使用 Codex 自定义模型

选择「Claude Code · Codex 自定义模型」，明确选择已保存的供应商和模型。准备与继续都从供应商文件按 UUID 重新核对 endpoint、key、wire API、模型和推理强度的 SHA-256 指纹；全局活动供应商切换不影响这条路由，所选供应商修改后要求重新准备。当前实现支持 Responses 和 Chat 两种 API key 接入，不接收官方订阅 token。

桥接复用已有 Codex 本地代理，在 `/migration/<记录 UUID>/v1/messages` 和 `/count_tokens` 注册独立路由。代理先验证本地 token，再查路由；路由冻结目标模型，不采信请求的模型字段。供应商密钥仅留在内存，转发时只发送给该供应商。Claude Code 的 `--settings` 是本次进程的 JSON 覆盖，包含本地 URL/token 和固定模型别名；不激活全局供应商，不写 CC 全局 settings，不把上游 key 传给 CC。启用此路由时若代理尚未启动，以禁止配置修复的方式启动，避免顺带改写 Codex 配置。

`AgentProtocolBridge` 把文本、系统指令、普通函数工具及其错误结果转成 Responses；Chat 上游再复用现有转换器。Responses 文本和工具参数增量映射为 Anthropic SSE；Chat 文本流式输出，工具名/id/参数合并到完成后再输出，避免碎片名被错误执行。仅明确的完成或 token 上限终态生成 message_stop，失败和 EOF 不伪造成功；不支持的输入在请求前返回 400，过大返回 413，上游失败返回 502 或已开始流中的错误事件。完成、失败、截断、缓存 usage 与断开取消有独立回归。

`count_tokens` 是本地保守估计，不是厂商 tokenizer 或计费依据。工具搜索关闭，以普通函数定义传递工具；签名 thinking 不转换，未知附件/工具格式拒绝。新请求图片有映射单元测试，历史附件迁移仍拒绝，未做真实视觉调用。温度、采样参数或特殊推理状态未保证对所有供应商兼容。

每次运行最多注册 128 条迁移路由；路由和密钥仅存于进程内存。须保持 ClaudeBar 及代理运行，重启后从迁移记录点击「继续」重新注册。直接运行原生 `claude --resume` 不会自动重建此路由。已注册路由不随全局活动模型改变；没有新增独立后台服务、路由撤销 UI 或 OAuth 凭据库。客户端在活跃流中断开已验证会取消上游；上游长时间无字节时的取消时延仍受下一次写入和网络超时影响。

## 兼容边界

固定已验证版本：Claude Code 2.1.288、Codex CLI 0.159.0-alpha.12.1、Cursor CLI 2026.06.19-20-24-33-653a7fb、Cursor 桌面读写 3.23.12。未知目标版本拒绝写入；升级需要更新固定样本并重新验收。

文件上限 16 MiB、正文上限 400,000 UTF-8 字节、消息上限 8,000；Codex 文件发现最多遍历 60,000 项。首版不总结或截断超限历史。

桌面每条 bubble 携带原生 conversationState，实际展开可能更早达到 16 MiB，因此还做预分配估计和精确序列化体积检查；不能把正文上限当成桌面一定可导入的承诺。数据库被其他写事务占用约 2 秒后拒绝；不暂停或杀死 Cursor。

运行中、待确认、运行中子 agent、未完成工具、子代理、历史压缩、缺失 parent、重复 ID、分分页缺口和附件会拒绝。Codex 开启工具记录时，只支持已验证的 response_item 调用/结果配对；canonical 工具记录无法完整对应时明确拒绝，并提示关闭该选项。CC 工作目录编码超过 200 字符时拒绝，尚未实现其长路径哈希分支。多媒体历史、工具语义重建、Cursor 同模型桥接及新 OAuth 注册未实现。自定义模型到 CC 的跨协议桥已实现并以 Kimi Responses / DeepSeek Chat 验证；不表示任意供应商、MCP 工具或长任务均兼容。官方历史迁到 CC 当前模型已通过，继续消费 ChatGPT 套餐需另行实现官方 SIWC 授权和专用参数适配，不能复用现有登录文件冒充授权。

这些阈值约束本地转换，不能保证任意目标模型的 context window 足够，也不能保证它逐字使用所有旧事实。

## 验证

```bash
make test TEST=session-migration
make test TEST=agent-protocol-bridge
make test
make build
make release
```

测试直接编译生产转换器、存储、服务和终端入口，使用临时原生文件及模拟传输；覆盖 dev/release/未标记构建、事务失败、原生 REPLACE 冲突、共享 blob 损坏、数据库锁、来源/配置变化、版本门禁、官方登录缺失、原生编码、工具开关与延迟保存。协议桥测试直接使用生产状态机及生产 HTTP 传输切片，模拟上游和临时凭据，覆盖认证、冻结模型、并行参数、错误、截断与断开取消。第三阶段直接定位、Responses/Chat 原生 CC 工具与冷恢复证据见 [第三阶段完整报告](../reviews/session-migration-phase3-implementation-2026-10-03.md)。真实 Cursor 桌面 UI 续聊、冷重载、迁出及工具负对照见 [第二阶段验收](../reviews/session-migration-phase2-implementation-2026-10-03.md)；六方向 CLI 首版结果见 [首版报告](../reviews/session-migration-implementation-2026-10-03.md)，先前可行性及 GitHub 研究见 [深度调研](../reviews/session-migration-deep-research-2026-10-03.md)。
