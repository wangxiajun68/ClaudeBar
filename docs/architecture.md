# ClaudeBar 技术架构文档

> 最后更新：2026-08-01
> 本文档描述 ClaudeBar 的实际实现细节，与 `Sources/` 代码一一对应，供维护与扩展参考。

---

## 1. 技术栈与构建

### 1.1 技术选型

| 项 | 选择 | 说明 |
|----|------|------|
| 语言 | Swift 5.9+ | 随 Xcode/Command Line Tools 提供 |
| UI | SwiftUI + AppKit 混合 | SwiftUI 渲染面板内容；AppKit 管理 `NSStatusItem`/`NSPanel`/`NSWindow` |
| Widget | WidgetKit | systemLarge 尺寸，`StaticConfiguration` |
| 数据 | Foundation Codable + JSONSerialization | 编码用 Codable，settings.json 读写用 JSONSerialization 以保留未知字段 |
| 数据库 | SQLite3（系统库） | 读 Cursor 的 `state.vscdb`，仅只读 |
| 依赖 | **零第三方依赖** | 仅链接 `libsqlite3` 与系统框架 |
| 构建 | `swiftc` + `bash` 脚本 | 无 Xcode 工程、无 SPM |
| 最低系统 | macOS 14.0 (Sonoma), arm64 | 仅 Apple Silicon |

### 1.2 构建脚本 `Sources/build.sh`

脚本完成「编译主 app → 编译 Widget appex → 生成 Info.plist → 生成 entitlements → 签名 → 安装到 /Applications → 注册 Widget」全流程。

**主 app 编译：**

```bash
swiftc -o "$MACOS_DIR/ClaudeBar" \
  -sdk macosx -target arm64-apple-macos14.0 \
  -framework SwiftUI -framework AppKit -framework WidgetKit \
  -lsqlite3 \
  -Xlinker -rpath -Xlinker /usr/lib/swift \
  -Xlinker -rpath -Xlinker "$SDK_PATH/System/Library/Frameworks" \
  $(find Sources/ClaudeBar -name '*.swift')
```

注意 `-lsqlite3` 用于链接 `CursorSessionMonitor` / `CursorUsageStats` 直接调用的 C SQLite API。

**Widget appex 编译：**

```bash
swiftc -o "$APPEX_CONTENTS/MacOS/ClaudeBarWidget" \
  -module-name ClaudeBarWidget -parse-as-library \
  -sdk macosx -target arm64-apple-macos14.0 \
  -framework SwiftUI -framework WidgetKit \
  -Xlinker -application_extension \
  -Xlinker -e -Xlinker _NSExtensionMain \
  $(find Sources/Widget -name '*.swift')
```

`-Xlinker -application_extension` 标记为扩展安全；`-Xlinker -e _NSExtensionMain` 指定扩展入口。Widget 源码 `import Foundation` 但**不**链接 sqlite3（它不直接访问 Cursor DB，只读快照）。

> **关键决策**：Widget 直接编译进 appex 的 `Contents/MacOS/`，而非先编译到主 app 的 MacOS/ 再 `cp`——后者会留下一个游离的 `ClaudeBarWidget` 二进制，导致 `codesign --deep` 签到多余产物。

### 1.3 Bundle 结构

```
ClaudeBar.app/
└── Contents/
    ├── Info.plist                 (LSUIElement=true, com.claudebar.app)
    ├── MacOS/
    │   └── ClaudeBar              (主二进制)
    ├── Resources/
    │   └── AppIcon.icns
    └── PlugIns/
        └── ClaudeBarWidget.appex/
            └── Contents/
                ├── Info.plist     (NSExtension: widgetkit-extension)
                └── MacOS/
                    └── ClaudeBarWidget
```

---

## 2. 应用启动与窗口管理

### 2.1 入口 `ClaudeBarApp.swift`

```swift
@main
struct ClaudeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}
```

使用 `@NSApplicationDelegateAdaptor` 而非 SwiftUI `MenuBarExtra`，因为面板需要自定义毛玻璃、居中定位、失焦收起等行为，`MenuBarExtra` 无法满足。

