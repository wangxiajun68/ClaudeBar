# 灵动岛会话监控深度审查 · 2026-10-01

结论：当前实现确实会漏掉需要人工处理的会话、保留错误的中间活动、重复发送完成通知，并把部分无法确认的状态显示成空闲。问题贯穿数据采集、状态模型、缓存和通知投递，单纯缩短轮询间隔无法解决。

审查对象为当前工作区，包括已有未提交改动。未修改生产源码、Makefile 或已有测试；新增本报告与隔离复现脚本。没有启动应用、VPN、真实 Codex app-server，没有请求通知或其他系统权限，没有读取真实会话内容或修改真实配置。

## 验证结果

已执行：

```bash
make test TEST="completion-notify session-waiting island-session-alert waiting-notify codex-session cursor-turn"
.venv/bin/python docs/reviews/island-session-monitor-repro-2026-10-01.py
```

现有 6 组回归全部通过，耗时 10.02 秒。新增脚本从当时的生产文件提取 Swift 函数，在临时目录编译并执行，复现了 10 个问题场景。脚本成功代表缺陷仍可复现，不代表修复通过；因此没有把它作为正常回归加入 Makefile。修复时应把这些场景改成正确行为断言，加入已有对应测试组。该脚本按 2026-10-01 的源码切片固定，其依赖的私有签名（如 `ProviderStore.transcriptStamp`、`ExternalSessionMonitor.recoverBeforeTail`）在 2026-10-02 的修复中已改名或改变形态，现在直接运行会在编译期失败，需按当时代码回看或改写后才能复现；下面各条目的行号也只是当时的定位。

未执行全回归、App 构建或运行时端到端测试。这次交付是审查，没有生产改动。macOS 实际通知展示、全屏可见性、终端焦点恢复，以及当前安装版本的客户端事件格式，仍需后续受控验证。

## 状态能力现状

| 能力 | Claude Code | Codex | Cursor |
|---|---|---|---|
| 工作中 | session status + 粗略工具 pending | 回合事件 + 文件写入时间推断 | transcript + SQLite checkpoint 推断 |
| 人工处理 | waiting + 工具名；提醒会漏 | `isWaiting` 固定 false | 两个 flag 合成一个布尔值 |
| 上下文压缩 | 无专门阶段 | 无专门阶段；压缩事件被忽略 | 无专门阶段 |
| 中间活动 | 最近工具名，可能属于上一轮 | 灵动岛收到固定空字符串 | 最近导出的工具名 |
| 子代理 | 已采集，但缓存可能冻结；灵动岛未展示 | 已采集；灵动岛丢弃子代理 | 已采集；灵动岛未展示 |
| 失败 / 中止 | 没有统一状态 | 中止退为空闲 | 错误结束退为空闲 |
| 系统通知点击 | PID 路由，未携带稳定会话身份 | 无路由数据 | 无路由数据 |

这里描述的是仓库实现。`ExternalSessionInfo` 的注释声称旧版 Codex 不落盘审批事件，但本次没有验证当前客户端，不能把该注释当作“当前客户端绝不可能提供状态”的结论。

## 发现与优先级

### 1. [P1] Codex 的人工选择和审批完全无法进入提醒链路

位置：`Sources/ClaudeBar/Utils/ExternalSessionMonitor.swift:93`、`:475`、`:515`，`Sources/ClaudeBar/Models/IslandLiveModel.swift:331`，`Sources/ClaudeBar/NotchIslandController.swift:469`。

`isWaiting` 直接返回 false。无论实际是权限审批、人工选择还是计划确认，灵动岛都不会产生 needs-input 事件，通知 fallback 的 Codex 分支也直接退出。它会先显示运行中，文件安静超过 300 秒后显示空闲，并标为 `hasStalledTurn`。独立调用生产 `isRunning` 已复现开放回合在第 301 秒变为空闲。

同一规则也会把没有新日志的长工具执行或慢模型响应误判为空闲。这是规则的确定结果；本次没有测量真实工作中出现这类长间隔的频率。界面还会据此提供“清理卡住的会话”，清理涉及删除续写分支及会话。该动作需要用户确认，审查未执行它，但“日志静默”不应成为“可以清理”的事实依据。

