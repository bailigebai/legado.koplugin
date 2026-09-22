# v0.7.2：九款阅读小票与按书保存阅读设置

本版完整安装包：`legado.koplugin-v0.7.2-receipts-book-settings-20260914.zip`。

## 六款新增小票

原有阅读票据、封面进度卡、日历胶片继续保留。新增样式均使用本书封面、标题、作者和已有阅读记录；没有记录时显示空状态，不编造时长或历史。

| 新样式 | 主要效果 | 设计参考 |
| --- | --- | --- |
| 书店结账单 | 店签、时长明细、进度合计 | [ReceiptLine](https://github.com/receiptline/receiptline) |
| 阅读登机牌 | 黑色票头、旅程主标题、三列阅读信息、章节票根 | [Apple Wallet 票面设计](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/PassKit_PG/Creating.html) |
| 图书馆借阅卡 | 图书馆题签、阅读登记表、状态印记 | [Knock Knock Personal Library Kit](https://knockknockstuff.com/products/personal-library-kit) |
| 影院票根 | 海报封面、虚线撕口、日期时长与记录编号 | [TicketPrinting](https://www.ticketprinting.com/Event-Tickets/) |
| 阅读明信片 | 相片框、收件题签、章节留言与日期 | [MOO Postcards](https://www.moo.com/us/postcards) |
| 阅读日报 | 报头、书名头条、时长与封面双栏 | [Newspaper Club](https://www.newspaperclub.com/) |

参考资料于 2026-09-14 访问；只借鉴布局逻辑，没有复制品牌、商业图片或引入模板引擎。所有布局由现有 KOReader 原生文字、线条和图片控件绘制。

操作：打开一本书的小票，点击**整个屏幕顶部四分之一**，选择“样式”。“宽度 / 高度”继续控制纸张大小，默认宽 75%、高 90%；文字和封面保持比例。底部短评可编辑，保存后只显示短评正文。

## 阅读设置跟随本书

网络小说每章是独立缓存文档，旧版 KOReader 把每章当成不同文件保存设置，因此下一章会回到默认排版。本版在书籍记录中保存原生排版设置，在新章节第一次排版之前恢复。

字号、字体、左右/上下边距、行距、字距、对比度及原生底栏的文档排版选项按书保存。调整之后切到下一章、目录跳转或退出后重开，无需再调；切换其他书籍时使用那本书自己的设置。明确切换站点书源时继承当前书的设置。

章节进度、目录、书签和批注仍按各自原有方式保存，不复制其他章的阅读位置。本地整本文件继续由 KOReader 原生机制保存。设备全局选项，例如前光或无线网络，不改为每书设置。

## 安装与验收

1. 完全退出 KOReader，解压新 ZIP，将其中的 `legado.koplugin` 完整复制到 `koreader/plugins/`，替换旧插件代码，保留插件数据目录。
2. 重新启动 KOReader；到“工具 → 书源阅读”，打开小票检查九个样式，尝试宽高设置和短评，返回后重新进入确认保留。
3. 打开网络书 A，调整字号、左右边距和对比度，切到下一章，再从目录跳到一个以前读过的章节，确认设置一致。
4. 退出并重启 KOReader，再打开 A 检查；打开书 B 改成另一组设置，往返 A/B，确认互不覆盖。
5. 在 A 切换站点书源，继续读一章并退出重开，确认样式设置仍保留。

桌面检查与设备验收范围见 [测试说明](testing.md)。布局预览使用实际插件布局与桌面字体，并非 Kindle 实拍；物理触屏、实际字体与翻页效果仍需在设备验收。
