# 第三期无感阅读研究（仅研究，不改运行代码）

日期：2026-09-15。依据当前工作树真实源码、两份上游 README/许可证及缓存的 KOReader v2026.07.1 源码。第一、二期尚在同一工作树开发；下面的现状描述是研究时快照，实施时应合并这两期最终接口。

## 结论

可行。采用 **Leko 的独立分页/正文控件与局部动画，继续使用本插件的 ReaderSession、书源、缓存、书架、目录和历史**。启用“无感阅读”后，网络小说路径不得创建、调用或伪造 ReaderUI；KOReader 的 Font、TextWidget、TextBoxWidget、InputContainer、UIManager 和 Screen/Blitbuffer 可继续使用。

这不是复制整个 Leko 插件：Leko 的阅读模块确实独立于 ReaderUI，但 ReaderView 仍直接依赖它自己的 BookService、Storage、TocView 和统计数据库桥。移植时应把这些业务依赖接回现有模块。QuickJS、Java 兼容层、手机导入、Leko 的书源/存储系统不是阅读器依赖，不应因移植阅读界面而加入。

研究只确认源码接口与可行性；尚未证明 KPW6 的物理墨水屏动画、触摸响应或内存峰值。

## 三种可行方案

| 方案 | 真正绕开 ReaderUI | 优点 | 代价与限制 | 判断 |
| --- | --- | --- | --- | --- |
| A. 移植 Leko 的分页/绘制/字体选择/局部动画，接现有会话 | 是 | 最接近用户指定的阅读方式；现有书源、书架、缓存和历史继续工作 | 需把 Leko 业务依赖改为现有回调；HTML 转文本；补字符级位置 | **推荐** |
| B. 自建全屏控件，直接调用 KOReader Document/CREngine 排版 | 是 | 可继续使用已生成 HTML，丰富排版与原生背景支持较多 | 要自己处理文档加载、重排、坐标和释放；不能直接等同 Leko 分页体验 | 可作为富文本需求方案，本期不选 |
| C. 整套内嵌 Leko 插件并桥接两份数据 | 是 | 上游功能集中存在 | 双存储、双书源、双预取、双统计和试读状态，迁移/冲突面最大 | 不采用 |

只给 ReaderUI 增加遮罩、隐藏菜单或改按钮文字不属于可行方案，不能满足本期要求。

## 固定参考与许可

| 项目 | 本次核对版本 | 许可证与处理 |
| --- | --- | --- |
| `jnjnnjzch/leko-reader` | `57dff8958dd43a5d95cb2dac22ca363d874de29b`，本地 tag `v0.16.0` | README 声明 AGPL-3.0-or-later，根及插件内均有 AGPL 文本；保留原许可证、来源、版本与修改说明 |
| `koplugin-swipe-animation/Swipe_Animation.koplugin` | `59dce480c38538976325f7ebc0831e36bc4c6ed4`，本地 tag `v4.3` | 根 LICENSE 为 GPLv3；README 作者列出 `xhs:5699990012`、nuku、Echoes、小红薯6809667F、斯普特尼克的漫游；保留来源/贡献者与 GPL 文本 |
| 当前 legado 插件 | 当前开发工作树 | README 声明 AGPL-3.0-only；`THIRD_PARTY_NOTICES.md` 已存在，应追加以上两条，不另造平行清单 |
| KOReader | 项目固定基线 v2026.07.1 | 当前 notices 记为 AGPL-3.0；Swipe README 所称“与 KOReader 相同的 GPLv3”不应作为 KOReader 许可事实复述 |

Leko 的 QuickJS 是 MIT，但本推荐不携带它的二进制或 bridge，因此不需要为阅读器引入新的 native ABI。直接复制/改写的阅读模块仍属于相应 AGPL/GPL 代码，应在插件包携带版权文本与源文件对应信息。AGPLv3 第 13 节含与 GPLv3 组合的许可条款；不要删除 GPL 原文或把其来源改称原创。打包应包含可对应该包的修改源码和 notices。

