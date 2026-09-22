# 第三期独立阅读核心：暂存交付与接口

## 本轮临时规划：高 DPI 排版与恢复边界

范围仅运行目录 `leko_reader.lua`、核心规格与本文档，不修改分页器接口。备选方案：①按比例放大固定高度，简单但不能覆盖真实字体额外字高；②每页重新探测页眉、页脚和进度字体，正确但增加后台分页成本；③按字号及屏幕缩放缓存真实 TextWidget 高度，同一布局数据同时供预留与绘制使用。推荐并实施③，将像素高度安全换回分页器现有逻辑高度参数。

正文、章节页脚、进度详情与条分别保留不重叠区域，边距与条宽高随屏幕缩放。顶部 12% 全宽打开菜单，保留中央入口。通过一个可见性检查恢复阅读：Resume/ReadingResumed 广播及正文翻页操作仅在正文是顶层可见控件时恢复；不添加全局钩子。

验收采用两倍缩放、额外 glyph 高度、18 号页眉页脚、22 号进度字和 16 高度组合，并检查缓存复用、时钟刷新区域、左右上角菜单、前灯浮层返回以及覆盖页上的休眠恢复。完成后仅运行既有六项定向回归，停止扩展范围；Kindle 字体、触摸及残影仍需实机验收。

2026-09-15 冻结结果：先复现真实 TextWidget 页眉字高进入正文的失败，再完成修复。core 规格从 57 增至 **103 断言**；分页器、core、字体、动画、adapter 与真实 Session 集成 **6 项规格、953 断言全部通过**。两倍缩放且额外 25 像素 glyph 高度下，页眉与正文、章节行与详情、详情与进度条互不重叠；16 像素横向边距、4 像素条厚随缩放生效。初次与再次完整后台分页合计只探测一次 22 号进度字体，高度缓存在外观/尺寸刷新时失效。时钟 dirty 区域覆盖当前实际页眉区域。顶部左右角及中央点击均打开菜单且不翻页；真实亮度按钮打开原生覆盖层，覆盖期间两种恢复广播均保持暂停，返回正文后 tap/page key 正常恢复。

复验命令：`.tools/python/python.exe scripts/run_lua_specs.py --spec spec/phase3/leko_paginator_spec.lua --spec spec/phase3/leko_reader_core_spec.lua --spec spec/phase3/leko_font_spec.lua --spec spec/phase3/leko_animation_spec.lua --spec spec/phase3/leko_adapter_spec.lua --spec spec/phase3_session_spec.lua`。本次改动限于运行核心、core 规格、接口文档；没有修改分页器或宿主模块。

本核心最初隔离交付于 `staging/phase3/legado/`，现已由主任务复制到 `legado.koplugin/legado/` 并接入 Session/生产适配器；后续以运行目录为准，staging 只是早期快照。专项位于 `spec/phase3/`，独立集成规格为 `spec/phase3_session_spec.lua`。harness 已移除 staging 搜索路径，集成规格还核对真实加载来源；最终包清单、版权及完整 App 验收由主任务负责。

## 已实现范围

- 真正独立的 KOReader InputContainer/TextWidget/TextBoxWidget 正文，不 require 或构造 ReaderUI，不使用其文档或伪对象。
- 已清理 HTML 转段落、实体与 Unicode 检查；Leko 的 768 字符分页窗口、真实控件测量、标题开章布局、字间/行间/段落与边距效果、缩进、字族与 TTC face 选择。
- 同章前后页、章首页返回上一章末页、章尾请求下一章、显式前后章按钮。网络/目录由宿主回调负责。
- 总页数按每批 4 页、批间 10 ms 在 UI 调度器计算；未完成为 nil，不谎报 0 或 1。仅保存章节页起点，不缓存每一页控件；页视图、旧动画缓冲、旧章数据在关闭后释放。最近 256 个游标用于精确往返，更早位置使用本章规范页起点。
- 阅读菜单、完整排版控制、前灯入口、目录/详情/换源/重取本章/书架/小票/回顾/插件设置/双向模式切换回调。外部入口只有传入 callback 后才显示，最终集成必须提供用户要求的所有 callback。
- Leko 原版动画（设备原生或软件分条）、跨章黑白净屏、Swipe 擦除渐显、关闭；Swipe 刷新 UI/Fast 与横竖帧延时可调。动画局部运行，不替换全局 UIManager/Screen。
- settings 读取已有五个 reader_corner_* 与 progress_bar_*；第一期背景准备函数的输出可直接绘制；标题通过 alpha-mask 保留背景；透明小票仍由 Presenter 覆盖该页面。

