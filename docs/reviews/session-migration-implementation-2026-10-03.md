# 会话迁移首版实现与验收记录

> 本文保留首版验收状态。Cursor 桌面接收和可选完成工具记录已在后续实现，当前结果见 [第二阶段报告](session-migration-phase2-implementation-2026-10-03.md)，当前契约见 [技术文档](../technical/session-migration.md)。

日期：2026-10-03。分支：`codex/session-migration`。独立工作树：`/Users/wangxiajun/.codex/worktrees/session-migration/ClaudeBar`。基线为 `78802d3`；原工作区的其他未提交改动未带入。

## 已实现的结果

ClaudeBar 会话页已接入正文迁移入口、目标选择、预览、原生会话创建、终端续聊和迁移记录。核心适配器为 Swift，应用没有增加 Python、常驻代理或第三方运行依赖。

这是可审查、可构建的首版。两个应用包已构建及验证身份，但没有安装、启动或手工点验 ClaudeBar。真实续聊验证使用从工作树生产源码编译的独立 Swift 转换器，加已安装的原生 CLI；不能把这一验证等同于 App 全流程已经手工验收。

| 来源 | 可创建的目标 | 实现及证据 |
|---|---|---|
| Claude Code | Codex 当前配置 / 官方登录、Cursor CLI | Swift 原生转换与真实 CLI 续聊通过 |
| Codex | Claude Code、Cursor CLI；也可重新创建 Codex 官方/当前配置分支 | 六方向实测中官方历史跨客户端通过；官方目标覆盖既有自定义配置的补测通过 |
| Cursor CLI | Claude Code、Codex | Swift 原生转换与真实 CLI 续聊通过；会话页从迁移记录提供入口 |
| Cursor 桌面 | Claude Code、Codex、Cursor CLI | 桌面正文读取器已实现，临时真实 schema 回归通过；本次 Swift 版未重新运行桌面 UI 实验 |
| 其他客户端 → Cursor 桌面 | 未实现 | 前一阶段研究脚本已证明固定版本可以导入；产品版暂不写桌面数据库 |

界面上的 Cursor 目标明确标为 **Cursor CLI · Auto**。原有 Cursor 会话卡片仍是桌面来源。用户不能把这理解为点击一次就进入 Cursor 桌面同一聊天。

## 在会话页怎样使用

1. 等来源回合结束；悬停会话卡片，点击分支图标。
2. 选择「Claude Code · 当前配置」「Codex · 当前配置」「Codex · 官方登录」或「Cursor CLI · Auto」。官方目标可填写账号可用的模型名。
3. 查看正文消息数量与遗漏提示，点击「创建并打开」。程序创建全新的目标原生 ID，在原 cwd/worktree 启动 resume。
4. 「迁移记录」保留来源、目标与模型。点击「继续」重新打开目标；目标产生新回合后，可用旁边的分支图标再迁移，保留同一逻辑会话 ID。

开发版入口禁用，服务和终端的副作用入口也独立拒绝；不能通过切 UI 状态或环境变量绕过。此规则来自仓库 dev/release 边界，未在本实现中放宽。

## 官方、自定义模型与账号

**官方 Codex → CC**：提取官方历史正文并创建 CC 原生会话，接续模型使用 CC 当前配置。本机实测为 DeepSeek，官方 GPT 的认证没有迁入 CC。

**自定义 Codex → CC / Cursor**：读取规则与官方来源一致，来源 provider 不影响正文适配器。迁入后分别使用 CC 当前模型、Cursor Auto。此前 Python 调研已真实验证 Kimi 来源；本次六方向 Swift 实测没有重新生成 Kimi 来源，因此不把旧实验称为新的 Swift 实测。

**官方 ↔ 自定义 Codex**：创建新的正文分支，可选择官方登录或当前已选择的自定义 provider/model。避免原生 fork/resume 携带另一上游的 reasoning item ID。历史原 ID 不带入新分支；两个目标可在迁移记录中关联为一条逻辑会话。

**保留全局自定义配置而使用官方 Codex**：生产 `MigrationCommand` 以本次进程的 provider 参数指定官方认证、Responses HTTP 和所选模型，不改全局 config.toml。补测保留原有用户配置，未用 `--ignore-user-config`，目标真实返回来源四个事实。未登录 ChatGPT 时明确拒绝，不自动进行 OAuth，也不把 API key 当作官方订阅登录。

