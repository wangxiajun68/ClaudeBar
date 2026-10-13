# ClaudeBar 网关与 New API 对比

核对时间：2026-10-12。参照 [QuantumNous/new-api](https://github.com/QuantumNous/new-api) 的当前主分支文档和下列生产源码；没有将 New API 源码复制到应用。上游主分支会继续变化，本表不是对某个发行版的完整兼容认证。

## 范围与结论

New API 是服务端聚合平台；ClaudeBar 是带本机令牌的桌面单进程网关。值得直接补齐的是调度、故障恢复、协议完整性、多模态能力约束和资源边界。多租户售卖、支付和跨节点协调需要不同的部署及数据模型，不能通过增加几个配置开关宣称已经具备。

本轮已补齐下表标记“新增”的功能，但**不等于实现 New API 全部端点和供应商适配器**。未完成项单独列出，不把拒绝请求当作支持，也不把模拟上游验证当作真实供应商认证。

2026-10-13 补充复查：保留语音响应长度以便客户端检测截断；拒绝无法转换的 Responses 内容、工具结果媒体和供应商私有音频历史 ID；64 并发占用条聚合为至多 16 格，保持窄窗口布局。

## 调度与稳定性

| 能力 | ClaudeBar 现状 |
| --- | --- |
| 通道优先级与权重 | 保留池内顺序、均衡、延迟策略；新增供应商权重 1–100，共享同一供应商的模型不会重复增加权重 |
| 并发隔离 | 全局与供应商独立额度；上限扩到 64，默认仍为全局 4、供应商 2；在 actor 内原子预留、转移和释放 |
| 有界排队 | 全局最多 1024、供应商独立容量，默认 32 / 8；累计等待正文 64 MiB；最早可执行请求优先，不让繁忙供应商阻塞其他供应商 |
| 速率限制 | 全局及新增供应商滚动分钟窗口，范围 1–6000；入队不计额度，真正尝试才计入，重试同样不能绕过限制 |
| 重试 | 同任务档位的兼容候选内切换；最多 1–5 次且受总重试预算限制；开始向客户端输出后不重放 |
| 熔断恢复 | 429 按供应商共享冷却；支持秒数和 HTTP 日期 `Retry-After`；冷却后只放行一个恢复探测，避免并发重试洪峰 |
| 超时 | 排队、首个有效输出、上游无数据、重试预算、请求总时长各有边界；注释心跳不能无限延长首帧和总时长 |
| 断开与慢下游 | 断开取消上游和排队；等待下游写入完成再转发，整个请求的总期限可中断卡住的写入 |
| SSE | 增量有界解码，支持 CR/LF/CRLF、BOM、多行 data；注释和未知字段也受大小限制；未终止响应不是成功 |
| 追踪 | 每次请求生成 UUID；排队、各次尝试、上游及下游 `X-Request-ID` 关联；错误 JSON 带 request_id |
| 重配置与退出 | 旧队列明确失败；活动请求保留其额度至结束；取消任务及计时器，不重放内存队列 |

参考：[通道选择](https://raw.githubusercontent.com/QuantumNous/new-api/main/service/channel_select.go)、[请求转发](https://raw.githubusercontent.com/QuantumNous/new-api/main/controller/relay.go)、[限流](https://raw.githubusercontent.com/QuantumNous/new-api/main/middleware/model-rate-limit.go)、[流扫描](https://raw.githubusercontent.com/QuantumNous/new-api/main/relay/helper/stream_scanner.go)、[请求策略](https://raw.githubusercontent.com/QuantumNous/new-api/main/service/request_policy.go)。这些源码用于核对能力及失败场景，不作为本地性能结果的来源。

## 多模态与接口

| 入口 / 能力 | 实现情况与限制 |
| --- | --- |
| Chat Completions | JSON / SSE；工具、图片；新增音频输入、视频输入、原生 PDF、Chat 语音和图片输出 |
| Responses | JSON / SSE 转 Chat；图片、音频、视频和 PDF 输入不再被转换器静默丢弃；仍只转换文本及工具输出 |
| Anthropic Messages | JSON / SSE 转 Chat；图片及新增 PDF 文档输入，保留标题和上下文；不伪造文档引用能力 |
| `/v1/images/generations` | 新增 JSON 图像生成，单张；返回 URL 或 base64 原样保留；需要独立“图像生成 API”能力 |
| `/v1/audio/speech` | 新增二进制语音合成；16 KiB 分块转发、写入背压、64 MiB 响应总上限；不在二进制响应尾部追加 SSE 错误 |
| `/v1/embeddings` | 新增字符串及字符串数组输入，float / base64 输出；需要独立嵌入能力；固定池内首个兼容模型，仅同名模型可备用，不因冷却或权重混用向量空间 |
| `/v1/rerank` | 新增字符串 query 与字符串 documents，校验结果索引和分数；需要独立重排序能力 |
| Gemini 原生协议 | 尚未实现 generateContent / streamGenerateContent 入口；支持兼容 Chat 的 Gemini 上游不等于支持 Gemini 原生协议 |
| 转录、翻译、图像编辑 | 尚未实现 multipart `/audio/transcriptions`、`/audio/translations`、`/images/edits`；可经支持音频输入的 Chat 模型理解音频，但不是 Whisper API 兼容承诺 |
| 视频生成与异步任务 | 尚未实现任务创建、状态、结果、取消和任务所属供应商持久化；视频输入理解不等于视频生成 |
| Realtime / Responses WebSocket | 尚未实现双向 WebSocket 转发、会话恢复与音频事件协议 |
| 原生供应商适配 | 仍使用保存的 OpenAI 兼容上游。没有实现 New API 的所有原生 Anthropic、Gemini、Azure、Bedrock 等认证和协议适配 |

媒体校验不读取本地路径、不下载远端媒体、不解码整份 base64 再重新编码。单个内联附件最多 16 MiB 编码数据；请求整体仍受 HTTP 64 MiB、队列总字节保护限制。文本上下文估算不把 base64 当文本 token；媒体预留只是本地路由估算，真实文件页数、音视频时长及模型 tokenizer 仍由上游约束。

普通 SSE 单事件 1 MiB、总计 16 MiB；明确请求 Chat 图片或语音输出时允许单事件 16 MiB、总计 64 MiB。大媒体不是解除所有内存限制的理由。所有新能力在旧配置中默认关闭；OpenRouter 从新鲜目录的 input/output modalities 获取，手动供应商必须显式声明。

OpenRouter 仍需所有已公布价格维度为零，目录新鲜；PDF 强制 `file-parser` 的 `native` 引擎，禁止默认回退到付费 OCR。独立图像 / 语音 / 嵌入 / 重排序 API 的价格与端点不同，因此目前只接受用户确认免费的手动供应商，不用 Chat 免费目录冒充这些 API 的免费证明。

协议依据：[OpenRouter 音频](https://openrouter.ai/docs/guides/overview/multimodal/audio)、[视频](https://openrouter.ai/docs/guides/overview/multimodal/videos)、[PDF](https://openrouter.ai/docs/guides/overview/multimodal/pdfs)、[OpenAI 图像生成](https://developers.openai.com/api/reference/resources/images/methods/generate)、[语音合成](https://developers.openai.com/api/reference/resources/audio/subresources/speech/methods/create)、[嵌入](https://developers.openai.com/api/reference/resources/embeddings/methods/create)。具体媒体格式、声音、图片尺寸和可用模型依赖供应商，不由一个能力开关保证。

## 安全及尚未具备的平台能力

- 保留本机令牌、供应商凭据替换、拒绝重定向携带凭据、0600 原子私有写入、dev / release 隔离。未经鉴权不继续读取声明的大正文。
- 新增严格 Content-Length、重复头拒绝、64 KiB 请求头上限、15 秒读取期限；不支持 HTTP chunked 请求体，畸形请求关闭连接而非继续猜测边界。
- 没有多用户 / 分组 / RBAC、用户独立 API Key、金额额度预扣与退款、支付和发票、Redis 分布式限流、集群共享队列、插件执行沙箱。
- 没有持久化会话亲和、跨请求 KV 缓存亲和、统一 TPM / 每日 token 配额、自动质量评测或内容审核策略。当前 RPM 不能替代供应商 TPM 限制。
- 最近路由是有界内存记录，不是完整审计平台；现有流量日志是否保存正文仍由用户选项控制。没有新增正文/媒体审计副本。

这些能力要继续补齐时，需要先确定单机用途与服务端用途的边界，尤其是身份、扣费语义、异步任务归属和重放策略。不能直接套用“多试一次”到有副作用的任务创建 API。

## 可复测性能

路由基准：同机优化编译，200 个池成员、1000 条目录、1000 次 begin/finish，三轮中位数。改动前参考 `c49ed36cd5a1a1c53d3fcc4d4278f9adce3e86a3`：P95 0.719 ms；调度优化后 0.330 ms，约降低 54%。这是 actor 路由耗时，不是模型推理延迟或网络 QPS 保证。

合成突发：512 请求、64 并发槽、每个请求模拟 2 ms 服务，约 63–65 ms 完成；没有超过并发上限，结束后配额、等待数和等待字节均归零。SSE 58 万字节 / 1 万事件约 5–8 ms。媒体语法校验 8 MiB 约 62 ms；不会另外分配解码后的媒体副本。数字受同机其他构建任务影响，应以可重复基准而非单次最小值判断。

优化点：目录 ID 索引、供应商 / 成员占用计数、队列字节及供应商计数缓存、头游标式分钟窗口、输出快照合并、单实例连接池。没有增加常驻运行服务或第三方依赖。

验证入口：

```bash
make test TEST=free-model-gateway
make test TEST=gateway-performance
python3 Tests/gateway-performance-regressions.py --baseline-ref c49ed36cd5a1a1c53d3fcc4d4278f9adce3e86a3
python3 Tools/render-model-gateway-preview.py
make test
make build
make release
```

协议测试使用临时目录、模拟凭据和本机模拟上游；构建仅生成包，不安装、不启动正式应用、不操作 VPN，也未调用付费推理或真实多模态供应商。