## 构造接口

```lua
local Reader = require('legado.ui.leko_reader')
local widget, err = Reader.new{
    book = book,                       -- { id, name/title, author }
    chapter = chapter,                 -- { uid, title, url }
    index = chapter_index, count = #chapters,
    catalog_complete = complete,       -- false 时全书比例为 nil
    body = cleaned_cached_html,
    settings = app.settings,           -- 只读取；核心不直接保存 settings/style/progress
    style = progress.immersive_style,
    position = progress.immersive_position,
    fraction = fallback_fraction,
    background = prepared_path,        -- 可省略，见下文
    callbacks = callbacks,
}
if not widget then return nil, err end
-- ready 由 adapter 负责；构建成功前不要关闭旧阅读页。
UIManager:show(widget)
```

返回的是实际 widget，不是 ReaderSession proxy。Adapter 可持有它并把以下中立 API 接给 Session。

| 方法 | 返回/效果 |
| --- | --- |
| `getPosition()` | `{chapter_uid, paragraph, char, content_checksum}`；同章 UID 和原 HTML checksum 匹配、段落/字符均为有效范围内整数才使用精确游标；损坏的游标回退 fraction |
| `getProgressFraction()` | 0～1 的本章字符位置比例，基于页面起点 |
| `setProgressFraction(fraction)` | `true` 或 `nil,error`；0～1，1 会在异步分页结束后对齐到最后一页 |
| `getReaderSettings()` | 当前独立排版的浅拷贝，不能放入原 native `reader_settings` 覆盖原生设置 |
| `getReadingContext()` | book/chapter 名称、章 index/count、真实已知章页码/页数、章 fraction、可用时全书估算及宿主派生数据 |
| `applyStyle(changes)` | 校验并预先构建新页；调用 style_changed；任一步失败保留旧页/样式 |
| `refreshAppearance()` | 重新读 settings、准备背景、重排正文及重新计算页数 |
| `refreshBackground()` | 只重新准备背景，返回 true 或 nil,error |
| `nextPage()/previousPage()` | 同章翻页；到真实页边界时请求 chapter callback，不根据未知 total 猜边界 |
| `requestChapter(index,last_page,refresh)` | 委托宿主取章节；可选 refresh=true 标记重取本章；旧请求会取消，新的 is_current guard 随关闭/后续请求失效 |
| `animateEntry(direction,chapter_changed)` | `forward/backward`；**新页 show、旧页关闭后**调用，用于跨章/后端入场动画 |
| `showMenu()/showLayoutMenu()` | 显示真实 KOReader ButtonDialog；菜单含“关闭无感阅读”回调 |
| `runAction(name)` | 给外部页面的中立动作入口；暂停后调用宿主，失败恢复阅读 |
| `pauseReading(suspend)/resumeReading()` | 幂等暂停/恢复；普通覆盖操作保存失败则继续原阅读，物理休眠传 suspend=true，即使保存失败也停止计时 |
| `flushProgress()` | 委托 flush callback，核心不写盘 |
| `close()` | 先 flush；失败不关闭。成功取消任务/动画/弹层、释放控件并 close callback 一次 |

关闭后位置、fraction 和 context 的轻量快照仍可查询，正文模型及页起点表已释放。`onCloseWidget` 强制销毁会执行 close callback；adapter 的此回调也必须保存最终位置，不能只依赖手动 `close()`。

## 回调约定

所有回调的第一个参数都是该 widget。普通回调返回 `false,error` 或 `nil,error` 表示失败；无返回值表示操作已接收。核心通过 pcall 接错误并报告 `error` 回调。

