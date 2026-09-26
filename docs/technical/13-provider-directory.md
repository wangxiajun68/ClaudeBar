# 供应商目录与 Codex 会话监控

> ClaudeBar 技术文档 · §13
> 相关：设计文档 [供应商管理](../design/surfaces/providers.md) · 技术文档 [ProviderStore](03-provider-store.md)

核查日期：2026-09-24。

## 交互来源

- [CC Switch 添加供应商](https://github.com/farion1231/cc-switch/blob/main/docs/user-manual/en/2-providers/2.1-add.md)：选择预设、预填名称与地址、填写 Key、保存。
- [LiteLLM 网关](https://docs.litellm.ai/docs/proxy/quick_start)、[Messages 接口](https://docs.litellm.ai/docs/anthropic_unified)：模型名由网关配置决定，目录不捏造用户的网关别名。

CC Switch 中部分平台仍被列为 Chat Completions；预设协议以当前供应商官方文档为准，不从兼容 OpenAI 推断兼容 Responses。

## 原生协议核查

- [DeepSeek Responses](https://api-docs.deepseek.com/api/create-response/) 与 [Anthropic 兼容](https://api-docs.deepseek.com/guides/anthropic_api/)。
- [Kimi 官方接入说明](https://www.kimi.ai/academy/use-kimi-api-in-codex-and-claude-code)：两种协议均支持，链接指向开放平台配置指南。
- [智谱 Responses](https://docs.bigmodel.cn/cn/guide/develop/responses/introduction)：基址 `/api/v1`，与 Chat Completions 的 `/api/paas/v4` 不同。
- [MiniMax Codex](https://platform.minimax.io/docs/token-plan/codex) 与 [Responses](https://platform.minimax.io/docs/api-reference/responses-create)：MiniMax-M3，`/v1` 基址。
- [百炼 Responses](https://www.alibabacloud.com/help/en/model-studio/qwen-api-via-openai-responses)：`/compatible-mode/v1`，原 dashscope 域名仍有效，官方建议迁移到用户工作空间专用域名。
- [OpenRouter Claude Code](https://github.com/OpenRouterTeam/docs/blob/main/cookbook/coding-agents/claude-code-integration.mdx)：Claude 基址 `/api`，由客户端添加 `/v1/messages`。
- [Anthropic Sonnet 4.6](https://platform.claude.com/docs/en/models/sonnet-4-6/overview)：保留可用的稳定模型 ID，允许用户编辑。

这些是文档核查，不是使用真实 Key 的付费端到端验证。模型可用性仍由账号、区域和套餐决定。

## 目录与协议补充

目录包含 23 项（含地区、套餐的独立入口），已有配置按 URL 归组；同一个厂商可保存多份配置。识别会移除标准 API 方法后缀与 `/v1`，不会抹去 `/coding`、`/plan` 等产品路径。当前用户的 GLM、DeepSeek、Qwen、OpenRouter 属于预设，Aibox、B300-Local 属于自定义。

- [智谱 Coding Plan / Codex](https://docs.bigmodel.cn/cn/coding-plan/tool/codex) 与 [Z.AI / Codex](https://docs.z.ai/devpack/tool/codex)：当前文档分别确认 `/api/v1` Responses。旧 Chat 套餐入口 `/api/coding/paas/v4` 仍作为显式选项，不把通用 `/api/paas/v4/models` 当作套餐模型列表。
- [百炼 Coding Plan](https://help.aliyun.com/zh/model-studio/coding-plan)：专用域名 `coding.dashscope.aliyuncs.com`，Anthropic `/apps/anthropic`、OpenAI `/v1`，不能与按量 Key 混用。目录中暂按 Chat 兼容接入，不据此推断原生 Responses。
- [火山 Agent Plan / Codex](https://docs.volcengine.com/docs/82379/2556054) 与 [Coding Plan / Codex](https://docs.volcengine.com/docs/82379/2556056)：套餐分别使用 `/api/plan/v3`、`/api/coding/v3`；普通方舟使用 `/api/v3`。CC 使用对应的 Anthropic 入口，独立存储。
- [Step Plan API](https://platform.stepfun.com/docs/zh/step-plan/integrations/reasoning-api.md) 与 [Claude Code](https://platform.stepfun.com/docs/zh/step-plan/integrations/claude-code.md)：套餐 `/step_plan/v1/chat/completions` 和 `/step_plan/v1/messages`，与普通 API 分开。
- [硅基流动 / Claude Code](https://docs.siliconflow.cn/docs/usercases/use-siliconcloud-in-ClaudeCode)：原生 Messages；Codex 通过 Chat 转换。
- [NVIDIA NIM](https://docs.api.nvidia.com/nim/reference/mistralai-mistral-small-4-119b-2603-infer)：`integrate.api.nvidia.com/v1` Chat。
- [Google OpenAI 兼容](https://ai.google.dev/gemini-api/docs/openai)：`/v1beta/openai` Chat，模型列表同基址 `/models`。URL 拼接不额外插入 `/v1`。
- [xAI API](https://docs.x.ai/docs/api-reference)：`/v1` 支持 Responses / Chat。

只向当前客户端提供有预设的入口；如果历史配置属于已知厂商但无当前客户端预设，仍保留卡片中的历史配置，不让它消失。模型 ID 由用户编辑或拉取；套餐／账号权限不能仅靠目录确认。

## 模型拉取与凭据输入

快速配置和已有配置详情共用 `ProviderModelFetchButton`，导入之前必须勾选确认，已存在的模型不重复添加。URL、Key 或协议变更时取消旧请求并清除旧结果。原有高级编辑器也使用同一拉取器。

`ModelListFetcher` 保留当前产品路径，去掉 `/messages`、`/responses`、`/chat/completions` 等完整方法后缀后请求模型列表。[DeepSeek 模型列表](https://api-docs.deepseek.com/api/list-models/) 使用显式 `/models` 地址。其余未配置专用列表的接口尝试当前基址的 `/models`（Anthropic 必要时 `/v1/models`），失败后提示手工填写，不跨套餐尝试其他产品地址。支持 `data`、`models` 两种常见返回结构；列表接口不代表所有模型都可用于当前协议或套餐。

请求禁止重定向，错误内容遮蔽完整 Key，认证重试先清除旧头。Key 控件编辑时使用普通 TextField，失焦后遮蔽，避免 SecureField 的 macOS Passwords 行为；存储机制沿用项目原有实现。

Codex 的 Chat 上游必须经过现有本地 Responses → Chat 转换，不依赖用户额外打开路由开关。原生 Responses 预设保留原协议。目录保存不会直接改写客户端配置，激活时才生效。

## 本机端点与 Key 校验

是否要求 Key 由 **Base URL 的主机**决定，与供应商名称无关：`ProviderCatalogEntry.isLocalEndpoint(_:)` 判定 `localhost` / `127.0.0.0/8` / `::1` / `0.0.0.0` / `.local` / `10/8` / `192.168/16` / `172.16/12`。

- 本机端点：Key 可留空，快速配置与已有配置详情都不再报「请填写 API Key」，Key 控件转为「本机服务无需 Key（留空即可）」；「检测连通性」不再把空 Key 判为失败，而用占位串发出探测请求。
- 远程端点：Key 仍为必填，连通性检测照旧要求非空。
- 之所以不能按供应商名判定：Ollama 与 LM Studio 默认无鉴权，但套了公网反代之后就是真需要 Key；`Ollama` 这个名字无法区分这两种情况，主机可以。
- 边界用例（`localhost.evil.com`、`127.0.0.2.example.com`、`172.15/172.32`、`192.169` 等）由 `Tests/local-endpoint-regressions.py` 锁定。

## 图标与验证范围

`Sources/ProviderIcons` 包含 LobeHub Icons 1.97.1 的真实厂商图标与 LiteLLM 官方文档 favicon。资源随应用打包，无运行时远程图片请求；来源及许可证见该目录 README 和 LICENSE。

图标必须在自己主题的垫底上可见：`ProviderIdentityMark` 把 PNG 画在 `Theme.bgSecondary` 上，`Tests/provider-icon-regressions.py` 要求每个资源的实心像素对对应主题垫底的对比度 ≥ 3:1。纯白或荧光色的 `-color` 变体在浅色主题下会渲染成一块空白，因此 Kimi、NVIDIA、OpenRouter、硅基流动、火山方舟改用单色变体；Ollama 与 LM Studio 补上了厂商图标。新增图标前先跑该测试。

目录内所有平台均为文档核查，不是使用真实 Key 的付费端到端验证；模型可用性由账号、区域和套餐决定。

按用户要求，本轮只修改代码，未构建、未运行需要 Swift 编译的测试、未使用用户 Key 请求供应商。仅做差异空白检查、构建脚本语法与资源完整性静态检查。既有 Codex 会话回归测试保留，供后续构建验证使用。

## 会话显示

Codex 最新版本的 `state_*.sqlite` 以只读模式读取，`archived = 0` 决定主会话卡片成员。进程持有文件、最近写入、最新 task 生命周期仅决定运行状态，不能排除空闲主会话。索引标题用于区分同一个项目中的多个会话。缺少 rollout 时保留索引信息；子代理通过索引 source 和 rollout 元数据双重排除。索引不可用时保留旧版近期文件扫描回退。

`Tests/codex-session-regressions.py` 使用临时数据库和日志测试空闲、运行、崩溃遗留 open turn、缺失／损坏日志、归档、子代理分类和标题。不会改写用户的 Codex 数据。`Tests/e2e-codex-tree.py` 是它的另一半：monitor 交出的东西 → `externalSessionTree` / 各计数器，合成 fixture 常跑，加 `CLAUDEBAR_E2E_REAL_INDEX=1` 时再对真实 `~/.codex` 索引断言一遍（main 有内容、没有 helper 被当成 main、每个 helper 的 parent 都在同一次扫描里）。它要编整个 app target（约 2 分钟），所以**不在 `make test` 里**。
