# 模型花费估算

> ClaudeBar 技术文档 · §15
> 相关：[数据访问层](04-data-access-layer.md) · [供应商目录](13-provider-directory.md)

概览页的「模型花费」磁贴与用量页每个模型瓦片上的价格都由这里算出。核心事实：**ClaudeBar 拿不到账单**。

- Claude Code / Codex 订阅不按 token 计费，本地只能读到 token。
- 第三方中转不回传单价。**只有 OpenRouter 与 Cursor 的接口回传金额**（见下），其余平台一个都没有。
- 国产平台没有公开的「查价」接口；硅基流动有价格页但 `/v1/models` 只返回模型 ID。

所以这里的数字是 **按厂商官方刊例价折算的估算**：回答「这批 token 走按量 API 要花多少钱」，不是「实际扣了多少」。磁贴 tooltip 第一行就写明「按官方刊例价估算（非账单）」。

## 组成

| 文件 | 职责 |
|------|------|
| `Utils/ModelPricing.swift` | slug 归一化与匹配、逐桶计价、分币种累加、金额格式化、「无价」分类。**只管估算**——不接受金额，也就不可能把实扣折进来 |
| `Utils/ModelPriceTable.swift` | 内置价目表 + 无价名单（编译进二进制、带核查日期）。**改内置价只改这一个文件**，日期在 `ModelPricing.updated` |
| `Utils/ModelPriceCatalog.swift` | 价目表的可写层：用户编辑与抓取回来的**覆盖行**（各带生效日）、待确认队列、核查新鲜度；落盘 `price-overrides.json`。**不发网络请求** |
| `Utils/ModelPriceSources.swift` | 出站那一半：models.dev（美元厂商）与各人民币厂商的定价页解析。解析不出的页面返回空并报告为「未能读取」，绝不用聚合源的国际价顶替 |
| `Utils/CursorLedger.swift` / `Utils/CursorLedgerStore.swift` | Cursor 的**实际扣费**：解码、窗口规划与取数节奏（见 [04 数据访问层](04-data-access-layer.md)） |
| `Utils/ExchangeRate.swift` | USD→CNY 汇率：双源查询、TTL 缓存、手动覆盖；默认模式下不发请求 |
| `Views/Shared/UsageModelCard.swift` | 用量瓦片上的价格行：估算一行、`Cursor 实扣` 一行，各自成句、永不相加 |
| `Views/Shared/ModelPriceCard.swift` | 设置页的模型定价表：逐行编辑、覆盖行的溯源标签、待确认的抓取候选与差异行 |
| `Views/Shared/ExchangeRateTile.swift` | 设置页的汇率控件（仅折算模式下显示） |
| `Models/ProviderStore+Derived.swift` | `costEstimate` / `costLine(for:)` 两个估算入口；实扣不进 store，`UsageView` 直接读 `CursorLedgerStore`（`rows` / `windowLabel`） |
| `Tests/model-cost-regressions.py` | 锁定 slug 匹配（含 effort 档归一）、**覆盖价与内置表的并列判定**（同 slug 的覆盖在生效日取胜、生效日之前不生效、清除后复原；短 slug 覆盖不吞更长内置 slug）、币种隔离、无价分类与格式化 |
| `Tests/model-price-source-regressions.py` | 用 `Tests/fixtures/price-pages/` 的页面快照跑真实解析器，抽出的数字与内置表的行逐条比对 |
| `Tests/cursor-ledger-regressions.py` | 锁定实扣解码、窗口退化、以及「实扣到不了估算那条路」（`ModelUsage` 不带钱） |

### 覆盖行与内置表的关系

覆盖（用户手动编辑或抓取后应用）不替换内置表，而是在解析时参与同一次最长匹配，**等长 slug 时覆盖胜出**，因此「改一行内置模型的价格」这种最常见的编辑确实生效；覆盖行还带生效日，生效日之前记录的用量仍按当时的价格计价，改价因此是前向的。默认不抓取：`autoCheckIfStale()` 在没有核查记录时直接返回，第一次联网必须由用户点「查询更新」发起，抓取结果默认进入待确认队列而不是直接应用。抓取到的行按 `apply(_:)` 与编辑器同一套规则校验（canonical slug、四个桶全为正、cacheRead ≤ input）；被拒绝的行留在待确认队列里，不静默丢弃。

