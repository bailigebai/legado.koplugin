# 第二期：KOReader 阅读统计桥

目标：把同一本网络小说跨章节的阅读时段写入既有 KOReader `statistics.sqlite3`，复用主阅读器生命周期，避免章节伪书与双记时。主任务负责调用和菜单，本子任务只新增桥与测试。

## 方案比较

| 方案 | 影响 | 选择 |
| --- | --- | --- |
| 固定 schema 的数据库桥 | 只写已存在的官方统计库，固定虚拟页映射；无需假造 ReaderUI | 采用 |
| 给每章创建原生统计文档 | 章节分裂为多本书，需侵入文档身份与原生事件 | 不采用 |
| 单独统计库与同步任务 | 增加第二套统计、重试文件和同步状态 | 本期不采用 |

参考实现：`.tools/leko-reader/leko.koplugin/Leko/KOReaderStatisticsBridge.lua`（AGPL，主任务登记 notices）。沿用原型的固定虚拟页数、时段和数据库桥思路，复用本项目已有 MD5。

## 固定接口

`Statistics.new{clock,db_path,settings={is_enabled,min_sec,max_sec}}`；缺省配置读取 KOReader `statistics` 设置。`is_enabled=false` 不打开库。

- `start(book, virtual_page, stable_book_id)`：稳定 ID 缺省 `book.id`；同书已暂停实例继续使用，不重置待写队列。
- `onPageChanged(page)`、`pause()`、`resume(page)`：完成页时段、排除暂停时长。
- `checkpoint()`：结束当前时段并写入；`flush()`：只重试待写时段。
- `close()`：完成最后时段；写失败保留队列，重复 close 只重试。
- `status()`：`pending`、`pending_limit=500`、`active`、`paused`、`blocked`、`closed`、`last_error`。
- 成功 `true`；关闭/禁用等无操作 `false`；错误 `nil, {code,message,details}`，不影响正文继续阅读。

## 数据与失败边界

- 只接受官方 schema `20221111` 和必需表/视图/字段；以 `rw` 打开，缺库不创建、不迁移。
- 所有变动在事务内，所有动态值绑定；稳定书 ID 的 MD5 命名空间为 `legado-reader\0`。
- 10000 个固定虚拟页，短时段遵循配置下限，单次时段遵循上限；按官方方式统计不同页和每页上限。
- SQL 失败回滚并保留原待写时段；唯一键去重使重试不重复。
- 最多 500 个待写时段；满后停止新增并明确报 `STATISTICS_QUEUE_FULL`，恢复写入后继续。切换书籍前必须成功写完旧书，否则保留原实例并报告失败。
- 主任务已接受只在内存保留失败队列；不承诺强制退出或断电零丢失，不另建持久重试文件。

## 验证

- [x] 先新增失败测试，覆盖启用、身份、计时、暂停、跨章、写失败和500上限。
- [x] 新增 `legado.koplugin/legado/lib/koreader_statistics.lua`；不改 session、adapter、settings、presenter。
- [x] 用官方 LJSQLite3 和原生 SQLite 的临时数据库验证 schema、绑定、事务回滚、重复重试、聚合及缺库。
- [x] 交给主任务独立审计、接入和打包；设备计时与菜单由主任务验收。

## 验证记录

- `scripts/run_lua_specs.py --spec spec/koreader_statistics_spec.lua`：49 项断言通过。
- `spec/native_koreader_statistics_test.py`：官方 KOReader v2026.07.1 包内 LJSQLite3，原生 SQLite 3.45.1；缺库与检查后消失均不创建，旧/未来/缺字段 schema 原字节不变，锁冲突不插入半本书，标题含引号/NUL 可绑定，跨源稳定书 ID 只生成一条书籍记录，批次中途失败整体回滚，重试不重复，各页时长按原生上限聚合。
- 原生数据库均用临时目录；未打开用户的真实统计数据库。
- 同期背景管线复核新增 `spec/native_reader_background_test.py`：145 项断言，真实 BlitBuffer 像素、预乘透明度、缩放/裁剪、C 参数字节指针类型、编码/替换失败与释放标志通过；运行代码由主任务修复。
- 仍需主任务核验：主阅读器真实事件调用、原生统计禁用避免双记、统计菜单跳转、Kindle 实际暂停/恢复与跨章节计时。