```lua
local callbacks = {
    page_changed = function(view, page, total)
        -- page/total 可为 nil。只有它们都是有效整数时传给原“剩余三页”预取规则。
        -- 同时更新统计桥的字符进度；这不是 end_of_book 事件。
    end,
    chapter = function(view, index, request)
        -- request.last_page: 上一章末页；request.is_current(): 前景请求是否仍然有效。
        -- 返回可选 { cancel = function(self) ... end } 或 nil,error。
        -- 构建目标后在 ready 包装中 show 排队，再提交 Session，关闭旧 widget、setDirty 新、animateEntry。
    end,
    flush = function(view) return persist(view:getPosition(), view:getProgressFraction(), view:getReaderSettings()) end,
    close = function(view) -- 保存最终状态并通知 Session；不要自动打开书架，跨章也会 close。
    end,
    pause = function(view, suspend) -- ReaderSession 暂停计时；suspend=true 表示物理休眠。
    end,
    resume = function(view) -- ReaderSession 恢复计时；统计桥 resume。
    end,
    style_changed = function(view, style) -- 接收待保存样式，成功才切换视图。
        return persist_style(style)
    end,
    toggle_reader = function(view) -- 保存 fraction，成功打开 ReaderUI 后再关闭本 view。
    end,
    toc = function(view) -- 打开现 App 目录；返回时调用 view:resumeReading()。
    end,
    settings = function(view) -- 插件设置；变更后 refreshAppearance，返回 resumeReading。
    end,
    bookshelf = function(view) -- 退出流程可显示未入架试读选择，再 close 并回书架。
    end,
    receipt = function(view) -- 先 flush，原小票显示当前 getReadingContext；返回 resumeReading。
    end,
    review = function(view) end,
    book_info = function(view) end,
    sources = function(view) end,
    refresh = function(view) -- 显式强制获取当前章，失败保留旧页。
    end,
    add_to_shelf = function(view) end, -- 仅未入架时提供该回调
    end_of_book = function(view) end, -- 已知完整目录最后一章的最后一页继续翻
    error = function(view, err) -- err.code/err.message，统一交 App 诊断和中文提示。
    end,
    context = function(view, base)
        -- 可返回以下附加字段；没有统计数据时不生成虚假剩余时间。
        return { reading_seconds = seconds, chapter_remaining = remaining_seconds,
            book_remaining = book_remaining_seconds, chapter_remaining_text = formatted_time,
            prefetch = {cached=cached_count,total=requested_count} }
    end,
}
```

`chapter` callback 同步完成并关闭 view 后才返回 handle 的情况也会立即取消该 handle。关闭/换章后迟到网络结果仍需使用 request.is_current 与 Session 原有 generation 双重校验。

原 native 适配器的 `read_settings` 回调与本 widget 的 style_changed 含义不同；保留原生设置独立字段，不能直接混用。Session ready/候选提交仍由主代理现有流程控制。本模块没有自带存储、BookService、HTTP 或原生统计 DB 写入。

## 背景与页眉页脚

`background` 接受第一期 `Background.prepare(settings)` 返回的屏幕尺寸图片路径、`function(view,bb,x,y)`，或有 `paintTo(bb,x,y)` 的对象。省略时若 `settings:get('reader_background')` 非空，会调用现 `legado.lib.reader_background.prepare`。设置变动与旋转后由 refreshAppearance 重新准备。路径解码失败保留上一次背景并交 error callback；清空设置恢复白底。

现 `reader_corner_tl/tc/tr/bl/br`、`progress_bar`、`progress_bar_mode/font_size/height` 直接读取。页眉与页脚分别使用 reader_header_font_size、reader_footer_font_size，默认均为 11 号；进度详情仍使用独立 progress_bar_font_size。独立 style 的 show_header/show_footer 是各区域总开关。进度未知时显示 `—/—`；完整目录未知时显示“目录加载中”。`context` 可提供剩余时间和真实预取状态；无数据时显示“时间待估算”。

## 原始来源与许可证（待主代理纳入最终 notices 和包清单）

