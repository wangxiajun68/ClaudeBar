# 真实会话迁移实验原型

这是 2026-10-03 的调研工具，使用已安装的原生客户端和真实模型；会消耗目标账号/API 的额度。**没有接入 ClaudeBar，也不是支持任意生产会话的迁移工具。** 只支持本报告创建的短文本合成会话。不能把它当作已处理分支、压缩、多媒体、子代理或任意旧版本的转换器。

原型保留了实际使用的三个文本适配器、原生恢复调用、供应商切换实验、协议桥接和编程交接实验。Cursor CLI 的 protobuf 布局参考 ctxmv 的公开格式实现，Python 实现为本次编写；参考版本见报告。没有下载执行第三方安装脚本或修改客户端二进制。

默认不运行真实请求。两个环境变量均须显式设置；客户端版本不匹配时拒绝运行。Cursor 桌面写入另外需要单独启用。没有让 ClaudeBar dev 绕过系统集成限制的环境变量；这里的开关只属于独立研究脚本。

## 固定环境

- macOS；Python 3.9+ 标准库；本机 `~/.local/bin/claude`、`codex`、`agent`。
- Claude Code 2.1.288；Codex CLI 0.159.0-alpha.12.1；Cursor CLI 2026.06.19-20-24-33-653a7fb。
- Cursor 桌面写入固定 3.23.12，标准 macOS 安装位置。
- 使用本机已有配置：CC 的 `~/.claude/settings.json`、ClaudeBar Codex provider JSON、Codex 原生认证、Cursor 原生账号。
- `CLAUDEBAR_MIGRATION_PROVIDER_INDEX` 默认 6，必须指向本机已有且支持 Responses 的 provider。本次真实上游为 kimi-k3。不同机器先检查自身配置，不能按索引猜测供应商。
- 网络代理 `http://127.0.0.1:17890`；不修改系统代理。

凭据只在进程内读取或通过进程环境提供；不将 key 写入实验文件。官方 Codex 调用读取原生认证目录，原生 CLI 可能进行正常 token 刷新；只创建和恢复脚本生成的新合成会话。原型会在 `~/.codex/sessions` 增加实验会话；Cursor 桌面步骤会增加新的合成聊天记录。CC、Cursor CLI、自定义 Codex 的实验状态位于临时目录。源码不自动清理这些记录，也不触碰其他用户会话。

## 复现 CLI 矩阵

在仓库根目录执行。变量名不会覆盖 HOME 或 CODEX_HOME；所有命令仅用于显式的独立研究。

```bash
export CLAUDEBAR_MIGRATION_LIVE=1
export CLAUDEBAR_MIGRATION_LAB_DIR="$(mktemp -d -t claudebar-session-live-research)"
export CLAUDEBAR_MIGRATION_PROVIDER_INDEX=6
python3 docs/reviews/session-migration-lab-2026-10-03/live_probe.py cc
python3 docs/reviews/session-migration-lab-2026-10-03/live_probe.py codex-official
python3 docs/reviews/session-migration-lab-2026-10-03/live_probe.py cursor
python3 docs/reviews/session-migration-lab-2026-10-03/custom_seed.py
python3 docs/reviews/session-migration-lab-2026-10-03/graft_probe.py codex-official cc
python3 docs/reviews/session-migration-lab-2026-10-03/graft_probe.py cc codex
python3 docs/reviews/session-migration-lab-2026-10-03/graft_probe.py cc cursor
python3 docs/reviews/session-migration-lab-2026-10-03/graft_probe.py cursor cc
python3 docs/reviews/session-migration-lab-2026-10-03/graft_probe.py cursor codex
python3 docs/reviews/session-migration-lab-2026-10-03/graft_probe.py codex-official cursor
python3 docs/reviews/session-migration-lab-2026-10-03/graft_probe.py codex-custom cc
python3 docs/reviews/session-migration-lab-2026-10-03/graft_probe.py codex-custom cursor
python3 docs/reviews/session-migration-lab-2026-10-03/graft_probe.py codex-custom codex
python3 docs/reviews/session-migration-lab-2026-10-03/cold_probe.py
python3 docs/reviews/session-migration-lab-2026-10-03/controls.py
```

