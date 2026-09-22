# 后三章准备与跨章延迟优化计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 初稿已获用户“B方案”批准。实施状态见文末和本版验收文档。

**Goal:** 当前阅读第 N 章时准备 N+1、N+2、N+3 的完整正文和可复用排版，让准备命中的跨章接近普通翻页，找出并消除当前 3–4 秒额外停顿。

**Architecture:** 复用 ReaderSession、RequestEngine、CacheStore 和现有分页器。在共享读取流程维护滚动三章准备窗口；无感阅读复用活动阅读窗口，先准备下一章候选状态再一次性切换。原生 KOReader 的逐章文档打开单独测量，必要时升级为连续文档方案，不把两种模式混作同一性能承诺。

**Tech Stack:** Lua/LuaJIT、KOReader v2026.07.1、现有子进程 HTTP、Leko 派生分页器；不新增依赖。

**Spec:** 本任务用户要求：分析“没提前加载”与“跨章阅读器响应慢”，提供优化计划，提前做好后三章，翻页/跨章平滑衔接。当前阅读模式尚未得到用户确认，方案分别覆盖无感和原生。

## 约束与事实边界

- 以当前工作区 v0.10.9 代码为准；Kindle 实际安装版本、有效预取设置和实际 backend 尚未读取。
- 只做与跨章相关的最小修改；不碰授权、默认书源、书架、现有阅读数据和其他插件。
- 不降低正文完整性、缓存校验、进度保存和失败回滚要求，不以跳章、假页或纯等待动画冒充完成。
- 默认目标 N+1..N+3，预取设置 0 仍明确关闭自动预读；原有手动 1..10 配置保留，内存预排版最多三章。
- 完整正文继续使用当前 4 MiB 总量上限和 20 个网页分页上限；分页解析失败不标记为准备完成。
- 目录和准备进度界面最多每 6 秒更新；这是显示节流，不能阻止目录或正文任务立即启动。
- 最多预热下一章一页的绘制资源，其余只存文本和分页索引，不创建三个活动阅读窗口，不常驻三章全部位图。
- 物理墨水屏刷新不等于软件提交。所有性能数字是待实机验证的验收目标，不是当前结果。
- 当前没有可用 Kindle，只有 9 月 14 日及更早日志，没有本版跨章计时；不能给 3–4 秒编造耗时占比。

## 已确认的代码原因

| 检查项 | 当前行为与证据 | 对症状的影响 |
| --- | --- | --- |
| 预读触发 | `reader_session.lua:_schedulePrefetch` 在当前章提交后 scheduleIn(0) | 不是一直等剩三页；重做触发器不是充分修复 |
| 三章请求 | `_prefetch` 仅一个 `prefetch_request`，前章 callback 完成才 step 到后章 | 设置 3 表示最多顺序准备三章，不代表三章已同时就绪；慢章会推迟后续章 |
| 目录不足 | 只在“连下一章也没有”时立即补目录；`_scheduleBackgroundCatalog` 固定延后 6 秒 | 初始目录 1..3、正在读 1 时只能准备 2、3；准备第 4 章要等补目录 |
| 无感预排版 | 仅 `index == state.index+1` 调用 prepareChapter；Reader.prepare 返回 model 和首个 page | 后二章只有正文缓存，下一章也没有完整分页索引或现成绘制控件 |
| 无感切章 | Adapter.open 每次 Reader.new、validatePaint，随后替换旧 widget；animateEntry 又调用 _setPage | 已下载且首屏排版命中仍有对象创建、绘制验证和第二次正文控件构造 |
| 无感后台工作 | `_startPagination` 每批计算 4 页，使用主 UI 调度 | 后台是分时执行，并非另一个 CPU 线程；一批太重仍可占用输入时间 |
| 原生切章 | Adapter.openDocument 调用 ReaderUI.showReader；官方 doShowReader 关闭旧实例，openDocument、ReaderUI:new | HTML 已缓存也要重新打开引擎、读取设置和渲染，下载预读无法消除这部分 |
| 跨章动画 | 默认允许跨章净屏；wave 分段调用 refreshUI；Kindle 驱动会等待前次更新提交 | 是设备侧耗时嫌疑，需要开/关动画实测，尚未证明它占几秒 |
| 计时缺口 | reader_ready 从候选打开阶段计时，发生在实际显示与进入动画完成之前 | 不包含此前缓存读取/保存耗时，也不能代表触摸到首屏可见总延迟 |

本轮在宿主运行生产代码、替换平台 IO 的临时诊断：