## 计价口径

每个模型一条 `Rate`，**单位是「每百万 token 的货币金额」**，分四个桶——与 `ModelUsage` 存的桶一一对应：

| 桶 | 对应字段 | 说明 |
|----|----------|------|
| `input` | `inputTokens` | 未命中缓存的输入 |
| `output` | `outputTokens` | 输出（各家已把 reasoning token 并进来） |
| `cacheRead` | `cacheReadTokens` | 命中 prompt cache 的读 |
| `cacheWrite` | `cacheCreationTokens` | 写入 cache |

`ModelUsage` 的桶是**互斥**的（Claude 的 `input_tokens` 不含缓存字段；Codex 解析时从 `input_tokens` 里减掉了 `cached_input_tokens`；代理侧由 `TokenTotals` 在落库前折掉，见 [§04](04-data-access-layer.md)），所以四项各自乘单价直接相加，不会重复计费。

这条互斥性不是各家上游天然给的——三条来源各自的形状不同，`TokenTotals`（`Utils/StreamAssembler.swift`）负责在**唯一知道协议的那一层**抹平：

| 来源 | 上游报的形状 | 处理 |
|------|--------------|------|
| Anthropic Messages | `input_tokens` 与 `cache_read_input_tokens` / `cache_creation_input_tokens` 并列，前者**不含**后两者 | 原样采信 |
| Chat Completions | `prompt_tokens` **含**命中数，另外在 `prompt_tokens_details.cached_tokens`（DeepSeek 还额外给顶层 `prompt_cache_hit_tokens`）报命中 | `input = prompt_tokens − 命中` |
| Responses | `input_tokens` **含** `input_tokens_details.cached_tokens` | 同上 |
| 中转回显 Anthropic 字段 | `cache_read_input_tokens` 旁边是**不含**缓存的 `input_tokens` | 不折，按 Anthropic 处理 |

DeepSeek 自己的文档就写明了这条等式：`prompt_tokens == prompt_cache_hit_tokens + prompt_cache_miss_tokens`。**旧版本把这个和 `cached_tokens` 一起原样存了**，于是命中那部分既按 `input` 全价算了一次、又按 `cacheRead` 折价算了一次，`totalTokens` 也把它加了两次。第三方 rollup（`proxy-usage.db`）里修前的行走过一次 `input -= cache_read` 的迁移（`user_version = 1`），JSONL 后端同理（`usage-third-party.v1` 标记文件）。`Tests/proxy-usage-regressions.py` 锁定这些形状。

### 厂商的桶各不相同，按三条规则映射

1. **没有 cache-write 桶**（DeepSeek、阶跃、火山、Kimi 非 K3 系列、GLM）→ `cacheWrite = input`。它们的文档就是这么说的（「首次写入按未命中计费」/「cache-miss 价已包含写入费用」），这是厂商自己的模型，不是猜的。
2. **分时段定价**（DeepSeek 及其在火山的托管版：错峰 = 五折）→ 用**峰时**价。rollup 的键是 (day, model)，没有小时粒度，事后无法套用错峰窗口；而且这个应用观测到的用量本来就集中在工作时段。代价：错峰时段的花费被高估最多 2 倍。
3. **按上下文长度分档**（GLM-5.x 的 <32K/≥32K、火山 doubao 2.0 系、qwen 的 flash 系）→ 用**基础档**。原因同上：分档是 per-request 的，rollup 没有这个维度。代价：长上下文请求被低估。

Anthropic 的写入价取 **5 分钟 TTL**（1.25× input）；1 小时 TTL（2×）不单独建模。

## 币种：默认不换算

Anthropic / OpenAI 用 USD 刊例价，DeepSeek / 智谱 / 百炼 / 火山 / MiniMax / 阶跃 / Kimi 用 CNY。表里 `currency` 就是厂商自己的计价币种。

`Cost` 因此是两个独立的累加器：

```swift
struct Cost { var cny: Double = 0; var usd: Double = 0 }
```

- `dominant` 取金额大的那个，做磁贴主数字。
- `secondary` 取另一个，做副行「另有 $43.20」。
- 两者都是 0 时没有主数字（磁贴显示 `—`）。

