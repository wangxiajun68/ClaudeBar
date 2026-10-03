# 会话迁移第二阶段：Cursor 桌面接收与工具交接

日期：2026-10-03。分支：`codex/session-migration`。工作树：`/Users/wangxiajun/.codex/worktrees/session-migration/ClaudeBar`。本阶段基于首版提交 `39c6c2f`，没有带入原工作区的其他未提交改动。

## 本阶段完成了什么

现在可以把 Claude Code、官方 Codex、自定义 Codex 的历史创建为 Cursor 桌面的原生聊天，看到旧正文并真实继续回答。桌面新增回合后再迁回 CC 或官方 Codex也已实际验证。会话页增加「Cursor 桌面 · 项目模型」，迁移记录显示可检索的聊天标题。

Claude Code / Codex 还增加默认关闭的「包含已完成工具的输入与结果」。完成的工具记录可以成为普通历史上下文，目标能使用其中的事实；工具不会再次执行，也不伪装成目标客户端的原生工具调用。工具错误结果会保留。

52 组完整回归、dev 与 release 构建、Widget、版本身份、entitlements 和签名均通过。ClaudeBar App 没有安装或启动。本次桌面 UI 实验是在已安装 Cursor 中，用独立编译的生产 Swift 适配器创建合成聊天后实际点击、发送问题、查看答案。服务及打开入口由生产函数配合临时存储和模拟客户端回归验证，不能把它称为 ClaudeBar 正式包完整手工验收。

## 可做、不能做与目前不够顺畅的部分

| 场景 | 当前结果 | 具体边界 |
|---|---|---|
| CC / Codex → Cursor 桌面 | 已实现，三个真实来源通过 | Cursor 3.23.12；项目必须已有聊天登记；使用该项目已有模型设置 |
| Cursor 桌面新增回合 → CC / 官方 Codex | 两个真实反向续聊通过 | 导出正文，重新建立目标原生 ID；不共享内部推理状态 |
| CC、Codex、Cursor CLI 互转 | 延续首版生产实现及六方向真实验收 | 此阶段未重复全部六个 CLI 方向，原证据保留 |
| 官方 Codex ↔ 自定义 Codex | 延续首版的新正文分支方案 | 每次按目标配置创建新会话，不原样带入 provider reasoning ID |
| 自定义 Codex → CC / Cursor | 正文可继续；本次 Kimi 历史迁入桌面通过 | CC 使用自己的配置，桌面本次使用 Grok，模型并未自动继承 |
| CC / Codex 完成工具资料 | 可选，生产回归与真实正负对照通过 | 有限格式、完整调用/结果配对；作为历史文本，不重放 |
| Cursor 原生工具详情完整转换 | 未实现 | 正文照常导出，非正文工具细节提示遗漏 |
| 一次点击后精确聚焦 Cursor 指定聊天 | 尚未实现 | 打开项目，再在历史选标题；已有窗口可能需手动重载 |
| 未登记的 Cursor 项目自动建立完整原生工作区 | 尚未实现 | 明确提示先在 Cursor 打开项目并创建聊天，不猜 workspace ID |
| 同一自定义模型跨 Codex / CC / Cursor | 尚未产品化 | 历史迁移和模型协议接入是两项能力；需要独立协议桥及认证方案 |
| 把官方 ChatGPT 登录直接搬进 CC | 当前迁移功能不支持 | 使用 CC 自己的模型/账号；新认证接入需单独实现和验收 |
| 图片、音频、文档、压缩历史、子代理 | 明确拒绝或尚未支持 | 不用静默丢弃冒充完整迁移 |
| 正在执行或待确认的回合 | 明确拒绝 | 不能无损迁移正在运行的进程、权限等待和工具状态 |

目标的 context window 与模型能力仍限制它能利用多少旧事实。短合成历史成功不证明所有长任务都能无损继续。

## 怎样在产品里使用

