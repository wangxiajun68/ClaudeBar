# Claude Code workflow 状态监控

会话页在所属 Claude Code 会话下显示 workflow 名称、状态、当前／最近阶段、已返回结果的 agent 数、已发现的 agent 总数及运行数量。状态显示为「运行中」「已暂停」「已完成」「失败」「已取消」或「状态未知」（`stopped` 归入已取消）。已返回结果数优先取通知携带的 `agents_done`，没有时退回按 journal 的 `result` 记录计数；总数取已发现 agent（`agent-*.meta.json` 元数据与 journal 记录）和通知上报数量的最大值；运行数量在状态为运行中时等于尚未返回结果的 agent 数，其他状态为 0。计数随动态派生变化，不预先固定。最终通知提供失败数量时额外显示失败数量。

数据来源是 Claude Code 自身的本地记录，不安装 hook、不修改 Claude Code 配置、不启动会话：

- `projects/<项目>/<sessionId>/subagents/workflows/<运行 ID>/journal.jsonl`，运行 ID 需匹配 `wf_` 加字母数字或连字符：`started` / `result` 记录 agent 生命周期，`phase` 提供阶段；同目录下 journal 中尚未返回结果的 agent 的 `agent-<id>.jsonl` 修改时间用于活动证据。
- 主会话 JSONL（`projects/<项目>/<sessionId>.jsonl`）的 `toolUseResult`：按 `runId`、`taskId`、`workflowName` 和启动状态关联整个运行。
- 主会话中的原生 `task-notification`：按 task ID 更新完成、失败、暂停或取消等明确状态，并在同一 task ID 的运行上读取其携带的 `agent_count` / `agents_done` / `agents_error` 计数（旧 task ID 的通知不采用其中的计数）。Claude Code 2.1.287 把这条记录写在 `attachment.prompt` 上，`origin.kind` 在 `attachment` 里面；旧格式仍认顶层 `origin` + `message.content`。排队中的 `queue-operation` 和普通消息里引用的同名标签都不是状态事件。恢复后，旧 task ID 的通知不覆盖新运行。

所有 journal 中记录为已返回结果的 agent 不等于整个 workflow 完成；完成只能来自明确的状态事件。工具返回也不等于 agent 结束。终态需要明确事件。

已记录的「运行中」运行，在会话进程不再存活，或距离最近一次活动（journal 或未完成 agent 日志的修改时间）超过 90 秒时显示「状态未知」。反向也成立：状态尚未确定、会话存活、90 秒内有活动且 journal 中仍有未返回结果的 agent 时显示「运行中」。未知不是失败判定；较长的模型推理也可能进入未知。没有可识别的暂停／取消事件时同样显示未知，不猜测原因。

主会话空闲且 workflow 仍有运行证据时，会话保持忙碌。活动行在父会话自己的回合仍在跑时也列出每一个运行中的 workflow（名称与阶段）和每一个仍在运行的直接子 agent，不只留第一个；等待用户确认时保留等待提示。日志按新增字节增量解析，处理残缺末行、截断与文件替换：每个路径的解析缓存最多保留 64 条，超过单行长度上限（4,000,000 字节）的记录整行丢弃。

验证：`make test TEST=workflow-session`。回归使用临时目录中的原生记录结构，不启动真实 workflow。这些磁盘记录属于 Claude Code 的内部格式，版本变更可能需要更新解析。