把两种币种加起来会得到一个虚构的数字，静默丢掉一种则会让总额少一块——这两种都做过，`Tests/model-cost-regressions.py` 里各有一条断言守着。

### 可选折算（设置 → 模型花费 → 显示货币）

默认 `split`（分列）**不联网、不换算**。用户可切到「人民币」或「美元」，此时才需要汇率。

`ModelPricing` **自身不保存汇率**——`cost.converted(to:rate:)` 把汇率当**参数**，`present(_:display:rate:)` 同理。这是整个模块里唯一会把两种货币相加的地方，参数化意味着「不可能在拿不到汇率的情况下算出一个折算金额」。`CostDisplay` 也定义在 `ModelPricing.swift` 而不是 `AppPreferences`：定价规则和选择它的开关留在同一个文件里，回归测试也不必拖进整个偏好图。

| `CostDisplay` | 行为 | 需要汇率 |
|---|---|---|
| `split`（默认） | 两个数字分列 | 否 |
| `cny` | 全部折算成 ¥ | 是 |
| `usd` | 全部折算成 $ | 是 |

规则：

- **只有一种货币时不需要汇率**，也不标「折算」——本来就没有发生换算。此时即使请求的是另一种货币，也照原币种显示：把 ¥700 显示成 $ 需要凭空造一个汇率。
- **只有两种货币都有、且用户选了折算**才真正转换，`Presented.isConverted` 为 true，副行改为显示原币金额（`¥21.5（$3.00）`），让每个模型的价格可核对。
- **汇率不可用**（未取到 / 用户填了非法值）→ 退回分列并给出 `fallbackReason`，**绝不按 1 换算**。

### 汇率来源（`Utils/ExchangeRate.swift`）

| 顺序 | 来源 | 说明 |
|---|---|---|
| 1 | `open.er-api.com/v6/latest/USD` | exchangerate-api 免费层，自带 `time_next_update_utc` |
| 2 | `latest.currency-api.pages.dev/v1/currencies/usd.json` | fawazahmed0/currency-api，CDN 上的静态文件，作回退 |

两者都无需 Key、每日更新。只取 `CNY`——应用只涉及两种货币，不做通用汇率框架。

关键行为：

- **默认模式下一次请求都不发。** `ExchangeRate.start()` 在启动时先看偏好；`costDisplay` 的 `didSet` 只在 `needsRate` 时触发。这与本项目对其他出站请求的态度一致：开关没打开，代码路径完全不执行。
- **手动汇率是逃生门。** `AppPreferences.manualUSDToCNY` 一旦设定，`refreshIfStale()` 直接返回，永远不联网。合法区间 `(1, 20)`，越界视为清空——一个手滑打成 `72` 的汇率会把所有折算金额放大十倍且不报错。
- **TTL 12 小时**（来源每日更新，一天问两次已足够）。缓存写 UserDefaults：三个标量，且必须在重启后存活，否则选了折算模式的用户每次启动都要等一次网络请求。
- **失败保留旧值**：过期汇率好过没有汇率，`isStale` 会在文案里标出来。
- 取回后用 `NotificationCenter` 发 `.exchangeRateDidChange`，磁贴与设置页据此刷新。

## 有模型，但没有价

`rate(for:)` 返回 nil 时**绝不按 0 计**，也不套别的模型的价。这时候 `unpricedReason(_:)` 再问一次「这是已知的无价模型吗」，`Estimate.Line` 因此带一个 `unpriced: Unpriced?`：

| `Unpriced` | 含义 | 磁贴文案 |
|---|---|---|
| `.subscription` | 会员 / 套餐 SKU，压根不按 token 计费 | 「N 个订阅制」 |
| `.notPublished` | 按量计费，但官方没公开刊例价 | 「N 个未公开价」 |
| `.unknownSlug` | 表里没有这个名字 | 「N 个未计价」 |

分这三类不是为了好看：**订阅制**要用户去订阅页看额度，**未公开价**是厂商的问题，**未收录**是这张表该补的行。混成「未计价」三种都得不到该有的处理。

名单在 `ModelPriceTable.unpriced`：

