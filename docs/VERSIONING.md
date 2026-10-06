# 版本管理

> 相关：[更新日志](CHANGELOG.md) · [发版流程](RELEASING.md) · [构建与分发](design/09-build-and-distribution.md)

ClaudeBar 使用语义化版本，版本号只有一个写入点。发版时 tag、安装包文件名、应用「设置」里的版本必须一致。

## 版本号

格式：`MAJOR.MINOR.PATCH`（例：`1.15.0`）

| 位 | 何时增加 | 例 |
|----|----------|----|
| MAJOR | 不兼容的行为或数据格式变化：用户必须改配置才能继续用 | 供应商文件无法被旧版读取 |
| MINOR | 向下兼容的新功能 | 流量检查器、飞书文档工作区 |
| PATCH | 向下兼容的缺陷修复、性能、文案、文档 | VPN 页卡顿、崩溃修复 |

预发布号（`-beta.1`）与构建元数据暂不使用；Release workflow 也不把 Release 标为 prerelease。

不要跳号，不要复用已打过 tag 的号码。

## 单一来源

仓库根目录 [`VERSION`](../VERSION) 是唯一手写版本号。

构建与发版从该文件读取，写入：

| 位置 | 用途 |
|------|------|
| 主 app `Info.plist` | `CFBundleShortVersionString` 与 `CFBundleVersion` |
| Widget appex `Info.plist` | 同上 |
| `.build/dist/ClaudeBar-<ver>-macOS-arm64.dmg` | 发行物文件名 |
| Git tag `v<ver>` | 触发 [release.yml](../.github/workflows/release.yml) |
| 设置页「版本」 | 读 bundle 短版本，与 `VERSION` 一致 |

`Sources/build.sh` 校验文件存在且匹配 `^[0-9]+\.[0-9]+\.[0-9]+$`，否则拒绝构建。

构建结束后 `Tools/check-bundle.py` 会再比对主 app 与 Widget appex 的 `CFBundleShortVersionString` / `CFBundleVersion` 是否等于 `VERSION`：不相等时构建失败，已签名的产物也不会被构建缓存复用。

两份 Info.plist 都由 `Sources/build.sh` 从 `VERSION` 生成，不要在 Swift 源码、plist 文件或 README 徽章里再写一份版本号。README 的 Release 徽章指向 GitHub 最新 tag。

## Git 与 tag

| 约定 | 说明 |
|------|------|
| 默认分支 | `main` |
| 发版 tag | annotated：`v` + `VERSION` 全文，如 `v1.15.0` |
| 校验 | tag `v1.15.0` 必须等于文件 `1.15.0`，否则 Release workflow 失败 |
| 移动 tag | 禁止。已发布的号码不可改 |

```bash
# 正确
VERSION=$(tr -d '[:space:]' < VERSION)   # 1.15.1
git tag -a "v${VERSION}" -m "ClaudeBar ${VERSION}"

# 错误
git tag v1.15         # 短 tag
git tag 1.15.1        # 缺 v 前缀
```

## 更新日志

用户可见的行为变更写入 [`docs/CHANGELOG.md`](CHANGELOG.md)，格式接近 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

### 结构

```markdown
## [Unreleased]
### 新增
### 变更
### 修复
### 性能
### 移除

## [1.15.0] — 2026-10-03
…
```

- `[Unreleased]` 永远在最上面。开发过程中往这里追加，发版时把整段改名为 `## [x.y.z] — YYYY-MM-DD`，再留一个空的 `[Unreleased]`。
- 分类按实际出现选用：常用新增 / 变更 / 修复，另有性能、移除、内部、体积、测试等按需使用，空分类删掉。
- 面向使用者写「能做什么 / 修了什么」，不要记内部重命名或文件搬迁，除非影响兼容。
- 提交信息用 Conventional Commits；不能用 commit log 代替 CHANGELOG。

### 什么必须记

- 新页面、新设置项、新代理 / 抓包能力
- 供应商 / 配置文件格式变化
- 用户能感知的缺陷与性能
- 删除的功能或数据源

### 什么不必记

- 纯重构、注释、CI 微调
- 未合并的本地试验

## 开发中如何改版本

日常开发不要先改 `VERSION`。功能进 `[Unreleased]`，号码仍停在上一个已发版。

准备发版时：

1. 根据上表决定升 MINOR 还是 PATCH（极少升 MAJOR）。
2. 把 `VERSION` 改成新号码。
3. 把 `[Unreleased]` 改成 `## [新号码] — 当天日期`，补一句摘要。
4. 按 [RELEASING.md](RELEASING.md) 提交、打 tag、推送。

检查清单：

```
[ ] VERSION 已改，且只有三位数
[ ] CHANGELOG 顶部是新版本段，下面仍有历史版本
[ ] CHANGELOG 里没有半截 Unreleased 混在已发版段里
[ ] git tag -a "v$(cat VERSION)"
[ ] tag 与 VERSION 字符串完全一致
```

## 版本从哪里读

```bash
# 仓库
cat VERSION

# 已安装应用
defaults read /Applications/ClaudeBar.app/Contents/Info CFBundleShortVersionString

# 应用内
设置 → 左侧栏底部的版本号
```

三处不一致时：先看是否用了旧的 `/Applications` 安装，再看 tag 是否对应当前 `VERSION`。
