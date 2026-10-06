# Security Policy

## 支持范围

| 范围 | 说明 |
|------|------|
| 代码分支 | 当前 `main` |
| 发行版本 | [最新 GitHub Release](https://github.com/wangxiajun68/ClaudeBar/releases/latest) |

本应用面向本机使用，发布构建为 ad-hoc 签名、不经 Apple 公证，**不对历史版本提供长期安全补丁**。请始终使用最新 Release。

## 报告漏洞

请通过以下方式**私下**报告安全问题：

1. GitHub 仓库 **Security → Advisories → Report a vulnerability**
2. 或联系仓库所有者

**请勿**在公开 Issue、PR 或讨论区粘贴：

- API key、access token、session cookie
- 完整 `~/.claude/settings.json`、`config.toml`、`auth.json`
- 会话 transcript 或代理抓包中的敏感正文

报告时请尽量包含：受影响版本、复现步骤、影响范围、建议修复思路。

## 数据边界

ClaudeBar 是纯本地应用：读取本机配置与会话文件，不向任何自建服务器上传数据；出站请求只发给用户自己配置或该功能选定的服务（供应商 API 与余额查询、订阅拉取、模型价格表、汇率、天气、Cursor / Codex 官方用量接口、VPN 订阅、出口 IP 探测与 `geosite.dat`）。其中汇率、天气、供应商余额与 Cursor / Codex 官方用量读数在相应功能启用后于启动时按需自动刷新，VPN 订阅在内核就绪后启动 30 分钟定时刷新、就绪时还会查询一次出口 IP，模型价格表仅在距上次检查超过一周时才会在启动后复查，其余请求由对应用户操作触发。

| 数据 | 访问方式 | 说明 |
|------|----------|------|
| Claude Code 配置与会话 | 只读（切换时写 `settings.json`；迁移时写入新会话） | `~/.claude/` |
| Cursor 状态库 | 只读（迁移到 Cursor 桌面时写 `state.vscdb` 与 `workspaceStorage` 图片目录；迁移到 Cursor CLI 时新建 `chats/…/store.db`） | `state.vscdb`、`projects`、`chats` |
| Codex rollout | 只读（切换时写 `config.toml` / `auth.json`；迁移时写入新 rollout） | `~/.codex/` |
| 供应商列表 | 读写 | `~/.claude/claude-bar-*.json` |
| 用量索引 / 日志 | 读写 | `~/Library/Application Support/ClaudeBar/` |
| 本地 LLM 代理 | 仅 `127.0.0.1`，令牌鉴权 | 由路由偏好、抓包开关、Chat 协议或迁移桥需要时自动运行；勿暴露到公网 |
| 会话迁移记录 | 读写 | `~/Library/Application Support/ClaudeBar/SessionMigrations/` |

构建产物（DMG / zip）**不包含**任何用户密钥。请勿将个人 `~/.claude`、`~/.codex` 目录提交进 Git 仓库。

### 本地代理的鉴权

本地代理会**注入当前供应商的 API key**，因此它对本机任何进程都是一个凭据入口。它有三层约束：

1. `NWListener` 用 `requiredLocalEndpoint` 绑定 `127.0.0.1`（`requiredInterfaceType` 只是接口偏好，不是绑定地址）；
2. 每个连接必须带本机令牌 —— `~/Library/Application Support/ClaudeBar/proxy-token`（0600，`O_EXCL | O_NOFOLLOW` 创建），`Authorization: Bearer <token>` 或 `x-api-key: <token>`；
3. 客户端自带的 `Authorization` / `x-api-key` / `Cookie` 等**不会**透传给上游 —— 代理始终注入自己的上游凭据，不采用客户端的。

令牌是**同用户**级别的秘密：同用户的进程能直接读文件。它挡的是「顺手用一下」这一类（装依赖时跑的 postinstall 脚本、编辑器插件、别的 App 到 `127.0.0.1` 上乱试），不是同用户下的恶意代码 —— 后者本来就能读你所有的配置文件。

ClaudeBar 写入的密钥文件为 `0600`：`proxy-token` 用 `open(..., O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)` 创建；`~/.claude/settings.json`、两份供应商列表与 `~/.codex/config.toml` 经 `PrivateFileWriter` 写入（0600 暂存文件 + `rename`，落盘权限不取决于目标文件原权限）。`FileManager.copyItem` 产生的备份副本同样收窄：`config.toml.bak` 经 `PrivateFileWriter.harden`，`settings.json.bak` 在 `SettingsManager.backUpOnce` 里重设 0600。`~/.codex/auth.json` 由 Codex 创建，应用只在原文件上改写、沿用其原权限。抓包库中的请求头会脱敏，`authorization` / `x-api-key` / `proxy-authorization` / `cookie` / `set-cookie` 统一替换为 `…`。

### 特权辅助工具

只有两件事需要 root，各走一个专用 setuid helper：

- **风扇写入**：`claudebar-fanctl`（`/usr/local/bin/claudebar-fanctl`，mode 4755）。SMC 读取由 `SMCController` 在进程内只读完成、不需要特权；每一次风扇写入（`FanHelperInstaller.setFanSpeed` / `setAutomatic` / `resetAll`）都交给这个 helper。
- **电池充电控制**：`claudebar-batteryctl`（`/Library/PrivilegedHelperTools/com.claudebar.batteryctl`，mode 4755）。

两者都只在用户显式操作时安装一次（管理员授权）：先把内置副本拷进 root 拥有的暂存目录，先校验 SHA-256、再 `codesign --verify --strict` 暂存副本，通过后才 `chown root:wheel` + `chmod 4755` 移入目标路径，校验失败即拒绝安装 —— 应用包可被当前用户写入，不校验就等于把「用户可写文件 → root 执行」当成特性。helper 自身启动即校验 `geteuid() == 0`，风扇编号只接受 SMC 上报 `FNum` 范围内的值，越界即拒绝。

**TUN 下的 DNS 不需要 root**：`VpnTunDnsHelper.setSystemDNSNow()`（定义在 `Sources/ClaudeBar/Utils/VpnSystemProxyController.swift`）以当前用户调 `/usr/sbin/networksetup -setdnsservers <service> 223.5.5.5 119.29.29.29`，改之前先把各服务的原值快照进 `.original_dns`，停止时按快照恢复（原本走 DHCP 的服务以 `Empty` 交回系统）；全程不经过任何特权 helper。

**开发测试版不做系统集成**：VPN 内核不启动（`VpnManager.startCore()`）、系统代理与 DNS 不写、两个 helper 不安装。这些入口都在真正触发系统调用的函数里以 `BuildChannel.allowsSystemIntegration` 为第一道闸（dev 为 `false`，release 为 `true`；见 `Sources/Shared/BuildChannel.swift`、`VpnManager.startCore()`、`VpnSystemProxyController` 的写入 / 清除 / 守卫函数、`VpnTunDnsHelper.setSystemDNSNow()`、`FanHelperInstaller`、`BatteryHelperInstaller`），不是靠 UI 开关或默认偏好。

## 依赖与供应链

- **零第三方运行时依赖**，仅链接 Apple 系统框架与 `libsqlite3`。
- CI 使用 GitHub Actions 官方 `macos-26` runner；依赖项见 [dependabot.yml](.github/dependabot.yml)。

## 披露时间线

我们会在确认漏洞后尽快修复，并在修复版本发布后通过 GitHub Security Advisory 公开说明（致谢报告者，除非您要求匿名）。
