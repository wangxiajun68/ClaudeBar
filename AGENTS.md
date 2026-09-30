# ClaudeBar 开发规范

本文件适用于整个仓库。目标是让开发测试版和正式版可以共存，日常开发不得中断用户正在使用的 VPN 或修改正式版配置。

## 项目与目录

- 原生 macOS SwiftUI / AppKit 菜单栏应用，macOS 15+，应用目标为 arm64。
- 不使用 Xcode 工程或 Swift Package；以 `Makefile` → `Sources/build.sh` 为构建入口。
- `Sources/ClaudeBar/Models`：状态、偏好和业务模型；`Utils`：持久化、客户端和系统集成；`Views` / `Theme`：界面与样式。
- `Sources/Widget`：Widget 扩展；`WidgetSnapshot.swift` 必须保持指向主应用模型的符号链接。
- `Sources/Shared/BuildChannel.swift`：主应用与 Widget 共享的编译期版本身份和系统集成策略。
- `Sources/build-config.sh`：构建身份、优化参数、输出与安装路径；更改时必须同步共享 Swift 身份及隔离测试。
- `Tests`：无需启动应用的 Python / Swift 源码切片回归；`Tools`：检查及资源工具；`docs`：开发与产品文档。

## 安全的日常命令

```bash
make setup        # 创建 .venv 并安装固定版本的测试依赖
make doctor       # 只读环境检查
make build        # 开发版；仅构建，不安装、不启动
make run          # 构建并启动开发版
make test-fast    # 快速单元回归，不编译 App
make test TEST=core # 只验证当前改动涉及的单组
make test         # 所有已登记回归；不启动应用
make release      # 正式版；仅构建
make package      # 正式版 DMG、zip、SHA-256
```

完整命令、输出目录和人工验证流程见 `docs/DEVELOPMENT.md`。

## 必须保持的版本边界

1. 默认 `dev`，禁止把默认构建改为安装正式版。`make install` 仅是 `install-dev` 的别名。
2. 两个版本的 bundle ID、可执行文件名、App Group、URL scheme、产物目录和数据目录必须不同。正式版保留 `com.claudebar.app` 和现有用户数据路径，不能自动迁移或复制真实凭据到开发环境。
3. 应用拥有的文件通过 `FilePaths` 或 `BuildChannel.appName` 定位；禁止新增硬编码 `Application Support/ClaudeBar` 的写入路径。
4. `UserDefaults.standard` 随应用 bundle ID 隔离；不得改用正式版的固定 suite。Widget 的宿主、扩展、签名 entitlement、快照目标必须使用同一版本身份。
5. 开发测试版不启动 VPN 内核，不设置或清除系统代理、DNS、TUN，不写 SMC、不调用／替换系统特权辅助工具，不注册登录项，不修改外部客户端连接器、不调用真实 Codex app-server。限制必须在副作用入口执行，不能只靠 UI 开关或默认偏好。
6. 开发测试版不请求任何会弹窗的系统权限（定位、蓝牙、屏幕录制、其他 App 数据）。授权是写在用户 TCC 数据库里的**持久状态**，会活得比请求它的那个构建更久；而 dev 构建是可有可无的。所有请求入口以 `BuildChannel.promptsForSystemPermissions` 为第一道闸，且必须在真正触发系统 API 的那一个函数里，而不是各个调用点分散判断。
7. 禁止 `pkill ClaudeBar`、`pkill mihomo`、`killall widgetkitd` 等全局进程操作。安装脚本发现对应版本运行时必须拒绝替换；由用户正常退出完成 VPN 清理。
8. 正式版安装是 `make install-release` 的显式操作，会覆盖 `/Applications/ClaudeBar.app`。未经任务授权，不执行它，不运行正式版 VPN／充电／风扇控制测试。
9. 不创建允许环境变量绕过开发版系统集成限制的后门。网络和硬件集成的端到端验证用独立测试机器或显式正式版流程。

## 编码与变更

- 遵循相邻 Swift 代码风格，使用现有状态模型、Theme 和组件，不为一个改动引入平行架构。
- UI 状态在主 actor 更新；文件、网络、子进程等待避免阻塞主线程。保留后台任务取消、退出清理及所有权边界。
- 秘密不进入日志、测试夹具、截图或提交；配置写入复用 `PrivateFileWriter`，保留已有文件权限与签名校验。
- 禁止用静默编译失败掩盖缺失的安全组件。辅助工具签名必须先于包签名；签名后验证包及版本身份。
- 新增跨目标字段要同步快照编码／解码。修改源码切片锚点或依赖要同步测试夹具。
- mihomo 默认使用提交的压缩归档，禁止日常构建自动追踪 latest。更新内核是显式维护操作，提交 `.xz` 和 `.version` 并记录来源与变更。
- 不顺带格式化、迁移或清理无关代码；不要覆盖用户未提交的工作。

## 快速验证与轻量运行

- 只有 dev / release 两个应用，开发与测试共用 dev；禁止再引入独立 test 身份和数据目录。
- 开发版保留 `-O -g` 与 Swift 增量编译，依赖图／对象缓存不得随包重建删除。默认限制编译任务数，避免无限并行耗尽内存。
- 无变更时复用经签名与输入指纹验证的产物；源码、资源、编译参数、工具链、身份变化必须使缓存失效。失败的构建不能更新成功标记。
- 日常优先 `make test TEST=<组名>` 或 `make test-fast`，直接验证生产函数／状态机，不为测试启动 App；交付与发布仍运行全回归。
- 不新增常驻构建服务、测试框架或运行依赖；不要为性能目标未经测量改写业务 UI。开发版与正式版都保持优化编译。
- 开发图标使用带 DEV 标志的专用资源，正式图标保持原样。

## 验证与交付

- 构建／版本／启动／持久化／系统集成改动：运行 `make test`，编译 dev、release，检查包身份、Widget、entitlements 和签名。
- 回归测试不得修改真实用户配置、启动 VPN、写硬件或杀进程。使用临时目录与模拟进程传输；测试执行真实生产逻辑。
- 回归清单在 `Makefile`，CI 调用它；不要在 CI 复制另一份清单。
- 发布前执行测试门禁与 `make package`；版本以根目录 `VERSION` 为准，tag 必须匹配；更新 `docs/CHANGELOG.md`。
- 文档与实际命令保持一致。交付说明列出完成的变更、验证结果和未验证的系统集成；不能把编译通过说成运行 VPN 验证通过。
