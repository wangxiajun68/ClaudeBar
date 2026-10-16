# ClaudeBar 1.17.0 发布验证

日期：2026-10-16，macOS / Apple Silicon 本地验证。网络下载、Git 和 GitHub 命令使用 `http://127.0.0.1:17890`；现有系统代理也已只读核对为该端口，没有修改系统网络设置。

## 应用

- `make test`：105 组全部通过，768.97 秒。测试使用固定数据、临时目录和模拟传输。
- `CODESIGN_IDENTITY=- make build`：开发版编译通过；包身份、Widget、URL scheme、entitlements 与签名检查通过。
- `CODESIGN_IDENTITY=- make package`：正式版编译与相同检查通过；生成 DMG、zip 和各自 SHA-256。构建与打包均跳过安装，没有启动桌面应用或替换正在运行的正式版。
- VERSION 为 `1.17.0`，CHANGELOG 版本提取通过；源码及系统集成逻辑本轮没有修改。

本地安装包：

| 文件 | SHA-256 |
| --- | --- |
| ClaudeBar-1.17.0-macOS-arm64.dmg | b4173d95229af6c36a0136614c0832d1c8bcf00c2bb31fc8ce5895ee3a28b43e |
| ClaudeBar-1.17.0-macOS-arm64.zip | 062806a33dd6ec222cf308bee5aa342c2c010da85c76e09e2b7763cb53e3ed0f |

GitHub workflow 会独立构建发行物，因此其时间戳与文件哈希可能不同；下载时使用同一 release 附带的校验和。

未进行真实 VPN、TUN、DNS、硬件、helper 安装或用户数据迁移测试；编译与回归通过不能代替这些验证。签名为 ad-hoc，没有 Developer ID 公证。

## 文档与演示

双语 README 已按安装、界面、功能、API、CLI、数据和开发重排，增加 Popup、双显示器灵动岛和网关示例。相关本地文档链接与 Git 空白检查通过。

素材来自生产视图和固定样本。主窗口预览修复依赖漂移，改用原生宿主等待异步分析完成；用量参考日期固定到样本月份。VPN 使用已有独立原生预览。没有访问真实账号或读取私人会话。

影片目标为 52 秒 / 1560 帧 / 1920×1080 / 30fps，静音；完成分镜检查和 11 个时刻的 3D 位移 / 回跳检查。编码、播放和附件验收结果见[影片验收](../promo/DESIGN.md)。

## 仓库

日常工作在 dev；发布时 main 快进到同一提交，tag 为 v1.17.0。CI 覆盖 dev 和 main。此前尚未提交的架构 / 品牌研究纳入本次提交，不表示原生应用已迁移为 Rust。

Orveil 的既有更新已单独通过 `make check` 与 `make build`，提交到本地 dev：`61566e2`。Orveil 未配置远端，本次未推送或发布。