修复方向：核实当前客户端可提供的只读状态信号，区分等待人工、工作中、失联和状态未知。没有可靠信号时明确显示“状态未知 / 更新暂停”，不能用超时宣称空闲或卡死。不能假定新建一个独立 app-server 进程能接收到已有宿主连接上的审批请求；实时接入需先验证连接归属，并保持 dev 的系统集成限制。

### 2. [P1] 压缩没有被建模，上下文数值也会保留压缩前的值

位置：`Sources/ClaudeBar/Utils/SessionMonitor.swift:158`、`:345`，`Sources/ClaudeBar/Utils/ExternalSessionMonitor.swift:735`、`:780`，`Sources/ClaudeBar/Models/IslandLiveModel.swift:67`。

三种客户端的岛内快照都只有 busy / waiting 布尔值，没有压缩阶段。Codex parser 处理 task_started、task_complete、turn_aborted、token_count，其余 event_msg 均被跳过。隔离输入“180K token_count → context_compacted”后，生产函数仍返回 180K 和开放回合，完全没有压缩状态或数据有效性变化。这证明 parser 不消费此类记录；是否以及何时当前客户端发出该记录，未做现场验证。

Claude 也只读取最近 assistant usage，不识别压缩边界；压缩期间可能继续显示旧工具和旧用量，压缩后直到下一条 usage 才更新。上下文数值下降本身不等于“正在压缩”，不能反向猜测开始时刻。

修复方向：消费已确认的压缩事件，分别处理开始、结束和失败；无开始信号时只显示已知结果。压缩后的旧上下文应失效或标记为估算，等待新的有效用量，不应继续冒充当前值。

### 3. [P1] 等待提醒只认布尔边沿，漏掉新会话和连续问题

位置：`Sources/ClaudeBar/Models/IdleTransitionDetector.swift:162`，`Sources/ClaudeBar/Models/IslandLiveModel.swift:268`。

生产 detector 的两个隔离复现均成立：

- 应用已经监控旧会话，新会话首次被发现时已经 waiting，完全不提醒。
- 两个不同问题之间的 busy 状态短于轮询间隔，采样得到 waiting → waiting，第二个问题完全不提醒。

“启动时不轰炸历史通知”的策略被套到了运行期间所有新会话。检测输入只有 ID 与布尔值，连 pendingTool / waitingReason 改变都看不到，更无法区分同一种工具提出的两次不同问题。

修复方向：区分启动基线和运行中新会话，给人工请求使用稳定的请求身份 / 工具调用 ID；按请求去重。首次看到仍待处理的新请求，应进入待办集合。启动时可以汇总已有待办，避免逐条弹窗。

### 4. [P1] 提醒互相覆盖且缺少持续待办，人工请求会再次消失

位置：`Sources/ClaudeBar/NotchIslandController.swift:418`、`:434`、`:451`，`Sources/ClaudeBar/Views/Island/NotchIslandView.swift:248`。

`showAlert` 无队列，每次直接赋值 `state.alert`，所有类型同等覆盖。同一轮检测到多个等待会话时，前面的提醒可在同一主线程处理批次内被后面的替换。等待提醒随后也可被完成提醒或额度重置覆盖。只有“当时不能展示提醒条”才发系统通知；被覆盖的等待没有 fallback 或补发。

提醒 6 秒后自动收起，但收起态左翼只读 `busySessions`，完全不读已存在的 `waitingSessions`。因此，一个仍在等人工确认的会话可能又变成用量进度环。人工请求处理完后也没有按请求身份取消旧提醒，短时间内会继续显示过期的“去确认”。

另有展示条件问题：`state?.mode != .expanded` 在 state 为 nil 时仍为 true，之后 `guard let state` 返回，既没有显示也没有 fallback。全屏可见性不在该判断里；是否实际不可见应做 UI 验证。

修复方向：人工待办持久显示到解决；按请求身份排队 / 聚合，人工处理优先于完成和额度。请求已解除就移除对应提醒。展示能力应包含有效 panel / state 和可见性，投递失败才路由到其他通道。

### 5. [P1] Cursor / Codex 系统通知的“继续”和“去确认”没有功能

位置：`Sources/ClaudeBar/Utils/NotificationService.swift:103`、`:125`、`:137`、`:158`、`:179`，`Sources/ClaudeBar/ClaudeBarApp.swift:120`。（2026-10-02 起路由通过 `ResumeRoute` 传递，行号已变。）