```json
{
  "partial_catalog_1_to_3": {
    "initial_content_requests": 1,
    "after_two_responses_cached": 2,
    "catalog_requests_before_timer": 0,
    "catalog_timer_seconds": 6,
    "next_request_after_catalog": "c4"
  },
  "prepared_immersive_chapter": {
    "parse_calls_on_open": 0,
    "first_page_pagination_calls_on_open": 0,
    "full_pagination_index_prepared": false,
    "new_widget_on_open": true,
    "extra_widget_rebuild_at_entry": 1,
    "mock_text_widgets_before_after_entry": [20, 32]
  }
}
```

这些是调度/调用次数证据，不是 Kindle 毫秒性能测量。完整记录在 `.tools/chapter-latency-analysis-20260916.json`。现有相关规格 5 组、394 断言通过，说明现有状态流程符合旧测试，但没有证明跨章速度合格。

## 三个方案

| 方案 | 做法 | 成本与结论 |
| --- | --- | --- |
| A 只完善三章正文预读 | 补齐短目录、提前下载 N+1..N+3 | 最小，但仍保留新建页面/打开原生文档，不能满足本次“消除额外跨章停顿”目标 |
| B 三章准备 + 复用无感阅读窗口（推荐） | 完整正文缓存、解析模型、首屏及分页索引分时准备；复用现有窗口/时钟/背景，提交候选章节；去重复绘制 | 能直接消除已经确认的无感切章重复工作；涉及会话与窗口交接，需要完整回滚测试；原生模式共享下载收益，仍单独测引擎成本 |
| C 原生连续文档 | 将多章放进同一个 KOReader 文档，使文档内章节跳转不必再次开引擎 | 若用户主要用原生并坚持跨章等同翻页，需要该方向；目录映射、分页/统计/进度及文档补充机制更复杂。仅合并三章仍会每三章卡一次，不能视作完成，先证明运行中文档扩展可行 |

推荐先执行 B 的共享准备与无感路径，原生做同样的分段测量。如果用户使用原生且开引擎占主耗时，先拿 C 的可行性实验和维护成本评审，不继续堆下载补丁或擅自切换其阅读模式。

## 任务 1：先测量完整一次跨章

**文件：** `reader_session.lua`、`leko_reader_ui.lua`、`koreader_reader_ui.lua`、`ui/leko_reader.lua`、`ui/bootstrap.lua`；测试扩展 `spec/phase1_prefetch_spec.lua`、`spec/phase3_session_spec.lua`。

**接口：** 复用 `ReaderSession:_timing(stage, started, backend)` 和现有 timing 回调。为一次跨章附加单调递增 attempt_id，使用同一单调时间源；事件只记录序号、模式、缓存/排版状态、耗时，不记录书名、网址、正文或密钥。

- [ ] 先记录触摸/按键处理入口、目录条目就绪、正文状态（未开始/排队/下载/缓存）、完整正文读入、进度保存、排版复用/重做、窗口切换/引擎就绪、首次绘制提交、动画提交结束、后台单批耗时。
- [ ] 给 reader_ready 明确含义，不能将其当 total。普通翻页同样记录输入到提交，形成可比较基线。
- [ ] 同一本书/同字号按冷缓存、热缓存断网、动画关闭、动画开启四组各 30 次；两种 backend 分开，不混算 P50/P95。
- [ ] 核验实际安装版本和有效预取值。使用现成真实书源正文缓存做断网对照，不需要为了性能测量重复查询 919 站点。
- [ ] 未命中拆分为目录不足、排队、下载未完、解析失败、写盘失败、正文失效或排版失效；UI 已就绪但屏幕仍慢则查刷新提交/设备日志。

示例检验（沿用现有 fixture）：

```lua
local events = {}
f.session.timing = function(metric) events[#events + 1] = metric end
f.open(); f.scheduler:runNext(); f.finish(1, '<p>next</p>')
local requests_before = #f.requests
f.next()
eq(requests_before, #f.requests, 'hot chapter must not request network')
-- 扩展同一 fixture 记录各边界；total 从同一次输入开始，不能从 Reader.new 开始。
```

**验收：** 一次 3–4 秒等待能分解到具体阶段，冷/热缓存及动画差异可解释；诊断本身不频繁刷新屏幕。

## 任务 2：滚动补齐后三章完整内容

**文件：** `reader_session.lua`；必要时在 `request_engine.lua`/`book_service.lua` 的已有优先级接口补充取消/保留行为；测试 `phase1_prefetch_spec.lua`、`request_concurrency_spec.lua`、`catalog_startup_limit_spec.lua`。

