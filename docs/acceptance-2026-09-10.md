# v0.2.7 导入与首页修复记录

## 已复现的问题

用户截图明确显示 `STORAGE_ERROR`，不是网络错误。将原版 KOReader v2026.07.1 发布包里的 `common/lua-ljsqlite3/init.lua` 原样加载到 LuaJIT 2.1，调用 Windows 原生 SQLite 3.45.1，生产导入器保存书源时复现相同错误。

根因：原版 `db:exec()` 按每一个分号拆命令，没有识别 SQL 引号。书源中的 JavaScript、HTML 实体、Cookie 和 URL 都可能带分号，导致写入语句被拆坏。之前的内存/模拟数据库测试没有暴露该问题。现在通过 `prepare()` 执行单条完整命令，并在执行后关闭语句；创建数据库结构也改为逐条提交命令。数据库格式及原有数据保持兼容。

首页另有两个可复现问题：`Home.new()` 缺少 `kind="home"`，生产入口无法识别；封面占位 TextWidget 缺少 `face`，原版控件在 `textwidget.lua:112` 计算大小时崩溃。还有封面回调没有传到可见格子、导航后旧网格残留并遮挡阅读器，均加入了回归检查并修复。

## 本次实测

1. 在线获取用户网址：HTTP 200，4,465,023 字节、919 源。SHA256：`8ca6123043aa9d694a65420827ae144c6f498f097688476d40e53d4c44dc29f5`。
2. 使用生产 SourceImporter、Storage、SqliteBackend 和未改动的 KOReader SQLite Lua 封装，将完整合集写入临时磁盘数据库；关闭连接、重新打开后逐源逐字段对照，包括嵌套规则。
3. 再次导入：新增 0、更新 919，总数仍为 919。原有书架和进度保留。
4. 用真实 SQLite 触发器模拟批量写到一半失败，确认整批回滚、旧书源保留、随后可重试。分号、引号、NUL、章节、进度也经过保存读取验证。
5. 生产 App → Home → Presenter → CoverGrid 加载原版 TextWidget、Button、FocusManager、分组和边框代码，检查空首页、有阅读记录、同步缓存封面、异步封面、取消、按钮宽高、选书和功能导航。进入阅读器前窗口集合不再残留插件网格。
6. 全量 67 个 Lua 规格通过，共 3,661 项断言；网络桌面适配检查、命名空间、入口、EPUB、发布包白名单、版本校验、恶意 ZIP、兼容检查器自检通过。固定 KOReader v2026.07.1 官方契约检查及真实 SQLite 专项通过。

独立代码复核发现了旧网格残留的问题；修复后复核相关测试通过。额外通过 SQLite 原生接口确认失败回滚后没有遗留预编译语句，六本长书名的首页布局也在 600×800 测试屏幕范围内。

## 可复跑命令

在项目根目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check-koreader-compat.ps1 -Offline
.tools/python/python.exe -B spec/official_sqlite_test.py --url YOUR_SOURCE_COLLECTION_URL
powershell -ExecutionPolicy Bypass -File scripts/run-specs.ps1
```

第一次准备环境时去掉 `-Offline`，获取固定版本的原版源码和发布包。测试只在临时目录创建数据库，不使用用户设备的数据。

## Kindle 验收

退出 KOReader，只替换 `koreader/plugins/legado.koplugin/` 插件目录，保留个人数据和设置，完整重启。确认关于信息中的版本为 0.2.7。

- “工具 → 书源阅读 → 首页”：没有记录时显示“暂无最近阅读”和添加入口；有阅读记录时显示封面或占位及分行功能按钮。
- “书源管理 → 从网址导入”：填用户提供的网址。原书源为空时预期新增 919；再次导入预期更新 919，关闭重开后列表仍存在。
- 也可以直接点击“导入推荐书源（919条）”，插件会自动请求同一地址。已下载副本位于项目的 `sources/yuedu-260114.json`，供离线导入或复核使用。
- 从首页或书架选书，再开始阅读：旧封面页不再遮挡阅读器。

如果仍报错，请保留错误提示及本次启动的 `koreader/crash.log`；不要删除数据库。新版保存错误会说明本地存储故障类型。

## 尚未验证与范围

未连接 Kindle 真机；未验证该设备上的 TLS、子进程、ARM SQLite 二进制、实际字体/图片渲染、触摸及阅读排版。原版 Lua 接口在桌面通过不等于真机已通过。

919 是可导入并持久化的书源数量，不代表 919 个网站都能搜索或阅读。本次没有重新逐站验证正文，也没有增加完整 JavaScript、WebView 或网站登录支持。此前抽样阅读记录见 `live-sources-2026-09-08.md`。

moon 的完整统一布局仍待继续实现；v0.2.7 是本阶段的导入与首页故障修复包。