两种客户端调用 `post` 都传 pid: nil，通知 userInfo 因而为空。通知响应只转发 PID；App 接收函数没有 PID 就立即返回。按钮看起来可用，但代码链路无法定位或打开对应会话。Claude 也只保存 PID，没有 sessionId；旧通知若遇到 PID 复用，可能定位到另一会话。

修复方向：通知 payload 保存客户端类型、稳定 sessionId、cwd 和宿主信息，以统一路由打开；校验当前会话身份。Cursor 目前 `openInCursor` 只打开目录，不定位具体 composer，修复时应明确其可支持的定位范围，不能宣称已经跳到特定问题。这条已在 2026-10-02 修复：横幅改为携带 `ResumeRoute`（agent / sessionId / cwd / pid / inDesktop），但 Cursor 的 “去确认” 仍然只打开项目目录。

### 6. [P1] 开发版通知授权入口没有系统权限闸门

位置：`Sources/ClaudeBar/Utils/NotificationService.swift:46`、`:51`，`Sources/ClaudeBar/Models/AppPreferences.swift:51`。

实际调用 `requestAuthorization` 的函数没有 `BuildChannel.promptsForSystemPermissions` 判断。开启通知或产生系统提醒都能进入该路径。违反 AGENTS.md 第 6 条“所有请求入口”及“真正触发系统 API 的函数”必须加闸的规定。通知权限的底层存储是否属于 TCC 不影响本仓库禁止 dev 弹出系统授权的明确边界。

修复方向：在授权函数入口加编译期身份闸门，并补覆盖 NotificationService 的隔离检查。本次没有调用该 API，没有触发授权弹窗。该闸门已在 2026-09-30 的 `promptsForSystemPermissions` 工作中补上，`requestAuthorizationIfNeeded()` 现在第一行就检查构建身份。

### 7. [P1] 子代理刷新被父会话缓存短路，监控树会冻结

位置：`Sources/ClaudeBar/Models/ProviderStore.swift:422`、`:433`、`:437`、`:456`。

父 transcript 字节数未变化时，直接沿用子代理和 workflows 后 continue。子代理独立写自己的文件，即使它已完成或更换活动，父文件不增长也不会触发扫描。隔离复现：父文件固定，子代理从 tool_use 写入 tool_result；直接调用生产 scanner 返回 done，经过生产 enrich 仍为 running。

子代理纯模型生成且没有 dangling tool 时，`scanAgentActivity` 也会直接认作 done；这种推断本身没有“正在生成”的证据。灵动岛 flatten 又不携带子代理摘要，所以已有树数据也到不了岛内。

修复方向：父 transcript 与子代理目录分别判断变化；至少对子代理保存各自指纹和阶段。父会话“正在等待子代理”应有摘要，不依赖父文件持续写入。

### 8. [P2] Claude 完成去重键会回退，同一个答案可重复通知

位置：`Sources/ClaudeBar/Models/ProviderStore.swift:351`、`:451`，`Sources/ClaudeBar/Models/IslandLiveModel.swift:315`。

注释要求轮次计数不能回退，但代码取的是 `max(result[i].turnCount, ctx.turnCount)`。`result` 来自新读的 session JSON，turnCount 默认 0，不是 previous 的计数。

隔离复现：同一 final answer 后追加不产生答案的 system 记录，96KB 尾窗滑动移走前面的用户 / assistant 记录。生产 enrich 发布的计数从 3 降到 1；UUID 完全相同，但 ProviderStore 的 `count|uuid` 键变了，生产完成 detector 再次发出通知。灵动岛实际传的是裸 UUID，和该字段注释声称的 `count|uuid` 不一致，两个提醒通道的去重语义分裂。

修复方向：使用稳定的回合与答复身份，不把滑动窗口中的记录数当作回合 ID。仅做 max(previous, current) 可缓解计数回退，但不能让滑动窗口计数成为可靠的全局回合计数。

### 9. [P2] 工具 pending 使用行顺序而非调用身份，多工具会判错

位置：`Sources/ClaudeBar/Utils/SessionMonitor.swift:419`、`:435`、`:452`、`:533`。