- `.subscription`：`kimi-for-coding`、`kimi-for-coding-highspeed`（Kimi Code 会员，与开放平台是两套产品）、`ark-code`（火山 Coding/Agent Plan 的 `ark-code-latest` 别名，官方说该端点不能用于 API 调用）。
- `.notPublished`：`qwen3.8-max`、`qwen3.8-flash`——百炼文档明说这两个的显式缓存命中价**不是**标准的 10%，让去控制台看，所以没有公开数字；`gpt-5.4-pro`、`gpt-5.5-pro`——OpenAI 公布了它们的 input/output（$30/$180），但没给 cached-input 价，而缓存读占本应用统计的 token 大头，**只有一半的卡片不如不给**。

这三类的 token 都计入 `unpricedTokens`，tooltip 里写明「未计入合计的模型共 N token」。

## slug 匹配

记录下来的模型名是「客户端当初配的什么就是什么」。`ModelPricing.canonical` 剥掉路由元数据：

| 输入 | 归一化 |
|------|--------|
| `anthropic/claude-sonnet-4-6` | `claude-sonnet-4-6`（`vendor/` 前缀） |
| `claude-sonnet-4-6:free` | `claude-sonnet-4-6`（OpenRouter 的 `:free` / `:nitro`） |
| `claude-sonnet-4-6-20250929` | `claude-sonnet-4-6`（日期戳） |
| `glm-5.3-flash-latest` | `glm-5.3-flash`（`-latest` 后缀） |
| `claude-opus-5-5-medium` | `claude-opus-5-5`（**effort / 速度档**） |
| `claude-4.6-sonnet-medium-thinking` | `claude-4.6-sonnet`（档位叠加，**循环剥**） |

最后一组是为了让 Cursor 的模型名落到本地客户端那一行：Cursor 按 effort 档命名
（`claude-opus-5-5-medium`），Claude Code / Codex 记的是基础名（`claude-opus-5-5`），
不归一的话同一个模型会在用量页裂成两行、Cursor 的实际扣费找不到归属的瓦片。剥的是受控的一组词
（`-low` / `-medium` / `-high` / `-xhigh` / `-fast` / `-thinking`），**按连字符边界**匹配，
所以厂商自己的 `-highspeed`（`minimax-m2.7-highspeed`）不受影响。

这条同时作用于定价查表，方向是安全的：查表本就是最长 slug 优先的前缀匹配，剥掉只会落向基础档；
而且**价目表与无价名单里没有任何键以这些词结尾**——有的话那个键永远命中不了
（`Tests/model-cost-regressions.py` 对两张表都断言这一条）。

匹配用 **token 边界的前缀**（`name == slug || name.hasPrefix(slug + "-")`），并且 **最长 slug 优先**——价目表与无价名单**合在一次查找里**比长度：

- `claude-sonnet-4-6-20250929` 命中 `claude-sonnet-4-6`（前缀 + 边界）。
- `claude-sonnet-4-65` **不**命中（边界挡住了）。
- `glm-5.3-flash` 命中 `glm-5.3-flash` 而不是更短的 `glm-5`（最长优先）。
- `gpt-5.5-pro` 命中无价名单的 `gpt-5.5-pro` 而不是价目表的 `gpt-5.5`（更长者胜）。**这一条是「先查无价名单」写法会踩的坑**：那样写能通过「名单里的 slug 都算不出钱」的检查，却会把 pro 档按 $5/$30 计——两个不同产品、不同价格。

### 表里的键必须是 canonical 形式

查表只在归一化后的名字上做一次，所以 `ModelPriceTable` 的键必须满足 `canonical(slug) == slug`。火山 Coding Plan 的官方模型 ID 是 `ark-code-latest`，名单里因此写成 `ark-code`——写 `-latest` 的那个键永远命中不了。这条约束（以及「同一个 slug 不能既在价目表又在无价名单」）由回归测试守着，加新行时不用自己记。

## 金额格式化

`ModelPricing.format` 手写千分位而不用 `NumberFormatter`：它每帧都在最密的页面上被调用，一次布局一个 formatter 是本项目别处（`UsageStats` 的缓存 formatter）刻意避开的开销。

- `¥1,284.60` — 两位小数，千分位
- `<¥0.01` — 不足一分显示下限，`¥0.00` 会被读成「没有花费」
- 非有限值与负数都退化成 `¥0.00`（估算不该出现负花费）

