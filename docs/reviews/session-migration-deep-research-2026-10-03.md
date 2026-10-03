# Codex、Cursor、Claude Code 会话互迁与模型切换：深度调研及真实验证

调研日期：2026-10-03。CC 指 Claude Code 客户端。本文是 ClaudeBar 的技术可行性报告与实验交付，**迁移原型已经实际运行，但会话页尚未接入生产功能**。

## 1. 结论与建议

**三种客户端之间的六个转换方向都能实现正文历史迁移并继续对话。** 本次用真实账号/供应商建立源对话，自编转换器写入目标原生格式，再让目标模型回答不包含原答案的新问题。Codex 与 CC 使用原生 CLI；Cursor 的 CLI 和 3.23.12 桌面端分别验证，桌面端实际显示迁移历史并完成模型续聊。

**官方与自定义 Codex 的切换也可做，但不能只换 provider 然后原样恢复所有历史状态。** 自定义 Kimi → 官方 GPT 的原生 fork 本次真实失败：官方服务找不到历史中自定义服务产生的 reasoning item ID。转换为可移植正文、重建新会话后，同一来源立即成功。因此产品默认应创建有来源关联的目标分支，在 ClaudeBar 中把它们显示为同一条逻辑会话。

**换会话客户端、换模型、换认证/计费是三个不同操作。** 官方 GPT 的历史已经成功进入 CC，但本机 CC 接着使用的是其配置的 DeepSeek。自定义 Kimi 的历史进入 CC 后仍使用 Kimi，也通过自编 Responses → Anthropic 协议桥接实际跑通；桥接目前只验证文本。Cursor 继承自定义会话后使用其自身 Auto / Grok 模型，尚未证明任意 Kimi endpoint 可以直接成为 Cursor 的模型。

推荐先实现：**六方向的正文/任务上下文转换、来源关联、正确 cwd/worktree、目标进程的独立模型配置、失败时回退到新的可移植分支**。Cursor 桌面写入应列为固定版本的实验能力；长历史、原生工具结构、图片和不透明压缩另做兼容验收。

## 2. 实际使用的客户端、模型与账号

| 客户端 | 本机版本 | 真实模型/路径 | 会话与认证处理 |
|---|---|---|---|
| Codex 官方 | 0.159.0-alpha.12.1 | gpt-6.1-sol，ChatGPT 官方认证 | 原生认证保持在已有目录；CLI 只创建新的合成实验线程 |
| Codex 自定义 | 同上 | kimi-k3，已有自定义 Responses provider | 私有临时 CODEX_HOME；key 仅进程环境，不复制官方 auth.json |
| Claude Code | 2.1.288 | deepseek-v4.1-flash，经本机已有 Anthropic 兼容网关 | 私有临时 CLAUDE_CONFIG_DIR；关闭工具、MCP 和用户配置来源 |
| Cursor CLI | 2026.06.19-20-24-33-653a7fb | Auto，经已有 Cursor 账号 | 临时 CURSOR_CONFIG_DIR / DATA_DIR；认证存储使用内存模式 |
| Cursor 桌面 | 3.23.12 | Grok 4.7 Medium，经已有 Cursor 账号 | 新空实验工作区；只新增合成聊天，真实旧会话只读 |
| CC + 自编协议桥 | 2.1.288 | 同一 kimi-k3 自定义 Responses 上游 | CC 连接随机回环端口；桥在内存中使用自定义供应商 key |

本次没有本机 Anthropic 官方 Claude 模型的实测，也没有把 Cursor CLI 的 Auto 宣称为固定模型。Cursor 的源原生记录显示 Auto 路由到其模型，这个路由将来可能变化。

网络请求使用用户允许的 `127.0.0.1:17890` 代理，未更改系统代理。没有启动 ClaudeBar、安装正式版、运行 VPN/硬件测试、修改客户端全局 provider 选择、复制真实旧聊天到网络、调用真实 Codex app-server。Codex CLI 会正常维护自身新增实验线程及认证生命周期，不能把这说成完全不写原生用户目录。

## 3. 如何证明是真正续聊

每个源客户端先接收一个独立随机标记，例如 `MIGRATE-5f44f4266d2b`，以及三项事实：`never edit VERSION`、`verify parser regression`、`keep original session`；模型真实回复 ACK。随后读取其原生持久化记录，只提取用户/助手正文，转换为目标格式。

