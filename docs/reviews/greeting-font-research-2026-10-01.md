# 问候创意字体调研与管理（2026-10-01）

本轮从字体作者项目和 Google Fonts 源仓库调查字形风格、许可、文件版本及字符覆盖，新增 7 款中文、15 款英文。连同已有字体，可选目录为 14 款中文、39 款英文，其中 4 款英文由 macOS 提供，其余字体随应用分发。

## 筛选方向

| 风格 | 中文选择 | 英文选择 | 用途 |
| --- | --- | --- | --- |
| 圆润、厚实 | 寒蝉圆黑粗体／特粗、寒蝉全圆体 | Fredoka Bold、Baloo 2 ExtraBold、Lilita One | 默认温暖、饱满的问候 |
| 童趣、漫画 | 站酷快乐体、霞鹜漫黑 | Chewy、Luckiest Guy、Rubik Bubbles | 活泼手绘及泡泡字 |
| 随笔、行草 | 悠哉、志莽行书、龙藏、刘建毛草 | Caveat Bold、Oleo Script Bold | 自然、奔放的个人表达 |
| 复古、招牌 | 站酷庆科黄油、得意黑 | Bungee、Bungee Shade、Righteous、Shrikhand | 美术字、斜体、海报风格 |
| 书卷、花体 | 霞鹜臻楷、马善政、站酷小薇 | Berkshire Swash、原有花体 | 温润楷书、毛笔及卷曲装饰 |
| 轮廓、立体 | — | Rampart One、Monoton | 积木轮廓、多线霓虹效果 |

## 作者资料与取舍