| 本地新增模块 | 原始文件/修改摘要 | 原许可 |
| --- | --- | --- |
| `leko_paginator.lua` | Leko `Paginator.lua`；内联 `ReaderMargins.lua`；去除 BookService 与原局部上一页启发式，直接读取已传入 model；页眉页脚高度适配本插件 | AGPL-3.0-or-later |
| `leko_text.lua` | Leko `Util.lua` 的 UTF-8 窗口与位置函数；新 HTML 段落适配使用原 Safe entity decoder；验证编码/图片边界 | AGPL-3.0-or-later 派生 |
| `leko_reader.lua` | Leko `ReaderView.lua` 阅读布局/操作理念及文本绘制；删除双业务层，新增现插件 callback、背景遮罩、分批章节页索引、按书 style 接口 | AGPL-3.0-or-later 派生 |
| `leko_font_selection.lua` | Leko `FontSelectionView.lua`，保留字体/路径/face 选择，中文样式名，修正返回回调 | AGPL-3.0-or-later |
| `leko_native_swipe.lua` | Leko `SwipeAnimation.lua`，命名空间与来源注释 | AGPL-3.0-or-later |
| `leko_chapter_wave.lua` | Leko `ChapterWaveRefresh.lua`，命名空间与来源注释 | AGPL-3.0-or-later |
| `leko_animation.lua` | Leko `SwipeRefresh.lua` + Swipe `2-swipe-animation-core.lua` 的分条边界/擦除逻辑；去掉全局 hooks、ReaderUI 检测和阻塞 usleep，加入真实可选分支与调节参数 | Leko AGPL-3.0-or-later + Swipe GPLv3 |
| `leko_reader_ui.lua` | 本插件新增的 Session proxy；读 payload，转换事件与生命周期，构建和显示职责分开 | 本项目 AGPL-3.0-or-later |

Leko 固定提交 `57dff8958dd43a5d95cb2dac22ca363d874de29b`（v0.16.0）；Swipe 固定提交 `59dce480c38538976325f7ebc0831e36bc4c6ed4`（v4.3）。须把 `.tools/leko-reader/LICENSE` 与 `.tools/swipe-animation/LICENSE` 原文纳入插件随包许可，追加作者/来源/修改表；Swipe README 作者为 `xhs:5699990012`、nuku、Echoes、小红薯6809667F、斯普特尼克的漫游。根项目仍按当前 AGPLv3 方案发布，组合中不删除 GPL 原文。无 QuickJS 二进制依赖。

额外宿主模块 `fontlist` 已确认存在于固定 KOReader v2026.07.1 的 `frontend/fontlist.lua`。最终 `check_koreader_compat.py` 需要归类该模块；本核心直接使用此真实模块，已删除上游不存在于该基线的 `ui/fontlist` 备用路径。

## 限制与验收边界

- 阅读器实现 Leko 的纯文字分页。含 `<img>` 的章节明确返回 `UNSUPPORTED_CONTENT`，不自动退回 ReaderUI、不静默删图；adapter 保留旧阅读页并提示用户手动关闭无感阅读。链接正文保留，内文链接/选择词典/批注不是 Leko 原阅读器已有能力。
- 插件与 KOReader 统计桥、书架试读保存、完整目录、背景设置菜单和实际双向切换由主代理接入；这些 callback 必须完整提供后才算第三期完成。核心不会自行创建 DB 或把虚拟统计单位当作章页数。
- 总页数通过真实分页逐步计算，极长章节计算总耗时仍与章长成比例；首屏和翻页不等待它。当前章页起点占用线性内存，章节大小限 8 MB；需要实机测大章与大字号内存峰值。
- 测试使用真实 KOReader 控件代码，字体/显示/调度平台层由 Windows harness 代替。XText 分支验证的是索引接口，字体渲染质量、波形完成、残影、触屏延时和耗电仍须 KPW6 验收。

专项命令：

```powershell
.tools/python/python.exe scripts/run_lua_specs.py --spec spec/phase3/leko_paginator_spec.lua --spec spec/phase3/leko_reader_core_spec.lua --spec spec/phase3/leko_font_spec.lua --spec spec/phase3/leko_animation_spec.lua --spec spec/phase3/leko_adapter_spec.lua
```

本轮已覆盖：转换/编码拒绝、长段落覆盖、真实分页边界、XText 与 RenderText 接口、不同边距、真实按钮/排版弹层、前后章、未知总页数、暂停/关闭/迟到 handle、样式保存失败、TTC face、缺字体恢复、透明背景标题、旋转重排、原版原生动画/软件擦除/跨章波形、关闭不分配、取消与缓冲单次释放。没有运行长全量测试，也没有声称完整应用或 Kindle 已验收。

