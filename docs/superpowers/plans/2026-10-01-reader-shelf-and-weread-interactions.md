# 不亦阅乎 Reader and Shelf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完成已确认的墨水屏书架首页、三书架切换、阅读默认值、微信图片与随文评论、拖动选字，并在 Kindle 上验证与交付。

**Architecture:** 沿用 Presenter 和 LibraryScreen 的页面边界，不建立第二套书库。微信协议及图片资源归适配层处理，ReaderSession 只决定阅读后端和失败回滚，独立阅读器只消费已校验的评论标记和选择状态。

**Tech Stack:** Lua、KOReader 原生控件、现有 Lua spec runner、PowerShell 打包及 Kindle MTP 安装脚本。

**Spec:** `docs/superpowers/specs/2026-09-29-reader-ui-mode-image-selection-design.md`

## Global Constraints

- 目标设备 Kindle Paperwhite Signature Edition；先以 600×800 控件布局验算，再在设备实际分辨率验收。
- 首屏一大四小，主封面目标至少 230×320；第二页起每页十二本，三行四列。
- 三书架保持书源、本地、微信三种独立身份；微信账号切换不能复用旧账号数据或迟到回调。
- 无感阅读默认开启；无单书动画偏好的新书默认 `swipe_classic`，保留已有单书偏好。
- 微信含图片书自动原生阅读；图片离线可见，获取失败保留上一可读页面。
- 整本书评在详情外层，本章与段落评论在阅读内；只有核验原文位置后才绘制段落标记。
- 不新增运行依赖，不复制 Moon 实现，沿用原创 `assets/logo.svg`，触控目标至少 36 像素。

## Review Focus

- 长简介和五本书同时出现时，600×800 首页无溢出且简介可滚动：Task 1 的布局测试。
- 微信换号与离开书架后，旧页面按钮、封面和请求不得带回旧书：Task 2 的生命周期测试。
- 图片相对地址、非法域名、单图超限、离线缺图不应生成假成功的章节：Task 4 的缓存测试。
- HTML 标签、空白、多字节中文或原文版本差异不能把评论标在错段：Task 5 的范围映射测试。
- 拖动选区时不翻页，超 4000 字节不发送 AI：Task 6 的手势测试。

---

### Task 1: 首页主卡片和统一页面按钮

**Files:**
- Modify: `legado.koplugin/legado/ui/library_screen.lua`
- Modify: `legado.koplugin/legado/ui/presenter.lua`
- Test: `spec/native_library_screen_spec.lua`
- Test: `spec/phase3/detail_presentation_spec.lua`

**Interfaces:**
- Consumes: `LibraryScreen.new(options)` 的 `mode="shelf_hero"`、`hero_action`、现有详情和底部按钮参数。
- Produces: `screen.cells[1].cover` 至少 230×320、`screen.cells[1].intro_widget` 可滚动、首屏四本小封面完整显示；详情只突出一个阅读按钮。

- [ ] 写布局测试：长简介的全文仍在滚动控件内，主封面至少 230×320，`screen:getSize().h <= 800`，四本小封面及全部按钮可触达，第二页 3×4。
- [ ] 运行 `.tools\python\Scripts\python.exe scripts\run_lua_specs.py --spec spec/native_library_screen_spec.lua`，确认新断言先失败。
- [ ] 在 `library_screen.lua` 根据可用高度计算主卡和简介尺寸；调整 `presenter.lua` 的详情主要/次要按钮分组，不改页面数据职责。
- [ ] 运行本任务两个规格及 `scripts/check-koreader-compat.ps1 -Offline`，确认通过。
- [ ] 提交 `feat: enlarge shelf hero and simplify page actions`。

### Task 2: 三书架模式和返回上下文

**Files:**
- Modify: `legado.koplugin/legado/ui/presenter.lua`
- Modify: `legado.koplugin/legado/ui/bookshelf.lua`
- Modify: `legado.koplugin/legado/ui/weread.lua`
- Test: `spec/compact_shelf_spec.lua`
- Test: `spec/weread_shelf_ui_spec.lua`
- Test: `spec/weread_navigation_async_spec.lua`

**Interfaces:**
- Consumes: `Presenter:_shelf(view,page)`、`Presenter:_weread(view)` 和两种 `:page(page)` 的现有结果。
- Produces: `Presenter:_switchShelf(origin,mode)`，其中 `mode` 为 `sources|weread|local`；每个模式保存自己的页码和筛选，书架顶栏固定显示 `切换书架`。

- [ ] 写测试：书源→微信→本地→书源可直接切换；选中项可见；返回详情保持发起模式和页码；微信未登录仍显示扫码；换号或离页后旧回调无效。
- [ ] 运行三个规格，确认新断言先失败。
- [ ] 用现有 Presenter 控制器和异步代际检查接线，不合并三类书籍 ID；保留最近阅读时间排序，页码越界回到最后有效页。
- [ ] 运行三个规格和 `spec/library_async_spec.lua`，确认通过。
- [ ] 提交 `feat: add three-way shelf switcher`。

### Task 3: 阅读默认 Swipe 和逐书图片模式

**Files:**
- Modify: `legado.koplugin/legado/ui/leko_reader.lua`
- Modify: `legado.koplugin/legado/ui/app.lua`
- Modify: `legado.koplugin/legado/lib/reader_session.lua`
- Test: `spec/reader_entry_defaults_spec.lua`
- Test: `spec/weread_app_reading_spec.lua`
- Test: `spec/phase3/leko_ripple_spec.lua`