`AppDelegate.applicationDidFinishLaunching`：
1. `NSApp.setActivationPolicy(.accessory)` — 无 Dock 图标，但不影响接收鼠标事件、不抢终端焦点。
2. 构造 `ProviderStore`（单例状态中枢，构造时立即 `refresh()`）。
3. 构造 `MenuBarController(providerStore:)` 并 `setup()` 创建菜单栏图标。
4. `store.refresh()` 触发首次全量刷新。

`application(_:open:)` 处理 `claudebar://` URL scheme —— Widget 点击时由系统经由此入口唤起面板。

`applicationShouldTerminateAfterLastWindowClosed` 返回 `false` —— 关闭编辑窗口不应退出 app。

### 2.2 `MenuBarController` — 面板的承载与定位

核心职责：维护 `NSStatusItem`、创建并复用一个 `NSPanel`、处理显示/隐藏、点击外部收起。

**面板特性（`makePanel`）：**
- 类型 `KeyablePanel: NSPanel`，`canBecomeKey = true` / `canBecomeMain = false` —— 可成为 key window（SwiftUI Alert/控件需 key）但不激活应用。
- `styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView]` —— 非激活面板，隐藏标题栏按钮。
- `backgroundColor = .clear` + `NSVisualEffectView(material: .menu, blendingMode: .behindWindow)` —— 毛玻璃背景，材质与系统菜单栏下拉一致。
- `appearance = .vibrantDark`、`collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]` —— 全空间可见、全屏辅助。
- `hidesOnDeactivate = false`、`isFloatingPanel = true` —— 悬浮且不因失焦隐藏（自行用事件监听收起）。

**定位逻辑（`sizeAndPosition`）：**
- 宽度 `max(560, fittingSize.width)`，高度上限为屏幕可见区高度 -8。
- 水平：以状态项图标的**全局 x 中心**对齐面板中心（`globalIconX = windowOriginX + btnInWindow.midX`），再 clamp 到屏幕内。
- 垂直：`y = screen.visibleFrame.maxY - height - 4`，即紧贴菜单栏下方。
- 使用 `NSScreen.screens.first`（主屏）而非 `NSScreen.main`，因为后者可能是负 origin 的副屏。

**收起监听（`installMonitors`）：**
- `localMonitor`：本 app 内的鼠标按下若不在 panel.frame 内则 `hide()`。
- `globalMonitor`：其他 app 的鼠标按下一律 `hide()`（切回主线程执行）。

> 单例面板被复用（`panel ?? makePanel()`），`isReleasedWhenClosed = false`，避免反复创建。

---

## 3. 状态中枢 `ProviderStore`

`ProviderStore: ObservableObject` 是唯一真值源，持有全部 `@Published` 状态并在 `init` 时 `refresh()`。

### 3.1 Published 状态

| 字段 | 类型 | 含义 |
|------|------|------|
| `providers` | `[Provider]` | 全部 Provider 配置 |
| `activeProviderID` | `UUID?` | 当前激活 Provider |
| `currentEnv` | `EnvConfig?` | 当前 settings.json 的 env |
| `hasSettingsFile` | `Bool` | settings.json 是否存在 |
| `balanceText` / `balanceLoading` | `String?` / `Bool` | DeepSeek 余额 |
| `sessions` | `[SessionInfo]` | Claude Code 活跃会话 |
| `cursorSessions` | `[CursorSessionInfo]` | Cursor 活跃会话 |
| `usageStats` / `usageLoading` | `[ModelUsage]` / `Bool` | token 用量 |
| `usagePeriod` / `usageReferenceDate` | `UsagePeriod` / `Date` | 用量周期，变化即重算 |
| `collapsedProviderIDs` | `Set<UUID>` | 折叠的 Provider |
| `expandedSessionPIDs` | `Set<Int>` | 展开的会话（显示子 Agent） |
| `cursorExpanded` | `Set<String>` | 展开的 Cursor 会话 |