目标只收到如下新问题，不包含任何预期答案：

> From our previous conversation, return only a JSON object with keys marker, constraint, next_step, decision and their exact remembered values. Do not use tools or read files. If a fact is absent, use "unknown".

验收检查四个事实逐项恢复；尤其随机标记无法由一般常识猜出。新目标 CLI cwd 为空，没有放置交接摘要或答案文件；Cursor 桌面模型通过新会话原生历史获取源事实。随后用新的客户端进程按目标 ID 再 resume，检查落盘和再次续聊。三个没有历史的新会话收到相同问题，都回答四项 unknown，排除了问题本身包含答案。

结果里的 `exact_match` 表示四项事实均恢复。优先解析 JSON 字段；模型返回不完整 JSON 时，检查四个完整事实字符串。**它不是严格 JSON 格式合规指标。** 本机 CC 使用的 DeepSeek 网关多次返回缺少前缀的 JSON 文本；事实仍正确。这是本次响应格式现象，未定位根因，不应解释为迁移器已经解决流式兼容问题。

可审阅证据：[脱敏结果 JSON](session-migration-live-results-2026-10-03.json)，以及[实际实验代码和复现说明](session-migration-lab-2026-10-03/README.md)。结果不含 key、token、原生系统提示、用户真实旧聊天或桌面加密字段。

## 4. 六方向真实转换矩阵

这里的 Codex 为本次官方 GPT 来源/目标；自定义情况在下一节。

| 方向 | 本次实现 | 真实事实回忆 | 退出后恢复/桌面表现 |
|---|---|---|---|
| Codex → CC | canonical 正文 → CC JSONL 父子消息链 → `claude --resume` | 通过 | 新进程再次 resume 通过 |
| CC → Codex | CC 正文 → Codex rollout message/event → `codex exec resume` | 通过 | 新进程再次 resume 通过；另有实际编程交接 |
| Codex → Cursor CLI | 正文 → SQLite blobs/meta + protobuf turn DAG | 通过 | 新进程再次 resume 通过 |
| Cursor CLI → Codex | 按 root 引用顺序读取正文，去掉供应商状态 | 通过 | 新进程再次 resume 通过 |
| CC → Cursor CLI | CC 正文 → 同上 Cursor CLI 格式 | 通过 | 新进程再次 resume 通过 |
| Cursor CLI → CC | root 正文 → CC JSONL | 通过 | 新进程再次 resume 通过 |

桌面端另做了四项真实验证，不能由上述 CLI 表自动推导：

| 方向 | 结果 | 实际验证内容 |
|---|---|---|
| Cursor 桌面 → CC | 通过 | 桌面真实源模型回复 ACK；按新 composer 的有序 bubble 正文转换；CC 回忆正确 |
| Cursor 桌面 → Codex | 通过 | 同一真实桌面来源；官方 GPT 回忆正确 |
| CC → Cursor 桌面 | 通过 | 新会话在 Agents 列表出现，旧正文可见；Grok 回忆 CC 的独立随机标记 |
| Codex 官方 → Cursor 桌面 | 通过 | 新会话在列表出现，正文可见；Grok 回忆官方 Codex 的独立随机标记 |

因此，若产品中的「Cursor」指桌面端，六个方向也都有本次短文本续聊证据。不是全部方向都测试了桌面重载后的第二轮：桌面重载续聊对自定义 Codex 来源额外测试了一例，结果通过；另两条迁移历史在重载后也仍然可见。

六方向的 CLI 目标恢复目前约 CC 0.6–2.7 秒、官方 Codex 15–16 秒、Cursor CLI 26–33 秒。这是本机短上下文、当前网络和模型的实验耗时，含客户端启动和推理，**不是转换器耗时或产品 SLA**。产品可以减少操作步骤，但不能承诺所有目标立即产出回答。

## 5. 官方与自定义模型切换的真实结果