**同一自定义模型跨客户端**：还需要 Responses/OpenAI 与 Anthropic 等协议桥、目标客户端的模型接入和认证支持。此前文本桥接实验成功，本次产品没有集成桥接，CC 不会自动继承 Codex 的 endpoint/key。Cursor Auto 也不等于来源自定义模型。

继续已有准备记录时，当前配置与供应商列表指纹变化会拒绝旧路由。这样能发现同模型名称下的供应商切换，但不能保证外部 shell profile、原生 keychain 账号切换或供应商服务器行为都被指纹捕获。

## 真实验证方法和结果

从真实 CC、官方 Codex、Cursor CLI 的合成来源读取原生持久化历史。每个来源先记住独立随机标记及三项约束并真实回复 ACK。Swift 转换器只导出正文，写入新的原生历史。目标在新的空工作目录收到不包含预期答案的回忆问题，真实模型回复四项事实。使用用户指定的 `127.0.0.1:17890` 代理，不改变系统网络设置。

| 生产 Swift 转换方向 | 目标模型/入口 | 四项事实 | 原生追加后再读取 |
|---|---|---|---|
| CC → Codex | ChatGPT 官方 GPT CLI | 通过 | 4 条正文，原历史和新回合都保留 |
| 官方 Codex → CC | 现有 DeepSeek Anthropic 兼容配置 | 通过 | 4 条正文都保留 |
| CC → Cursor CLI | Cursor Auto | 通过 | 立即读失败；稍后读保留 6 条正文 |
| Cursor CLI → CC | 现有 DeepSeek 配置 | 通过 | 4 条正文都保留 |
| Cursor CLI → Codex | ChatGPT 官方 GPT CLI | 通过 | 4 条正文都保留 |
| 官方 Codex → Cursor CLI | Cursor Auto | 通过 | 立即读失败；稍后读保留 6 条正文 |

补充验证：

- 两个 Cursor 目标分别用全新的原生进程再次 resume，均恢复四个事实；最终 Swift 读取保存原 2 条消息加两次续聊，共 6 条正文。
- 工作目录包含中文、emoji、空格、`$` 与单引号时，官方 Codex → CC 成功，CC 真实回复后 Swift 再读保留 4 条正文。
- 使用生产官方 route 参数并保留既有自定义用户配置，CC → 官方 Codex 成功。
- 有的 CC 回答缺失 JSON 前缀，但四项完整事实字符串存在。验收优先逐字段解析，再比较完整字符串；结果的成功表示事实恢复，不表示严格 JSON 格式合规。

脱敏证据：[Swift 真实续聊结果](session-migration-swift-live-results-2026-10-03.json)。其中保留早期立即读取失败，后续成功是追加的独立检查，没有把失败改写为成功。旧 Python 实验、桌面 UI、负对照与编码交接证据仍见 [深度调研](session-migration-deep-research-2026-10-03.md) 及其结果文件。

### 实验发现的修正

**macOS 路径别名**：Foundation 解析 `/private/var` 与 `/var` 的行为和 Node/Python 不一致，且目录创建前后解析结果可能不同。初版 Cursor 目标因此找不到历史，路径归属检查也失败。生产实现改用 POSIX realpath，连同最接近的现存父目录统一处理；修正后六方向的原生目标都能恢复事实。

**CC 中文目录编码**：编码按 JavaScript UTF-16 单元处理，不能按 UTF-8 字节替换；emoji 对应两个单元。回归与原生 CC 实测验证了此规则。超过 200 字符的长目录哈希分支暂未实现，直接拒绝。

**Codex 二次迁移**：导入的 legacy 历史在续聊后可能追加 canonical 事件。只因有 canonical 就切换读取器会丢失原导入前缀。现在按历史模式选择：legacy 始终读取 response_item，paginated 才读取连续 ordinal 的 canonical 事件。

**Cursor 保存延迟**：真实 CLI 已输出答案，但新 blob/root 未完全落盘，立即再次转换会失败。最终历史和新进程冷恢复证明正文仍保存成功。读取器以新事务有限重试，累计等待约 3.1 秒；没有承诺原生客户端总在这段时间内落盘，超时明确提示重试。

## 源码和验证入口

