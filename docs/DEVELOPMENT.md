# 开发测试与正式版本

项目只有两个应用：**ClaudeBar Dev（开发和测试共用）**与 **ClaudeBar（正式版）**。构建继续使用系统 Swift / C 编译器，没有新增包管理器或常驻构建服务。开发规范见 [AGENTS.md](../AGENTS.md)。

## 准备与日常命令

需要 macOS 15+、Apple Silicon、Xcode 或 Command Line Tools、Python 3.9–3.13；CI 使用 Python 3.12。

```bash
make setup                 # 测试依赖仅安装在项目 .venv
make doctor                # 只读环境检查
make build                 # 开发测试版；增量编译，不安装、不启动
make run                   # 构建并启动开发测试版
make test-fast             # 隔离、端点、配置持久化的快速单元回归
make test TEST=core        # 只验证当前修改涉及的一组
make test TEST="core local-endpoint"  # 指定多组，也支持逗号分隔
make test                  # 全部回归；CI/发布门禁
```

测试直接编译生产 Swift 函数或控制器，在临时目录使用夹具与模拟传输运行，不需要构建或启动 App，也不访问真实网络／硬件。回归清单只在 `Makefile`，不新增测试框架。`test-fast` 是日常烟测，不替代提交前的完整回归。

## 两个版本的隔离

| 项目 | 开发测试版 dev | 正式版 release |
|---|---|---|
| 应用名称 / 图标 | ClaudeBar Dev / 带 DEV 标志 | ClaudeBar / 原图标 |
| bundle ID | `com.claudebar.app.dev` | `com.claudebar.app` |
| 可执行文件 | `ClaudeBarDev` | `ClaudeBar` |
| 产物 | `.build/dev/ClaudeBar Dev.app` | `.build/release/ClaudeBar.app` |
| 显式安装目录 | `~/Applications` | `/Applications` |
| Application Support 子目录 | `ClaudeBar Dev` | `ClaudeBar` |
| LLM 本地代理默认端口 | 15722 | 15721 |
| URL scheme | `claudebar-dev` | `claudebar` |
| 系统网络 / 硬件写入 | 禁止 | 保留正式功能 |

Widget ID / App Group 为各自 bundle ID 加 `.widget`。偏好由各自 `UserDefaults.standard` 隔离；日志、SQLite、token、Widget 快照均使用各自路径。开发版的 Claude / Codex 配置与供应商文件位于自身 Application Support 目录内的 `.claude` / `.codex`，不会导入或覆盖真实用户配置。

正式版可以始终运行。开发版的启动、退出、VPN 开关及异常清理都不启动／回收 VPN 内核，不修改或清除系统代理、DNS、TUN，不安装／调用正式版特权辅助工具，不写 SMC，不注册登录项，不修改外部连接器，不调用真实 Codex app-server。开发版也不请求任何会弹窗的系统权限（定位、蓝牙、屏幕录制、其他 App 数据）：TCC 授权是持久的，而且 ad-hoc 签名或身份变化会让重编后的应用在系统眼里变成新 App，于是反复弹窗——这也是本地重建一直被反复要求授权的原因。界面测试与状态机逻辑通过单元夹具验证；需要真实 VPN／硬件端到端验证时使用独立机器或明确允许接管的正式版流程。

开发版 Claude / Codex 会话列表使用隔离目录的脱敏夹具；Cursor 只读数据查询保留。LLM 本地代理可使用隔离供应商和独立端口验证，不要手动改成正式版占用的端口。

## 编译和运行速度

开发版使用 `-O -g -incremental -enable-batch-mode`：保留符号，同时避免无优化版长期运行的开销。Swift 的依赖图和对象文件保存在 `.build/dev/objects/`；修改源码后由编译器决定重编译受影响文件。默认最多 4 个编译任务，内存较少时可用 `CLAUDEBAR_BUILD_JOBS=2 make build`。

输入未变化时，构建校验源码／资源／工具链／编译参数／签名身份的指纹及现有包签名，直接复用产物，跳过编译、资源复制和签名。缓存只在验证成功后写入；包被破坏或验证失败会重新构建。无变更的 `make run` 因此只需要快速检查和启动。正式版仍使用 `-O -whole-module-optimization`，不影响发布性能。

本机验证：无变更构建约 0.4 秒；修改一个函数后只重编译 204 个对象中的 1 个，整包约 6.7 秒；单组端点测试约 0.9 秒，快速回归约 6 秒。耗时随机器、改动依赖和工具链而变化。

首次编译需要生成完整对象缓存，耗时不能代表后续增量编译。开发版带优化，调试时部分局部变量可能被优化掉；性能数据与正式版也不应视为完全一致。要排查编译缓存可执行 `CLAUDEBAR_FORCE_REBUILD=1 make build`（强制重建包；Swift 仍可复用有效对象）。只有确认没有对应构建进程后才能删除 `.build/dev/objects` 来做冷编译。

mihomo 默认使用提交的压缩归档，不在构建时联网查询 latest。`MIHOMO_UPDATE=1` 是维护者显式更新入口；不要与其他构建并行更新，提交归档与版本文件并检查来源。开发版不运行其内核。

## 安装与正式版

```bash
make install-dev        # ~/Applications/ClaudeBar Dev.app；make install 的别名
make release            # 仅构建正式版
make package            # 正式版 DMG / zip / SHA-256 → .build/dist/
```

默认构建均不安装、不杀进程。显式安装发现对应版本运行时会拒绝替换；正常退出该版本后再安装。开发版安装不重启共享 Widget 守护进程，不会结束正式版或其 VPN。

本机开发默认使用 `ClaudeBar Dev` 自签证书以稳定权限，缺失时会创建并信任它；**两个版本都用它**，包括正式版——ad-hoc 签名没有证书可依据，指定要求退化成整份二进制的 cdhash，每次重编译都会被 TCC 当成新 App，屏幕录制反复要求授权。只验证编译、避免操作钥匙串时使用 `CODESIGN_IDENTITY=- make build`；CI 默认 ad-hoc。尚未配置 Developer ID 凭据和 Apple 公证，发布前需要先配置（见 [构建与签名](technical/07-build-and-signing.md)）。

只有要替换本机正式版时，正常退出正式版，显式执行 `make install-release`。此操作会覆盖 `/Applications/ClaudeBar.app`，不属于日常开发流程。`make package` 不安装、不发布到 GitHub；tag 流程见 [RELEASING.md](RELEASING.md)。

脚本默认 `CLAUDEBAR_CHANNEL=dev`，只接受 `dev` / `release`；不再提供独立 test 应用或 `build-test` / `run-test` 命令。`CLAUDEBAR_SKIP_INSTALL=0` 显式安装；打包要求 release 且 skip-install=1。两个版本使用独立构建锁；遗留锁需先确认构建已结束再删除。

CI 只编译两个版本，在 dev job 运行全部回归；发布前运行相同门禁。每次构建或复用时都会检查主应用／Widget 的身份、版本、URL scheme、App Group、DEV 图标与签名，不启动应用。