数据流：

```
UsageIndex / ProxyUsageStore          （token 事实）
        ↓
ProviderStore.usageStats              （当前周期的每模型聚合，已按周期 chip 变）
        ↓  ModelPricing.estimate
ProviderStore.costEstimate            （概览磁贴）
        ↓  ModelPricing.cost(of:) / unpricedReason(_:)
ProviderStore.costLine(for:)          （用量瓦片，逐个模型，不重建整个 estimate）
        ↓  ModelPricing.present(_:display:rate:)   ← ExchangeRate.effectiveRate
UsageModelCard（用量页） / popup 用量区 / 灵动岛用量卡（按偏好渲染：分列 / 折算）
```

`costEstimate` 与周期选择天然联动：`usageStats` 就是周期聚合，换日 / 月 / 年 / 全部自动跟着变，不需要额外查询。折算只发生在**渲染**这一步，`Estimate` 本身始终保留两种货币的原值——切换显示模式不会丢失任何信息，也不会把折算结果写回数据。

## 哪些平台能拿到真金额

估算之所以是估算，是因为绝大多数厂商不回传钱。真金额来源只有两个：

- **OpenRouter**：响应里的 `usage.cost`（credits）与 `usage.cost_details.upstream_inference_cost`；`prompt_tokens_details.cached_tokens` / `cache_write_tokens` 给的是读 / 写。`GET /api/v1/models` 的 `pricing.prompt` 等单位是 **USD per token**（不是 per million），`overrides[]` 里带 `min_prompt_tokens` 或 UTC 时段的条件价（OpenRouter 就用它表达 OpenAI 的长上下文档）。注意：`cost` 单位文档写的是 credits，从未给过 credits↔USD 的汇率。**尚未接入。**
- **Cursor**（**已接入**）：`api2.cursor.sh` 的 `DashboardService.GetAggregatedUsageEvents` / `GetFilteredUsageEvents`，用本机 `state.vscdb` 里已存的裸 JWT 调用，不新增凭据。每条带 `tokenUsage.{inputTokens,outputTokens,cacheWriteTokens,cacheReadTokens,totalCents}`，且 `totalCents == chargedCents`（9,895 条逐条核对）——**是实际扣掉的数额**。解码与窗口见 [04 数据访问层](04-data-access-layer.md) 的 `CursorLedger` 一节。

其余厂商（含所有国产平台）都只有 token 事实，金额只能自己乘价目表——这正是本模块存在的理由。

### 实际扣费与估算**并列，绝不合并**

用量页「按模型」的瓦片上，一个模型可以同时有两行钱：

```
claude-opus-5-5        38.7M
  估算  ¥1,284.60          ← token × 刊例价表，本模块算的
  Cursor 实扣  $34.65      ← Cursor 自己扣的，来自它的账本
  ⓘ 9月28日–10月28日        ← 仅当金额覆盖的窗口与页面周期不一致时出现
```

三条规则，都有回归断言守着：

1. **永不相加。** 两个数回答不同的问题（「按刊例价这批 token 值多少」vs「Cursor 扣了多少」），
   来自不同来源（本地价目表 vs Cursor 账本），可能覆盖不同窗口。把它们合成一个数，得到的既不是
   估算也不是账单。`ModelUsage` **没有金额字段**，`ModelPricing.estimate` **只接受 token**——
   类型系统就是这条规则的执行者（`Tests/cursor-ledger-regressions.py` 断言 `ModelUsage` 不带钱）。
2. **措辞不共享。** 实扣那行写「Cursor 实扣」，估算那行写「按官方刊例价估算」；两者的
   accessibility label 各自成句。实扣上出现「估算」二字是这个功能最不能犯的错。
3. **窗口必须说出来。** Cursor 的金额接口接受的是**窗口**（上限约 90 天，超出非确定性报错），
   不是「今天 / 月 / 年」。切到别的周期时**保留旧值并标明它属于哪个窗口**，而不是让数字消失
   ——数字消失会读成「数据坏了」，而不是读成「口径不同」。`年` / `全部` 退化为账单周期并标注
   「仅覆盖一个账期」，绝不返回一年的某个切片冒充总额。

## 为什么不接动态价源