## Leko 阅读器实际组成

| 文件与入口 | 真实职责 | 移植处理 |
| --- | --- | --- |
| `Leko/ReaderView.lua:59` | `InputContainer:extend` 的非 modal 全屏页面，触摸/按键路由、页构建、菜单、章节导航、字体设置、生命周期 | 移植其阅读功能与布局；BookService/Storage/Toc/UI 业务入口替换为现插件回调 |
| `Leko/Paginator.lua:319` | 逐页排版，段落+字符位置、章节首页标题、行距/边距/缩进、前后页 | 保留有界测量和真实字体尺寸，不使用估计的“字号×字符数”断行 |
| `Leko/ReaderMargins.lua` | 5 档左右边距；保证每增一档至少少一列全角字 | 可直接命名空间移植；避免相邻档位实际宽度相同 |
| `Leko/ReaderFooter.lua` | 按 UTF-8 字符计章节比例；预取缓存条状态/文字 | 复用比例算法，预取状态接现 ReaderSession；保留现有页眉页脚选项 |
| `Leko/FontSelectionView.lua` | 已装字体、TTC face、Regular/Bold/Italic、同名字体按路径区分、简中优先排序 | 可移植；仅将用户可见样式名本地化，字体真实名称保持原样 |
| `Leko/SwipeRefresh.lua` | 页面目标缓冲、原生/软件/跨章动画协调、取消/收尾、generation | 可命名空间移植，为另一种 wipe 增加真实分支，避免两套生命周期 |
| `Leko/SwipeAnimation.lua` | 能力检测与 MTK 原生 swipe 一次性标志 | 可命名空间移植，不按设备名称猜能力 |
| `Leko/ChapterWaveRefresh.lua` | 跨章黑白净屏移动带 | 可命名空间移植，目标页由调用方管理，保留取消清理 |
| `Leko/ReadingCoordinator.lua` | 异步获取章节、过期任务判断、创建阅读器 | **不整体移植**，现 ReaderSession/阅读 intent 已负责该领域 |
| `Leko/KOReaderStatisticsBridge.lua` | 无 Document 的原生 `statistics.sqlite3` 写入桥 | 第二期若已有桥则复用；否则独立提取并做 schema/事务/失败处理，不能为了统计创建 ReaderUI |
| `Leko/Util.lua` | UTF-8、位置比较等加上大量无关网络/路径工具 | 只提取分页必需函数；实体解码优先复用当前 `safe_functions.functions.htmldecode` |

Paginator 依赖 `Font`、`TextBoxWidget`、`TextWidget`、`device.screen`；正文优先使用 TextWidget 的 `_xtext:makeLine`，无 XText 时用 `ui/rendertext:getSubTextByWidth`。这两个绘制路径都需覆盖。它用最多 768 字符的前向窗口处理巨长单段落，字符/字节提示避免每页重扫整个段落；标题过高时保留至少一行正文，避免标题页翻不动。

### 需要完整保留的阅读操作

Leko 源码中存在：上一页/下一页、上一章/下一章、目录/指定章跳转、书籍详情、加入书架、未入架试读退出选择、重新获取本章、字体及 face、字号 6 档、行距 5 档、边距 5 档、段间距 5 档、首行缩进、页眉/页脚、前灯对话框、页面动画开关、跨章净屏开关、暂停/恢复、保存位置、原生统计桥。

这些阅读操作应由本插件的功能入口或等价控件完成，不能只留下菜单名称。书籍详情、换源、加入书架、目录、缓存下载等复用现插件流程，试读退出则按当前书架成员状态显示对应选择。