1. 等来源回合结束，包括 Cursor 仍运行的子 agent。会话卡片悬停后点击迁移分支图标。
2. 如需迁到桌面，先在 Cursor 打开相同 cwd/worktree 并创建一条聊天，让它登记项目及模型。
3. 选择「Cursor 桌面 · 项目模型」。CC / Codex 可选择携带完成工具资料；预览会显示条数、资料大小和遗漏说明。
4. 点击「创建并打开」。程序建立新聊天，打开项目；在历史中搜索「ClaudeBar · 迁移」。记录中给出精确标题，例如 `ClaudeBar · 迁移 · c2e53978`。
5. 如果已打开的窗口没有刷新历史，用户手动执行 Reload Window。程序不自动重载用户正在工作的窗口。
6. 在目标继续说话。之后可从迁移记录再把目标的新历史迁往其他客户端，沿用逻辑会话关联。

Cursor 桌面模型来自最近可识别的同项目聊天，保存 modelName、maxMode 和受限 selectedModels 参数。它不一定等于当前焦点聊天；不会复制其他聊天的账号、上下文或系统提示。用户随后仍能在 Cursor 自己的界面改变模型。旧迁移记录也不冻结 keychain 登录或服务端状态。

## 实际对话验收

### 三个来源迁入桌面

来源沿用上一阶段真实生成的合成原生会话：CC、官方 GPT Codex 和自定义 Kimi `kimi-k3`。每个先保存独立随机 marker 与三项约束并真实回复 ACK。本阶段用生产 Swift 读取这些原生历史，迁到已经登记的临时 Cursor 项目；实验主动把三个来源放入同一个合成目标项目，产品自身仍保留来源 cwd。

所有目标都使用原生 Cursor 模型配置 `grok-4.7`，界面显示 Grok 4.7 Medium。在 Cursor Agents 窗口实际打开三个迁移聊天，看到旧问题和 ACK，然后发送如下问题：

```text
From our previous conversation, return only a JSON object with keys marker,
constraint, next_step, decision and their exact remembered values.
Do not use tools or read files. If a fact is absent, use "unknown".
```

问题不包含任何预期答案。约束为 `never edit VERSION`，下一步为 `verify parser regression`，决定为 `keep original session`。

| 来源 | Cursor 原生 ID | marker | UI 显示历史并真实回答 | 最新生产读取器回读 |
|---|---|---|---|---|
| CC | `c2e53978-9e17-4cf2-9cd2-c85aa5ce4464` | `MIGRATE-bc4cde261f12` | 四项逐字段一致 | 6 条：来源 2 条＋两次续聊 4 条 |
| 官方 Codex | `69ef6484-98e5-47e9-bcf2-a86622df2db7` | `MIGRATE-5f44f4266d2b` | 四项逐字段一致 | 4 条：来源 2 条＋一次续聊 2 条 |
| 自定义 Codex | `8189ca85-8642-48ec-a172-4857d5e23b51` | `MIGRATE-773b6da47f58` | 四项逐字段一致 | 4 条：来源 2 条＋一次续聊 2 条 |

CC 目标第一次回复完成后，实际重载本次合成聊天所在的 Cursor Agents 窗口，再次发送同样的问题；四项事实再次一致，旧消息与第一次新回合均保留。这是窗口重载后的继续对话验证；没有把它扩大为退出整个 Cursor 应用再启动的验证。另外两个来源没有做第二次重载提问。

收尾审查加固项目与同名模型参数指纹后，最后版本生产适配器再次创建 CC → Cursor 桌面目标 `224f920f-4982-4827-a2a9-db15915c6ff2`。实际 UI 加载旧正文并重新提问，四项事实逐字段一致；生产读取器回读 4 条，记录含完整 profile 指纹。该补测单独保存在结果 JSON，没有代替或改写前面的三来源证据。

### 桌面继续后再迁出