**Interfaces:**
- Consumes: `ReaderSession:resume(...)`、章节 `body` 和既有 `progress.immersive_style`。
- Produces: 单书进度中的 `contains_images` 标志；`<img>` 章节及该书以后章节走 native，纯文字书维持 immersive；已有动画偏好不被默认值覆盖。

- [ ] 写测试：新书 `swipe_classic`、已有 `side_ripple` 保留、首章及后续章见图自动 native、失败不前移进度、提示模式变更。
- [ ] 运行上述规格，确认新断言先失败。
- [ ] 在正文进入排版前检测图片；`reader_session.lua` 持久化逐书标志并切换后端，保留原章/进度。
- [ ] 运行上述规格和 `spec/phase3_session_spec.lua`，确认通过。
- [ ] 提交 `feat: use Swipe by default and native reader for image books`。

### Task 4: 微信章节图片安全缓存

**Files:**
- Create: `legado.koplugin/legado/lib/weread_images.lua`
- Modify: `legado.koplugin/legado/lib/weread_service.lua`
- Modify: `legado.koplugin/legado/lib/cache_store.lua`
- Modify: `legado.koplugin/legado/lib/reader_session.lua`
- Test: `spec/weread_image_cache_spec.lua`

**Interfaces:**
- Consumes: 当前章节 HTML、书/章 ID、微信客户端已校验的会话、现有缓存目录。
- Produces: `WereadImages:prepare(book_id, chapter_uid, html, callback)`，成功回传全本地化 HTML，失败回传可显示错误；缓存读取时校验图片存在和可解码格式。

- [ ] 写测试：相对和绝对图片地址落本地引用；重开离线可见；非法 scheme/host、超限、损坏、缺图或取消请求报错且不产生完成状态。
- [ ] 运行新规格，确认失败。
- [ ] 最小实现受信 HTTPS 地址解析、大小/数量上限、原子写入和 HTML 引用替换；请求只传必要会话数据，错误不记录凭据。
- [ ] 运行新规格、`spec/weread_reading_spec.lua` 和缓存规格，确认通过。
- [ ] 提交 `feat: cache WeRead chapter images for native reading`。

### Task 5: 当前章随文评论与原文位置校验

**Files:**
- Modify: `legado.koplugin/legado/lib/weread_client.lua`
- Modify: `legado.koplugin/legado/lib/weread_mapper.lua`
- Modify: `legado.koplugin/legado/lib/leko_text.lua`
- Modify: `legado.koplugin/legado/ui/presenter.lua`
- Modify: `legado.koplugin/legado/ui/leko_reader.lua`
- Test: `spec/weread_inline_comments_spec.lua`
- Test: `spec/weread_reviews_pagination_spec.lua`

**Interfaces:**
- Consumes: 当前账号、`bookId`、`chapterUid`、HTML 正文、远端原文摘要和 `range`。
- Produces: `Client:chapterComments(book_id,chapter_uid,callback)`；Mapper 仅在原文摘要与显示文字核验匹配时返回段落标记，失配评论仍进本章列表。

- [ ] 写测试：当前书/章请求、分页、无评论/离线/失效状态、迟到响应；HTML 标签/空白/中文定位和版本差异降级；详情整本书评仍在外层。
- [ ] 运行新规格，确认失败。
- [ ] 接官方划线/随文评论接口，映射章节位置和显示状态；将 `本章评论` 只挂微信阅读菜单，不阻断正文。
- [ ] 运行新规格、原有评论分页和微信导航规格，确认通过。
- [ ] 提交 `feat: show verified WeRead inline chapter comments`。

### Task 6: 独立阅读器拖动选字

**Files:**
- Modify: `legado.koplugin/legado/ui/leko_reader.lua`
- Test: `spec/phase3/leko_ai_hold_spec.lua`
- Test: `spec/ai_selection_ui_spec.lua`

**Interfaces:**
- Consumes: 当前页文字位置和现有 AI 回调。
- Produces: 选区 `anchor/focus` 状态；长按开始、拖动更新、显式 `AI 解释` 发送、取消/切章清除；原生阅读继续用 KOReader 自带划词。

- [ ] 写测试：字词选区、拖动扩展、高亮、取消、切章清除、普通滑动仍翻页、选择滑动不翻页、超 4000 字节拒发。
- [ ] 运行两个规格，确认新断言先失败。
- [ ] 在手势层实现选择状态与确认菜单，AI 密钥仍由现有服务管理。
- [ ] 运行两个规格和阅读器手势/翻页规格，确认通过。
- [ ] 提交 `feat: add drag text selection to immersive reader`。

### Task 7: 设备验收和安装包

**Files:**
- Modify: `docs/superpowers/specs/2026-09-29-reader-ui-mode-image-selection-design.md`（仅记录实机验收结果）
- Create: `docs/reader-ui-device-acceptance-2026-10-01.md`

**Interfaces:**
- Consumes: Tasks 1–6 的通过结果、已连接 Kindle、现有打包及安装脚本。
- Produces: 版本化 ZIP、设备插件文件读回比对、实际界面及微信账号可验证功能记录。

- [ ] 运行 `powershell -ExecutionPolicy Bypass -File scripts/run-specs.ps1` 及 `powershell -ExecutionPolicy Bypass -File scripts/check-koreader-compat.ps1 -Offline`。
- [ ] 在 Kindle 走书架三模式、600×800/实际屏幕布局、扫码、评论、图片章、离线重开、选字和翻页；记录无法使用真实账号验证的项。
- [ ] 运行现有打包脚本，核对 ZIP 清单，安装设备并读回比对；使用现有项目发布流程同步 ZIP 和 GitHub 版本。
- [ ] 记录版本、commit、测试计数、设备验证证据和剩余限制，提交交付记录。