### 3.2 刷新管线 `refresh()`

```
refresh()
  ├── hasSettingsFile = ...
  ├── currentEnv = SettingsManager.readSettings().env
  ├── loadProviders()          ← 含旧格式迁移 + 当前 Provider 探测
  ├── refreshBalance()         ← async, DeepSeek API
  ├── refreshUsage()           ← Task.detached 扫描 jsonl
  ├── refreshSessions()        ← 同步扫 sessions/*.json
  ├── startSessionPolling()    ← 2.5s 定时器
  └── writeWidgetSnapshot()    ← 推送给 Widget
```

`usagePeriod` 与 `usageReferenceDate` 的 `didSet` 会触发 `refreshUsage()`，实现周期切换即时重算。

### 3.3 `loadProviders()` 的当前态探测

加载 providers.json 后，用 `currentEnv.ANTHROPIC_BASE_URL`（trim `/` 后）匹配出当前激活 Provider，再用 case-insensitive 匹配 `ANTHROPIC_MODEL` 定位其 `activeModelID`，并立即 `saveProviders()` 持久化探测结果。这使得用户在 Claude Code 外手改 settings.json 后，ClaudeBar 能识别当前态。

### 3.4 `activateModel` 写入流程

```
activateModel(providerID, modelID)
  ├── buildEnv(provider, model)     ← 构造完整 EnvConfig
  ├── SettingsManager.writeSettings(env)   ← 合并写回 settings.json
  ├── activeProviderID = providerID
  ├── currentEnv = env
  ├── providers[idx].activeModelID = modelID
  ├── saveProviders()
  └── refreshBalance()
```

`buildEnv` 把所选 `model.name` 同时写入 `ANTHROPIC_MODEL` 与 8 个 `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL[_NAME]`，确保 Claude Code 内部按 tier 路由时一致。

---

## 4. 数据访问层

### 4.1 `FilePaths` — 路径常量

集中管理所有文件系统路径，分三组：

- **Claude Code**：`~/.claude/settings.json`、`~/.claude/claude-bar-providers.json`（新）、`~/.claude/claude-bar-presets.json`（旧，迁移用）、`~/.claude/projects/`、`~/.claude/sessions/`。
- **Cursor**：`~/.cursor/projects/`、`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`。
- **App Group**：`com.claudebar.app.widget`，快照文件 `claude-bar-widget-data.json`。

`cursorProjectName(for:)` 复现 Cursor 的 cwd 编码：去前导 `/` 后把 `/` 换成 `-`（注意 Cursor **不**加前导 `-`，与 Claude Code 不同）。`cursorTranscriptURL(cwd:composerId:)` 拼出 `agent-transcripts/<composerId>/<composerId>.jsonl`。

### 4.2 `SettingsManager` — settings.json 读写

**读**：`JSONSerialization` 解析为 `[String: Any]`，取 `env` 字典构造 `EnvConfig`（缺字段默认 `""`）。返回 `(env, raw)` 以便调用方访问其他顶层字段。

**写**：关键在于**不破坏用户手改的配置**：
1. 先 `readSettings()` 取旧 env。
2. `preserve(newValue, existing)`：新值非空用新值，否则保留旧值，都空则空。这避免空字段覆盖用户已有 token。
3. 保留 settings.json 的其他顶层字段（`permissions`、`enabledPlugins` 等）——先读现有 JSON 再替换 `env` 键。
4. `JSONSerialization` 会把 URL 中的 `/` 转义成 `\/`，写回前字符串替换修复，保证 URL 可读。

### 4.3 `writeWidgetSnapshot()` — 四路冗余写入

因 Widget 沙盒环境的多样性，快照被写到四个位置，按 Widget 读取优先级：

1. **App Group 容器**：`containerURL(forSecurityApplicationGroupIdentifier:)` 下的 `claude-bar-widget-data.json`（首选，沙盒可读）。
2. **`~/.claude/`**：非沙盒回退。
3. **Widget 沙盒容器**：`~/Library/Containers/com.claudebar.app.widget/Data/claude-bar-widget-data.json`。
4. **UserDefaults (App Group)**：`shared.set(data, forKey: "widgetSnapshot")`。