使用最后版本生产源码编译的独立 Swift 读取器，在 SQLite 只读事务中读出上述真实桌面新历史，生产存储函数创建新目标，再以实际原生 CLI resume 提问。

| 链路 | 导入消息 | 目标 | 实际结果 |
|---|---|---|---|
| CC → Cursor 桌面 → CC | 6 条 | CC 当前 Anthropic 兼容配置 | exit 0；0.92 秒；四项逐字段一致 |
| 自定义 Kimi Codex → Cursor 桌面 → 官方 Codex | 4 条 | 已有 ChatGPT 登录，GPT CLI | exit 0；18.55 秒；四项逐字段一致 |

这些 CLI 测试关闭工具与额外项目规则/记忆，使用不含答案的回忆问题；没有借助交接文件读取答案。官方目标沿用已有账号，不复制认证文件，不改全局 provider；网络调用使用 `127.0.0.1:17890` 进程代理。

### 工具资料正负对照

来源为前阶段实际编码交接时的合成 Codex rollout，包含真实 `custom_tool_call` / `custom_tool_call_output`。第一条 shell 结果的 JSON 中有 `chunk_id: b1b719`，该值不在普通用户/助手正文里。

用同一生产读取器分别开启/关闭工具资料，创建两个全新 CC 原生目标，在空目录以关闭工具的 CC 进程提问。问题仅要求回忆第一条旧 shell 结果的 chunk_id，不给出预期值。

| 模式 | 转换后消息 | 携带完成工具项 | CC 实际答复 | 判断 |
|---|---|---|---|---|
| 包含工具资料 | 7 条 | 2 | `{"chunk_id":"b1b719"}` | 恢复工具结果独有事实 |
| 只含正文 | 5 条 | 0 | `{"chunk_id":"unknown"}` | 负对照符合预期 |

两次 exit 0，均约 1.19 秒。证明工具结果作为文本上下文有效；没有证明原生工具状态可复用、文件编辑可重放或任意工具输出格式都受支持。

完整脱敏结果见 [第二阶段真实验证 JSON](session-migration-phase2-live-results-2026-10-03.json)。只记录合成事实、会话 ID、答案、匹配与测试状态；不提交账号、endpoint、token、环境变量快照或用户真实聊天。

## 实验中实际失败及修正

第一轮三个导入能出现在侧栏，但点击自定义来源的聊天后正文空白，renderer 报 `Failed to load composer data for agent`。因此「数据库有行、侧栏有标题」不足以证明桌面可继续。

查看本机 Cursor 3.23.12 的已安装 renderer，发现 native composer 读取会直接访问 `codeBlockData` 等字典。适配器初版未构造所有必要默认值。修正增加 `codeBlockData`、`originalFileStates`、`usageData` 空字典、正确 richText 字符串、数字 addedFiles/removedFiles 以及上下文集合。此后用全新 ID 重做三个导入并实际发送问题，全部成功。旧失败 ID 保留在证据 JSON 中，三个失败测试聊天已通过原生 UI 可恢复归档，没有永久删除。

另一个风险来自原生 `cursorDiskKV` 的 `key TEXT UNIQUE ON CONFLICT REPLACE`。普通 INSERT 遇到同 key 会覆盖旧聊天，初始临时测试若只用 PRIMARY KEY 就漏掉这个风险。当前生产函数显式 `INSERT OR ABORT`，回归夹具使用真实冲突策略，覆盖 header 冲突、仅 composer KV 冲突以及共享 blob 字节不一致，并断言原记录不变。

路径处理还保留已登记 workspace URI 与 ID 的配对。只用 realpath 改写 `/var`、符号链接或别名 URI，却继续沿用旧 workspace ID，会把相同目录错误关联到不同原生工作区。现在 realpath 只用于比对物理目录，返回元数据保留登记路径；增加别名回归。

## 桌面写入与回滚设计