调研过全部公开的机器可读价源（2026-09-25），结论是**没有一个能替代这张表**，而且有几个会静默改错数字。记录在这里，避免以后有人顺手接一个。**表仍然是唯一事实来源**：抓取只用来核对与提议，不自动改写。

**美元那一半自动核对，人民币那一半读厂商自己的定价页**：

| 来源 | 单位 | 币种 | 覆盖本表 | 问题 |
|---|---|---|---|---|
| models.dev `/api.json` | 每百万 | **折算后的 USD** | 55/56 | 无 `currency` 字段；CNY 全被按各自汇率折成 USD（各 provider 汇率还不同）；DeepSeek 记的是**错峰价**；`deepseek-v4-pro` 是**改价前的旧价** |
| LiteLLM `model_prices_and_context_window.json` | **每 token** | USD | 56/56 | 火山豆包 8 条全是 `0.0` 占位；无厂商侧 StepFun；`raw.githubusercontent.com` 在部分网络不可达（用 jsdelivr 镜像） |
| Vercel AI Gateway `/v1/models` | 每 token | USD | 50/56 | 缺 5 条火山与 `deepseek-flash`；但它是唯一把错峰建模成 `peak_pricing.multiplier + UTC 窗口`（而不是烘焙成数字）的源 |
| OpenRouter `/models` | 每 token | USD | 50/56 | **ToS 明令禁止**抓取与再分发（见下）；且 headline 是**最便宜路由**的价，不是厂商刊例价 |
| PPIO `api.ppinfra.com` | 每百万 | **CNY（未声明）** | ~12/56 命中 | 是**转售商**自己的价目，不是厂商的 |

models.dev 在这张表里只用于 **Anthropic 与 OpenAI 两家**（`ModelPriceSources.usdVendors`），因为其余条目是聚合源自己折出来的国际价；人民币厂商一律读厂商定价页（DeepSeek / 智谱 / Kimi / 百炼 / 阶跃 / MiniMax，见 `ModelPriceSources.vendors`），解析不出的页面返回空并报「未能读取」。火山方舟在 `uncheckable` 里，理由写在名单上。

**三个会静默改错的具体例子**（都是我实测确认的，不是推断）：

1. **DeepSeek 会掉一半。** models.dev 的 `deepseek/deepseek-flash` 是 `0.15 USD`，÷6.75 ≈ ¥1——正是**错峰**价。本表的约定是记峰时（见上「三条规则」）。直接导入会让这两行腰斩。
2. **阿里会把国际价当国内价。** models.dev 的 `alibaba-cn/qwen3.7-max` 是 `2.5 USD`（国际站价），阿里云国内站是 **12 元**。导入会让它看起来便宜 4.8 倍。
3. **`qwen3.7-flash` 曾经真的写错了**，而且是本表自己的错：写成 `0.03 / 0.13`，那是**美元**刊例价留着人民币符号——比真价（`0.2 元 / 0.8 元`）便宜 6.7 倍。是这次调研交叉比对才发现的。现在有回归断言守着这一类（见下）。

**OpenRouter 是法律问题，不是技术问题。** 它的 ToS（2026-08-31 更新）明确禁止用任何自动化手段「抓取或复制本服务上的任何信息」，以及「以转售为目的访问本服务」。把它的端点接进一个消费级应用并复制价格，是灰的。**不要接。**

## 更新价目表

1. 核对厂商定价页，改 `Sources/ClaudeBar/Utils/ModelPriceTable.swift` 里对应的行（文件里每段都标了来源 URL）。
2. 改 `ModelPricing.updated` 的日期（tooltip 末尾显示「价目表核查于 …」）—— 它是唯一的日期来源，价目表文件里只写注释。
3. `python3 Tests/model-cost-regressions.py` —— 会校验 slug 唯一且 canonical、input/output 非零、cache 桶非零、无价名单与价目表不重叠，以及**本应用目录里内置的那些模型 ID 都有交代**。
4. 设置页「模型定价 → 查询更新」可以对现有行做一次自动核对：差异进入待确认队列，逐条「应用」才写入 `price-overrides.json`，不改动内置表也不重新发版。抓到的页面解析数字由 `Tests/model-price-source-regressions.py` 用 `Tests/fixtures/price-pages/` 的快照守着。