| 文件 | 职责 |
|---|---|
| `Models/SessionMigration.swift` | 统一正文模型、来源、目标、记录和失败类型 |
| `Utils/MigrationHistory.swift` | POSIX 路径、Claude/Codex JSONL 读写、分支/完整性与上限检查 |
| `Utils/MigrationCursorHistory.swift` | 只读 SQLite 快照、CLI protobuf/blob 校验及原生新库写入 |
| `Utils/MigrationStorage.swift` | 私有暂存、拒绝替换、回滚、去重、逻辑关联与 resume 参数 |
| `Utils/SessionMigrationService.swift` | actor I/O、版本、登录、配置指纹和 BuildChannel 门禁 |
| `Views/Shared/SessionMigrationDialog.swift` | 共用入口、目标选择、预览、准备与记录 |
| `Views/Pages/SessionsView.swift` | 四种会话卡片接入及迁移记录区域 |
| `Utils/TerminalLauncher.swift` | 复用终端启动路径；不依赖 Codex 桌面索引 |
| `Tests/session-migration-regressions.py` | 直接编译生产函数，临时原生存储与模拟 CLI/终端验证 |

全量入口仍在 Makefile 唯一 TEST_SUITES 清单中，新增 `session-migration`，没有另一份 CI 回归列表。

| 检查 | 最终结果 |
|---|---|
| `make test PYTHON=/Users/wangxiajun/Project/ClaudeBar/.venv/bin/python` | 52 组全部通过，172.89 秒 |
| 迁移回归 | dev / release / 未标记三种构建模式通过；临时目录、真实生产逻辑、模拟进程 |
| `make build` | dev 编译、Widget、bundle ID、URL scheme、entitlements、签名通过 |
| `make release` | release 编译、Widget、身份及签名通过；未安装 |
| `git diff --check` | 通过 |
| 原生真实模型调用 | 六个 CLI 方向、两次 Cursor 冷恢复及两项路由/路径补测通过 |
| ClaudeBar 手工操作 / 正式安装 | 未执行 |
| VPN、硬件、系统代理、真实 Codex app-server | 未执行 |

release 编译仍显示基线 VPN 模块的 actor/非 throwing try 警告及 linker 重复 rpath 警告；没有为本任务改动 VPN 源码，构建成功不代表这些历史警告已解决。

## 首版不能做与下一步

首版拒绝运行中、待确认或未完成工具的来源，以及子代理、压缩、外部分页引用、缺失父节点/消息、重复 ID、附件和超限历史。限额为源文件 16 MiB、正文 400,000 UTF-8 字节、8,000 条消息。没有静默压缩或只保留尾部。

完成的工具记录不作为可执行工具序列迁移，也不重放文件操作；预览明确提示工具细节遗漏。接续模型可以在原工作目录重新读取文件，但它能否理解先前全部操作需要另行验收。正文能保留，不代表目标模型 context window 必然足够。

固定兼容版本是 Claude Code 2.1.288、Codex CLI 0.159.0-alpha.12.1、Cursor CLI 2026.06.19-20-24-33-653a7fb、Cursor 桌面来源 3.23.12。未知目标版本先拒绝；升级需要原生样本和真实验收，不能仅替换版本号。

后续按以下顺序推进：

1. 在显式正式版流程中手工验收会话页 → 原生终端 → 真实回复 → 再迁移；保留现有开发版隔离，不为了演示放开 dev。
2. 用真实短文本、工具丰富、分支、压缩和超长历史建立可移植任务摘要/文件变更层，明确每一层遗漏；扩大版本兼容验收。
3. Cursor 桌面接收作为独立固定版本功能，处理数据库写入事务、窗口重载、UI 定位、并发更新和回滚，不把 CLI 的成功当作桌面的成功。
4. 若要求“同一自定义模型仍在 CC”，再实现完整协议桥或复用经验证的现有接入；工具、流式错误、思考签名、取消、认证和计费都需要真实覆盖。
5. 官方模型从 CC 调用属于新的协议及认证接入需求，不能用“正文能迁移”推导“官方订阅凭据能搬到 CC”。

当前实现完成正文迁移首版。详细产品契约见 [技术文档](../technical/session-migration.md)；此前 GitHub 类似项目、官方接口及不可移植状态的调查保留在深度报告中。
