# 微信章节讨论详情 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 从无感阅读章末查看头像、名称、实际点赞数及完整回复；修复用户追加反馈的词典返回格式问题。

**Architecture:** 现有章节列表控制器保留章节所有权；详情/回复由独立短生命周期控制器按需读取。卡片作为 LibraryScreen 的 custom_body 复用布局、焦点和关闭取消；头像复用 CoverLoader 的有界缓存。

**Tech Stack:** LuaJIT / KOReader widgets / 现有 RequestEngine；无新依赖。

**Spec:** `docs/superpowers/specs/2026-10-03-weread-discussion-details.md`

## Global Constraints

- 未返回数量时省略字段，不推断为零、不显示“点赞数未提供”。
- 只读查看，后台优先级，当前页头像，GET 接口必须核对官方代码。
- 关闭、换章、换账号后响应不更新旧界面；头像不携带登录头。

## Review Focus

- 真实点赞 0 与缺失值不能混为一谈。
- 回复对象或其他想法的结果不能误归属当前想法。
- 关闭与同步回调、异步回调竞态不得重开旧页面。
- 当前页头像取消及损坏图片回退，不影响页面阅读。
- 小屏、横屏、长中文内容不能遮挡页脚；全文可读。

### Task 1: 已知字段及缺失数量

**Files:** `lib/weread_mapper.lua`, `ui/leko_reader.lua`, `ui/presenter.lua` (均位于 `legado.koplugin/legado/`); `spec/weread_chapter_discussions_spec.lua`, `spec/weread_chapter_discussions_ui_spec.lua`。

- [x] 增加失败用例：未知数量不出现任何占位赞文案；保留真实 0；头像和作者从嵌套 author 解析。
- [x] 运行对应 spec，确认失败原因。
- [x] 实现有界字符串、可信头像解析及文案省略。
- [x] 对应 spec 通过。

### Task 2: 想法详情及回复

**Files:** `lib/weread_client.lua`, `lib/weread_mapper.lua`, 新 `lib/weread_discussion_detail.lua`；新协议/控制器 spec。

- [x] 核对官方详情/回复 GET 参数及真实响应；记录证据后确定方法接口。
- [x] 失败用例：请求归属、回复分页去重、真实赞 0、缺失赞、取消、账号切换、错误重试。
- [x] 最小实现详情/回复读取与控制器；完整正文始终来自原列表或有效详情。
- [x] 对应 spec 通过。

### Task 3: 卡片与头像

**Files:** 新 `ui/discussion_body.lua`、`ui/chapter_discussions.lua`、`ui/presenter.lua`、`ui/library_screen.lua`、`ui/bootstrap.lua`、`lib/cover_loader.lua`；新 native 卡片和详情 UI spec。

- [x] 失败用例：头像、名称、正文与元信息布局；可见页加载/取消，失败占位；完整正文及回复全文可查看。
- [x] custom_body 复用 LibraryScreen，不改变通用书架模式；按需详情导航，旧 callbacks 失效。
- [x] 核对真实 KOReader 控件布局及关闭生命周期；对应 spec 通过。

### 追加修复：词典暂无释义与嵌套释义

**Files:** `lib/weread_dictionary.lua`、`spec/weread_dictionary_spec.lua`。

- [x] 对照官方词典组件核对 status 与不同 message 类型的结构。
- [x] 失败用例：status=0、成功空内容、result[].means[].mean、缺失 status；运行后确认失败。
- [x] 补齐现有解析；无释义返回正常未收录提示，格式错误及认证错误保留独立处理。
- [x] 词典协议、UI、App 共 52 个断言通过。

### Task 4: 审查与交付

- [x] 新上下文审查根因、取消和输入边界，修复必要问题。
- [x] 全套规格、官方 KOReader 兼容检查。
- [x] 安装包校验：v0.10.48 共 154 个包文件；安装前回滚演练三种故障均通过。
- [ ] 更新版本及验收文档，提交并同步两个旧交接目录。
- [ ] 已连接设备时备份、校验安装并完整读回；无连接时如实报告待安装。

## 执行记录

- 起点：`d6413e6`，工作区干净，v0.10.47。真实 500 条历史响应的头像域名共三种；用户截图对应想法可在响应中找到，点赞 2 / 回复 1。
- 用户连接后已确认 Kindle GN433W116246017G，v0.10.47 基线 150 个文件全部备份并逐字节核对。
- 真实官方想法详情回放：莉莉蒙、2 个赞、1 条回复、2 名点赞者及各自头像。电脑使用设备旧会话探测返回 -2012，匿名更多回复返回 -2010；非空子回复与更多回复成功仍需有效登录实机验收。
- 独立审查发现连续子回复分页应使用 isExpandAll=0，并需吸收分页中首次返回的真实数量；已分别做失败用例与修复。
- 补充关闭回调时不启动新请求、阅读全文返回时保留初次详情加载的生命周期用例。
- 用户追加“巨石糖果山”词典报错；官方词典组件将非成功状态显示为“暂无释义”，且部分类型释义位于 means 数组。插件原解析误报网络失败，已按官方结构修复。这个具体词条当前是否收录未取得有效会话实测结果。
- 最终全套检查 210 个规格、48,859 条断言通过；包行为、EPUB、传输及实际 HTML 入口均通过。官方 v2026.07.1 兼容检查通过。复审 102 条定向断言通过，无新增 Critical / Important 问题。