写完后 `WidgetCenter.shared.reloadAllTimelines()` 通知所有 Widget 刷新。

### 4.4 `SessionMonitor` — Claude Code 会话

**数据源**：`~/.claude/sessions/<pid>.json`，每个文件含 `pid`、`sessionId`、`cwd`、`startedAt`、`status`、`updatedAt` 等字段。

**判活**：`kill(pid_t(pid), 0) == 0`（信号 0 探测进程存在），死进程沉底。

**上下文扫描 `fetchContext`**：读 transcript `projects/<encoded-cwd>/<sessionId>.jsonl` 的**尾部 96KB**（`FileHandle.seekToEnd` 后回退）：
- 只处理含 `"usage"` 且 `"type":"assistant"` 的行。
- `lastContext = input_tokens + cache_read_input_tokens + cache_creation_input_tokens`（最新一条）。
- 从最后一条 `tool_use` 提取活动描述（`describeActivity`：`Bash · build.sh`、`Read · File.swift`、`Agent · Explore` 等）。
- `toolPending`：若最后 `tool_use` 的行号 > 最后 `tool_result` 的行号 → 该工具调用尚未返回 → busy。

**transcript 路径编码**：`/Users/wangxiajun/Project/ClaudeBar` → `projects/-Users-wangxiajun-Project-ClaudeBar`（去前导 `/` 后换 `-`，并加前导 `-`，与 Cursor 编码不同）。

**子 Agent / Workflow `fetchSubagents`**：
- 直属子 Agent：`<sessionDir>/subagents/agent-<id>.meta.json` + 同名 `.jsonl`。
- Workflow：`<sessionDir>/subagents/workflows/<wf_id>/agent-<id>.meta.json`，各 agent 的 transcript 在 `<wf_id>/<fname>.jsonl`。
- 每个 agent 的 `scanAgentActivity` 读尾部 32KB 判定 running/done。

### 4.5 `CursorSessionMonitor` — Cursor 会话

**数据源**：Cursor 的 `state.vscdb`（SQLite，WAL 模式），表 `composerHeaders`（含 `composerId`、`recency`、`value` JSON、`isArchived`、`isSubagent`）。DB 约 6.5GB，但 `(recency, composerId)` 有索引。

**打开方式**：`sqlite3_open_v2` + `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX`，`busy_timeout 2000`。WAL 允许并发读，不阻塞 Cursor 的写入。

**查询**：取 `isArchived=0 AND isSubagent=0` 按 `recency DESC` 最多 80 条，过滤 3 天内活跃（`lastUpdatedAt > cutoff`），取前 14 个展示。

**head 字段解析**：`name`、`createdAt`、`lastUpdatedAt`、`contextUsagePercent`、`agentLocation.status == "active"`（判 busy）、`workspaceIdentifier.uri.fsPath`（或 `draftTarget.environment.uri.fsPath`）取 cwd。

**transcript 扫描**：与 Claude 类似但更简单——Cursor 的 JSONL 有 `{"type":"turn_ended"}` 标记，pending 判定为「最后一条 assistant 行号 > 最后 `turn_ended` 行号」。

**子 Agent**：`fetchSubagents` 查 `isSubagent=1`，按 `subagentInfo.parentComposerId`（或 `rootParentConversationId`）归组到可见的父会话下。

### 4.6 `UsageStats` — token 用量扫描

**数据源**：`~/.claude/projects/**/*.jsonl` 的 assistant 消息 `message.usage`。

**三级过滤**（性能关键，`~/.claude/projects` 可达数千文件、数百 MB）：
1. **文件 mtime 预筛**：`contentModificationDate < interval.start` 直接跳过整个文件（消息按时间追加，mtime = 最后写入）。
2. **UTC 日期字符串粗筛**：ISO 时间戳零填充，前 10 字符字典序 == 时间序。取 `[interval.start-1d, interval.end+1d]`（±1 天 slack 容时区），行首日期不在窗口则跳过，避免 JSON 解析。
3. **精确解析**：`ISO8601DateFormatter`（线程安全，`DateFormatter` 不是）解析后 `interval.contains`。

