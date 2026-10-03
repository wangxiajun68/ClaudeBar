# 会话迁移：首版契约

会话页可把已结束回合的用户/助手正文迁入另一个客户端的新会话，再通过现有终端路由恢复。工作目录保持原项目或 worktree；目标客户端重新加载自己的项目规则、工具、权限和账号。迁移不是移动原文件，也不是迁移模型内部状态。

## 入口与范围

会话卡片悬停操作中的分支图标打开「继续于…」。目标为 Claude Code 当前配置、Codex 当前配置、Codex 官方登录、Cursor CLI Auto。先读取预览及遗漏说明，随后「创建并打开」。会话页的「迁移记录」可继续打开目标或把目标的新回合再迁往其他客户端。

Claude Code、Codex 与 Cursor CLI 的原生文件互转已实现。Cursor 桌面只读出正文，接收端选择 Cursor 时打开 CLI。会话页原有 Cursor 卡片对应桌面会话；CLI 来源通过迁移记录提供。首版不增加 CLI 全量会话发现器。

开发版在真实历史读取、客户端版本探测、写入和终端打开入口拒绝系统集成；不会迁移真实账号或凭据。纯转换器通过临时目录和模拟进程测试，不提供环境变量绕过 App 的闸。

## 数据与事务

- `MigrationSource` 保存客户端、原生 ID、cwd、标题与运行状态。
- `MigrationPreview` 包含正文消息、完整来源快照 SHA-256 与遗漏说明，不保存来源的模型思考、provider item ID 或认证。
- `MigrationRecord` 保存来源关联、目标 ID/路径、逻辑会话 ID、模型/provider、配置指纹及可执行路径；状态只称「已准备」。终端打开不能证明模型已经回复。
- 记录和暂存位于 `FilePaths.sessionMigrationsDir`，随 dev/release 数据目录隔离。正文写入目标客户端自己的原生目录，不复制 auth.json、keychain 或 settings。
- 先暂存，再安装新的原生文件，最后发布记录；安装拒绝替换，记录写入失败回滚本次目标文件，来源保持不动。JSONL/记录通过 `PrivateFileWriter` 写 0600；SQLite 在 0700 暂存目录创建并收紧为 0600。
- 同一来源快照、目标、模型和配置重复准备时复用目标。目标再次迁移时沿用逻辑会话 ID。不会把旧目标的真实新回合覆盖为来源历史。

来源在准备前后核对指纹。当前配置目标同时核对原生配置与 ClaudeBar 供应商列表的指纹，防止模型名字相同但供应商已经切换。继续打开时再次检查配置、可执行路径、版本、目标文件和工作目录；变化后要求重新准备。官方 Codex 单独检查本机已有 ChatGPT 登录。

## 原生适配器

`MigrationHistory` 处理 JSONL。Claude Code 按最新主分支的 parent UUID 回溯；Codex paginated 读取 ordinal 连续的 canonical 事件，legacy 读取 response_item 投影。legacy 续聊追加 canonical 事件后仍读取完整投影，避免丢失导入前缀。

`MigrationCursorHistory` 以只读 SQLite 事务读取桌面 bubble 正文或 CLI protobuf/blob 历史；CLI 校验 blob SHA-256，并写原生 meta TEXT、blob BLOB、消息和 turn DAG。客户端返回答案可能早于历史保存完成，读取器最多等待约 3.1 秒并重新打开快照；仍未完成则提示稍后重试。

`MigrationPath` 使用 POSIX realpath 统一 cwd 和路径归属。Cursor workspace key 为真实路径 UTF-8 的 MD5；Claude Code 目录编码按 JavaScript UTF-16 单元替换非 ASCII 字符。macOS `/var` 与 `/private/var` 的别名、符号链接和未创建的子目录都按相同规则处理。

`SessionMigrationService` actor 执行 I/O、版本探测和配置核对；`SessionMigrationModel` 在主 actor 更新界面。`TerminalLauncher.openMigratedSession` 复用既有终端路由。新 Codex rollout 可能尚未进入桌面索引，因此首版通过终端恢复。

Codex 当前配置以进程参数指定现有 provider/model；官方目标使用临时 provider 名 `claudebar_migration_official`、官方认证及 Responses HTTP。不会改写全局 provider 选择或把官方 token 交给 CC。迁入 CC 后使用 CC 的当前配置，迁入 Cursor CLI 后使用 Auto。

## 兼容边界

固定已验证版本：Claude Code 2.1.288、Codex CLI 0.159.0-alpha.12.1、Cursor CLI 2026.06.19-20-24-33-653a7fb、Cursor 桌面来源 3.23.12。未知目标版本拒绝写入；升级需要更新固定样本并重新验收。

文件上限 16 MiB、正文上限 400,000 UTF-8 字节、消息上限 8,000；Codex 文件发现最多遍历 60,000 项。首版不总结或截断超限历史。

运行中、待确认、未完成工具、子代理、历史压缩、缺失 parent、重复 ID、分分页缺口和附件会拒绝。已经完成的工具调用/结果不重放，预览明确提示遗漏。CC 工作目录编码超过 200 字符时拒绝，尚未实现其长路径哈希分支。Cursor 桌面写入、多媒体、工具语义重建、同一个自定义模型的跨协议迁移及新 OAuth 注册未实现。

这些阈值约束本地转换，不能保证任意目标模型的 context window 足够，也不能保证它逐字使用所有旧事实。

## 验证

```bash
make test TEST=session-migration
make test
make build
make release
```

测试直接编译生产转换器、存储、服务和终端入口，使用临时原生文件及模拟传输；覆盖 dev/release/未标记构建、事务失败、来源/配置变化、版本门禁、官方登录缺失、原生编码与延迟保存。真实模型、失败现象和手工 UI 验证边界见 [实现验收报告](../reviews/session-migration-implementation-2026-10-03.md)；先前可行性及 GitHub 研究见 [深度调研](../reviews/session-migration-deep-research-2026-10-03.md)。
