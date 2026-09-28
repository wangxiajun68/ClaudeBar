# mihomo sidecar

ClaudeBar 的 VPN 页把 [mihomo](https://github.com/MetaCubeX/mihomo)（Clash Meta）打进来：随包内置的是 `ClaudeBar.app/Contents/Resources/mihomo-core.xz`，首次启动由 `VpnManager.extractBundledCoreIfNeeded` 用 `Utils/XZArchive.swift` 解到 `~/Library/Application Support/ClaudeBar/vpn/mihomo`。

- 钉版本见 [`.version`](.version)（当前构建目标 **v1.19.31**）。
- 54 MB 的原始二进制**不进 Git**。`Sources/build.sh` 会在编译前按 `.version` / GitHub latest 拉 `darwin-arm64`。
- **打包后的 `.xz`（13 MB）进 Git**：`Sources/ClaudeBar/Resources/mihomo-core.xz` 与同目录的 `.version`。发布构建直接复用它（`package` 里省掉 117 s 的 LZMA，只剩一次 `cp`）；版本对不上时构建自动重打，打出来的一定是当前 vendored 的内核，并提示提交。
- 离线或已缓存：`MIHOMO_SKIP_DOWNLOAD=1`，前提是本目录已有可执行文件 `mihomo`。既没有归档、机器上又没有 `xz` 时，构建退化为内置原始二进制（功能不受影响，只是包大 41 MB）。
