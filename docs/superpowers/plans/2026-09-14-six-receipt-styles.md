# 六款创意阅读小票实施规划

目标：在现有阅读票据、封面进度卡、日历胶片之外，新增六款可直接选择的小票，并交付完整安装包。用户已授权规划、开发和重新打包，本阶段在现有工作树内顺序完成。

## 参考收集（2026-09-14）

以下为实际访问到的公开资料。借鉴信息层级、留白、表格和票根结构，自行用原生控件绘制；不复制品牌、图片或第三方代码。公开产品页不是销量排名，也不代表所有市售设计。

| 新样式 / 保存值 | 公开参考 | 本插件中的布局 |
| --- | --- | --- |
| 书店结账单 / bookshop | [ReceiptLine](https://github.com/receiptline/receiptline)，公开项目标题为 Markdown for receipts / Printable digital receipts | 居中店签，书名配小封面，阅读时长明细，粗分隔线和大号进度合计；不伪造价格 |
| 阅读登机牌 / boarding | [Apple Wallet Pass Design and Creation](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/PassKit_PG/Creating.html)，说明登机牌主字段、辅助字段和票面信息上限 | 黑色票头、书页到远方的阅读旅程、小封面及书名、三列日期/时长/天数、章节票根 |
| 图书馆借阅卡 / library | [Knock Knock Personal Library Kit](https://knockknockstuff.com/products/personal-library-kit)，个人图书馆借阅卡产品 | 私人图书馆题签，书名作者及小封面，日期与阅读数据登记表，阅读状态印记；不补造历史借阅记录 |
| 影院票根 / cinema | [TicketPrinting Event Tickets](https://www.ticketprinting.com/Event-Tickets/)，公开活动票模板与票纸/装订/编号选项 | 大书名、居中海报式封面、虚线撕口、日期及阅读时长、当前章节和记录编号 |
| 阅读明信片 / postcard | [MOO Postcards](https://www.moo.com/us/postcards)，不同纸型和尺寸的明信片产品 | 左侧封面相片框，右侧收件题签与书名，分栏竖线，章节留言、日期和进度 |
| 阅读日报 / newspaper | [Newspaper Club](https://www.newspaperclub.com/)，Broadsheet/Tabloid/Midi/Mini 版式与模板入口 | 报头、日期期号、书名头条、封面与时长双栏、当前章节报道和进度线 |

Dribbble 返回空的 HTTP 202，Canva 返回 403；未将它们当成已看过的设计参考。

## 三种实现方案比较

1. **推荐：扩展现有原生绘制。** 复用 receipt_screen.lua 的文字、封面、进度、线条及控制栏；增加统一样式清单，供绘制、设置校验和菜单共用。无需新运行依赖，黑白屏清晰，尺寸变化不拉伸封面或字形。
2. 背景图片模板：可以快速获得复杂纹理，但缩放会模糊、可变文字难排版，还增加解码与内存成本。
3. 通用模板引擎：适合将来允许用户编程制作任意模板；当前只有九款固定布局，新增配置语言和解释器不值得。

## 范围与文件

- 新增 `legado/lib/receipt_styles.lua`：九款固定样式的有序清单和有效值集合。
- 修改 `legado/ui/receipt_screen.lua`：六个原生布局分支；保留公共顶部四分之一手势、明确窗口重画、返回、尺寸、短评、异步封面及清理逻辑。
- 修改 `legado/lib/settings.lua`、`legado/ui/presenter.lua`：共用清单，九款均可选、可保存、重启可恢复。
- 修改相关 spec、发布白名单和说明；增加开发用预览脚本，通过真实布局输出效果图（桌面字体代替 Kindle 字体，明确标注非设备截图）。
- 新增样式仍使用默认 75% 宽 / 90% 高，支持现有全部宽高选项。空封面、空记录、超长书名/作者/章节和短评均有安全显示。

## 执行与验收

- [x] 扩展持久化、菜单切换、原生布局和 UIManager 重画测试，先确认旧实现无法支持新样式。
- [x] 加入六款布局，所有样式共用原生控件；不增加网络请求或图片素材依赖。
- [x] 输出九款总览及窄尺寸预览，检查排版、文字/封面比例和公共控制栏。
- [x] 测试四种横竖屏分辨率与最小/默认/最大尺寸；九款均检查边界、点击、关闭、异步封面和实际重画队列。
- [x] 全量 Lua 测试、KOReader 原生兼容检查，使用已复制的设备 UIManager 再验证控制栏。
- [x] 更新安装说明，生成独立命名的完整 ZIP，检查内容与 SHA256，复制到普通 `AA/dist` 并验证。

设备验收：安装并完全重启 KOReader，从阅读回顾或书籍更多进入小票，点击屏幕顶部四分之一区域，选择“样式”，逐款查看；修改宽高、短评后重开，确认选择保留。电脑测试不替代 Kindle 物理触屏验收。

实际结果：前五阶段完成；全量 98 规格 / 24,789 断言、原生兼容 12 规格 / 20,257 断言通过。独立审计发现并修复原生多行字体附加高度，已用官方字体指标回归。新增按书保存排版需求另见 `2026-09-14-book-reader-settings.md`，一并纳入 v0.7.2。

交付完成：普通 `AA/dist/legado.koplugin-v0.7.2-receipts-book-settings-20260914.zip`，91条目，版本0.7.2，工作树包与交付包SHA256一致；运行文件逐字节一致。
