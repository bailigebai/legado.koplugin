# 微信跨章失败和切回原生阅读后闪退

基线 v0.10.42 / 1aa81b0。用户报告微信跨下一章失败，关闭无感阅读后点按翻页闪退。已识别 Kindle，核实安装版本 v0.10.41，并读取同次日志确认原生评论调度异常。

## 阶段 1：已确认的原生随文评论宿主契约错误

官方 KOReader v2026.07.1 `ReaderView:registerViewModule` 把 widget.ui 赋值为当前 ReaderUI。`weread_native_comments.lua` 却在注册之前用 ui 字段存 UIManager，随后 setRows、异步搜索和 close 通过 self.ui 调用 scheduleIn/unschedule/setDirty。这些方法属于 UIManager，当前 ReaderUI 不提供；评论加载或章节关闭会抛出错误。现有测试替身遗漏了宿主对 ui 字段的赋值。

三个方案：

1. 推荐：使用独立 manager 字段保留 UIManager，符合现有 ReaderChrome 模式；以官方注册函数验证加载、点击、章节切换和取消。
2. 停用原生随文评论：避开错误但损失用户要求的功能。
3. pcall 吞掉调度异常：保留错误对象和未完成任务，不能修复根因。

验收：先让官方注册函数进入既有行为测试并观察失败；最小修改管理器引用后，评论定位、翻页后的目标更新和关闭时取消任务全部通过。不能据此宣称已经确认用户的同次闪退原因。

## 阶段 2：微信跨章的具体失败

沿 ReaderSession 的 cache_read / fetch / clean / body_write / html_write / reader_open 分支核对原始错误。当前统一提示掩盖阶段；优先用设备日志确认错误和版本，必要时在现有诊断边界记录安全的错误码、阶段和 Lua 文件位置，不记录帐号凭据、正文或网络响应。

获得证据后复现具体失败，单独修复并验证。没有证据时保留未确认项，不把网络、缓存或帐号问题当作既定根因。

## 当前执行证据

- 已识别 Kindle GN433W116246017G，当前 v0.10.41；旧插件已复制备份，145 文件与原始 v0.10.41 包逐字节一致。
- 同次 crash.log 10/03 09:01:55：`weread_native_comments.lua:60: attempt to call method 'scheduleIn' (a nil value)`，调用链为 setChapterComments / App on_change / Comments:_notify / Comments:load / prepareChapterComments / bootstrap action / UIManager:_checkTasks / handleInput。与官方注册函数进入行为测试后的 RED 一致。
- 改用独立 manager 字段后，评论定位、翻页后的目标更新、关闭取消、晚到任务不读文档、不重画、重复关闭通过。
- 跨章诊断原先丢失错误码的 RED 已复现；复用现有详细提示后显示代码、阶段和安全 Lua 位置，原始凭据/正文不展示。仅记录限制长度且通过字符白名单的代码和阶段。
- 完整 191 项 Lua 规格、48,217 条断言，以及传输、命名空间、EPUB、安装包和宿主检查器行为检查通过。官方 12 项宿主契约、37,894 条断言及 SQLite 实测通过。
- 微信跨章的统一提示在旧日志中没有具体错误码，尚不能认定为相同错误；新版用于复验和采集具体阶段。
- 独立只读审查未发现关键或重要问题；7 项规格、230 条断言通过。审查另以基线模块重现 scheduleIn nil，并验证安全日志白名单、非法字符回退及长度限制。微信跨章具体原因和更新后的真实触控仍为待验收项。

## 阶段 3：验证和交付

目标测试、完整项目回归和官方宿主检查通过；与实现分开审查宿主字段覆盖、晚到任务、重复关闭和跨章状态。按既有授权打包、同步旧交接格式、发布 GitHub；设备连接后先备份并核对基线，再安装及独立回读。实机微信连续跨章和退出无感阅读后的翻页由设备验收。