转换程序先读源原生历史，写入另一客户端的原生存储，再启动目标 `resume`。目标问题不包含随机标记或约束答案。`cold_probe.py` 启动新的客户端进程进行第二次恢复；`controls.py` 用没有历史的新会话问相同问题。

`exact_match` 的含义是四个事实都恢复；首先比较解析后的 JSON 字段，若模型返回格式错误的 JSON，则要求四个完整预期字符串都存在于回答。本次 CC 使用的上游偶有响应前缀缺失，因此必须同时查看 `answer`，不能把该字段当作“严格 JSON 合规”。

## 供应商与协议实验

```bash
python3 docs/reviews/session-migration-lab-2026-10-03/provider_probe.py codex-official custom
python3 docs/reviews/session-migration-lab-2026-10-03/provider_probe.py codex-custom official
python3 docs/reviews/session-migration-lab-2026-10-03/relay_probe.py
python3 docs/reviews/session-migration-lab-2026-10-03/coding_probe.py
python3 docs/reviews/session-migration-lab-2026-10-03/official_public_probe.py
```

- `provider_probe.py` 原生 fork + 本次进程 provider 覆盖；自定义 → 官方的原始 fork 本次失败，纯文本重新建会话的对照已通过。只复制合成的自定义 rollout 到官方原生目录，未复制认证。
- `relay_probe.py` 将隔离 CC 的 Anthropic 请求转为真实 Kimi Responses 请求，再回传 Anthropic SSE。仅验证文本、无工具的范围；没有实现工具、图片、思考签名、取消或完整流式协议。
- `coding_probe.py` 创建临时 Python 文件；CC 给方案，Codex 接续真实编辑与执行测试。不会编辑仓库源码。
- `official_public_probe.py` 只读测试已有 Codex token 对公共 `/v1/models` 的访问，不启动新 OAuth 注册；本次得到 403。不会打印 token 或 JWT payload。

## Cursor 桌面步骤

CLI 与桌面不是同一个存储。桌面验证必须在 UI 中执行；CLI 返回成功不能代替桌面续聊成功。

1. 在 `$CLAUDEBAR_MIGRATION_LAB_DIR/workspace-cursor-desktop` 创建空目录，用 Cursor 的 Open Workspace → Open Folder 打开它。
2. 建立新的合成会话，让模型记住新生成的随机标记和约束，回复 ACK；不使用工具。
3. 通过只读 SQLite 提取该新会话的 `fullConversationHeadersOnly` / `bubbleId` 正文，填入实验 ledger 的 `cursor-desktop` 源。`desktop_extract.py <新 composer UUID>` 实现了这个步骤，要求该会话 cwd 在实验目录内。
4. 提取成功后可以运行 `graft_probe.py cursor-desktop cc` 与 `graft_probe.py cursor-desktop codex`。
5. 阅读 `desktop_graft.py`。显式设置 `CLAUDEBAR_ALLOW_DESKTOP_GRAFT=1` 后，运行 `desktop_graft.py cc`、`desktop_graft.py codex-official`、`desktop_graft.py codex-custom`。这一步直接向当前用户 Cursor 数据库插入**新的**合成会话，不能在其他版本盲目运行。
6. 在实验窗口使用 Reload Window，打开 `MIGRATION ...` 三个新聊天。必须分别看见历史并发送不带原答案的回忆问题。实际回答由 `desktop_verify.py` 只读收集；这只是辅助核对，不能替代 UI 人工观察。
7. 再次重载窗口，本次对自定义来源又发了一个回忆问题，验证持久化后还能继续。

本次原生 Claude 导入弹窗只做了检查，没有按 Sync 批量导入其他用户真实聊天。桌面实验采用自编适配器。所有 `ui_*` 证据标志来自实际 UI 操作观察。

## 文件与限制

`graft_probe.py` 是转换/启动公共函数；其余脚本分别负责来源、矩阵、恢复和特殊案例。`live-ledger.json` 与原生日志写入私有临时目录；仓库只保留经过筛选的结果 JSON。

这些脚本是实际验证实现的留档。产品化必须用 Swift、PrivateFileWriter、原生终端路由和 BuildChannel 入口闸实现；不能给 App 增加此 Python 运行依赖。读取器目前仅适用于本实验的短、单支、未压缩文本会话；不要对未知真实长历史静默降级。
