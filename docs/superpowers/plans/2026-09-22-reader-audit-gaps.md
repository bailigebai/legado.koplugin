# 阅读功能审计缺口 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 补齐审计确认的完整目录后台加载、统一目录分页和书架批量分类，并保持首章启动与既有阅读数据不变。

**Architecture:** 复用 `ReaderSession:loadCatalog` 的异步完整目录请求，不增加新的目录服务；详情目录与侧边目录都使用 15 章页大小；批量分类只在当前书架视图维护书籍 ID 选择集合，最终调用已有 `Storage:updateBooks` 一次性保存。

**Tech Stack:** Lua/LuaJIT、KOReader UI、现有 `run_lua_specs.py` 规格运行器。

**Spec:** `docs/reader-library-0.10.18.md` 与本次审计结论。

## Global Constraints

- 首章打开仍只准备前三章，完整目录请求必须在 6 秒后台启动。
- 目录请求失败时保留已有目录和阅读状态，不得冒泡退出 KOReader。
- 目录页固定 15 章，保留现有上一页、下一页、上/下 20 页和顺序切换。
- 批量分类不得限制书架数量，不得修改阅读进度、书源和缓存。
- 不新增依赖；所有异步回调必须受现有 generation/active 检查保护。

---

### Task 1: 后台完整目录加载

**Files:**
- Modify: `legado.koplugin/legado/lib/reader_session.lua:228-241`
- Test: `spec/phase1_prefetch_spec.lua`

**Interfaces:**
- Consumes: existing `ReaderSession:loadCatalog(state, callback, on_progress, options)`.
- Produces: delayed background call with no `max_chapters`, followed by existing prefetch on success.

- [x] **Step 1: Write the failing test** — record the options passed by the fixture catalog request after the 6-second background task and assert `max_chapters == nil`.
- [x] **Step 2: Run the focused spec** — ` .tools/python/python.exe scripts/run_lua_specs.py --spec spec/phase1_prefetch_spec.lua`; expected failure because current code passes a 24-chapter cap.
- [x] **Step 3: Implement the minimal change** — remove only the `max_chapters` option from `_scheduleBackgroundCatalog`; leave near-end bounded catalog expansion unchanged.
- [x] **Step 4: Run the focused spec again** — expected PASS.

### Task 2: 统一详情目录为 15 章

**Files:**
- Modify: `legado.koplugin/legado/ui/presenter.lua:1335-1363`
- Test: `spec/presenter_spec.lua` or a focused catalog assertion in `spec/compact_shelf_spec.lua`

**Interfaces:**
- Consumes: existing catalog view pagination and `LibraryScreen` `already_paginated` contract.
- Produces: `page_size = 15`; all existing navigation callbacks unchanged.

- [x] **Step 1: Write the failing test** — construct a 16-chapter catalog and assert the first rendered page contains 15 entries and the second contains 1.
- [x] **Step 2: Run the focused spec** — expected failure because the presenter currently renders 24 entries.
- [x] **Step 3: Change only the page-size constant** — set `local page_size = 15`; do not alter navigation semantics.
- [x] **Step 4: Run the focused spec again** — expected PASS.

### Task 3: 书架批量分类

**Files:**
- Modify: `legado.koplugin/legado/ui/presenter.lua:338-422, 453-494, 988-1028`
- Test: `spec/compact_shelf_spec.lua`

**Interfaces:**
- Consumes: `Shelf:page`, `Storage:updateBooks`, and existing `_editCategories(back, book)` UI.
- Produces: `view.batch_select`, `view.selected_books`, a “批量分类” action, selectable shelf tiles, and one category operation applied to all selected books.

- [x] **Step 1: Write the failing test** — enter batch mode, select two book IDs, open category editor, apply one category, and assert both stored books contain it.
- [x] **Step 2: Run the focused spec** — expected failure because the shelf has no batch action or selection state.
- [x] **Step 3: Implement minimal selection state** — prefix selected tiles with `✓`, toggle IDs in the view map, preserve selections across shelf pages, and add a single batch category action.
- [x] **Step 4: Reuse existing category validation** — make `_editCategories` accept an optional list; update each copied book and call `updateBooks` once. Empty selection shows an informational message.
- [x] **Step 5: Run the focused spec again** — expected PASS.

### Task 4: Documentation and release checks

**Files:**
- Modify: `README.md:33,52`
- Test: existing `spec/release_docs_spec.lua`

- [x] **Step 1: Correct the package filename to `legado.koplugin-v0.10.19.zip` and update the style count to 15.
- [x] **Step 2: Run full Lua specs, KOReader compatibility, sensitive scan, and package verification.
- [x] **Step 3: Build a new patch release package and record its SHA-256.

---
