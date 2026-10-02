# 飞书文档工作区

连接器页顶部选择「飞书文档」，进入原生双栏工作区。CLI 接口按官方 larksuite/cli 及本机 lark-cli 1.0.95 的 help / reference 核对。

## 使用

正式版使用已安装的官方 `lark-cli`，从 `~/.local/bin`、Homebrew、`/usr/local/bin`、Bun 及进程 PATH 查找。应用不安装 CLI、不自动升级、不保存令牌、不自动登录。先在终端按官方说明完成安装与用户授权：

```bash
lark-cli config init --new --brand feishu
lark-cli auth login --recommend
lark-cli auth status
```

官方说明：https://github.com/larksuite/cli

云空间列表、全文搜索、知识库、评论及成员操作需要各自的飞书开放平台权限。缺少知识库权限不影响云空间功能。连接设置页提供安装与授权说明，失败信息不回显 CLI 的原始 stderr 或凭据。

## 功能范围

- 云空间文件夹、个人文档库、可访问知识空间与 Wiki 子节点浏览，面包屑返回。
- 全局文档搜索，300ms 防抖；文件类型筛选与显式分页。计数表示实际已加载资源数量，不使用服务端估算总数。
- Docx / Wiki 文档的 Markdown 排版预览、源码阅读与复制，支持追加和明确确认后的全文替换。替换以读取的 revision_id 为基准；Markdown 导入会损失部分富文本和嵌入内容，界面会提示并再次确认。
- 云空间文档创建、文件夹创建、重命名、复制、移动与删除。Wiki 不提供 Drive 移动或删除，避免把 Wiki 节点 token 当作 Drive 资源 token。
- 文件上传、Word / Markdown 导入为在线 Docx；导出 PDF、Word、Markdown，用户选择目录，已有文件不覆盖。
- 分页读取评论、添加全文评论、解决 / 重新打开评论；卡片未包含的更多回复在飞书中查看。
- 查看协作者，按邮箱添加阅读 / 编辑权限、移除成员；权限变更再次确认，Wiki 新增权限仅作用于当前页，不发送消息通知。
- 分页历史版本列表及指定 revision 的只读阅读，不执行版本回滚。
- 其他文件类型支持资源信息和在飞书中打开，不在本界面编辑表格、Base 或幻灯片内部内容。

## 界面与风格

工作区嵌入 `ConnectorsView`，不增加主导航页面。页内入口、类型筛选、详情标签及编辑/权限/导出选项复用 `SegmentedCapsule`；页头复用 `PageHeaderCard` 和 `headerControl`。按钮、图标按钮、搜索框、字段、卡片、空状态分别复用 `ActionButton`、`ActionIcon`、`InstrumentSearchField`、`InstrumentFieldStyle`、`panelCard`、`StandbyEmptyState`，跟随全局明暗主题及减少动态效果设置。文件类型使用统一尺寸的图标井，工作区标记是应用自有静态矢量图形。

## 性能与隔离

原生 List 复用文档行。512KB 内的正文复用现有 Markdown 组件，在后台解析并懒加载段落；更大的正文自动使用 NSTextView 非连续布局，也可手动切换源码；不为每行文本建立 SwiftUI 节点。CLI 与 JSON 解码在后台执行，stdout / stderr 同时排空，保留输出上限 16MiB，单次请求超时 90 秒。导航及正文请求支持取消和请求身份校验，取消只终止该请求拥有的子进程。内存最多保留 12 组列表、8 篇正文，有效期 60 秒；刷新或写入后失效，不在磁盘缓存云文档。

开发版仅显示示例数据。即使只读 CLI 命令也可能刷新共享令牌，因此在真实进程启动入口用 `BuildChannel.allowsSystemIntegration` 拒绝所有真实 CLI 请求；写入入口再次拒绝开发版操作。不读取或复制正式 CLI 凭据、不修改系统代理、不请求系统权限，不启动 VPN。网络代理由 CLI 进程的现有环境配置决定，页面不修改系统代理或外部客户端配置。

## 验证

```bash
make test TEST=feishu-documents
make test
make build
make release
```

回归测试直接编译生产 JSON 解析、请求构建和状态模型，验证 Drive / 搜索 / Wiki 返回、分页参数、链接边界、凭据安全错误、开发版拒绝执行以及自有模拟子进程取消。测试不访问飞书服务。构建和签名验证不能替代正式版账号的云端读写验证；后者需用户在明确授权的资源上手工执行。
