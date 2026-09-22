# 单本书原生阅读设置持久化

目标：同一本书切章、目录跳转、离线重开及明确换源后保留原生排版设置；不同书独立；不迁移章节进度、目录或批注。

## 已核实的根因

- `ReaderSession:_open_cached` 为每章写不同 HTML 路径，KOReader `DocSettings:open(file)` 按该路径打开章节 sidecar。
- 原生 `ReaderUI:init` 在 `DocSettingsLoad` 后发送 `ReadSettings`，之后才渲染和执行 `after_open_callback`。现有适配器在 after-open 才附加行为，不能用于首次排版恢复。
- 底栏配置由 `ReaderConfig` 的 `Configurable` 保存为 `copt_*`；字号、Gamma、页边距等最新值在 `SaveSettings` 事件才进入 `doc_settings`。
- 当前插件 `_save` 只保存进度和阅读历史，没有书级排版设置。原生 `DocSettings` 不使用通用 LuaSettings 的 `file` 字段，不能伪造 `file` 后调用 `flush`。
- 换源候选的 `book.id` 随来源与 URL 改变，必须显式传递设置继承来源，不能靠同书名猜测。

## 方案比较

| 方案 | 改动及成本 | 结论 |
| --- | --- | --- |
| 全书生成一个持续增长的文档 | 统一原生 sidecar，但需要重建目录、进度映射、缓存与换源行为 | 范围过大 |
| 每章共享或复制整份 sidecar | 改动看似少，却会把章节定位、批注、目录和文档身份一起共享 | 不采用 |
| 书籍记录保存排版白名单，原生读取前恢复 | 复用现有 Storage 原子写盘；只补设置生命周期和显式换源参数 | 推荐 |

## 推荐实现

1. `reader_session.lua` 把排版快照写入已有 `progress.reader_settings`，使用当前配置的 Storage 路径（生产 SQLite；不可用时现有 Lua 回退文件），不新建数据库或旁路设置文件。
2. `koreader_reader_ui.lua` 在启动期间安装仅匹配目标文件的 `ReadSettings` 前钩子；设置读取仍在旧文档关闭后执行，获得最后一次保存的设置。成功或失败后移除钩子。
3. 保存快照前发送原生 `SaveSettings`，让 ReaderConfig、ReaderFont 等收集最新值；随后复制原生配置枚举中的底栏设置以及明确的字体/CSS/排版键。排除进度、文档属性、目录、批注及未知字段。
4. 已存在书级快照时，其白名单值优先于旧章节 sidecar；快照缺失的白名单值从章节删除，避免已取消的设置复活；第一次使用时保留当前章节原生设置。`false` 和 `0` 是有效值。
5. `app.lua` 明确换源时传递旧书 ID，新来源独立保存继承后的快照，下一章或重开不再从旧来源覆盖。
6. 本地整本文件没有书源会话的恢复回调，继续使用原生 sidecar。

## 验证

- 先新增失败回归：实际 Storage 磁盘写入及重新实例化、原生 ReaderUI 初始化/关闭/SaveSettings 顺序、原生 Configurable 和底栏枚举。
- 覆盖章节切换、读过的章节、目录跳转、离线/普通重开、不同书、显式换源与再次重开、false/0、取消样式后旧值不复活。
- 确认进度、目录、批注不进入快照；加载失败恢复启动钩子；存储失败不覆盖已落盘快照并保留重试内容。
- 运行相关阅读生命周期规格和完整 Lua 规格；真机字号、页边距和对比度操作仍需产品验收。

## 预定文件

- `legado.koplugin/legado/lib/reader_session.lua`
- `legado.koplugin/legado/lib/koreader_reader_ui.lua`
- `legado.koplugin/legado/ui/app.lua`（仅换源参数）
- `spec/book_reader_settings_spec.lua`

无需新增运行时模块、依赖或打包清单项。

## 验证记录

- 首轮红测试：下一章首帧字号期望 34，实际 14；确认捕获原问题。
- 最终定向结果：`book_reader_settings_spec.lua` 70 断言通过；连同现有阅读、进度、目录、启动失败、换源、页眉页脚规格共 12 组、558 断言通过。
- 新规格执行未改动的原生 ReaderUI 初始化/关闭/保存、Configurable、字体与排版处理器；章节 sidecar 与渲染器是桌面替身，书级 Storage 使用真实原子文件写入并重建实例读取。
- 加入两本书不同设置反复切换、原生底栏键枚举、已删除样式不复活、零/false、明确换源后的再次修改与重开、写盘失败恢复、读取失败及启动观察器完整移除（包括继承关系）检查。
- 本阶段 `git diff --check` 无空白错误；最终完整规格与原生兼容检查由主任务统一执行。尚未在 KPW6 真机进行操作验收。