建议中文按钮：`回到书架`、`章节目录`、`上一章`、`下一章`、`阅读排版`、`重新获取本章`、`书籍详情`、`正文字体`、`文字大小`、`行间距`、`左右留白`、`段落间距`、`段首缩进`、`屏幕亮度`、`翻页效果`、`跨章净屏`、`当前书籍小票`。字体样式 `Regular/Bold/Italic/Bold Italic` 对应 `常规/粗体/斜体/粗斜体`；不得改变用来选择 font face 的真实 index/path。

## 原动画与设备刷新

### Leko 原有路径

`ReaderView:setPage` 先更新逻辑页，再把完整目标控件传给 `SwipeRefresh:begin(widget, direction, callback, options)`。选项包括 `chapter_changed`、`page_animation_enabled`、`chapter_clean_wave_enabled`。`begin` 创建同尺寸/同类型/同旋转的目标 Blitbuffer，只保留一张目标页；`settle` 立即提交最终页再清除任务；`cancel` 释放任务/缓冲，不在退出后继续刷屏。回调含义是已提交像素，不是物理屏幕波形完成。

- 设备原生：`Device:canDoSwipeAnimation()` 与具体方法能力同时成立；先 blit 新页，再紧邻调用 `Screen:setSwipeDirection(forward == true)`、`setSwipeAnimations(true)`、`refreshUI`。KOReader `framebuffer_mxcfb.lua:610` 下次提交消费该开关；`_MTK_SetSwipeDirection` 自行处理屏幕旋转。菜单/失败/取消边界还要 `setSwipeAnimations(false)`。
- 软件分条：竖屏 8 条、横屏 6 条，18 ms 调度间隔；向前从右向左、向后反向；8 像素对齐与 8 像素重叠防细缝，逐条 `blitFrom` + `refreshUI`。使用 `UIManager:scheduleIn`，不需要阻塞睡眠。
- 跨章净屏：移动黑/白带后恢复正文；带宽按屏宽约 1/6，限制 32～128，8 像素对齐，步进比带宽小，16 像素重叠；4 ms 调度。优先 `refreshNoMergeUI`，没有则 `refreshUI`。仅尝试等待提交的可用方法，不等整段波形完成。最终整页提交确保无带状残留。

缓存的 KOReader `frontend/device/kindle/device.lua` 明确为 `KindlePaperWhite6` 声明 `isMTK`、`canDoSwipeAnimation`。这是基线源码能力声明，不等于当前用户设备已验收。

### Swipe_Animation 的擦除渐显路径

上游不是单个可 require 的普通动画插件。它覆盖 `frontend/ui/uimanager.lua`，全局包装 Screen 的 `beforePaint/afterPaint/setSwipeAnimations/setSwipeDirection`，在 `_repaint` 中读 `_G.SwipeAnimation`，并读取 `ReaderUI.instance` 判断章节和图片。整套复制会影响所有书和菜单，不应采用。

可提取 `patches/2-swipe-animation-core.lua:234` 的条带边界算法及 `runSwipeAnimation` 内的 reveal：旧页作背景，新页逐条显现；竖 8 / 横 6 条，默认竖 20 / 横 10 ms，可选 `refreshUI` 或 `refreshFast`；用 `Screen.alignment_constraint` 生成切点，Kobo 彩屏有取消对齐的特例。定期净屏先决定是否跳过动画，原文的轻度净屏为 `refreshPartial`，标准净屏为 `refreshFull`。

本插件应把算法放进同一局部协调器，接收显式方向/跨章标记/本地设置，不导入其 ReaderUI、全局 hooks、`_refresh_stack` 操作或 `ffi.C.usleep` 循环。按 `scheduleIn` 分帧可保留形态且允许取消；横竖延时与 UI/Fast 是必要设备调节项。若后续支持 Kobo，应保留其 MTK submission fence 的条件分支并真机验证，不能把 Kobo 的等待直接用于 Kindle。

用户可见选择建议为 `关闭`、`原版翻页`、`擦除渐显（Swipe）`，另有 `跨章净屏` 开关。原版在设备支持时调用硬件、不支持时走 Leko 软件分条；Swipe 选择必须实际走独立的 strip-alignment/timing/refresh-mode 路径，不能两个名称指向同一个实现。所有选项关闭时不得创建动画缓冲、调度动画或调用一次性硬件标志。