2026-09-15 最终本机验证：上述 5 个专项规格通过，合计 **799 断言**（分页 28、阅读核心 57、字体 7、动画 615、适配器 92）。末轮先复现非法存档游标导致恢复失败，再验证 NaN、无穷值、小数、零和越界段落/字符均回退已保存的 fraction，合法精确游标优先。8 个暂存模块与 6 个专项文件共 **14 个 Lua 文件**通过 LuaJIT `loadfile` 语法和行尾空白检查；8 个模块均有来源注释，无 ReaderUI import，没有全局 UIManager/Screen 替换或阻塞 usleep。

## Session proxy：最终公开约定

本次三种方案比较：① 独立 proxy 负责构建，生产 owner 管理显示替换，Session 负责提交，与现有候选事务一致；② 低层独立适配器同时提交会话并关闭旧页，容易双重提交/关闭；③ 新增单独切换协调层，会增加无必要的状态与依赖。采用方案①；另补齐统计菜单、重取请求标记、暂停保存失败阻止外部动作及构造失败资源释放。

```lua
local Adapter = require('legado.lib.leko_reader_ui')
local proxy, err = Adapter.open(owner, {
    state = candidate, -- {book, chapters, index, catalog_complete, restore_fraction?}
    body = cleaned_html,
    progress = saved_or_pending_progress,
    background = prepared_background, -- optional
}, callbacks)
```

`owner.settings`、可选 `owner.ui_manager` 传给真实独立控件。只读 payload.progress 的 `immersive_style`、`immersive_position` 和 `fraction`，不自行读写 Storage。未显式指定 state.restore_fraction 时，使用合法精确游标；其失效时只在 progress.chapter_uid 与目标章相同才使用 progress.fraction。显式 state.restore_fraction 用于模式切换，优先于旧精确游标。

这里的 `open` 指低层 `leko_reader_ui.open`：先完整构建 widget 并绑定 proxy 方法，再调用 callbacks.ready(proxy)。ready 抛错、返回 false 或携带 error 时，释放候选，调用 failure(err) 一次，返回 nil,error。尚未接受的候选不触发 Session flush/close，也不调用 owner.on_exit。构造失败不操作旧页。ready 无返回值按接受处理。低层不直接 show、不关闭 previous，也不设置 owner.current_document。生产 `koreader_reader_ui:openChapter` 包装 ready，先 show 候选排队，成功后才调用 Session ready；详见下文最终顺序。

| Proxy 字段/方法 | 约定 |
| --- | --- |
| `backend`, `is_legado_document` | `'immersive'`, `true` |
| `widget` | 实际独立阅读控件；没有伪造 `reader` 字段 |
| `book`, `reading_state`, `closed` | 书籍、传入候选、关闭状态 |
| `reading_settings_key` | `'immersive_style'`，Session 保存排版时使用此字段 |
| `restored_on_open` | `true`，Session 必须跳过第二次 setProgressFraction，防止覆盖精确游标 |
| `getPosition/getProgressFraction/setProgressFraction/getReaderSettings` | 转交核心的真实位置与独立排版 API |
| `getReadingContext` | 真实章页数/进度和宿主 context；实时使用 candidate 的章节数/目录完整标记 |
| `getPagePosition` | 返回 page,total；未知值为 nil；关闭后 nil |
| `flushProgress/close/pauseReading/resumeReading` | 转交核心；关闭先保存，失败保留可读状态，幂等；关闭当前 proxy 才清 owner.current_document |
| `refreshAppearance` | 同步目录元数据、重读背景/页眉页脚并重排；关闭后 false |
| `chrome:refresh()` | 仅调用 proxy:refreshAppearance()，供现设置调用点过渡；新代码优先中立方法 |
| `animateEntry/requestChapter/runAction/showMenu` | 转交核心对应方法 |

`callbacks.ready(proxy)`、`flush(proxy)`、`pause(proxy,suspend)`、`resume(proxy)`、`close(proxy)`、`end_of_book(proxy)`、`page_update(proxy,page,total)` 沿用 Session 约定；`failure(err)` 仅用于打开失败。构造期间、ready 内恢复位置时的页变化先暂存最新值，ready 成功后发布一次；未知页数仍为 nil。运行时错误可由 `error(proxy,err)` 接 App 诊断，不能使用 failure 回滚一个已经正常阅读的会话。普通 pause 保存失败时控件与 Session 均继续计时；物理 Suspend 保存失败仍暂停两者，保留待写进度，唤醒后重试不计入睡眠时长。

