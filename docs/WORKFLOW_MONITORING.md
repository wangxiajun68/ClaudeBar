# Claude Code workflow 状态监控

会话页在所属 CC 会话下显示 workflow 名称、状态、当前／最近阶段、已返回结果的 agent 数、已发现的 agent 总数及运行数量。总数会随动态派生增加，不是预先固定的进度分母。最终通知提供失败数量时额外显示失败数量。

数据来源是 Claude Code 自身的本地记录，不安装 hook、不修改 Claude Code 配置、不启动会话：

- `projects/<项目>/<sessionId>/subagents/workflows/<runId>/journal.jsonl`：`started` / `result` 记录 agent 生命周期；`phase` 提供阶段。
- 主会话 JSONL 的 `toolUseResult`：关联 `runId`、`taskId`、workflow 名称和启动状态。
- 主会话中的原生 `task-notification`：按 task ID 更新完成、失败、暂停或取消等明确状态。Claude Code 2.1.287 把这条记录写在 `attachment.prompt` 上，`origin.kind` 在 `attachment` 里面；旧格式仍认顶层 `origin` + `message.content`。排队中的 `queue-operation` 和普通消息里引用的同名标签都不是状态事件。恢复后，旧 task ID 的通知不覆盖新运行。
- 已关联任务的结构化任务查询结果：补充显式状态。

所有 agent 返回结果不等于整个 workflow 完成；脚本可能继续派生下一阶段。工具返回也不等于 agent 完成。终态需要明确事件。

进程已退出，或超过 90 秒没有 journal／未完成 agent 日志活动证据时，未确认终态的运行显示「状态未知」。这不是失败判定；较长的模型推理也可能进入未知，收到新活动后恢复。没有可识别的暂停／取消事件时也显示未知，不猜测原因。

主会话空闲且 workflow 仍有运行证据时，会话保持忙碌。活动行在父会话自己的回合仍在跑时也列出每一个运行中的 workflow（名称与阶段）和每一个仍在运行的直接子 agent，不只留第一个；等待用户确认时保留等待提示。日志按新增字节增量解析，处理残缺末行、截断与文件替换，缓存数量和单行长度均有上限。

验证：`make test TEST=workflow-session`。回归使用临时目录中的原生记录结构，不启动真实 workflow。这些磁盘记录属于 Claude Code 的内部格式，版本变更可能需要更新解析。