## 与当前 ReaderSession / App / Bootstrap 的连接

当前 `ReaderSession:_open_cached`（`legado/lib/reader_session.lua`）读取校验后的正文缓存，写章节 HTML，再调用 `ui:openDocument(path, callbacks)`。候选会话只有 ready 成功后才 active，失败可保持上一个 document。其 `_callbacks` 已有 read_settings、ready、failure、flush、pause、resume、close、end_of_book；预取、目录、换源与离线逻辑都应继续留在这里。

推荐明确区分“打开章节”和“打开本地文件”，避免通过 `.html` 后缀猜模式：

1. Bootstrap 构造现原生适配器和独立阅读适配器，配置共同的 on_exit/on_toc/on_settings/on_sources/on_review/on_receipt 回调。两个真实后端可以有一个小型分流入口，但无需通用工厂/服务层。
2. ReaderSession 对网络章节传入 `{book, source, chapter, chapters, index, body, catalog_complete, previous_document}` 与原 callbacks。独立模式直接排版已校验正文；原生模式才调用现 `writeHtml + openDocument`。UI adapter 选择不触发书源网络。
3. `App:startReading` 的本地文件路径、下载后的 EPUB 打开仍调用明确的本地 openDocument。无感模式只改变本期网络小说入口；如需本地 EPUB/PDF 也独立化，应按方案 B 另做文档功能，不能声称 Leko 文本分页已支持。
4. 首次读/跨章/目录跳转都走同一会话候选与 ready/failure 规则；独立 adapter 可以复用同一全屏视图替换正文，但必须为每章返回独立 proxy，旧 proxy close 不得误关新会话。目标页构建成功前不得销毁旧页。
5. “无感阅读”从当前原生顶栏开关进入时，先 flush 当前位置/排版、记录章节，再构建独立目标页，成功后关闭旧视图；保存开关或构建失败则保留旧视图并报告原因。关闭开关走逆向流程。不要让新 ReaderUI 的创建与旧独立视图的 close 再次触发返回书架。
6. 上/下章、重取本章、换源调用 ReaderSession；上一章最后一页必须有明确请求参数和恢复方式，不要靠 fraction=1 后继续触发 end_of_book。前景请求失败保留当前页，可重试；后到的旧请求由 generation/is_current 丢弃。

### 正文与位置

当前 `content_cleaner.lua` 保留 p/h1..h6/br/li/blockquote/strong/img 等安全 HTML；Leko `BookService:buildChapterModel` 只有 `{title, paragraphs}`，不能直接把 HTML 当纯文本输入。

应在独立阅读的正文适配处保留块边界与 br，再解码实体为纯文本；实体解码可复用现 Safe.functions.htmldecode，HTML 结构有复杂情况时复用已安装 htmlparser。不可改写原缓存，以免影响 EPUB/原生后端。验证数字实体、`&lt;` 字面文本、嵌套段落、单换行、多换行、全角缩进、末尾空白、章节标题重复。Leko 本身是纯文字阅读器，不实现内文图片/链接交互；如章节含有关键图片应明确提示不支持并让用户选择关闭无感模式，不可静默丢弃后仍报完整阅读成功。

现进度保存章节 UID/URL/index/title + fraction，并把 KOReader 排版保存在 `progress.reader_settings`。保留这些字段，同时保存独立游标 `{chapter_uid, paragraph, char, content_checksum}` 与独立排版字段；不要用 Leko style 覆盖原 native reader_settings。相同内容同模式重开优先字符游标，字号/边距更改保持同一段落字符；正文变化、换源或第一次切换后端时用章内 fraction 恢复，并明确为近似对齐。章节 UID 与正文校验码必须匹配才能复用游标。

