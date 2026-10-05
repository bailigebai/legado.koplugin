# 无感阅读章末讨论 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在微信无感阅读章末展示本章热门想法与点赞数，支持展开、取消和重试。

**Architecture:** Client 只读取已验证的官方热门接口；Mapper 提取文字与点赞；独立 Discussions 控制器绑定账号、文档、书籍、章节。无感阅读器提供卡片与点击事件，App 和 Presenter 负责请求及弹窗。

**Tech Stack:** LuaJIT、现有异步请求、KOReader TextWidget 与 library_screen、Lupa 行为测试。

**Spec:** `docs/superpowers/specs/2026-10-03-weread-immersive-rich-reading.md`

## Global Constraints

- 都在无感阅读中完成；本阶段不增加原生模式入口。
- GET `/web/review/list`，`bookId`、`chapterUid`、`listType=8`、`listMode=3`；不发明网络分页。
- 当前接口包括随文想法，文案为“章节讨论 · 本章热门想法”。
- 固定预留约两行高度，异步返回不能覆盖正文或改变分页。
- 不发布未完成的整套功能；不提交会话、日志和真实书籍正文。

## Review Focus

- 切换账号/章节后的成功返回不得更新旧页或打开旧详情。
- HTTP 200 的 `{}` 不能被误认为暂无讨论。
- 缺少或非法点赞数显示未知，不能伪造为零或热门列表总赞。
- 横屏、大字号、正文占满末页时卡片不得盖住文字与页脚。
- 失败、离线、关闭弹窗与翻下一章不应留下请求、计时暂停或重分页。

---

### Task 1: 热门接口、映射与控制器

**Files:** 修改 `legado.koplugin/legado/lib/weread_client.lua`、`weread_mapper.lua`；新建 `weread_chapter_discussions.lua`；新建 `spec/weread_chapter_discussions_spec.lua`。

**Interfaces:** `Client:chapterDiscussions(book_id,chapter_uid,callback)` 返回可取消请求；`Mapper.chapterDiscussions(wire,book_id,chapter_uid)` 返回 `{id,content,abstract,author,likes_count,comments_count}` 列表；`Discussions.new{client,book_id,chapter_uid,is_current,on_change}` 提供 `current/load/cancelLoad/close`。

- [x] 写失败测试：精确 GET 参数、外层点赞、书/章过滤、未知点赞、空对象协议错误、取消/换账号/重试/同步回调。
- [x] 运行 `.tools/python/Scripts/python.exe scripts/run_lua_specs.py --spec spec/weread_chapter_discussions_spec.lua`，确认缺少新功能而失败。
- [x] 实现上述接口；一次最多 100 条，响应最大 512 KiB；加载后不自动分页，失败可重试。
- [x] 运行新测试及 `spec/weread_inline_comments_spec.lua`、`spec/weread_client_spec.lua`，期望全部通过。

### Task 2: 章末卡片、App 生命周期和详情

**Files:** 修改 `legado.koplugin/legado/ui/leko_reader.lua`、`legado/lib/leko_paginator.lua`、`legado/lib/leko_reader_ui.lua`、`legado/lib/koreader_reader_ui.lua`、`legado/lib/reader_session.lua`、`legado/ui/app.lua`、`legado/ui/bootstrap.lua`、`legado/ui/presenter.lua`；新建 `spec/weread_chapter_discussions_ui_spec.lua`。

**Interfaces:** `View:setChapterDiscussions(value)`、`View:getChapterDiscussionTarget()`；回调 `chapter_discussions` 打开详情、`chapter_end` 触发懒加载；`App:prepareChapterDiscussions(document)`、`App:openChapterDiscussions(document)`；`Presenter:showChapterDiscussions(discussions,document)`。

- [x] 写失败测试：末页卡片、无覆盖、点击不翻页、普通书源无入口；列表每条点赞、返回原页、离线状态、章/账号过期按键。
- [x] 运行新 UI 测试，确认因缺少接口失败。
- [x] 接入卡片与生命周期：读取不阻塞翻页；章末懒加载；关闭取消；详情只做本地已返回列表分页；缺字段提示失败，不报告空结果。
- [x] 运行新 UI 测试、已有评论 UI/阅读测试、无感阅读器及适配器测试。

补充测试：`spec/weread_discussions_lifecycle_spec.lua` 覆盖实际适配器的跨章取消/复用窗口；`spec/weread_discussions_close_spec.lua` 覆盖真实 LibraryScreen 延迟关闭间隙。

### Task 3: 审查与阶段记录

- [x] 运行完整 Lua 测试和官方 KOReader 兼容检查，确认真实输出。
- [x] 独立审查根因、边界与上述 Review Focus；修复必要问题。
- [x] 在规划书记录完成证据和剩余富文本/自动词条证据，不把阶段完成描述为整套目标完成。

结果：196 个 Lua 测试 /48,455 条断言；官方契约 12 个测试 /37,894 条断言与 SQLite 通过。审查的两项 Important 均失败到通过验证。真实设备/账号验收未完成；整体富文本与官方词条目标未完成，详见 Spec 的阶段记录。