**接口：** 将单个 `prefetch_request` 改为按书源/书籍/章节 UID 索引的在途表，仍由 Session 唯一持有。复用 `getContent(...,{priority=...})`、`handle:promote()` 和 cancel。前台读取同一 UID 时加入现有任务，不再发第二次 HTTP。

- [ ] 目录覆盖目标改为 `min(已知全书末尾, N+prefetchCount())`；只要已知目录不足目标且未完整，就立即增量补到目标。现有 6 秒规则仅限制进度显示。
- [ ] 当前章首屏提交后即补 N+1..N+3，不阻塞第一次进入阅读。读到 N+1 后保留已有 N+2/N+3，立即补 N+4。
- [ ] N+1 为最高后台优先级；使用当前请求引擎有界并发，后台最多占两个请求槽，总并发仍遵循原有 2/3 上限。连续网页分页按站点规则顺序完成，不能并发猜 URL。
- [ ] 发生前台缺章时提升同章在途任务优先级；远期预取不能占住所有可用槽让前台排队。不同章节失败互不拖住，仍遵守现有有限重试规则。
- [ ] 只有全部网页正文合并、清洗成功且缓存原子写入成功才标“正文完成”。分别记内容完成数与排版完成数。
- [ ] 换书、换源、退出、休眠取消不再需要的任务；同书切章保留新窗口内的任务。旧代次结果不能写进新书视图。

关键反例：

```lua
local f=fixture()
f.open({chapters[1],chapters[2],chapters[3]},1,{catalog_complete=false})
f.scheduler:runNext()
eq(1,#f.catalog_requests,'three-chapter window extends partial catalog immediately')
eq(0,f.scheduler.now_value,'catalog preparation does not wait for display throttle')
```

**验收：** 三章均完整缓存后断网能连续跨三章；快速连翻不重复下载；正文进度有真实状态，不把设置值 3 显示成完成 3。

## 任务 3：提前排版与复用无感阅读窗口

**文件：** `leko_reader_ui.lua`、`ui/leko_reader.lua`、`leko_paginator.lua`、`reader_session.lua`；测试 `spec/phase3/leko_reader_core_spec.lua`、`phase3_session_spec.lua`、`book_reader_settings_spec.lua`、`immersive_event_guard_spec.lua`。

**接口：** 保留并扩展 `Reader.prepare(options, previous)` 返回值（已有 key/layout_key/model/page，增加 page_starts 和 pagination_position/complete）；由 Adapter 保存三章准备记录。准备记录不持有活动窗口、回调或时钟。增加 `View:replaceChapter(options, prepared, commit)`，返回 true 或 nil,error；commit 由 Session 提供，只有候选验证、旧进度保存与提交均成功才替换可见状态。

- [ ] 先让 N+1 完成首屏，再准备 N+2/N+3 首屏；随后分时补齐三章分页索引。章节页数不是首屏前置条件，已准备的索引不能在切章后从第一页重新计算。
- [ ] 后台分页每次最多一页并受约 8 ms 软预算约束；记录超预算调用。若单页计算本身超预算则在段落/字符窗口边界拆分，不假称 scheduleIn 已提供线程隔离。
- [ ] 准备键包含书源、书籍、章节 UID、正文校验值、字体/字号、行距/边距、屏幕尺寸/方向、页眉页脚尺寸。字号/旋转变更只淘汰排版，正文保留；换源不能串用旧正文。
- [ ] 同书同模式切章沿用活动全屏窗口、事件绑定、时钟和背景。只创建候选正文页资源；保存和验证成功后替换章节状态，避免 Reader.new/关闭旧窗口的整套流程。
- [ ] 下一章首屏的正文控件只构造一次；validatePaint 和动画共用已准备结果，不能 animateEntry 再 _makeWidgets 一遍。先改这一确定重复点，再做窗口复用，分别有测试。
- [ ] 避免缓存命中时重复解析和多次整章哈希；在缓存入口保持完整校验，内存中传递不可变的已验证内容/版本，不关闭磁盘损坏检查。
- [ ] 前三章正文全部落盘；三章文本/索引采用有界准备缓存。当前活动模型之外，后台原始正文预算 8 MiB、最多三个模型，页起点总数 10000；超过预算先释放最远章排版，仍保留其完整磁盘正文，不伪报排版就绪。预算不是实际 Lua RSS 上限，实机需测峰值并据此调低。
- [ ] 回到上一章保留上一章末页位置；快速前后跨章不能等待整章重分页。失败保留当前正文和可操作菜单，不进入 FileManager。

关键回归接口检验：