现 ReadingHistory.record 深拷贝历史，可保留新增字段；仍需核对 SQLite payload 与导出设置校验是否允许。写入失败应保留 pending progress 并可重试，不能先销毁唯一未保存游标。无感和原生来回切换都不能抹去另一套按书设置。

### 保留现有功能的验收映射

| 功能 | 连接点及完整行为 |
| --- | --- |
| 目录 | 继续 `App:openReadingCatalog` + `ReaderSession:loadCatalog`，保留加载更多、当前章定位、取消和失败提示；跳章后关闭目录，旧读页不复活 |
| 预取 | 复用第一期的临近页尾预取/在途任务复用；独立页变化应发相同页面位置通知；排版不得发网络请求；预取进度条读真实 cached/total |
| 进度 | chapter/fraction 继续支持书架、阅读回顾；字符游标用于精确重开；目录不完整仍显示“目录加载中”，不拿前三章估算成全书完成 |
| 回书架 | 先 settle/cancel 动画与未完成任务，flush 一次、取消时钟，关闭独立控件，再调用 Bootstrap 既有 on_exit；不进入 FileManager |
| 排版/设置 | 独立菜单提供全部 Leko 排版，按书保存；现插件页眉页脚/进度栏设置立即重排；字体缺失恢复系统字体并提示 |
| 背景 | 复用第一期 reader_background 的路径/目录选择、尺寸百分比/水平偏移/垂直位置参数与生成缓存；独立控件先绘背景后绘透明文字，不让 Leko 原有白色 FrameContainer 遮住背景；动画 target 也必须含同一背景 |
| 小票 | 继续复用十五种样式、大小、评分/状态/短评；当前书小票悬浮在独立正文，关闭后恢复相同位置/背景；小票背景与正文背景各按原规则 |
| 页眉页脚 | 保留五个自定义位置、时间、书名、章名、章页数/全书估算、隐藏/条/详细三种进度栏，不用 Leko 两个布尔选项覆盖用户原配置 |
| 插件统计 | 复用 ReaderSession + ReadingHistory.record 的累计/每日时长、跨午夜规则；目录、回顾、小票/设置等覆盖正文时暂停，返回恢复，休眠时间不计 |
| KOReader 统计 | 复用第二期统一桥；只有独立后端负责独立页事件，不与原生 ReaderStatistics 双重记时；稳定 book id，不能每章新建一本书 |

当前 `Presenter:_readingReceipt`（`legado/ui/presenter.lua`）只从 document.reader 的原生 toc/document/statistics 取页数和时间。应优先读取中立的 `document:getReadingContext()`（Leko `getCurrentReadingContext` 可参考）并使用已有 native 分支兼容另一后端。返回 `{chapter_title, chapter_page, chapter_pages, chapter_fraction, book_fraction, reading_seconds, remaining_seconds}` 等实际值；不能构造空 ReaderUI 形状只为让旧分支不报错。App:openSettings 的 applyProgressBar/document.chrome 调用也应通过独立 adapter 的实际重排入口完成。

## 原生统计的真实限制

Leko bridge 直接使用 lua-ljsqlite3、DataStorage、lfs 和 MD5；要求既有 `statistics.sqlite3`、`user_version=20221111`、book/page_stat_data/page_stat，缺失或未知 schema 就退出，不负责建库/迁移。参考 KOReader v2026.07.1 的 `DB_SCHEMA_VERSION` 确为 20221111。

它按全书 10,000 个虚拟进度单位记录页号，最短默认 5 秒、最长 120 秒、50 次翻页 flush。此页号是统计单位，不是真实排版页数，不能拿来展示小票章页数。移植后沿用第二期身份和配置，避免 Leko 专属 md5 前缀制造重复记录。锁库/事务失败时保留待写周期，不能照搬 close 路径中忽略 flush 失败的行为。schema 不匹配时插件自己的历史仍必须正常，并给出具体诊断。

