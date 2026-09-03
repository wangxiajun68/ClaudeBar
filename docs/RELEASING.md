# 发布 ClaudeBar（macOS arm64）

> 相关：[构建与分发](design/09-build-and-distribution.md) · [构建与签名](technical/07-build-and-signing.md)

## 分发模型

| 角色 | 路径 |
|------|------|
| **终端用户** | [GitHub Releases](https://github.com/wangxiajun68/ClaudeBar/releases) 下载 **DMG**，拖入 Applications |
| **维护者 / CI** | `Sources/build.sh` 编译并产出 `.build/dist/` 下的 DMG、zip、校验和 |
| **贡献者** | `make build` 或 `bash Sources/build.sh` 本地开发安装 |

`Sources/build.sh` 是**开发者与 CI 脚本**，不是面向用户的安装器。用户不应需要 clone 仓库或运行 shell 脚本来安装应用。

## 发行物

打 tag 后 CI 自动上传：

| 文件 | 用途 |
|------|------|
| `ClaudeBar-<version>-macOS-arm64.dmg` | **主分发格式**（含 Applications 快捷方式） |
| `ClaudeBar-<version>-macOS-arm64.zip` | 脚本/自动化备用 |
| `*.sha256` | 校验和 |

均为 **ad-hoc 签名**，目标 macOS 15+ Apple Silicon。无 Developer ID、无公证、无 Intel 包。

## 版本号

单一来源：仓库根目录 [`VERSION`](../VERSION)，格式 `MAJOR.MINOR.PATCH`。

`Sources/build.sh` 写入主 app 与 Widget appex 的 `CFBundleShortVersionString` / `CFBundleVersion`。

Git tag 必须是 `v` + 该文件内容（如 `1.8.0` → `v1.8.0`）。Release workflow 会校验不一致则失败。

## 本地验证打包

```bash
make package
ls -lh .build/dist/ClaudeBar-$(tr -d '[:space:]' < VERSION)-macOS-arm64.*
open .build/dist/ClaudeBar-$(tr -d '[:space:]' < VERSION)-macOS-arm64.dmg
```

## 发版步骤

1. `main` 处于要发布的提交（CI 绿）。
2. 更新 `VERSION` 与 [CHANGELOG.md](CHANGELOG.md) 的 `## [x.y.z]` 段。
3. 提交，例如 `chore(release): 1.8.1`。
4. 打 tag 并推送：

```bash
VERSION=$(tr -d '[:space:]' < VERSION)
git tag -a "v${VERSION}" -m "ClaudeBar ${VERSION}"
git push origin main
git push origin "v${VERSION}"
```

5. [`.github/workflows/release.yml`](../.github/workflows/release.yml) 构建 DMG/zip、上传 artifact，并创建 GitHub Release。

不要用 `v1.8` 这类短 tag，也不要移动已发布的 tag。

## 手动触发

Release workflow 支持 `workflow_dispatch`：只构建并上传 artifact，**不会**创建 GitHub Release（那一步仅在 `v*` tag 上跑）。
