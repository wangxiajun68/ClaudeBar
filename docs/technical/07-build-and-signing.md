# 构建与签名

> ClaudeBar 技术文档 · §7
> 相关：设计文档 [构建与分发](../design/09-build-and-distribution.md) · 技术文档 [技术栈与构建](01-tech-stack.md)

## 签名流程

ad-hoc 签名（`codesign -s -`，无 Team ID），**自底向上、不用 `--deep`**：

```bash
xattr -cr "$APP_BUNDLE"                        # 1. 清扩展属性（关键！）

codesign ... --entitlements widget.plist "$APPEX/.../ClaudeBarWidget"  # 2. appex 二进制
codesign ... --entitlements widget.plist "$APPEX_DIR"                  # 3. appex bundle
codesign ... --entitlements app.plist   "$MACOS_DIR/ClaudeBar"         # 4. 主二进制
codesign ... --entitlements app.plist   "$APP_BUNDLE"                 # 5. 主 bundle wrapper
```

## Entitlements

**Widget appex**（沙盒开）：
- `app-sandbox: true`
- `application-groups: ["com.claudebar.app.widget"]`
- `network.client: true`

**主 app**（沙盒关）：
- `app-sandbox: false`（需读 `~/.claude`、`~/.cursor`、调 osascript/Process）
- `application-groups: ["com.claudebar.app.widget"]`
- `network.client: true`
- `files.user-selected.read-write: true`

## 签名陷阱（踩坑记录）

1. **bundle wrapper 必须带 `--entitlements`**：签名 bundle 会重新密封主可执行文件，若 wrapper 不带 entitlements，codesign 会**剥离**刚嵌入主二进制的 entitlements，静默破坏 App Group 访问。
2. **`xattr -cr` 两次**：签名前一次；`cp` 安装到 /Applications 后再一次（`cp` 会重新引入 `com.apple.FinderInfo` 等扩展属性，导致 `codesign --deep --strict` 失败、Widget 加载失败）。
3. **Widget 直接编译进 appex**：不经过主 app MacOS/ 的中间产物，避免 codesign 签到多余二进制。
4. **不签 `--deep`**：App Group 容器等不需深签；自底向上显式签名更可控。

## Widget 注册

```bash
lsregister -f "$INSTALLED_APP"                  # 重新索引 LaunchServices
pluginkit -e use -i com.claudebar.app.widget    # 强制启用扩展
killall widgetkitd                               # 重启 widget 守护进程
```

否则 Widget 画廊可能滞后一次启动。首次使用仍需在桌面右键手动添加 "ClaudeBar"（systemLarge）组件。