只比较“最后 tool_use 行”和“最后 tool_result 行”，不检查 tool_use_id。隔离复现同一 assistant 消息同时调用 Read(a) 与 AskUserQuestion(b)，随后只有 a 返回结果；parser 将所有工具视为已完成，pendingTool 变为空，实际上 b 尚未返回。

新用户回合也不清空 lastActivity。另一隔离复现已进入新 prompt，返回的活动仍是上一轮 Read。在 CLI status 为 busy 时，灵动岛会显示该旧工具，令人误以为新回合在读文件。尾窗切在超过 96KB 的单条记录内部时，完整记录可能不在窗口内，状态证据会进一步缺失。

修复方向：按工具 ID 维护未完成集合，区分工具执行、等待人工和新回合；新回合及阶段变化主动清理过期活动。尾读窗口不足应报告证据缺失，必要时做有界补读，不能默默将“没读到”当作完成。

### 10. [P2] Claude 缓存只检查文件大小，还会错用会话身份与配置

位置：`Sources/ClaudeBar/Models/ProviderStore.swift:418`、`:422`、`:429`、`:432`。

同长度替换 transcript 时不重新读取。隔离复现把 same-answer UUID 换成同长度 next-answer，直接 scanner 得到 next-answer，enrich 仍发布 same-answer。更改配置中的模型窗口也不会生效：生产缓存分支保留旧 contextLimit，复现从 1000 改为 2000 仍返回 1000。

缓存和 Claude 岛内 ID 只用 PID；同进程会话切换或 PID 复用时，若字节数碰巧相同，可把另一会话的标题、模型、答复和子代理搬过来。身份碰撞的具体客户端场景未现场验证，代码没有防护则已确认。

修复方向：缓存键至少包含 sessionId、transcript 路径、文件身份、mtime 和 size。上下文配置独立于 transcript 缓存更新。

### 11. [P2] 轮询与索引缓存叠加延迟，打开岛也没有立即刷新会话

位置：`Sources/ClaudeBar/Models/AppConfig.swift:15`、`:17`、`:28`，`Sources/ClaudeBar/Models/ProviderStore.swift:587`、`:608`，`Sources/ClaudeBar/Utils/ExternalSessionMonitor.swift:484`，`Sources/ClaudeBar/NotchIslandController.swift:395`。

可见工作时每 2.5 秒、可见空闲每 5 秒、后台每 8 秒。收起或提醒模式不算 island expanded，通常仍使用后台节奏。Codex 新会话的索引还有 10 秒缓存，发现延迟可叠加下一次轮询及扫描耗时；固定 8 秒节奏下缓存可使发现跨过第二次轮询。Cursor / Codex 扫描是在 Claude 扫描完成后才发起，Claude I/O 慢还会推迟其他客户端。

visibility 回调只重设计时器；expand 只刷新用量与索引，没有立即 refreshSessions。用户打开岛时可以先看到数秒前的状态。已有 FSEvents handler 只刷新 usage，不驱动会话状态，且隐藏时停止；它不是实时会话监控链路。

修复方向：轻量事件驱动处理状态文件 / 索引变化，轮询作恢复兜底；显示时立即异步补读。保持单次扫描和取消边界，先测事件延迟与 CPU，再定节奏，不需要常驻构建服务或无限高频扫描。

### 12. [P2] Cursor 等待类型被混为计划确认，还可能被列表预算裁掉

位置：`Sources/ClaudeBar/Utils/CursorSessionMonitor.swift:224`、`:256`、`:262`，`Sources/ClaudeBar/Models/IslandLiveModel.swift:323`，`Sources/ClaudeBar/Utils/NotificationService.swift:106`。

hasPendingPlan 和 hasBlockingPendingActions 合成一个布尔值后丢失原因，所有等待显示“等待你确认计划”。一般阻塞操作不一定是计划确认。列表仅保障 status == active 的会话；一个等待会话若计算为 idle，且有 14 个以上较新的 idle 会话，可在进入 island flatten 前被截掉，待办排序无法补救。

这是按生产排序 / 截断逻辑推导的确定边界，本次未增加完整 SQLite 复现。修复时应保证 working 和 needs-input 都保留在可见集合，分别携带等待类型。