- [寒蝉全圆体作者说明](https://github.com/Warren2060/ChillRound)：与已有圆黑体区分，补充全圆笔画方向。
- [霞鹜臻楷作者说明](https://github.com/lxgw/LxgwZhenKai)：保留比文楷更厚实的书卷方向，原文件按作者发行版使用。
- [悠哉作者说明](https://github.com/lxgw/yozai-font)：衍生于 YozFont 的随笔字形，选择 Medium 字重。
- [霞鹜漫黑作者说明](https://github.com/lxgw/LxgwMarkerGothic)：马克笔风格，补充漫画方向。
- [小赖字体作者说明](https://github.com/lxgw/kose-font)：调研过但本轮未加入，避免与悠哉的轻松手写方向重复，也减少全字库资源体积。
- [Fredoka 官方说明](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/fredoka/DESCRIPTION.en_us.html)：圆润标题字体，使用原字体的 700 字重。
- [Shrikhand 官方说明](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/shrikhand/DESCRIPTION.en_us.html)：厚实、圆润的斜体方向。
- [Rampart One 官方说明](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/rampartone/DESCRIPTION.en_us.html)：立体块状轮廓；虽然含部分日文字形，本应用仅作为英文字体选择。
- [Monoton 官方说明](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/monoton/DESCRIPTION.en_us.html)：装饰标题用途，预览使用 32 pt 起始字号，问候大字使用现有按边界适配的字号。

## 本轮新增资源

| 字体 | 方向 | 许可 | 固定来源 |
| --- | --- | --- | --- |
| 志莽行书 | 行书笔意 · 流畅洒脱 | OFL 1.1 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/zhimangxing/ZhiMangXing-Regular.ttf) |
| 龙藏体 | 随性书写 · 毛边质感 | OFL 1.1 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/longcang/LongCang-Regular.ttf) |
| 刘建毛草 | 奔放草书 · 自由灵动 | OFL 1.1 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/liujianmaocao/LiuJianMaoCao-Regular.ttf) |
| Fredoka | 圆润粗体 · 柔软亲切 | OFL 1.1 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/fredoka/Fredoka%5Bwdth%2Cwght%5D.ttf) |
| Baloo 2 | 饱满圆体 · 活泼厚实 | OFL 1.1 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/baloo2/Baloo2%5Bwght%5D.ttf) |
| Chewy | 卡通手绘 · 胖胖俏皮 | Apache 2.0 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/apache/chewy/Chewy-Regular.ttf) |
| Shrikhand | 复古胖斜体 · 奶油质感 | OFL 1.1 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/shrikhand/Shrikhand-Regular.ttf) |
| Bungee | 招牌块体 · 城市海报 | OFL 1.1 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/bungee/Bungee-Regular.ttf) |
| Bungee Shade | 立体阴影 · 复古招牌 | OFL 1.1 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/bungeeshade/BungeeShade-Regular.ttf) |
| Luckiest Guy | 漫画海报 · 不规则粗体 | Apache 2.0 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/apache/luckiestguy/LuckiestGuy-Regular.ttf) |
| Lilita One | 短胖标题 · 柔和有力 | OFL 1.1 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/lilitaone/LilitaOne-Regular.ttf) |
| Berkshire Swash | 复古花体 · 卷曲装饰 | OFL 1.1 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/berkshireswash/BerkshireSwash-Regular.ttf) |
| Oleo Script Bold | 流动手写 · 温柔厚实 | OFL 1.1 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/oleoscript/OleoScript-Bold.ttf) |
| Righteous | 装饰艺术 · 几何复古 | OFL 1.1 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/righteous/Righteous-Regular.ttf) |
| Rampart One | 立体轮廓 · 纸上积木 | OFL 1.1 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/rampartone/RampartOne-Regular.ttf) |
| Monoton | 多线轮廓 · 复古霓虹 | OFL 1.1 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/monoton/Monoton-Regular.ttf) |
| Rubik Bubbles | 泡泡字形 · 软萌夸张 | OFL 1.1 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/rubikbubbles/RubikBubbles-Regular.ttf) |
| Caveat Bold | 随笔手写 · 自然轻松 | OFL 1.1 | [原文件](https://github.com/google/fonts/blob/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/caveat/Caveat%5Bwght%5D.ttf) |
| 寒蝉全圆体 | 全圆笔画 · 软糯温暖 | OFL 1.1 | [原文件](https://github.com/Warren2060/ChillRound/blob/46dda1602729b58de96e3fdee9f918d7aaa64727/ChillRound/ChillRoundF.ttf) |
| 霞鹜臻楷 | 厚实楷书 · 温润书卷 | OFL 1.1 | [原文件](https://github.com/lxgw/LxgwZhenKai/releases/download/v0.825/LXGWZhenKaiGB-Regular.ttf) |
| 悠哉字体 | 随笔手写 · 松弛自然 | OFL 1.1 | [原文件](https://github.com/lxgw/yozai-font/releases/download/v0.868/Yozai-Medium.ttf) |
| 霞鹜漫黑 | 马克笔字 · 漫画气质 | OFL 1.1 | [原文件](https://github.com/lxgw/LxgwMarkerGothic/releases/download/v1.003/LxgwMarkerGothic-v1.003.zip) |

字体原文件未改造、未子集化。完整许可与版权声明随文件存放，文件 SHA-256 和固定 commit／发行版见 [资源来源](../../Sources/Fonts/SOURCES.md)。变量字体使用其原有字重轴，轴范围已静态核对。

## 设置行为

- 默认只显示当前字体菜单，预览与管理默认折叠。折叠时不生成预览。首次使用在后台将未删除字体复制到按版本隔离的 `FilePaths.greetingFontsDir`，CoreText 从本地库读取。
- 展开后按当前问候语言展示实际字形；可按名称或风格搜索。
- 删除成功后实际移除本地库中的字体文件，清除字体描述符、字形与布局缓存，再从可选列表移除；失败显示错误且保留选择，记录在 bundle 隔离的 `UserDefaults.standard` 中。删除当前字体时选取同语言的可用默认字体；默认字体已删除时选取该语言第一款可用字体。
- 每种语言至少保留一款；删除按钮与模型入口均执行此约束。
- 恢复仅恢复当前语言的已删除字体，不改动另一语言的删除记录，不要求网络连接。
- 删除会减少应用本地字体库占用；签名包中的恢复原件保留，故不会减少安装包体积。系统自带字体禁用删除按钮。

## 验证边界

本轮仅完成源码与资源静态检查：新增字体文件头、表边界、中文问候／预览字符与英文小写及标点覆盖、变量字重范围、许可存在性、来源 SHA-256，以及 Python 夹具语法。本地文件删除／恢复／重启不复活、短句字号超过原上限、同语言回退、保留最后一款、恢复的回归用例已加入 `greeting-layout`。按用户要求，没有编译、构建、运行这些回归或启动界面；折叠、按钮交互、CoreText 渲染和视觉布局尚未实机验证。