**并行**：`DispatchQueue.concurrentPerform(iterations: n)` 每文件独立解析为 `[String: ModelUsage]`，再合并。`ModelUsage` 累加 `calls`、`inputTokens`、`outputTokens`、`cacheReadTokens`、`cacheCreationTokens`，`totalTokens = 三者输入 + 输出`。

**格式化**：`formatTokens` → `38.7M` / `318K` / `942`。

### 4.7 `CursorUsageStats` — Cursor 历史 token

**数据源**：同一 `state.vscdb` 的 `cursorDiskKV` 表，键 `bubbleId:<composerId>:<bubbleId>`，值 JSON 的 `tokenCount.inputTokens/outputTokens`。

**限制**（经验证）：Cursor 自 ~2026-03 起停止写 token 计数，故近期月无数据；无 per-bubble model 字段。按设计决策，聚合为单条 `ModelUsage(model: "Cursor")`，作为全量值追加到所有周期。

### 4.8 `BalanceFetcher` — DeepSeek 余额

仅当 `baseURL.contains("deepseek")` 时工作，请求 `<base>/user/balance`，Bearer token 鉴权，解析 `balance_infos[0].total_balance` / `currency`。5 秒超时，失败返回 nil（不报错）。

---

## 5. 视图层

### 5.1 `MenuBarView` — 主面板

宽 560pt 的 `VStack`，按区段组织：

- **Header**：CB 图标 + 标题 + 折叠按钮（`@AppStorage("configCollapsed")` 持久化）+ 刷新按钮。
- **当前配置**（折叠态隐藏）：绿/橙状态点 + Provider 名 + 模型 + host + ¥余额。
- **Sessions / Cursor Sessions**：各用 `LazyVGrid` 双列网格渲染 `sessionCard` / `cursorSessionCard`；`sessionRow` 是展开的详细版（含子 Agent）。
- **底部 HStack**：左 `providersSection`，右 `usageSection`，`maxHeight: 150`。
- **ActionBar**：刷新 / 编辑供应商 / 打开 settings.json / 退出。

**视觉规范**：
- 配色：深色半透明，文字 `Color.white.opacity(0.x)`，状态色绿/黄/红/紫（Cursor）。
- 上下文健康：`ratio < 0.6` 绿、`< 0.85` 黄、否则红。
- busy/active 的状态点带 `repeatForever(autoreverses: true)` 脉冲动画。
- 反馈 toast（`switchFeedback`）2 秒淡出。

**双击行为**：
- Claude 会话：`resumeInTerminal` → 优先 Warp（`/Applications/Warp.app` 存在时），否则 Terminal。Warp 路径：`NSWorkspace.open` 打开 cwd + 后台 `osascript` 注入 `claude --resume <sessionId>` 并回车。Terminal 路径：`do script`。
- Cursor 会话：`openInCursor` → 用 Cursor.app 打开 cwd。

`EditorWindowDelegate` 监听编辑窗口关闭，清理 `MenuBarView.editorWindowRef` 静态引用。

### 5.2 `ProviderRow` — Provider 行

- `isSingleModel`：整行可点选，显示 radio + 模型名 + checkmark。
- 多模型：`expandableHeader`（chevron + Provider 名 + "active" 胶囊 + "N models"）+ 展开后 `modelRow` 列表，每行 radio + 模型名（monospaced）+ 上下文上限（如 `1M`）+ checkmark。
- `formatContext`：`200000 → 200K`、`1000000 → 1M`。
- 模型名匹配用 case-insensitive（settings.json 大小写可能不同）。

### 5.3 `ProviderEditorView` — 编辑窗口