### 13. [P2] 岛内信息被过度压平，错误和失联均伪装成“等待输入”

位置：`Sources/ClaudeBar/Models/IslandLiveModel.swift:67`、`:306`，`Sources/ClaudeBar/Views/Island/IslandComponents.swift:153`、`:228`，`Sources/ClaudeBar/Utils/ExternalSessionMonitor.swift:812`，`Sources/ClaudeBar/Utils/CursorSessionMonitor.swift:387`。

Claude firstPrompt、Codex title、Cursor title/subtitle 均不进入 IslandSession，行标题只显示目录。同项目多个会话难以区分。Codex activity 固定为空，模型相同则运行行也相同；子代理摘要未进入模型。

IslandSession 没有 failed、cancelled、disconnected、unknown；所有非 busy、非 waiting 都画“等待输入”。Codex turn_aborted 或 Cursor 错误 turn_ended 不会产生完成通知，这是合理的，但错误状态也同时丢失。读取失败时各 monitor 还能返回空数组，既没有错误状态又会让 detector 丢掉已知身份；会话再次出现时重新 seed，可能漏掉等待或完成。

修复方向：在现有模型中增加可验证阶段、结果与数据新鲜度，保留上一份有效状态并区分“读取失败”和“会话消失”。岛内携带会话标题与子代理摘要，工具细节仍需满足秘密不进入 UI / 日志的规则。

### 14. [P2] 通知投递没有确认，现有测试也未覆盖真正的投递路径

位置：`Sources/ClaudeBar/Utils/NotificationService.swift:46`、`:149`、`:165`，`Sources/ClaudeBar/Models/IdleTransitionDetector.swift:45`，`Tests/waiting-notify-regressions.py:48`、`:122`。

授权请求异步进行，post 不等待结果就 add；authorized 字段被写入却没有用于发送判断。add 没有错误处理；检测器在实际投递前已标记事件已处理。首次授权时的消息、系统拒绝投递等情况都没有重试或岛内反馈，是否实际丢失及 OS 行为本次未执行验证。

waiting-notify 测试替换了真实 `state?.mode` 为 bool，再手写 BannerProbe 复制文案。虽然注释称测试生产通知 builder，实际没有执行 NotificationService，也没有验证响应路由、state 为 nil、多提醒覆盖、授权或投递错误。codex-session / island-session-alert 还直接断言 Codex 永远不 waiting，证明的是当前缺失被固定下来，不是需求已实现。其他组对正常 busy → waiting → busy 的测试没有覆盖轮询跳过中间状态。

修复方向：用模拟通知中心驱动实际 payload / 响应 / 投递代码；按 requestId 确认或明确处理失败。让测试验证人工请求能被可靠看见，而不是仅验证代码当前的布尔规则。`waiting-notify` 在 2026-10-02 已改为切片生产 `post` 载荷与标题/正文/副标题来断言，不再自行复制文案。

## 建议修复顺序与验收

1. 先修人工请求身份、首次发现策略、持久待办与提醒队列；同时修通知跳转和 dev 权限入口。连续问题、同时多个会话、通知关闭、岛关闭都应有明确行为。
2. 修工具 ID 配对、父子缓存、稳定完成键、会话身份与上下文配置缓存。将本次隔离复现移入现有对应回归组，避免另外维护一套测试清单。
3. 扩充压缩、工作阶段、失败 / 中止 / 失联与新鲜度。先验证每种客户端确实提供的信号；无法采集的阶段应明确未知。同步需要新增字段的 Widget 快照编码与解码。
4. 测量文件变更到状态发布、状态发布到提醒的延迟，以及多会话时扫描耗时。用事件驱动加有界恢复轮询改善时效；保留隐藏 UI 的低开销策略。
5. 增加整条采集 → 发布 → 去重 → 展示 / 投递 → 点击路由的临时文件 / SQLite / 模拟传输测试，覆盖压缩、排队、审批、连续问答、短回合、子代理、异常退出、文件替换、休眠恢复和读取失败。

对于后续生产修复，按 AGENTS.md 执行全回归；涉及启动、持久化、版本或系统集成时编译 dev / release 并检查身份、Widget、entitlements 与签名。真实客户端实时状态和系统通知展示用显式受控流程验证，不能把源码切片通过当作真实会话监控通过。
