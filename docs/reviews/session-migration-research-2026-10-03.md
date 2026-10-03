# Codex / Claude Code 会话迁移可行性调研

> 阶段一记录：本文以隔离模拟请求验证为主。新增真实模型、六方向、Cursor 桌面、官方/自定义切换与协议桥验证，见[最终深度报告](session-migration-deep-research-2026-10-03.md)。

日期：2026-10-03。此文是调研与隔离实验记录，不代表 ClaudeBar 已实现迁移功能。

## 结论

**可以实现「在 ClaudeBar 选择一个 Codex 会话，复制成新的 Claude Code 会话，然后继续工作」。** 用户消息与助手回答可以保持各自角色进入 Claude Code 的下一次模型请求，并能持久化为以后可再次恢复的会话。不限于把一段摘要放进新聊天。

边界是：迁移的是对话和工作上下文，目标获得新的会话身份；源会话保留。运行中的进程、工具连接、审批状态、账号授权、模型私有思考、服务端缓存不会随 transcript 迁移。代码文件也不会因转换聊天而自动复制。真实模型能否准确接续复杂任务，仍需后续验收。

建议第一版做 **Codex → Claude Code，用户/助手正文 + 历史工具文字记录 + 同一工作目录 + 来源关联**。长会话提供可审阅的精简交接，复杂分支、非本地会话和不支持的多媒体明确提示限制。不要把未知格式默默截断后宣称完整迁移。

## 调研与实验范围

- 阅读 ClaudeBar 的会话监控、会话页、终端恢复、Otty 桥接和版本隔离代码。
- 读取本机 CLI 版本：Claude Code `2.1.288`，Codex `0.159.0-alpha.12.1`。
- 对真实会话仅做本地、只读的结构统计，输出字段名、类型和计数；没有将真实会话正文或凭据复制到实验、报告或网络请求中。
- 核对 OpenAI / Anthropic 官方文档、OpenAI 开源实现，以及迁移工具作者发布的源码与验证记录。源码下载使用用户提供的 `127.0.0.1:17890` 代理。
- 使用已安装的 Claude CLI、合成数据、临时 `CLAUDE_CONFIG_DIR`、假 API key 和本机回环 HTTP 模拟服务验证恢复。启用 `--bare`、`--restricted`，禁用工具与 MCP，并限制配置来源。
- 没有启动 ClaudeBar，没有调用真实 Codex app-server，没有改外部客户端配置、用户会话、VPN 或硬件，也没有调用真实模型。

## 官方支持是不对称的

### Codex 导入 Claude Code

