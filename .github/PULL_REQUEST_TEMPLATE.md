## Summary

<!-- 用 1–3 句话说明本 PR 做了什么、为什么 -->

## Type

- [ ] feat — 新功能
- [ ] fix — 缺陷修复
- [ ] docs — 文档
- [ ] chore / ci — 构建、CI、仓库元数据
- [ ] refactor / perf — 重构或性能

## Checklist

- [ ] `make ci` 或 `CLAUDEBAR_SKIP_INSTALL=1 bash Sources/build.sh` 通过
- [ ] 用户可见文案为中文；代码标识符为英文
- [ ] 未引入第三方依赖（SPM / CocoaPods 等）
- [ ] 行为变更已写入 `docs/CHANGELOG.md` 的 `[Unreleased]`（发版规则见 `docs/VERSIONING.md`）
- [ ] 文档已更新（如适用）

## Test plan

<!-- 你如何验证？例如：打开主窗口 → 供应商页 → … -->

- [ ] 本地 `open /Applications/ClaudeBar.app` 验证相关页面

## Screenshots

<!-- UI 变更请附图，可删本节 -->