`MigrationCursorDesktop` 是纯 Swift / SQLite 适配器，复用已有 `MigrationCursorHistory.payload` 构造 Agent protobuf/blob 和 turn DAG。新 composer_v18、bubble_v3、session/bubble UUID 全部由本次创建，其他会话的数据只用于受限项目/模型 profile，不克隆原 composer。

写入流程：

1. 版本门禁固定 Cursor 3.23.12；只读 profile 从最近最多 2,000 条非 subagent header 中找到同 cwd 的已登记项目。检查表列集合、workspace ID 和模型字段；白名单项目及完整模型参数生成指纹，在去重之前再次核对，防止同名模型更改 max mode/推理参数仍复用旧目标。
2. 正文先受 400,000 UTF-8 字节 / 8,000 条限制；桌面每条 bubble 的原生状态展开另做 16 MiB 预分配与精确序列化上限，超限拒绝。
3. READWRITE 打开已有共享库，不 CREATE；busy timeout 2 秒，`BEGIN IMMEDIATE` 锁定本次写事务。
4. 仅插入新 ID 的 KV/header，显式 ABORT；共享 hash blob 已存在则逐字节检查，不覆盖。header 列显式列出，避免依赖列顺序。
5. 在数据库尚未提交时，通过 `PrivateFileWriter` 发布本次 0600 迁移记录，然后检查取消并 COMMIT。
6. 正常异常回滚本次行并清理本次记录。打开和去重检查指定原生 ID 的 header/composer，再检查 cwd 和回合状态；不是只看共享 state.vscdb 文件存在。

SQLite 和独立 manifest 文件不能组成真正的跨资源原子提交。崩溃发生在 manifest 发布后、COMMIT 前会留下「目标缺失」记录；当前打开明确拒绝，不凭记录伪造目标，也没有自动恢复/清理日记。COMMIT 成功但进程尚未返回时，记录与目标已经存在，下次可复用。

不支持任意历史 schema。当前 schema 检查是列集合与已验证结构，不是 Cursor 对外承诺的稳定迁移 API；也没有把所有未来索引、触发器或列约束变化视为兼容。未知版本必须重新取得真实样本、核对数据库与 renderer、完成读写和续聊验收。

数据库锁、碰撞及 manifest 失败在临时库中验证，未故意锁住真实用户全局库或破坏用户记录。真实全局库实验只新增本次合成聊天，正常客户端生成的后续状态由 Cursor 自己写入。没有替换整个库、改配置、修改应用 binary 或杀进程。

## 工具转换设计与剩余格式限制

CC 按最新 parent UUID 主链配对 tool_use / tool_result；不把兄弟分支合并。结果含 content 与 is_error。Codex 配对 response_item 的 function/custom call 与 output；paginated canonical 仍按原 ordinal 验证，匹配到的完成资料插入相应历史位置。存在 canonical 工具而无法完整对应时，开启选项会拒绝。

携带的内容只包含工具名字、输入、输出及明确归档标记。不会复制 call ID、私有 thinking、provider reasoning ID 或原生执行权限。输出包含附件时拒绝；CC 非文本结果块也拒绝。完成工具计数大于零时给来源指纹加入 `completed-tools-v1` 标记，使预览/准备及去重区分两种转换。关闭选项仍校验未完成工具，不允许把进行中的任务伪装成结束。

工具输出本身可能包含项目内容或秘密，所以选项默认关闭，界面明确说明它会随历史发给目标模型。它不会自动脱敏任意字符串；用户应根据预览来源决定是否携带。当前没有摘要、截断、外部结果资源下载或完整工具状态机重建。

## 同模型与官方配置问题的当前结论

官方、自定义 Codex 都能作为正文来源。自定义 Kimi 历史 → Cursor Grok → 官方 Codex 已形成真实闭环，说明历史的可读事实不依赖原 provider。官方历史 → CC 也可继续，但使用 CC 的配置；这不是把 GPT 官方订阅接入 CC。

