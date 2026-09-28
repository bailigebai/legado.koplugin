# 统一书架、微信读书与 AI 阅读 Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task. Each task has its own failing test, implementation and verification.

**Goal:** 在现有不亦阅乎插件中完成统一导航、微信读书、章节范围下载、AI 阅读解释和全插件缓存管理。

**Architecture:** 保留现有 App/Presenter/Shelf/ReaderSession/DownloadManager 的职责。新增微信读书适配层与 AI 服务层；UI 只调度功能并展示结果。所有账号凭据保持设备本地。

**Tech Stack:** KOReader Lua/LuaJIT、现有 SQLite/文件和异步 HTTP 抽象、项目 Lua 规格测试。

**Spec:** `docs/superpowers/specs/2026-09-28-unified-library-weread-ai-design.md`

## Global Constraints

- 使用简体中文、墨水屏可辨识的按钮和单色图标；不依赖外部运行时。
- 原有书源、书架、进度、离线下载和授权数据必须保留。
- API 密钥、微信会话和测试响应不得出现在日志、仓库或发布包中。
- 每个阶段先写失败测试、再实现、再运行相关规格；发布前做 KOReader 与设备验收。

## Review Focus

- 子页面返回时原书架页码、分类和批量选择状态不丢失。
- 微信账号失效或网络断开时，已缓存书架和本地进度仍可查看。
- 下载任务取消、目录变化及重复启动不能误标“整本已下载”。
- JSON 密钥文件过大、格式错误或含其他字段时不能泄露内容。
- 全局清理不能删除正在阅读章节、活跃下载和非缓存数据。

---

### Task 1: 整理书架入口和返回路径

**Files:** `legado.koplugin/legado/ui/presenter.lua`、`legado.koplugin/legado/ui/library_screen.lua`（如现有布局需要）、`spec/compact_shelf_spec.lua`、新增 `spec/shelf_action_groups_spec.lua`。

- [x] 写失败规格：主书架只显示找书、整理书架、书源与下载、更多四组；搜索/发现、分类/批量、书源/下载分别同组；阅读回顾只在更多一次；子页可返回原页码。
- [x] 运行两项规格，确认因当前扁平按钮结构而失败。
- [x] 在 Presenter 中集中构造组菜单，移除各页重复附加的全局动作；保留现有功能回调。
- [x] 运行书架、搜索、发现、下载、阅读回顾和原生界面规格并检查触控按钮。

### Task 2: 最近阅读首页与 4+12 封面分页

**Files:** `legado.koplugin/legado/ui/bookshelf.lua`、`legado.koplugin/legado/ui/presenter.lua`、`legado.koplugin/legado/ui/library_screen.lua`、相关书架与排版规格。

- [x] 写失败规格：首屏 1 本大卡片（封面、简介、继续阅读）加 4 本封面；第 2 页起每页 12 本且三行四列；最近阅读变化后更新；空书架可找书。
- [x] 让书架模型提供首页与后续页数据，Presenter 和 LibraryScreen 绘制对应布局。
- [x] 运行书架和屏幕规格，验证封面加载失败、已下载角标及翻页。

### Task 3: 部分章节缓存与快速选截至章节

**Files:** `legado.koplugin/legado/lib/download_manager.lua`、`legado.koplugin/legado/ui/book_detail.lua`、`legado.koplugin/legado/ui/downloads.lua`、`legado.koplugin/legado/ui/presenter.lua`、下载规格。

- [x] 写失败规格：从第一章到选定的截至章节，任务只缓存此范围；长目录可快速定位；进度分母为范围章节数。
- [x] 复用整本缓存任务生命周期，实现范围持久化、取消、继续与失败重试。
- [x] 验证部分完成不显示整本“已下载”标记；目录变化时明确告知并安全重试。

### Task 4: 微信扫码会话与远端书架

**Files:** 新增 `legado.koplugin/legado/lib/weread_session.lua`、`weread_client.lua`、`weread_mapper.lua`，接入 `app.lua`/`bootstrap.lua`，新增网络与存储规格。

- [x] 用模拟微信扫码协议写失败规格：获取二维码、轮询、确认、令牌续期、失效提示、取消请求、重启读回，不泄露凭据。
- [x] 实现独立会话存储与网络层，接入本地书架身份和后台同步。
- [x] 验证同名不同源不串数据、网络失败仍显示本地书架；真实扫码留待用户设备验收。

### Task 5: 微信书城、章节阅读、进度与评论

**Files:** 扩充微信适配层、`App`/`ReaderSession`/Presenter，新增书城、进度、评论规格。

- [x] 写失败规格覆盖书城发现/搜索、12 本分页、目录正文、历史进度、评论摘要点击详情与返回。
- [x] 接入现有阅读会话和缓存，保存源 ID 与远端书 ID；本地进度优先于云端历史位置，登录失效续期一次并校验评论书 ID。书城详情可加入远端微信书架并刷新本地快照，迟到的旧账号响应不会混入新账号书架。
- [ ] 在真实账号上验收书城、书架、阅读与评论；不以模拟请求替代此项验收。

### Task 6: AI 阅读解释

**Files:** 新增 `legado.koplugin/legado/lib/ai_service.lua`，扩充设置、阅读选择菜单与对应规格。

- [x] 写失败规格：DeepSeek/小米默认地址、密钥 JSON 文件校验、连接测试、默认解释提示词和自定义补充提示词。
- [x] 复用现有异步 HTTP/文件选择器，只在用户选择文本并触发时发送请求；显示结果与错误，隐藏密钥。
- [x] 用模拟接口验证两家请求；真实密钥连接需用户在设备上验收。

### Task 7: 全插件缓存统计与清理、图标

**Files:** 扩充 `cache_store.lua`、下载缓存模块、设置/维护页与规格；新增适配 KOReader 的图标和许可声明。

- [x] 写失败规格：按缓存种类和总量显示，确认后清理，保留进度、书架、授权、导出文件及活跃任务。
- [x] 实现分项清理和汇总回报，加入项目原创单色开卷 SVG 图标；桌面布局规格通过。
- [ ] 运行安全边界、包清单和设备验收。

### Task 8: 发布

- [x] 全量可运行规格除缺少外部 919 源样本的一项外通过；KOReader 真实源码路径启动契约、安装包清单通过。
- [ ] 按用户既定交接方式更新源码、ZIP、GitHub 项目；在发行说明中分清模拟验证与实机结果。
