# Contributing to Axon (ClaudeBar)

感谢关注本项目。这是一个零第三方依赖、swiftc 直编的 macOS 应用，贡献前请先读文档。

## 开始之前

1. 阅读 [docs/README.md](docs/README.md) —— 设计层讲「为什么」，技术层讲「怎么做」。
2. 改代码前先看 [docs/technical/10-extension-guide.md](docs/technical/10-extension-guide.md) —— 常见扩展场景（加 env 字段、加数据源、加 Widget 尺寸）已有既定步骤。
3. 构建：`bash Sources/build.sh`，然后 `killall ClaudeBar; open /Applications/ClaudeBar.app` 验证。

## 开发约定

- **零第三方依赖** —— 不要引入 SPM/CocoaPods 包。需要能力时优先用系统框架实现。
- **设计令牌唯一来源** —— 颜色/字体/间距/动画一律走 `Theme/Theme.swift`；视图文件里不手写裸数值（`Font.system(size:)` 等）。
- **状态只从 `ProviderStore` 流出** —— 视图不自行开 Timer、不做文件 I/O；数据采集放 `Utils/*Monitor.swift` / `Utils/*Stats.swift`，off-main 扫描 + off-main 发布。
- **发布克制** —— `@Published` 赋值前先做 Equatable 比较，不变不发布（见 `ProviderStore.refreshSessions` 的注释）。
- **注释专业、讲「为什么」** —— 不写变更史式注释；旧兼容代码直接删。
- **用户可见文案中文**，代码标识符英文。
- SourceKit 的 "Cannot find X in scope" 多为误报 —— 以 `bash Sources/build.sh` 的结果为准。

## 提交规范

- 提交信息用 conventional commits：`feat(ui): …` / `fix(sessions): …` / `perf(store): …` / `docs: …`。
- 一个提交一个完整可构建的状态；`bash Sources/build.sh` 通过再提交。
- 新数据源（新增一个 Agent 工具监控）请按 `ExternalSessionMonitor.swift` 的模式：mtime 判活 + 有界头读 + off-main 扫描，并在 `docs/` 补对应文档。

## 报告问题

请附上：macOS 版本、触发步骤、`~/.claude/claude-bar-widget-data.json`（如涉及 Widget）、以及 Console 中 Axon 相关日志。**不要贴 API key。**
