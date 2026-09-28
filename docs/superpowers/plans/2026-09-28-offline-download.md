# Offline Download Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将插件显示名改为“不亦阅乎”，支持书源整书章节缓存与现有 EPUB 导出，并显示下载进度和封面完成标记。

**Architecture:** 现有 `DownloadManager` 增加缓存任务类型，复用持久化队列；独立 `CacheStore` 存放不自动清理的离线正文。`ReaderSession` 优先读取离线缓存，书架依据完整任务与完整目录给出标记。

**Tech Stack:** Lua 5.1/LuaJIT、KOReader 原生控件、现有 Lupa 规格测试。

**Spec:** `docs/superpowers/specs/2026-09-28-offline-download-design.md`

## Global Constraints

- 保留 `legado.koplugin`、内部插件名、数据目录和授权身份。
- 不增加运行依赖，不删除或搬迁旧缓存；目录变更在重启 KOReader 后生效。
- 缓存完成不得使用部分目录、未成功写入正文或不可下载章节冒充。
- 不发布、不清理用户设备数据；自动测试不能替代 Kindle 实机验收。

## Review Focus

- 书源目录只加载一部分时不得显示已下载。
- 同名不同书源不得共享标记或正文。
- 已下载目录在设置切换后不得显示错误标记。
- 缓存写入中断、任务重启和 EPUB 旧记录不得互相覆盖。
- 目录不可写或部分章节请求失败时必须保留可重试状态。

## 2026-09-28 执行记录

名称、目录设置、双类型下载任务、离线阅读、书架标记和独立下载页均已实现，并同步到用户指定的源码目录。专项测试在该目录以 Windows 短路径运行，12 项、479 个断言通过；本地开发包校验通过（130 个条目）。完整 Lua 集合中 114 项通过，41 项因缺少 KOReader 宿主源码或旧书源样本未能运行；GitHub 连接失败，暂不能补齐官方宿主测试。Kindle 触控、目录权限和实际断网阅读留待设备验收。正式发布未进行。

---

### Task 1: 显示名称与目录设置

**Files:** `legado.koplugin/_meta.lua`, `main.lua`, `legado/ui/about.lua`, `legado/lib/koreader_reader_ui.lua`, `legado/lib/settings.lua`, `legado/ui/settings.lua`, `legado/ui/presenter.lua`; tests `spec/meta_spec.lua`, `spec/native_menu_startup_spec.lua`, `spec/settings_recovery_ui_spec.lua`.

**Interfaces:** `download_cache_dir` 是空字符串或设备绝对目录。`SettingsView:set("download_cache_dir", path)` 在写入前验证，界面说明重启生效。

- [ ] 写名称、目录持久化和非法路径的失败规格，运行确认失败。
- [ ] 实现最小显示文字与设置输入，运行专项规格确认通过。
- [ ] 运行受影响 UI 和设置规格，检查没有更改内部标识。

### Task 2: 缓存任务与现有 EPUB 共存

**Files:** `legado/lib/download_manager.lua`, `legado/ui/bootstrap.lua`, `legado/ui/book_detail.lua`, `legado/ui/app.lua`, `legado/ui/presenter.lua`; tests `spec/download_manager_spec.lua`, `spec/download_ui_spec.lua`.

**Interfaces:** `DownloadManager:enqueueCache(book)` 创建 `kind="cache"` 任务；旧 `enqueue(book)` 继续导出 EPUB；`DownloadManager:isCached(book)` 只在任务完成且完整目录属于当前专用缓存时为真。

- [ ] 写缓存任务完整目录、逐章进度、VIP/失败/取消/重试、旧 EPUB 记录的失败规格。
- [ ] 运行专项确认缺少新行为，再以最小分支复用现有下载队列。
- [ ] 在详情页加入“缓存整本”和明确的 EPUB 导出操作，专项及现有下载规格通过。

### Task 3: 离线阅读与书架标记

**Files:** `legado/lib/reader_session.lua`, `legado/ui/bookshelf.lua`, `legado/ui/library_screen.lua`, `legado/ui/app.lua`, `legado/ui/presenter.lua`; tests `spec/reading_cache_spec.lua`, `spec/library_screen_spec.lua` 或现有对应规格。

**Interfaces:** `ReaderSession.new({offline_cache=...})` 优先读离线正文/完整目录；`Shelf.new({is_cached=function(book) ... end})` 向封面 item 添加 `downloaded=true`。

- [ ] 写断网正文、切源、目录缺失和仅真正完成显示标记的失败规格。
- [ ] 实现阅读回退与封面右下角小标记；在无封面占位时也清楚显示。
- [ ] 运行阅读、书架与原生 UI 专项规格。

### Task 4: 下载页、回归和交付

**Files:** `legado/ui/downloads.lua`, `legado/ui/presenter.lua`, `README.md`, 新增功能验收说明；tests `spec/download_ui_spec.lua` 与受影响规格。

- [ ] 写任务类型、百分比、独立下载页刷新和完成状态的失败规格。
- [ ] 实现并运行专项；明确缓存目录变更、EPUB 操作和离线验收步骤。
- [ ] 运行全量 Lua、官方 KOReader 兼容和打包检查；检查 `git diff` 与 `git status`，记录实际证据及实机未验证项。