## 不宜原样搬来的边界

- `ReaderView:_chapterPageMetrics` 为对外查询可同步重排整章（安全上限 20,000 次）；小票/页脚不应每次触发。按当前章+排版缓存真实页边界，必要时分批计算，未算完显示“计算中”，不杜撰准确页数。
- `Paginator:findPreviousPage` 在章首回上一章时从上一章开头扫到结尾；长章需缓存/分批处理。其同章近邻搜索退 4096 字符或 8 段、最多 64 次，窗口起点不一定是原始页边界；需要验证前后往返没有缺字/重复、重开后上一页正确。
- Leko 普通 page history 数组随翻页增长。连续千页阅读应有有界策略或用当前章页边界缓存，明确跨章资源释放；不要无限保存多份整页控件/文本。
- `TextWidget._xtext` 属于宿主内部字段。生产基线与 RenderText 降级都测；降级缺字/字体不能伪装成正常完整排版。
- 背景、横竖屏、菜单覆盖、休眠都可能在动画进行时发生；旧尺寸/旧 generation 任务必须失效，释放缓存后不能继续 blit。
- 仅 `pcall` 抓错还不够：开页/恢复位置/保存失败必须回到可继续操作的旧页或有清晰失败结果，不能提前标记 ready。

## 必要验证（本研究未运行长全量测试）

1. **无 ReaderUI 路径证据**：测试将 `apps/reader/readerui` 的 require/showReader/new 设为失败，在启用无感的首次阅读、跨章、目录跳转、重开、换源中仍完整成功；关闭模式及本地文件路径仍由原生适配器覆盖。
2. **分页真实内容**：中文、英文混排、数字实体、长标题、首行缩进、全角空白、超长单段落、章节尾空行；拼接所有页面正文能恢复预期内容，没有漏字/死循环；字体真尺寸下不越界，左右边距每档不同；改字号恢复到原字符附近而非章节开头。
3. **会话故障/并发**：缓存同步 ready、远程延迟 ready、开页失败、恢复失败、连点下一页、上一章、换源、关闭后回调；旧章节不复活，书籍统计/进度不串；近页尾预取与在途任务复用不重复请求。
4. **开关往返**：原生中打开无感，立即成为独立控件；无感关闭后回原生；两次都保留书/章/位置与独立的按书排版；设置落盘失败保持原模式。
5. **功能联动**：所有中文按钮实际触发对应操作；目录返回、设置返回、小票关闭仍是原正文；十五款小票、背景各位置参数、阅读回顾月份/分页不丢；本章刷新失败仍可读旧缓存。
6. **动画 API**：fake Screen + 真 generation 调度分别验证原生调用相邻/标志清零、软件方向/对齐/覆盖全屏、跨章黑白带、Swipe UI/Fast/横竖延时、关闭不分配；异常/取消/重开/旋转/菜单中无遗留 callback/buffer；最终像素等于目标页。
7. **统计/保存**：暂停/休眠/覆盖弹层/跨午夜、双后端转换只计一次；存储失败重试；KOReader 缺 DB/未知 schema/锁库/事务回滚不破坏插件历史，不制造统计页数。
8. **真实宿主/包检查**：运行当前项目聚焦 reader/session/settings/history/presenter/namespace 规格，再用固定 KOReader Widget/字体模块验证真实控件尺寸与加载；完整包只含 `legado.koplugin/`，包含 AGPL/GPL/notices，无 `.tools`/QuickJS/全局 patches 或替换 UIManager。
9. **Kindle 验收**：KPW6 测无感首开、至少连续 10 次跨章与往返、断网缓存/下一章缺失、两类动画+净屏+关闭、横竖屏/夜间背景、休眠唤醒、设置/目录/小票期间立即操作；看残影、分条接缝、触控响应与内存趋势。桌面图像/调用记录不能替代此项。

研究完成后等待主代理安排实现；本文件没有承诺任何上述检查已通过。
