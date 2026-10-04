# 飞书官方云文档组件接入

正文默认使用官方 `DocComponentSdk 1.0.13`，不再把阅读界面建立在简化 Markdown 的重排上。图片、表格、目录和富文本由飞书组件呈现。当前配置为只读；新建文档、已有 Markdown 草稿、源码编辑继续使用现有原生编辑器。官方组件加载失败时显示具体阶段或平台错误码，并自动切换到已有正文阅读器；提供重试原版入口，顶部源码入口仍可使用。

## 接入方式

- `FeishuOfficialDocumentView` 用 `WKWebView` 承载组件，使用内存网站数据存储，不读取其他浏览器的登录 cookie。
- 每个可见视图启动一个临时 HTTP 宿主，只监听 `127.0.0.1` 的系统分配端口。宿主只提供随机路径的静态 HTML，校验 Host，只接受 GET，不提供凭据、文件或操作接口；切换文档、关闭视图时取消监听和连接。
- 使用当前 CLI 的用户身份：`auth status` 确认 App ID / Open ID，`api POST /open-apis/jssdk/ticket/get --as user` 获取票据，再检查账号未变化。没有新增 App Secret 配置或凭据存储。
- SHA-1 签名在原生侧生成，使用毫秒时间戳、随机 nonce 和宿主页准确 URL。网页只收到 SDK 需要的一次性签名对象，不收到 user access token 或 jsapi ticket。
- 脚本消息仅接受当前宿主的主 frame，远端文档 iframe 无权调用签名桥。鉴权失败可以刷新签名，失败重试有上限；关闭视图取消关联任务。
- 使用固定窗口视口，监听窗口尺寸变化同步 iframe 高度，不使用 SDK 的 `auto` 文档高度。明暗模式跟随应用；文档内链接在系统浏览器打开。

开发版在组件宿主和鉴权入口都有编译期身份闸，不启动组件监听、不加载远端 SDK、不读取 CLI 凭据。离线界面说明由正式版加载真实组件。

## 使用前提与验证边界

飞书要求企业自建应用，用户身份需要云空间权限 `drive:drive`；用户必须拥有文档读取权限。签名前检查 CLI 用户授权中的 `drive:drive`，缺少时直接回退正文阅读，避免 SDK 公钥请求返回 `Scope denied` 后整页无法阅读。应用开通权限后仍需重新授权用户账号。成员名片和搜索能力另有对应权限。应用后台的权限审批、发布由应用管理员完成。本次没有修改用户的飞书应用、授权或真实云文档。

官方文档面向普通 Web 宿主，没有明确承诺 macOS WKWebView + 临时回环 HTTP Origin 的兼容性。因此完成签名、宿主与编译测试后，仍须在正式版使用已授权的自建应用验证 SDK 鉴权、图片、长文滚动及窗口缩放。未经这一步不能宣称真实文档已成功显示。若飞书要求登记固定 HTTPS 宿主，需使用企业控制的 HTTPS 宿主页替换临时宿主；不能伪造已验证的域名或绕过平台校验。

验证命令：`make test TEST=feishu-component` 使用生产签名函数与官方示例向量，测试临时宿主的正常路由、错误路径、非 GET、缓存限制和停止服务，并验证开发版入口禁止访问。测试不获取票据或加载真实云文档。`make test` 包含此组；构建只构建，不安装或启动应用。

## 官方资料

- [开始使用](https://open.feishu.cn/document/common-capabilities/web-components/uYDO3YjL2gzN24iN3cjN/introduction)
- [组件 SDK 鉴权流程](https://open.feishu.cn/document/uYjL24iN/uUDO3YjL1gzN24SN4cjN)
- [云文档组件功能配置](https://open.feishu.cn/document/uYjL24iN/uYDO3YjL2gzN24iN3cjN/feature-config)