| 来源 → 目标 | 方法 | 结果 | 含义 |
|---|---|---|---|
| 官方 GPT Codex → 自定义 Kimi Codex | 原生 `exec fork`，覆盖本次进程 provider/model | 通过，约 19.8 秒 | 这个源短会话允许原生分支换供应商；源文件指纹未变 |
| 自定义 Kimi Codex → 官方 GPT Codex | 保留原生历史，直接 fork + provider 覆盖 | **失败**，退出 1 | 官方服务返回 404，找不到自定义来源 reasoning item ID |
| 同一 Kimi 来源 → 官方 GPT Codex | 只携带用户/助手正文，重建干净 rollout 再 resume | 通过，约 14.9 秒 | 可移植历史绕开了供应商内部状态；再次冷恢复也通过 |
| 自定义 Kimi Codex → CC / DeepSeek | 正文转换为 CC 原生 transcript | 通过 | 换客户端并换模型；再次冷恢复通过 |
| 自定义 Kimi Codex → CC / 同一 Kimi | 正文转换 + 自编 Anthropic ↔ Responses 文本协议桥 | 通过，约 4.6 秒 | 换客户端保留真实上游模型，不是模拟服务返回预设答案 |
| 自定义 Kimi Codex → Cursor CLI / Auto | 原生 CLI 格式嫁接 | 通过 | 继承历史，目标使用 Cursor 自己的模型；再次冷恢复通过 |
| 自定义 Kimi Codex → Cursor 桌面 / Grok | 新桌面格式嫁接 | 通过 | UI 可见且实际模型回忆正确；窗口重载后第二次提问也通过 |
| 官方 Codex → CC / DeepSeek | 正文迁移，使用 CC 自己的认证 | 通过 | 官方来源不妨碍历史转换；计费与目标认证独立 |

失败响应的关键内容是 `Item with id 'rs_…' not found`，并提示该 item 未在目标服务持久化。失败发生在源会话已经正确找到、目标官方服务也已收到请求之后。本次随后保留正文、移除 reasoning/provider ID，官方服务即成功；因此至少在此样本中，问题是携带了不兼容历史状态，不是账号无法使用或文本历史不可迁移。

本次没有测试所有自定义服务、所有模型及其工具能力。一个 Kimi Responses 上游通过，不代表所有宣称兼容 OpenAI 的网关都兼容 Codex，更不代表任意 Chat Completions endpoint 能直接用 Codex 本机当前版本。

## 6. 官方登录/额度如何在 CC 继续

需要给用户明确三个选择，而不是只有一个模糊的「切换」按钮。

| 用户想要的行为 | 可行性 | 做法与本次验证 |
|---|---|---|
| 官方 Codex 的历史，在 CC 用 CC 当前模型继续 | 已实测 | 转历史；认证使用目标 CC；本次 DeepSeek 接续成功 |
| 官方 Codex 的历史，在 CC 用自己的 OpenAI API 模型继续 | 有条件可实现 | CC 需要 Anthropic 兼容网关/协议桥；OpenAI API key 与模型授权另配置；本次没有 OpenAI API key 实测 |
| 官方 Codex 的历史，在 CC 保留 ChatGPT 套餐与 GPT 模型 | 有正式接入方向，尚未端到端验证 | 新的 SIWC 套餐授权 + 公共 Responses + CC 协议桥；不能把已有 auth.json 当作通用 CC key |