左 220pt 固定宽 Provider 列表（`List(selection:)` + 增/删/复制），右侧 master-detail：
- **Provider Configuration** GroupBox：Name / API Key / Base URL。
- **Model Configuration** GroupBox：左 170pt 模型列表（`EditableModel` 本地副本，回车或点 + 添加，右键设默认 / 删除），右模型详情（Name / Context Tokens / Auto Compact Window / Disable Compact / Disable Experimental Betas）。
- 底部 Save 按钮（⌘S / ⌘⏎），保存后 "Saved ✓" 反馈 2 秒。保存激活 Provider 时触发 `activateModel` 应用变更。

### 5.4 Widget 视图 `WidgetViews.swift`

`WidgetEntryView` 渲染 systemLarge：
- Header：ClaudeBar + 大号 token 总数 + 余额。
- Provider + Model + 相对时间。
- 模型分布条（多个模型按 ratio 横向拼接）+ 图例。
- 活跃会话列表（最多 3 条 Claude + 3 条 Cursor），每行状态点 + 项目 + 活动 + 上下文条。
- 空态显示 "等待数据..."。
- 点击整个 Widget 触发 `claudebar://` 唤起主面板。

`WidgetProvider.getTimeline`：读快照（四路回退），30s 后刷新；读失败返回 `diagnosticEntry`（把诊断字符串塞进 `activeProviderName` 显示，如 `UD:2048B F:Y/2048B`）。

---

## 6. 数据迁移

### 6.1 旧 Preset → Provider 迁移

`MigrationHelper.migrateIfNeeded()`（在 `Provider.swift`）：
1. 检测 `claude-bar-presets.json`（旧）是否存在且非空。
2. 按 `baseURL`（trim `/`）分组旧 preset。
3. 每组：旧 preset 的 `ANTHROPIC_MODEL` 去重后转为 `ModelConfig`（继承 contextTokens / disableCompact / 等），Provider 名取 URL host 的主域段首字母大写。
4. 返回 `ProvidersFile`，由 `loadProviders` 保存为新格式并**删除旧文件**。

### 6.2 `Provider.init(from:)` 的旧格式兼容

即便新格式文件，`Provider` 的 `Decodable` 实现也兼容：
- `models`：先试 `[ModelConfig]`，失败再试旧 `[String]`（此时用 provider 级的 `contextTokens`/`disableCompact` 等动态键）。
- `activeModelID`：先试 `UUID`，失败用旧 `activeModel`（String 模型名）匹配。
- `id` / `authToken` / `baseURL`：`decodeIfPresent` 缺失则生成默认。

`EnvConfig.init(from:)` 全字段 `decodeIfPresent`，缺字段默认 `""`，保证向后兼容。

`Preset.init(from:)`：`id` 缺失时生成新 UUID，让无 id 的旧数据存活。

---

## 7. 构建与签名

### 7.1 签名流程

ad-hoc 签名（`codesign -s -`，无 Team ID），**自底向上、不用 `--deep`**：

```bash
xattr -cr "$APP_BUNDLE"                        # 1. 清扩展属性（关键！）

codesign ... --entitlements widget.plist "$APPEX/.../ClaudeBarWidget"  # 2. appex 二进制
codesign ... --entitlements widget.plist "$APPEX_DIR"                  # 3. appex bundle
codesign ... --entitlements app.plist   "$MACOS_DIR/ClaudeBar"         # 4. 主二进制
codesign ... --entitlements app.plist   "$APP_BUNDLE"                 # 5. 主 bundle wrapper
```

### 7.2 Entitlements

**Widget appex**（沙盒开）：
- `app-sandbox: true`
- `application-groups: ["com.claudebar.app.widget"]`
- `network.client: true`

**主 app**（沙盒关）：
- `app-sandbox: false`（需读 `~/.claude`、`~/.cursor`、调 osascript/Process）
- `application-groups: ["com.claudebar.app.widget"]`
- `network.client: true`
- `files.user-selected.read-write: true`

### 7.3 签名陷阱（踩坑记录）