新增回调签名为 `save_style(style)`、`chapter(index,request)`、`refresh(request)`，这些回调不额外传 proxy。style 保存未接入时拒绝样式变更。chapter/refresh 的 request 含 `last_page`、`refresh`、`is_current()`；两类请求共用 generation 与 handle 取消边界。可选 `context(proxy,base)` 返回统计/剩余时间/预取字段，与前文核心约定一致。callback 返回 false 或 nil,error 表示失败；成功无返回值也允许。

| 核心动作 | Owner 回调（统一传 proxy） |
| --- | --- |
| toc / settings / bookshelf | on_toc / on_settings / on_exit |
| receipt / review / sources | on_receipt / on_review / on_source_sites |
| statistics / toggle_reader | on_statistics / on_toggle_reader |
| book_info / add_to_shelf | on_book_info / on_add_to_shelf |

显式 bookshelf 才执行 on_exit；普通 close、换章关闭和失败清理不自动回书架。所有覆盖页关闭后由 owner 调用 proxy:resumeReading()。

### 显示切换与实测边界

最终顺序是在同一 UI 事件内 `构建/绑定 proxy → 包装 ready 中 show(new.widget) 排队 → Session ready 校验与 before_commit → owner.current_document=new → old:close() → setDirty(new.widget,'ui') → new:animateEntry(direction,chapter_changed)`。不要在步骤间调度或让出事件。show 抛错时尚未提交会话/模式；Session ready 或 before_commit 拒绝时，低层适配器关闭刚排队的候选，旧阅读页仍保留。此前“先 Session ready，再 show”的顺序已替换，因为显示失败会留下已提交但未显示的候选。

专项提取并执行固定 KOReader v2026.07.1 的真实 `UIManager.show/close` 函数：新全屏 widget 在关闭旧页时始终覆盖 FileManager；旧动画 cancel 没有任何屏幕刷新；真实 close 触发 FlushSettings 后不会重复 final flush；旧 close 不会清空刚提交的新 owner。独立 Session 规格还执行真实 `ReaderUI.doShowReader/saveSettings/onClose/onCloseWidget`，只替代文档引擎/构造和平台 IO。软件测试不能证明 Kindle 无可见闪帧或波形残影。

额外故障回归确认：背景设置在正文缓冲分配后抛错，候选构造失败并逐一释放已分配缓冲；暂停/保存失败不继续执行 owner 外部动作；完整目录后续加载时独立正文页脚也更新全书进度，无需先从 proxy 查询一次；chapter 返回 false 正确报告失败，已取消的 handle 立即清空，后续失败重试不重复取消旧 handle。

## 独立集成审计冻结结果

2026-09-15：只读审计 Session 与生产 owner 的新增路由和双向切换，由主任务修改运行代码，本审计仅新增/补充规格。`spec/phase3_session_spec.lua` **108 个断言通过**；连同前述 5 个核心专项合计 **6 项规格、907 断言通过**。

覆盖真实运行目录加载、首次/前后章/目录跳转/重新实例化 Storage 与 Session、连续换源两套排版各自保存、双向模式切换和精确位置、两方向 before_commit 拒绝、保存与构造/显示失败保留旧页、迟到网络和原生启动、离线换章与重取不联网、关闭释放 owner/计时任务。审计发现并回归验证了换源丢原生排版、Session 关闭遗留控件、上一章只显示最后一个字、暂停保存失败错停计时、show 异常遗留候选五处问题，均已修复。

context 专项确认预取从 0/2 到 2/2 来自真实请求/缓存状态，查询与页脚绘制不读取 Storage/cache；不足 10 秒不估算。实际阅读 12 秒、前进 50% 时估余 12 秒，暂停 10 分钟不增加阅读时长或估算，恢复 8 秒后累计 20 秒。物理休眠遇存盘失败仍暂停两端，待写的休眠前 5 秒和恢复后 7 秒成功重试后累计 32 秒，睡眠 10 分钟被排除。

运行集成规格：`.tools/python/python.exe scripts/run_lua_specs.py --spec spec/phase3_session_spec.lua`。尚未包含完整 App 设置持久化、真实网络、SQLite 原生统计库和 Kindle 物理验收；这些结果由主任务统一报告。