Codex 官方 `/import` 已支持选择外部客户端的配置、项目及近期聊天；文档注明 CLI 发现范围为最近 30 天最多 50 个聊天，且本地 daemon、远程模式和任务运行期间有使用限制。桌面产品的导入入口也已存在。[官方导入说明](https://learn.chatgpt.com/docs/import)

App-server 的 `externalAgentConfig/detect`、`externalAgentConfig/import` 支持 `SESSIONS`，有导入进度、完成事件及历史记录。这里不需要假设只有直接伪造 Codex JSONL 才能做反向迁移。[官方协议](https://learn.chatgpt.com/docs/app-server#detect-and-import-external-agent-config)

进一步检查 OpenAI 源码：导入器读取外部消息，生成新的 Codex 会话元数据和持久化记录；用户/助手正文转换为相应 `ResponseItem::Message`。这也说明官方方案并非复制源客户端全部运行状态。[消息转换实现](https://github.com/openai/codex/blob/8f7a0f7a878199c6886600370e5be6bd37ca38a3/codex-rs/external-agent-migration/src/sessions/export.rs)、[会话持久化实现](https://github.com/openai/codex/blob/8f7a0f7a878199c6886600370e5be6bd37ca38a3/codex-rs/app-server/src/external_agent_migration/session_importer.rs)

### Claude Code 导入 Codex

Claude Code 已有 `claude import codex` / `/import codex`，但官方定义为配置导入：指令文件、MCP、命令、子代理、技能等。**当前官方文档未列出 Codex 聊天历史导入。** 不能用该命令替代本需求的会话转换器。[官方命令说明](https://code.claude.com/docs/en/commands)

有用的正式接收入口是 `claude --resume`：官方支持会话 ID、名称及 transcript `.jsonl` 的绝对路径，`--fork-session` 可以恢复为新 ID。SDK 也提供 resume / fork 和会话读取能力。这些是 Claude 原生会话接口，并不是官方保证兼容任意外部会话格式的 import API。[CLI 参数](https://code.claude.com/docs/en/cli-reference)、[SDK 会话说明](https://code.claude.com/docs/en/agent-sdk/sessions)

因此可采用「本地转换为经过验证的 Claude transcript → 正式 resume 接口」，同时为 transcript 格式维护版本兼容性。

## 本机验证结果

复现脚本：[session-migration-probe-2026-10-03.py](session-migration-probe-2026-10-03.py)。结果：[session-migration-probe-results-2026-10-03.json](session-migration-probe-results-2026-10-03.json)。脚本只使用合成会话，实验输出写入新建的临时目录。

| 实验 | 检查内容 | 结果 |
|---|---|---|
| baseline | 原生 CLI 能向本地模拟服务发请求并保存会话 | 通过 |
| converted-resume | Codex 形状的用户/助手消息转为 Claude transcript 后，下一次请求包含 `user → assistant → user` | 通过 |
| second-resume | fork 获得独立新 ID 和 transcript；退出后按新 ID 恢复，请求仍包含原上下文及新增消息 | 通过 |
| tool-evidence-text | 历史工具名称、命令、结果作为普通文字进入请求；没有发出历史工具调用 | 通过 |
| paginated-canonical-text | 从合成的当前 Codex canonical completed items 提取正文；排除同一文件里的 provider 环境消息 | 通过 |

合成的源上下文含项目标记 `ORCHID-731` 和「解析器已实现，待做回归」；恢复请求中保留了这些原文。模拟服务只返回固定 `MOCK_ACK_ONLY`，因此证明的是 **CLI 解析、角色保留、上下文实际送达请求、落盘、再次恢复**，不是模型理解力测试。

复现：

```bash
python3 docs/reviews/session-migration-probe-2026-10-03.py
```

脚本固定验证 Claude Code 2.1.288；其他版本拒绝运行，需先审查参数和格式再更新基线。它是调研复现工具，不是完整转换器，也不属于生产 App 回归清单。

## 当前 Codex 格式：落地时最关键的一点

本机 `~/.codex/sessions` 当时发现 13 份 JSONL，全部头部标记 `history_mode: paginated`。只读检查中，每份文件的 `ordinal` 都从零连续；未发现非空 `history_base` 或 `subagent_history_start_ordinal`。不能由此推断归档、其他机器或未来版本也满足这些条件。

其中 canonical completed item 统计包括 `UserMessage` 21 条、`AgentMessage` 38 条，以及命令执行、文件修改、MCP、图片查看、思考、扩展和压缩记录。这些是结构统计，文件在活跃写入时计数会变化。

**当前 paginated 格式应优先以 `event_msg.item_completed` 中的 `UserMessage` / `AgentMessage` 重建对话。** 同一个 rollout 的 `response_item.message` 还可能保存环境上下文、开发者指令以及供模型使用的消息投影。把两种表示全部拼接会重复消息；把全部 provider user message 当人类输入，也可能误导目标客户端。

`session-migrate` 当前源码已经区分 legacy / paginated，使用上述 canonical 消息来源；同时拒绝外部 `history_base` 引用、子代理历史投影及不连续序号。[固定源码版本](https://github.com/xhluca/session-migrate/blob/c23b1dbd21404f78be3b69d42ff4fb158ff52105/src/session_migrate/formats/codex.py)

注意该项目旧验证报告曾拒绝 paginated，会话读取的最新代码已扩展支持，不能把旧报告限制当作当前实现。本机验证使用的是当前形状的合成根会话，未运行第三方转换器，也未将上述 13 份真实会话导出再恢复。

压缩更复杂：抽查的 compacted 记录含 `replacement_history`、`retained_context` 和不透明 `compaction` 项，但没有可直接读取的普通摘要。**不能假定每个被压缩的 Codex 会话都能提取现成的明文总结。** 应区分用于阅读的完整时间线与下一轮真正需要的工作上下文；超预算时明确精简范围，必要时让用户审阅或由目标客户端另行总结。

## 能迁移什么

| 内容 | 可行性与第一版处理 |
|---|---|
| 用户消息、助手回答 | 保留角色、内容、顺序；来源标注在 ClaudeBar 记录中 |
| 已完成的命令、文件修改、测试结果 | 作为历史文字证据；优先保留文件路径、退出码、关键结果，裁剪冗长输出 |
| 本地源码与未提交修改 | 使用同一个确切 cwd / worktree 时已在那里；换目录或机器需要另做文件交接 |
| 已有明确明文摘要、待办、用户约束 | 可以携带；不能把目标客户端的系统策略替换为源模型系统提示 |
| 图片、附件 | 需逐种适配并检查存在性、大小和路径；文本第一版明确报告未迁移内容 |
| Claude / Codex 子代理 | 独立会话或总结结果；不能把所有子代理流随意拼到主对话 |
| 历史工具的原生结构 | 技术上部分可转换，但调用 ID、配对、工具语义和客户端版本相关；第一版转普通文字更稳妥 |
| 运行中的 shell、工具等待、审批弹窗 | 不能迁移；选择最后一个完整轮次，提示用户避免两个 agent 同时修改同一目录 |
| 私有 / 加密 / 带签名思考、不透明压缩状态 | 无通用跨供应商恢复方式；不复制或伪造签名 |
| 账号、API key、MCP 登录、权限、Hooks | 保持目标客户端自己的配置；不随会话迁移 |
| token 计费、缓存、模型 ID | 不当作目标端真实用量或授权；迁移后的请求重新计算上下文与费用 |

文字化历史工具记录只能避免转换器直接重放工具；**不保证模型不会自行决定重新执行命令**。真实目标会话仍服从自己的工具权限，交接应明确历史与下一步的区别。

## 现成工具的参考价值

| 工具 | 调研发现 | 对 ClaudeBar 的判断 |
|---|---|---|
| [session-migrate](https://github.com/xhluca/session-migrate) | 原生格式适配、消息/工具/部分媒体、迁移清单；当前 Codex reader 支持受限 paginated 根会话 | 最适合参考格式规则和失败用例；README 支持范围以 Linux 为主，不能直接视为本机 0.159 / 2.1.288 验收 |
| [resume-from](https://github.com/alexei-led/resume-from) | 预览后写入原生会话，按上下文预算裁剪，工具转不可重放文字；不迁移仓库或运行进程 | 产品范围与本项目第一版最接近，可参考交接语义；未安装或运行 |
| [CC Switch 会话管理](https://github.com/farion1231/cc-switch/blob/main/docs/user-manual/en/3-extensions/3.4-sessions.md) | 跨客户端发现、阅读和按原客户端 resume | 该文档未给出 Codex → Claude 的转换流程；不能将统一列表当作跨客户端迁移证据 |

不建议为了第一版新增 Python / Node 常驻组件或外部转换器运行依赖。ClaudeBar 是原生 Swift 项目，可以参考这些实现，用现有文件访问、私有写入和终端路由完成有限、可验证的适配。

## ClaudeBar 的接入方式

现有基础：

- `ExternalSessionMonitor.swift` 已解析 Codex index / rollout，识别 cwd、父子会话和运行状态。但 `ExternalSessionInfo` 没有直接暴露 rollout path，迁移需增加可验证的路径解析，不能只靠标题。
- `SessionMonitor.swift` 能定位 Claude transcript、监控活跃会话。它目前主要列活跃进程，迁移后尚未启动的 Claude 会话可能不会马上出现；来源关系应独立保存在 ClaudeBar，并在真实进程出现后关联。
- `TerminalLauncher.swift`、`OttyBridge.swift` 已有继续会话、终端选择与会话 ID 路由。迁移目标必须使用新 ID，避免被误当成现有 Codex pane 而聚焦回源会话。
- `SessionsView.swift` 的 Codex 卡片适合增加「在 Claude Code 继续」动作，默认保留原会话。

建议流程：

1. 选择源会话和目标，显示项目实际路径与 worktree。
2. 在后台只读获取稳定文件边界；运行中只选最后一个完整轮次。文件边界/指纹变化时重试或重新预览，不把正在追加的半行当坏文件吞掉。
3. 按 history mode 提取正式消息，去重；只保留与任务相关的工具证据。未知模式、缺失父历史或不支持的压缩结构给出可解释的失败或精简交接。
4. 预览正文范围、工具文字化、遗漏项、目标配置身份，以及大致上下文预算。token 只能估算，不能用源端 token 数当 Claude token 数。
5. 用 `PrivateFileWriter` 在 ClaudeBar 自己的 `FilePaths` 下写入新 transcript 与无敏感正文的来源清单，生成新 session / message UUID 和正确 parent chain。原文件保持只读。
6. 从相同 cwd 启动 `claude --resume <absolute-transcript-path> --fork-session`。长正文通过文件传递，终端命令只携带经过正确转义的路径；更强的目标进程集成应使用参数数组。
7. 得到目标真正落盘的 ID 后建立源/目标关联，后续继续用这个 ID；本次实验在 print JSON 输出中获得 ID，交互终端场景需要另行实现可靠关联，不能只猜「最新文件」。

不必直接向用户 `~/.claude/projects` 伪造文件，首次可以使用官方支持的绝对 transcript 路径恢复；CLI 自行创建目标会话。但该方案的终端 UI、picker 可见性、目标进程状态、Claude Desktop 接续和标题显示仍需验收。

### 版本隔离

迁移器的源读取、转换、预览可以在开发版验证。写入 ClaudeBar 自有目录中的合成目标也可以单元测试。

向真实外部客户端目录写入、调用真实 Codex app-server、启动真实迁移接续等副作用，应在各自最底层入口执行 `BuildChannel.allowsSystemIntegration` 闸门，遵守仓库既有开发隔离，不增加环境变量绕过。终端需要 Automation 的路径仍服从 `PermissionGate`，开发版不触发系统权限请求。

## 第一版范围与验收

推荐先支持本地 Codex 根会话的 legacy 与明确识别的 paginated canonical 格式；目标为已安装的 Claude Code CLI。同 cwd，保留用户/助手正文、关键工具文字记录、明确的来源与遗漏清单。转换本身不需要真实模型调用。

应验证：

- 合成多轮消息、特殊字符、超长工具输出、图片遗漏、半行追加、未知格式、缺失历史引用。
- 完整轮次截断与 ordinal 检查；同样的消息不能因 provider/canonical 双表示被重复导入。
- 压缩、分支、回滚、取消后状态与 Claude parent chain；不支持的形状不得声称完整迁移。
- 参数及路径转义、UUID 唯一性、权限模式、原文件不变、失败时不产生已成功的来源记录。
- 在本机精确 CLI 版本上验证请求上下文、真实落盘、再次恢复；升级 CLI 后重复兼容性验证。
- 正式版授权流程中，用受控任务验证目标模型知道任务、已完成部分和下一步，能在正确 worktree 继续并执行预期测试。还需验收终端与桌面可见性。
- 按仓库要求，涉及启动、持久化或系统集成的正式实现交付应运行 `make test`，构建 dev / release 并检查身份、Widget、entitlements 与签名。此次仅新增调研材料，未进行 App 构建或生产集成验收。

**可行性已确认；当前工作的成果是调研、协议层隔离实测和实现建议。真实复杂会话的完整迁移、真实模型接续与产品 UI 尚未实现或验收。**
