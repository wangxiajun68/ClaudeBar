# mihomo sidecar

ClaudeBar 的 VPN 页把 [mihomo](https://github.com/MetaCubeX/mihomo)（Clash Meta）作为 sidecar 打进 `ClaudeBar.app/Contents/Resources/mihomo-core`。

- 钉版本见 [`.version`](.version)（当前构建目标 **v1.19.30**）。
- 二进制 **不进 Git**（约 44 MB）。`Sources/build.sh` 会在编译前按 `.version` / GitHub latest 拉 `darwin-arm64`。
- 离线或已缓存：`MIHOMO_SKIP_DOWNLOAD=1`，前提是本目录已有可执行文件 `mihomo`。