要继续同一个自定义模型，需要额外的协议接入：Codex 的 Responses 与 CC 的 Anthropic 接口需要翻译文本、工具、SSE、错误、取消与思考签名；Cursor 是否能选到同一个 endpoint/model 还受它自己的接入规则限制。当前代码不自动迁移 endpoint/key，也未部署长期代理。此前研究里的文本桥接成功只证明一个最小子集，不能冒充完整 coding agent 兼容。

后续应先做可审查的协议桥独立模块：用模拟传输覆盖协议语义与取消，用合成真实任务验收选定供应商，再决定产品里的显式接入流程。官方账号桥接还要核实认证能力、客户端能力及相关服务约束，不能依靠复制 auth.json 达成。

## UI 定位、类似 GitHub 项目与后续路径

Cursor 官方 [Deeplinks 文档](https://prod.cursor.com/docs/reference/deeplinks)公开的是 prompt、command、rule；prompt 只是预填且须用户确认执行，URL 最长 10,000 字符。本次没有在该文档找到按 composer UUID 打开现有聊天的承诺，所以产品没有虚构 resume deeplink。不能据此断言内部永远没有私有命令。

GitHub 的 [cursor-workspace-tool](https://github.com/aviv-raz/cursor-workspace-tool)处理工作区和聊天管理；[cursaves 的存储说明](https://github.com/Callum-Ward/cursaves/blob/main/docs/how-cursor-stores-chats.md)记录 composerHeaders 与窗口选择关联。它们提供数据库方案参考，不等于原生厂商保证；没有安装或执行这些第三方工具。本实现以本机实际 schema、已安装 renderer 和真实 UI 为验收依据。

更顺畅的下一步可以在独立模块探索 Cursor 扩展或被验证的原生命令来选中已创建的 ID，并处理当前窗口缓存；若必须写窗口 workspaceStorage，则需明确选择状态的所有权、缓存刷新、并发和可恢复性。当前不改窗口选择数据库、不自动重启窗口。另需显式正式版流程对 ClaudeBar 整条 UI 操作验收；开发版集成闸继续保留。

## 回归与构建结果

| 验证 | 最终结果 |
|---|---|
| `make test PYTHON=/Users/wangxiajun/Project/ClaudeBar/.venv/bin/python` | 52 组全部通过，220.26 秒 |
| 迁移生产逻辑回归 | dev / release / 未标记三模式；临时原生数据库与模拟客户端 |
| 事务与完整性 | manifest 异常、header/KV 冲突、共享 blob 损坏、写锁、未登记项目、同名模型参数改变、工具缺结果、开关指纹、旧记录兼容均通过 |
| `make build` | dev 主包、Widget、身份、entitlements 和签名通过 |
| `make release` | release 主包、Widget、身份、entitlements 和签名通过；未安装 |
| Cursor UI | 三来源实际显示历史并真实答复；一个目标窗口重载后再次答复 |
| 桌面反向迁出 | CC 与官方 Codex 两目标真实答复通过 |
| 工具正负对照 | 开启恢复 tool-only 事实，关闭回答 unknown |
| ClaudeBar 正式包手工 UI | 未执行 |
| VPN / 硬件 / 系统代理 / 真 Codex app-server | 未执行 |

release 仍有基线 VpnManager actor 隔离、非 throwing try 及 linker 重复 rpath 警告，本阶段没有改这些模块。没有安装正式包、修改系统网络设置或请求新的系统权限。当前开发版门禁仍在真实读取、版本探测、写入和打开副作用入口生效；纯适配器实验没有给 App 添加绕过开关。

当前契约见 [技术文档](../technical/session-migration.md)；上一阶段六方向证据见 [首版报告](session-migration-implementation-2026-10-03.md)，完整可行性与不可移植状态研究见 [深度调研](session-migration-deep-research-2026-10-03.md)。
