# 发布 Axon（macOS arm64）

> 相关：[构建与分发](design/09-build-and-distribution.md) · [构建与签名](technical/07-build-and-signing.md)

发行物是 **ad-hoc 签名** 的 `ClaudeBar.app` zip，目标 macOS 26 Apple Silicon。没有 Developer ID、没有公证、没有 Intel 包。

## 版本号

单一来源：仓库根目录 [`VERSION`](../VERSION)，格式 `MAJOR.MINOR.PATCH`。

`Sources/build.sh` 把它写入：

- `ClaudeBar.app/Contents/Info.plist` → `CFBundleShortVersionString` / `CFBundleVersion`
- Widget appex 的对应字段

Git tag 必须是 `v` + 该文件内容，例如文件 `1.8.0` → tag `v1.8.0`。Release workflow 会校验不一致则失败。

## 本地打包（不安装）

```bash
AXON_SKIP_INSTALL=1 AXON_PACKAGE=1 bash Sources/build.sh
ls -l .build/dist/Axon-$(tr -d '[:space:]' < VERSION)-macos-arm64.zip*
```

`ditto -c -k --keepParent` 生成 zip，旁路 `.sha256`。zip 内仍是 `ClaudeBar.app`（bundle id `com.claudebar.app`），不要改名为 `Axon.app`。

## 打 tag（GitHub Release）

1. `main` 处于要发布的提交（CI 绿）。
2. 更新 `VERSION` 与 [CHANGELOG.md](CHANGELOG.md) 的 `## [x.y.z]` 段。
3. 提交，例如 `chore(release): 1.8.1`。
4. 打 tag 并推送：

```bash
VERSION=$(tr -d '[:space:]' < VERSION)
git tag -a "v${VERSION}" -m "Axon ${VERSION}"
git push origin main
git push origin "v${VERSION}"
```

5. [`.github/workflows/release.yml`](../.github/workflows/release.yml) 在 `macos-26` 上构建、上传 zip 与 checksum，并创建 GitHub Release。

不要用 `v1.8` 这类短 tag，也不要移动已发布的 tag。

## 安装说明（写给使用者）

解压 → `ClaudeBar.app` 放到 `/Applications`。Gatekeeper：

```bash
xattr -cr /Applications/ClaudeBar.app
```

## 手动触发

Release workflow 支持 `workflow_dispatch`：只构建并上传 artifact，**不会**创建 GitHub Release（那一步只在 `v*` tag 上跑）。