1. **bundle wrapper 必须带 `--entitlements`**：签名 bundle 会重新密封主可执行文件，若 wrapper 不带 entitlements，codesign 会**剥离**刚嵌入主二进制的 entitlements，静默破坏 App Group 访问。
2. **`xattr -cr` 两次**：签名前一次；`cp` 安装到 /Applications 后再一次（`cp` 会重新引入 `com.apple.FinderInfo` 等扩展属性，导致 `codesign --deep --strict` 失败、Widget 加载失败）。
3. **Widget 直接编译进 appex**：不经过主 app MacOS/ 的中间产物，避免 codesign 签到多余二进制。
4. **不签 `--deep`**：App Group 容器等不需深签；自底向上显式签名更可控。

### 7.4 Widget 注册

```bash
lsregister -f "$INSTALLED_APP"                  # 重新索引 LaunchServices
pluginkit -e use -i com.claudebar.app.widget    # 强制启用扩展
killall widgetkitd                               # 重启 widget 守护进程
```

否则 Widget 画廊可能滞后一次启动。首次使用仍需在桌面右键手动添加 "ClaudeBar"（systemLarge）组件。

---

## 8. 性能与并发考量

| 点 | 策略 |
|----|------|
| 会话轮询 | 2.5s `Timer.scheduledTimer`，`refreshSessions` 同步快路径（只读 sessions/*.json 小文件） |
| Cursor DB 查询 | `Task.detached(priority: .utility)` 后台执行，DB 大但走索引 + LIMIT |
| transcript 扫描 | 只读尾部 96KB（会话）/ 32KB（子 agent），不全读 |
| 用量统计 | `Task.detached` + 三级过滤 + `concurrentPerform` 并行解析 |
| 主线程 | 所有 `@Published` 更新经 `MainActor.run` / 主线程回调 |
| 快照写入 | 每次刷新写四路，`WidgetCenter.reloadAllTimelines()` 触发刷新 |

---

## 9. 关键文件索引

| 文件 | 行数 | 职责 |
|------|------|------|
| `Models/ProviderStore.swift` | ~347 | 状态中枢，刷新管线，Widget 快照 |
| `Views/MenuBarView.swift` | ~1195 | 主面板全部 UI + 双击行为 |
| `Utils/SessionMonitor.swift` | ~401 | Claude 会话/transcript/子 agent |
| `Utils/CursorSessionMonitor.swift` | ~385 | Cursor SQLite 会话 |
| `Utils/UsageStats.swift` | ~236 | token 用量三级过滤扫描 |
| `Models/Provider.swift` | ~172 | 数据模型 + 旧格式迁移 |
| `Sources/build.sh` | ~244 | 构建/签名/安装/注册 |
| `Models/SettingsManager.swift` | ~85 | settings.json 合并读写 |

---

## 10. 扩展指南

### 新增一个 env 字段
1. `Preset.swift` 的 `EnvConfig` 加属性 + `CodingKeys` + 两个 `init`。
2. `SettingsManager.swift` 的 `readSettings` 加读取、`writeSettings` 加 `preserve` 行。
3. `ProviderStore.buildEnv` 赋值。
4. 若需 UI 编辑，`ProviderEditorView` 的 `EditableModel` + 详情表单加字段。

### 新增一个 Provider 级余额源
1. `BalanceFetcher` 加分支或新建 fetcher。
2. `ProviderStore.refreshBalance` 按 baseURL 分发。

### 新增 Widget 尺寸
1. `ClaudeBarWidget.swift` 的 `supportedFamilies` 加项（如 `.systemMedium`）。
2. `WidgetViews.swift` 按 `@Environment(\.widgetFamily)` 分支布局。

### 新增 Cursor 之外的第二 IDE 监控
1. 新建 `Utils/<Ide>SessionMonitor.swift` + 数据模型。
2. `ProviderStore` 加 `@Published var ideSessions` + `refreshIdeSessions()`。
3. `MenuBarView` 加区段，`writeWidgetSnapshot` 加字段。
4. `WidgetSnapshot` 加对应 summary 类型。