模型 ID 以 [§13 供应商目录](13-provider-directory.md) 里的预设为准：那张表里的 slug 是「用户实际会记录下来的名字」，这里少一行，那张卡片就会显示「未计价」。新增厂商时两处一起加。

## 已知未核实项

- **火山方舟 Chat API 的 `usage` 字段名**：文档页是客户端渲染，抓不到 schema。定价页确认了计费公式用到「缓存命中」token 数（`doubao-*` 的命中价是公开的，约为 input 的 20%），但**响应里的字段名**需实际调一次接口确认。这只影响解析，不影响本模块的价目表。
- **OpenRouter 的 credits↔USD 汇率**：文档从未给出。
- **MiniMax Token Plan 国际版价格**：未获取。
- **GLM Coding Plan 新订阅价**：当前积分制套餐的 CNY 页面是纯 JS，拿不到；表里没有 Coding Plan 相关行（它是订阅制）。


### 2026-10-01 用量正确性排查

- 总 Token、每日记录、来源明细、按日计价统一包含 Claude Code、Codex 和第三方代理记录；Cursor 官方账单仍独立显示，不加进本地总量。
- Codex 同时扫描 `sessions` 和 `archived_sessions`。归档移动不再让历史用量消失，目录监听覆盖两者及归档目录的创建。缺失模型名的记录归入 `unknown` 并标记未计价，不能把已测量的 Token 丢弃。
- `last_token_usage` 优先作为新增用量；缺少它的旧记录使用累计输入、输出和缓存读取字段的差值。重复累计事件不再次加总，跨追加保存累计基线，零 Token 的上下文事件不增加调用次数。
- SQLite 索引升级到 v10 重建 Codex 派生记录；JSON 文件携带 `parserVersion`，旧版本同样重建。这只更新应用自己的缓存，不改写原始会话。
- 费用在每次发布用量时按日重算，发布前比较结果；估算结果发布到 `.usage` 观察域，解决「价格修改或每日分布改变但 Token 总量不变」时的旧金额。
- 同一模型部分日期未计价时保留已计价金额，同时显示未覆盖的 Token 数；不能因为某一天有价格就把所有日期标成完整估算。
- Responses 路由转发 Anthropic 形状的 usage 时，首次缓存写入即便读取为零也计入；第三方请求入账后主动通知刷新。
- 文件枚举保留返回的完整绝对路径，避免符号链接路径规范化后丢失子目录而漏读记录。

`make test TEST="usage-index model-cost proxy-usage usage-analysis"` 执行生产解析、持久化、升级和发布函数，使用临时 SQLite/JSON 与模拟会话；覆盖重复追加、半行、归档移动、消息 ID 去重、来源/每日/模型总量守恒、仅改价刷新及部分计价。全回归清单由 Makefile 维护。

只读抽查时，正式版 2026-10-01 索引里的 Claude Code **52,559,217** Token、未归档 Codex **11,469,321** Token 分别与原始 usage 去重加总一致；另外归档 Codex 中 UTC 日期为当天的记录合计 **47,056,983** Token，旧扫描入口完全遗漏。数值是排查时的快照，后续请求会继续增长；UTC 筛选值不代替本地日界线的正式查询。

补充模型完整性：平台按客户端来源归属，Codex 自定义模型与官方模型都在 Codex 平台内。模型清单改为本地与 Cursor 窗口记录的集合，不设数量上限；本地别名合并，Cursor 数量与账单日期独立显示，避免遗漏 Cursor-only 模型或把不同窗口加总。缺失模型标识保留 `unknown` 用量。模型卡片改用真实 Token 分量条，并明确标注本地估算及 Cursor 实扣。

口径边界：Token 是每次请求处理的输入、缓存和输出累计量，同一段上下文被多次使用会多次计入，并非独立文本的字数。金额仍是按价目表/用户覆盖价估算；错峰、上下文阶梯、缓存 TTL、代理折扣与订阅实际扣费不由日级 rollup 还原。Cursor 的窗口、截断和官方聚合覆盖限制见本页既有说明。

上游字段语义可核对 [OpenAI 的 Codex token accounting 文档](https://github.com/openai/symphony/blob/main/elixir/docs/token_accounting.md) 和 [Anthropic prompt caching 文档](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)。