```lua
local old_widget = current().widget
local prepared = assert(Reader.prepare(next_options))
local ok = old_widget:replaceChapter(next_options, prepared, function() return true end)
eq(true, ok, 'prepared candidate commits')
eq(old_widget, current().widget, 'same-book transition keeps the active reader window')
local old_uid = old_widget.chapter.uid
local failed = old_widget:replaceChapter(later_options, later_prepared,
    function() return nil,{code='STORAGE_ERROR'} end)
eq(nil, failed, 'failed commit rejects candidate')
eq(old_uid, old_widget.chapter.uid, 'failed commit preserves current chapter')
```

测试 fixture 应提供 next_options/later_options 和真实生产准备结果，覆盖同字重不同字体、内容更新、旋转、图片章降级、关闭后回调、重复点击、双重释放、索引末尾和章节序号一致性。

## 任务 4：显示与原生阅读边界

**文件：** `ui/leko_reader.lua`、`leko_animation.lua`、`leko_chapter_wave.lua`、`koreader_reader_ui.lua`；沿用动画规格与 `native_reading_flow_spec.lua`、`reader_startup_failure_spec.lua`。

- [ ] 把跨章单独净屏与普通翻页分别 A/B。准备命中时复用普通翻页刷新路径作为快速选项，不强迫每章走多段净屏；保留用户显式选择净屏的能力和稳定降级。
- [ ] 只有目标首屏已准备才启动动画；不以动画持续几秒掩盖等待。前后只提交必要刷新，顶部/底部统计不能附带全屏重画。
- [ ] 不移除 Kindle 驱动必要的提交同步，不直接并发操作 framebuffer；记录物理提交和软件排队耗时，避免新残影/崩溃。
- [ ] 原生正文/HTML 三章可提前准备，保存设置与统计去重，但保留每次必要的持久化和失败处理。先测 cache/progress/ReaderUI.open/render 各段。
- [ ] 如果原生开引擎仍超过目标，则停止声称 B 能达到原生无感。C 的独立小实验必须验证：同一 Document 内跨章、目录与章节进度映射、不中断阅读追加章节、全文增长后的重新分页成本、失败保留旧文档。不支持安全增量时明确报告，合并三章后每三章重开不是完整解决方案。

## 验收与实施顺序

| 条件 | 发布门槛 |
| --- | --- |
| 内容准备 | 当前首屏提交后首次调度即开始；N+1..N+3 全文完成，断网连续跨三章不请求网络 |
| 无感热准备跨章 | 同设备同字体 30 次以上，输入到首屏绘制提交 P95 目标 ≤200 ms；且比该设备普通翻页 P95 额外耗时 ≤100 ms |
| 物理显示 | 另用设备/录像测首屏可见，和普通翻页作对照；软件 200 ms 不代表墨水屏 200 ms |
| 原生模式 | 独立报告 P50/P95 和引擎占比；没有通过目标则报告差距/选择 C，不用无感模式数字代替 |
| 未准备完 | 150 ms 内有可取消的轻量提示，旧正文保留；不承诺网络尚未返回也能显示未取得的内容 |
| 后台输入 | 大章分页和三章预取中仍能翻页/开菜单；没有四页一批造成的秒级输入停顿 |
| 稳定性 | 500 次跨章、200 次菜单、50 次切模式与休眠/恢复；引用、任务、句柄无持续增长，错误路径不闪退 |
| 实机 | 两模式各至少 30 次跨章样本；弱网/断网、长章、快速连翻和旧进度恢复；没有新未处理错误/系统杀进程 |

顺序：测量 → 补齐三章 → 去重复构造 → 分时预排版 → 复用窗口 → 动画对照 → 原生可行性结论 → 独立审查 → 完整测试/可重现打包。每一步先补失败规格，再最小实现、定向检查；有新失败才扩大测试。

常规宿主检查：

```powershell
.tools/python/python.exe scripts/run_lua_specs.py --spec spec/phase1_prefetch_spec.lua --spec spec/phase3_session_spec.lua --spec spec/phase3/leko_reader_core_spec.lua --spec spec/request_concurrency_spec.lua --spec spec/native_reading_flow_spec.lua
powershell -ExecutionPolicy Bypass -File scripts/run-specs.ps1
powershell -ExecutionPolicy Bypass -File scripts/check-koreader-compat.ps1 -Offline
```

本计划初稿仅用于方案选择；用户已批准 B 并进入 v0.10.10 实施。实现、验证与设备边界见 [v0.10.10 验收文档](../../reader-library-0.10.10.md)。原生 C 未实施。不能把“宿主测试通过、预取值是 3”当作 Kindle 跨章延迟已经达标。