OpenAI 的普通 Codex 登录分为 ChatGPT 套餐认证和 API key 认证；API key 走独立 API 计费。[官方认证说明](https://learn.chatgpt.com/docs/auth)

**新发现：目前官方已提供 Sign in with ChatGPT 的第三方应用套餐调用文档。** 对开源/本地托管应用，客户端可经正式 OAuth 注册和用户授权申请 ChatGPT plan usage。它不授予读取 ChatGPT 原会话的权限；本地会话历史仍需迁移。本次原生 Codex 已有 token 对公共 `/v1/models` 的只读探测返回 **403**，且可见 scope 未包含相应 sharing/responses 权限；这证明本机现有登录不能直接当作该新流程已经授权的凭据，不能推导整个 SIWC 能力不可用。[正式接入概览](https://developers.openai.com/siwc/token-sharing-open-source)

建议架构：ClaudeBar 提供单独的「ChatGPT 套餐授权」连接，持久化独立 host ID；取得此客户端获准的 OAuth token 后，由网关转译 CC 的 Anthropic 请求，调用公共 `api.openai.com/v1/responses`。不要在第三方集成中使用 ChatGPT 私有 backend-api。模型从对应账号的目录获取，处理流结束、额度失败及 token 更新。[模型与推理规范](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)

这一路径目前要求 `store:false`、`stream:true`，HTTP 不带 `previous_response_id`，每次发送所需 input 历史；部分请求字段及托管工具不支持。完整 CC 工具桥必须做工具名称、参数、结果和流事件映射，不能直接复用本次文本 Kimi relay 的全部请求字段。[预览限制](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)

本次只调查了文档和现有 token 的公共目录探测，**未新增 OAuth 客户端注册、未授予新的套餐权限、未验证官方套餐经 CC 发出实际推理**。套餐可接入应列为独立后续里程碑，不列入本次已通过矩阵。付费或远程托管应用的适用范围需按当前官方接入流程确认。

## 7. 自定义模型如何跨平台保留

本次原型真实路径：

```text
Kimi Codex transcript
  → 用户/助手正文
  → CC 原生 transcript
  → claude --resume
  → 本机 Anthropic 兼容接口
  → 自编协议转换
  → 已有 Kimi Responses 服务
  → 转回 Anthropic SSE
  → CC 保存并展示模型新回答
```

上游实际收到 `user → assistant → user`，没有工具定义，模型为 kimi-k3，回答恢复了原来的随机标记和约束。这证明「同一自定义模型换成 CC 前端」在文本范围内可行。CC 官方也说明第三方 LLM 网关需提供兼容接口及对应认证配置。[CC 网关文档](https://code.claude.com/docs/en/llm-gateway)

工程上至少分三类：

| 自定义上游 | Codex 当前路径 | CC 路径 | Cursor 路径 |
|---|---|---|---|
| Responses 兼容 | 用专门 provider 配置；本次 Kimi 实测 | 原生 Anthropic 不直接匹配，需要兼容网关或桥；本次文本桥实测 | 依赖 Cursor 的模型目录/BYOK支持；任意 endpoint 未验证 |
| Anthropic Messages 兼容 | 需要 Responses 网关，不能只改 URL | 配置 Anthropic base URL 和 target model；本机 DeepSeek 即此类 | 需符合 Cursor 支持的 provider / 模型接口 |
| Chat Completions 兼容 | 当前实验版本需 Responses 转换层，不能当作直接可用 | 需要 Anthropic 转换层或上游双协议 | 可能适配其支持的 chat/BYOK路径，必须按版本实测 |

跨协议的完整工具桥难点包括：function/custom tool 命名、tool call/result 配对、多次工具迭代、SSE 增量顺序、思考/签名、结构化 JSON、图片附件、取消/重试、token 用量和参数差异。本次桥把上游完整文本响应转换成 SSE 返回 CC，没有证明低延迟逐 token 转发，也没有验证任何工具调用。

Cursor 官方 BYOK 文档支持指定供应商及模型范围，并说明请求会经 Cursor 后端构建提示；因此不能假定给 Cursor 填 `127.0.0.1` 就能像 CC 一样访问本机协议桥。自定义模型目录、远端网关可达性和产品版本是额外条件。[Cursor BYOK](https://cursor.com/help/models-and-usage/api-keys)

## 8. 官方现成能力与本次适配器的关系

**Codex：** 官方 `/import` 支持从 Claude Code / Cursor 等外部工具导入近期会话；CLI 文档有最近 30 天最多 50 条的发现范围。app-server 有 `externalAgentConfig/detect` 与 `externalAgentConfig/import` 的 SESSIONS 能力。产品接入时应优先正式接口；本次因仓库的开发隔离规范，没有调用真实 app-server，实验用了独立 Codex CLI 和新生成的 rollout。[导入说明](https://learn.chatgpt.com/docs/import)、[app-server 协议](https://learn.chatgpt.com/docs/app-server)

**CC：** `claude import codex` / `/import codex` 官方定义是配置、指令、技能、MCP 等导入，不能据此宣称会话历史已导入。正文转换后的接收入口是原生 `--resume`，支持 ID/名称/绝对 JSONL 路径，并有 fork 能力。[命令说明](https://code.claude.com/docs/en/commands)、[CLI 参数](https://code.claude.com/docs/en/cli-reference)

**Cursor CLI：** 原生 resume 可以接续自己的会话；ACP 提供 session/new、load、prompt 等标准宿主接口，但未在所查协议中发现通用外部历史导入方法。ACP 宿主会话存储不能直接当成普通 CLI store.db 的相同路径；本次没有测试 ACP 导入。[Cursor ACP](https://cursor.com/docs/cli/acp)、[CLI 参数](https://cursor.com/docs/cli/reference/parameters)

**Cursor 桌面：** 本机 Agents 窗口实际出现原生 Claude Code 导入入口。打开弹窗，界面说明读入 chats 后通过后续消息 fork，插件/skills 是独立同步项目。原生导入设置当前为关闭；弹窗会面对其他真实聊天，因此本次没有点击全量 Sync。不能再说 Cursor 桌面完全没有官方 CC 会话导入能力；本次通过的是自编适配器，而不是这个原生流程的全部验收。

## 9. 存储格式与实际嫁接实现

### 9.1 中间表示

原型的中间表示刻意很小：有序 `{role:user|assistant, text}`。它足以验证跨客户端上下文，但产品需扩展为带来源、消息身份、时间、工具证据、附件和遗漏清单的结构。不能把当前实验脚本当作一般会话 reader。

### 9.2 Codex

当前本机原生来源为 paginated history；优先读 `event_msg.item_completed` 的 `UserMessage` / `AgentMessage`。同文件 `response_item.message` 还保存供应商投影、环境与开发者指令，二者全拼会重复并污染目标上下文。

针对短合成来源，自编转换器输出新 `session_meta`，然后分别写 user/assistant 的 `response_item` 和会话事件，正文保持角色；目标 CLI 按新 UUID 真正 resume 并维护后续历史。没有把来源 auth、私有思考、provider message ID 或服务端引用当作对话内容。

生产 reader 需检查根历史是否完整、ordinal 是否连续、是否存在 `history_base`、子代理投影、缺页/半行及压缩后的替代历史；无法重建时必须明确拒绝或进入交接摘要模式。当前实验 reader 只处理本次完整短会话，没有实现这些通用情况。参考工具当前已经对其中多种情况显式拒绝。[session-migrate 的 Codex reader](https://github.com/xhluca/session-migrate/blob/c23b1dbd21404f78be3b69d42ff4fb158ff52105/src/session_migrate/formats/codex.py)

### 9.3 CC

写入新 session UUID、message UUID 与 parentUuid 链，user/assistant 保留角色，助手正文放 text blocks；以目标 cwd 的项目编码目录保存，原生 CLI resume 后生成真实新回答和状态。原型对短单支来源按顺序读取；产品需按有效父链选择分支，不能把多个分支或 sidechain 全拼。

项目正式版更适合先把转换 transcript 写到 ClaudeBar 自有私有目录，再使用 CC 的绝对 transcript resume/fork 入口，让 CLI 建立它自己的目标持久化记录。这样可以减少对 CC 全局索引的直接编辑。本次实际矩阵用的是隔离 config 下的新原生项目文件。

### 9.4 Cursor CLI

本次实际验证的位置为 `CURSOR_CONFIG_DIR/chats/<md5(resolve(cwd))>/<UUID>/store.db`。`blobs(id TEXT, data BLOB)` 保存 SHA-256 寻址内容；`meta['0']` 为 hex 包装的会话 JSON。

模型正文通过 protobuf root 的有序消息 hash 引用；可见 turns 则有 user message、assistant step、turn structure 的 DAG。转换器同时生成这两条结构，再写 workspace URI 与模式、metadata。只创建一个空的 store.db 或复制 JSONL transcript，不等于模型已获取上下文。

路径和模式都属于版本兼容点；cwd 的符号链接/真实路径不同可能改变 hash 和会话发现结果。恢复必须锁定确切原 cwd/worktree，不能只以项目 basename 匹配。

### 9.5 Cursor 桌面 3.23.12

本次自编嫁接实际写入：

- `composerHeaders` 的新会话索引，包含 workspaceId、recency 与 header JSON；
- `cursorDiskKV` 中新的 `composerData:<id>` 和 `bubbleId:<id>:<messageid>`，完整正文和顺序；
- `agentKv:blob:<sha256>` 的历史内容/turn blobs；
- composer 的 `conversationState` 引用及对应新会话 workspace 信息。

模板仅来自本次刚创建的合成桌面会话；为导入消息和会话生成全新 UUID，去除模板的思考/加密字段；共享 blob 如已存在只校验内容，不覆盖其他会话。一次事务插入新数据。重载实验窗口后，三个新会话出现在原生列表，旧正文可见，三次真实模型都继承了各自事实。

这证明新版格式有可实现路径，**没有证明上述所有字段都是最小必需条件**。例如 txcript 作者对其测试版本记录了由 bubbles 重建 agentKv 的能力；本次为消除模型上下文缺失，主动补齐两套结构，未做删字段消融验证。[txcript 桌面格式研究](https://github.com/skillsynchq/txcript/blob/main/docs/formats/cursor-desktop.md)

生产风险主要是版本升级、SQLite 并发和客户端内存缓存。CLI 创建目标与桌面写目标不可共用一个 adapter；写入成功也不能算 UI 已发现。当前实验需要窗口重载，尚不满足不打断用户界面的“一键立即可见”。

## 10. GitHub 上的类似实现与选型

以下能力来自作者代码/README；除明确注明外，本次没有安装运行这些第三方工具。真实矩阵运行的是自编原型，不能把它标为这些库全部通过本机验收。

| 项目 | 调研到的能力 | 可参考之处与边界 |
|---|---|---|
| [ctxmv](https://github.com/Ryu0118/ctxmv) | Swift 工具，CC/Codex/Cursor CLI 互迁；明确不支持 Cursor GUI | 最贴近 ClaudeBar 技术栈；本次审查了 root/turn blobs、SQLite writer 与 Codex writer；不直接照搬其 Codex 消息生成细节 |
| [session-migrate](https://github.com/xhluca/session-migrate) | 多客户端原生格式、迁移清单；当前 Codex reader 区分 legacy/paginated | 参考格式验证、未知状态拒绝、工具/媒体边界；旧验证报告不等于当前实现支持范围 |
| [cursor-session-interoperability](https://github.com/xhluca/cursor-session-interoperability) | 固定 2026.03 CLI 的干净格式研究、合成 DAG 与原生运行证据 | 很好的“实际上下文进入模型协议”验收思路；该固定旧版本不能代替本次六月 CLI |
| [txcript](https://github.com/skillsynchq/txcript) | Rust/CLI/WASM 的会话转换，单独研究 Cursor 桌面新 header 表与消息记录 | 当前桌面结构参考价值高；作者区分 native round-trip 与通用格式损失；不能假设适用于本机全部版本/模型 |
| [MoveZ](https://github.com/kv4u/MoveZ) | Cursor 桌面 transcript、global cursorDiskKV、workspace 登记 | 证明有人尝试 GUI 原生导入；所审 writer 没有维护本机新 composerHeaders 表，其空 conversationState 不能直接作为本机续聊保证 |
| [agenthop](https://github.com/CyrusSE/agenthop) | 多 agent 的列表、查看、迁移、恢复入口 | 参考统一操作体验；客户端分支/版本覆盖需单独验收 |
| [leftoff，原 codex-resume](https://github.com/ostiums/leftoff) | Codex/ChatGPT Work 到 CC 原生会话，处理工具文字和媒体 | 与官方 Codex → CC 路线接近；仓库已更名，不能停留在旧帖子里的名称与版本结论 |
| [tandem](https://github.com/Bhavya6187/tandem) | CC 与 Codex 成对会话及持续上下文转换 | 最接近“快速来回切”；工具映射/运行所有权比一次复制更难；本次未验证其长期同步一致性 |
| [resume-from](https://github.com/alexei-led/resume-from) | 可审阅的上下文预算与交接，原生目标恢复 | 参考正文/证据精简与目标接续；不把 shell 进程当可迁移状态 |
| [CC Switch](https://github.com/farion1231/cc-switch/blob/main/docs/user-manual/en/3-extensions/3.4-sessions.md) | 会话发现、阅读与按原客户端恢复 | 统一列表并不自动意味着格式互转；需区分管理器与转换器 |

重点源码核对的固定版本：ctxmv `44854474ac26d2152299d08b6a9c376b5681a067`；session-migrate `c23b1dbd21404f78be3b69d42ff4fb158ff52105`；MoveZ `16cfe35cfda0d3c7af283a30616f2ce803d744c0`。另外检查了 OpenAI 官方外部迁移实现 `8f7a0f7a878199c6886600370e5be6bd37ca38a3` 的消息转换/持久化路径。后续引入任何项目代码前，需按选定 commit 核对许可证和依赖，而不是运行网络上的一行安装命令。

选择建议：Swift 产品实现参考 ctxmv 的适配划分，Codex reader 参考 session-migrate 的严格拒绝规则，Cursor 桌面参考 txcript 的新表结构；全部通过 ClaudeBar 自己固定版本的适配层与回归验证。无需为第一版新增常驻 Python/Node 服务。

## 11. 能做、不能原样做、难做

| 对象 | 判断 | 产品处理 |
|---|---|---|
| 用户/助手正文、约束、决策、下一步 | 能做，短会话已实测 | 保留角色顺序，恢复到目标新会话 |
| 当前项目文件和未提交修改 | 同一实际 cwd/worktree 可继续使用；另一个目录不会自动拥有 | 指向原 worktree；远端/跨机另做文件与 Git 状态交接 |
| 历史命令、测试结果、文件改动证据 | 能作为不可执行文字携带 | 标明历史、关键输出、退出码；不要伪造目标工具调用 |
| 当前正在运行的终端、审批、未完成工具调用 | 不能通过 transcript 原样迁移 | 等完整轮次边界；维护单个修改者的运行所有权 |
| MCP 登录、插件授权、系统权限、key、账号/额度 | 不随历史迁移 | 使用目标已有连接；额外连接单独授权 |
| 带签名/加密思考、服务端 item/response/cache ID | 不能通用原样迁移；本次有直接失败证据 | 跨 provider 丢弃或转为明确可读的工作结论；不伪造签名 |
| 超长历史、压缩、分支、子代理 | 难做，未完整验收 | 有效父链和历史引用解析；完整存档与工作摘要分开；显示遗漏 |
| 图片/音频/附件 | 部分可适配，本文无真实跨平台媒体验收 | 逐类转换和存在性检查，超范围明确提示 |
| 在另一个客户端保留同一自定义模型 | 条件可行；Kimi → CC 文本已实测 | 协议、认证、模型支持分开检查；完整工具桥另验收 |
| 保留 ChatGPT 套餐到 CC | 有正式 OAuth 接入方向，但本次未获新增授权/实测推理 | SIWC 客户端 + 正式公共端点 + 协议桥，独立里程碑 |
| 无刷新地注入 Cursor 桌面并立刻可见 | 本次未达成 | 优先原生导入/开放入口；数据库方式保留实验标志与恢复策略 |
| 三方持续双向合并同一 ID | 不应假定能做 | 单一逻辑会话 + 多个原生分支，切换增量和去重，不同时写同一源文件 |
| 所有模型行为、权限和工具体验完全一致 | 无法由格式转换保证 | 展示目标模型和工具能力，让目标执行自己的权限策略 |

历史文字化能避免转换器重放调用，但目标模型仍可能决定再次运行工具。完整生产交接需区分“历史已执行”和“下一步待执行”，并由目标权限约束动作。

## 12. ClaudeBar 如何做出丝滑体验

### 12.1 用户可见流程

在会话卡片增加「继续于…」，目标选择包括 CC、Codex、Cursor，并明确 Cursor CLI/桌面。目标旁显示实际模型、认证类型和 cwd；默认复用先前成功组合。点击后后台准备目标分支、启动/打开目标，等待首轮接续成功，再把目标卡片与源卡片归入同一逻辑会话。

对于支持的短正文会话，用户不需要复制粘贴或手填 UUID。长上下文、不可携带附件、供应商不匹配时显示精简范围与目标能力。切换失败保留源与可重试目标，不把失败分支当作成功会话。

若目标为不同供应商，默认使用去除私有状态的正文分支；同供应商且版本兼容时，可优先原生 fork。正文分支有新原生 ID，但 UI 可以呈现为连续的任务时间线。用户再次切回时，把新完成的目标轮次作为增量追加到新的接收分支，避免反复复制整段历史。

### 12.2 最小模块与持久化

建议复用现有监控、ProviderStore 与终端路由，新增小型迁移服务和适配器，不建立第二套会话系统。逻辑记录至少包括：

```text
logicalConversationID
sourceClient + sourceSessionID + sourceFingerprint + branchTip
sourceCwd + canonicalCwd/worktree
migrationFormatVersion + source/targetClientVersion
transferredMessageCount + omissions + contextBudget
nativeTargetID + targetRuntime + providerReference + model
status: prepared / materialized / opening / continued / failed
```

providerReference 只保存配置引用，不存 key。复用 `PrivateFileWriter` 写私有中间文件与 manifest。目标会话材料全部成功后再公开索引；同源同目标同 tip 按指纹去重，但新 source tip 应允许再次迁移。

已有接入位置：

- `ExternalSessionMonitor.swift`：Codex index/rollout 已有读取基础，但模型需能安全解析/验证源 rollout 路径。
- `SessionMonitor.swift`：现以活跃 CC 进程为主；新迁移的非运行历史需要先用迁移记录展示，再与原生进程关联。
- `CursorSessionMonitor.swift` / `CursorDB.swift`：已有桌面只读发现；需要明确 CLI 与桌面是不同 runtime，不能沿用同一个存储实现。
- `TerminalLauncher.swift` / `OttyBridge.swift`：复用目标 ID、cwd 与终端选择，避免错误地聚焦回源 session pane。
- `CodexConfigWriter.swift` / `CodexProviderStore.swift`：全局 active provider 切换不能作为每个运行会话的路由。用本次进程覆盖/独立会话配置，维护已存在官方认证。
- `SessionsView.swift`：增加转换动作、准备/失败状态与来源链。

### 12.3 版本与副作用边界

按照本仓库规范，生产集成必须在读取外部客户端、写入目标存储、启动真实 CLI/app-server、修改连接器这些入口执行 BuildChannel 限制。dev 仅使用合成 fixture / 模拟传输；不能增加环境变量绕过 dev 限制。本文独立研究脚本不属于 App 开发版集成。

CC 可以优先通过私有 transcript + 正式 resume/fork；Codex 优先正式导入接口；Cursor 桌面优先其原生 CC 接收能力，缺少可编程入口时再考虑经过版本验证的数据库方案。不要让本次插入式实验脚本直接成为后台常驻生产写入器。

### 12.4 推荐实施顺序与验收

| 阶段 | 范围 | 达成标准 |
|---|---|---|
| 第一阶段 | CC ↔ Codex 官方/自定义，正文/工具证据、准确 cwd、来源分支、按会话启动配置 | 真实跨客户端回忆与编程接续；源不变；同 provider 与跨 provider 都可回退 |
| 第二阶段 | Cursor CLI 双向、版本固定的桌面发现/导出，桌面接收实验能力 | CLI 和桌面分别验收 UI/请求上下文；新旧路径/索引兼容，不误读其他工作区 |
| 第三阶段 | 增量来回切换、长历史预算、图片、工具/分支/子代理适配 | 有效父链/配对正确；遗漏明确；第二次与多次切回不重复/丢消息 |
| 独立模型阶段 | 同自定义模型完整工具协议桥；SIWC 官方套餐授权与 CC 桥 | 真实多步工具迭代、取消/失败/额度/刷新验收，原生认证不混用 |

本次原型已经解决“短文本历史能不能真正嫁接”和一个真实编程交接；后续产品工作的重点是可靠解析、权限/配置隔离、启动路由、索引即时可见和长会话兼容。无需等到完全无损搬运所有客户端私有状态才交付有价值的第一版。

## 13. 交付内容与验证边界

- 本报告：六方向、CLI/桌面分别验证、模型与认证拆分、GitHub 对比、格式和产品方案。
- [真实实验结果](session-migration-live-results-2026-10-03.json)：包含成功和失败，不隐藏自定义 → 官方原生 fork 的 404。
- [实验原型](session-migration-lab-2026-10-03/README.md)：真实来源、原生嫁接、冷恢复、无历史对照、文本协议桥、实际编辑测试。
- [阶段一报告](session-migration-research-2026-10-03.md) 与模拟请求实验保留，作为先前证据；本报告补充了真实模型与 Cursor，不能再把前一阶段“未调用真实模型”当作本次最终状态。

另外完成一项 CC → Codex 的真实编程交接：源 CC 给出解析器方案；转换后的官方 Codex 实际调用命令、修改 `count.py`、执行三项回归断言；独立重跑输出 `PARSER_REGRESSION_OK`，临时 VERSION 指纹未变。这个案例比事实回忆更接近实际工作，但仍是小型合成项目，没有证明任意大型仓库、长期任务或原生工具历史都已兼容。

本次未修改 ClaudeBar 应用源码，未启动应用、编译或发布。新增真实请求复现工具默认关闭，版本固定；不加入日常回归清单，以免普通 `make test` 消耗账号额度或写入真实客户端。验证完成：`make test` 的 51 组回归全部通过（153.06 秒）；12 个研究脚本均通过 Python 语法解析，默认环境下全部在读取配置/调用客户端前拒绝执行；报告附件链接和最终脱敏证据检查通过。上述检查不等同于生产迁移功能的验收。
