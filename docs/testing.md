# 测试与发布验证

## 自动测试环境

Windows 测试由 `scripts/run-specs.ps1` 启动，首次运行会把 Lupa 2.8 的 `luajit21` 测试运行时安装到未跟踪的 `.tools/python/`。首次需先运行下文 `check-koreader-compat.ps1` 取得原版控件源码，供原生首页回归使用。测试覆盖插件入口、持久化、规则、网络、UI、阅读缓存、EPUB、下载恢复、诊断与听书入口移除，并执行命名空间、入口冒烟和 EPUB ZIP 自检。

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run-specs.ps1
```

固定 KOReader 基线检查使用：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check-koreader-compat.ps1
```

该脚本只接受 KOReader v2026.07.1 的固定 commit，将官方源码及固定 `koreader-base` 子模块放入忽略的 `.tools/koreader/`（已有完全一致且干净的检出时复用），并校验官方 `kindlehf` ZIP 的固定 SHA256。它静态核对插件实际引用的 ReaderUI、UI、FFI/archiver、Socket/LuaSec/Ltn12、SQLite 与子进程相关模块路径，再使用官方 `ui/event.lua` 检查章尾事件和原生转发。v0.2.7 还实际执行原版文本、按钮、分组、边框、焦点控件代码，以及原版 LJSQLite3 封装调用桌面原生 SQLite。字体光栅化、图片渲染、设备屏幕边界使用替身；没有启动 Kindle 二进制，不能代替真机运行。

本版新增本地 HTML 书源完整流程、常用选择器、发现分类和翻页、原生菜单注册、菜单窗口退出及离线进度恢复检查。测试使用可控响应验证生产解析器和服务，不表示外部网站已可用。

2026-09-08 的 v0.2.1 验证：62 个 Lua 规格、3567 条断言全部通过；桌面运输 3 项检查、命名空间、入口冒烟、EPUB ZIP、打包白名单/可重复构建/恶意 ZIP 检查全部通过。官方 KOReader v2026.07.1 源码及固定 KindleHF 包的兼容检查通过，属于静态契约检查。

v0.2.1 的上述测试遗漏了实际插件搜索路径：测试曾额外加入 `plugin/?/init.lua`，而 KOReader PluginLoader 只追加 `plugin/?.lua`。v0.2.2 增加 `native_menu_startup_spec.lua`，限制为实际搜索路径并启动生产 Bootstrap、存储、书籍服务与书源管理，仅用内存文件系统和平台边界替身。v0.2.3 再验证延迟初始化和点击失败诊断。v0.2.5 增加 4.46 MiB 书源合集的进程通信往返测试，v0.2.6 增加首页封面墙测试。2026-09-09 全量 64 个 Lua 规格、3606 条断言及发布检查通过；官方启动、菜单和事件定向检查 31 条断言通过。设备实际画面仍需验收。

## 构建发布包

v0.2.7 补充验证：`spec/official_sqlite_test.py` 不再使用数据库替身，检查分号、引号、NUL、实际落盘重开、事务失败回滚和重试；`native_home_widget_spec.lua` 通过生产 App → Home → Presenter → 原版控件链检查首页，以及选书后开始阅读不残留旧窗口。完整实测记录见 [2026-09-10 修复记录](acceptance-2026-09-10.md)。

```powershell
.tools/python/python.exe -B spec/official_sqlite_test.py --url YOUR_SOURCE_COLLECTION_URL
```

`package.ps1` 默认先运行全部自动测试，然后仅把运行时、README、文档和许可证放进单一顶层目录。`-SkipTests` 只用于已经由同一流水线完成测试的开发场景。

```powershell
powershell -ExecutionPolicy Bypass -File scripts/package.ps1 -Version 0.3.2
powershell -ExecutionPolicy Bypass -File scripts/verify-package.ps1 -Archive dist/legado.koplugin-v0.3.2.zip -Version 0.3.2
powershell -ExecutionPolicy Bypass -File scripts/scan-sensitive.ps1
```

验证器检查顶层结构、必需文件、版本、禁入目录、凭据/书源 JSON、命名空间和入口加载。ZIP 使用排序条目和固定时间戳，以便相同提交生成相同 SHA256。

## 2026-09-14 v0.7.2 发布前检查

- `scripts/run-specs.ps1` 全流程通过：98 个 Lua 规格、24,789 条断言；命名空间、实际 HTML 文件读写、运输层、EPUB、打包白名单、可重复构建及恶意 ZIP 检查通过。
- `scripts/check-koreader-compat.ps1 -Offline` 通过：官方 v2026.07.1 的 28 个 UI 模块及其他运行模块检查、12 个原生相关规格 / 20,257 条断言、官方 LJSQLite3 实际 SQLite 测试通过。新增使用的 `util.tableDeepCopy` 也校验在官方源码和 KindleHF 包内存在。
- 九款小票覆盖 600×800、800×600、1200×1600、1600×1200，各测 75/90、50/55、95/95、50/95、95/55 宽高百分比。原生字体替身采用官方 NotoSans 的高度指标（height=1.362 em、ascender=1.069 em），修正并复测多行文字额外字高超出短评点击区的问题。
- 使用此前从 KPW6 读取的真实 `uimanager.lua`，九款小票的事件/重画测试 522 条断言通过；顶部左中右、白底与阅读悬浮、显示/隐藏、返回、尺寸、样式和延迟封面均在实际绘制队列中检查。
- `book_reader_settings_spec.lua` 70 条断言通过；使用未修改的原生 ReaderUI/Configurable/字体/排版处理代码段和真实文件系统保存书级设置，再新建 Storage 从磁盘读取。覆盖下章首次渲染、目录跳转、A/B 各自设置、重开、离线、换源后再修改、false/0、旧章节样式清除、读写失败及启动钩子清理。章节 sidecar、渲染引擎与硬件使用桌面替身。
- `scripts/preview_receipts.py` 从生产布局生成九款默认尺寸、窄尺寸、宽短尺寸预览；已逐图检查。它替换字体和光栅输出，不是 Kindle 截图，也不交付到插件运行目录。

复现证据：新样式在旧实现中被归一化为 classic；原生字号跨章测试先出现 `expected 34, got 14`；真实字体指标测试先出现短评文本高度 67、容器高度 62。三个问题分别修正后相关测试与完整流程通过。Kindle 实际触屏、字形及排版设置操作尚待设备验收。

## 未执行范围

真实书源已使用生产 Lua 解析器、服务和诊断流程在桌面联网抽样，结果见 [适配记录](live-sources-2026-09-08.md)。HTTP 与编码转换使用桌面 Python；不验证 Kindle 的 LuaSocket/TLS、原生 iconv、调度或阅读排版。探测工具不执行书源 JavaScript，每源最多 8 次请求，不下载整书；测试报告保留状态和计数，不保存正文、网址路径或凭据。

此前仅按盘符检查设备而记录为“未连接”；2026-09-14 已通过 MTP 读取物理 KPW6 的代码和日志，并安装单个小票文件修复。尚未运行真实触屏验收，不能宣称 Kindle 固件 5.19.5 真机已经通过。真机步骤见 `docs/kpw6-checklist.md`，设备验收仍需逐项记录。

### 2026-09-14 小票重画回归

旧版小票用 `setDirty(nil, 'ui')` 刷新已有画面，没有给窗口加重画标记。旧测试用假的 UIManager 并在点击后手工调用 `paintTo`，漏掉了这个故障。新增 `receipt_repaint_spec.lua` 通过真实 `show → sendEvent → _repaint` 流程检查按钮是否被绘制及是否可点击；设备原文件在新测试中失败，修复后回读的设备文件连续三次通过（每次 174 条断言）。

测试覆盖 1272×1696 分辨率、三种样式、白底与阅读悬浮入口、顶部左中右、显隐、返回、尺寸、样式及延迟封面。原生 UIManager 包含窗口栈与刷新队列；屏幕硬件、字体和图片解码仍使用平台替身。这是电脑上的调度回归测试，不等于实际 Kindle 触屏测试。

可选环境变量 `LEGADO_DEVICE_UIMANAGER` / `LEGADO_DEVICE_RECEIPT` 指向从设备读取的 Lua 文件；未设置时使用官方源码和工作区插件。运行 `.tools/python/python.exe scripts/run_lua_specs.py --spec spec/receipt_repaint_spec.lua`。此用例也已加入 `check-koreader-compat.ps1`。

新设备日志包含 `[LegadoReceipt] build=receipt-repaint-20260914`、`requested controls=` 和 `painted controls=`，分别识别运行文件、控制栏状态切换与完成绘制，不记录书名、正文或账号信息。完整重启 KOReader 才会加载新文件。

本版独立书库新增生产浏览流程、官方控件布局及 HTTP 解压验证，详见 [0.3.0 记录](library-browser-0.3.0.md)。Windows 解压专项使用已安装 Git 的 zlib1.dll，可通过 LEGADO_ZLIB 指定其它原生 zlib 路径；Kindle 运行期使用 KOReader 自带的 libz.so.1，不附加新依赖。

0.3.1 增加 4×3 书架和分类分页、二级菜单返回、原生长简介滚动及实际阅读文件格式检查。见 [本版记录](compact-shelf-reader-0.3.1.md)。

0.3.2 修正返回按钮随标题长度水平漂移的问题：标题栏占满内容宽度，返回固定左上角，标题在剩余对称区域居中；通过短标题、长标题、书架和详情的生产控件绘制核对位置。

## 2026-09-15 三期交付检查

- 第一、二期分别冻结为 v0.8.0 / v0.9.0 完整包；第三期 v0.10.0 含此前功能及独立 Leko 阅读器。冻结文件与校验值见开发规划和普通 `AA/dist/SHA256SUMS-20260915.txt`。
- 最终 `scripts/run-specs.ps1` 通过：118 组 Lua 规格、43,993 条断言；命名空间、真实 HTML IO、HTTP 传输、EPUB、可重复打包/恶意 ZIP/版本错配检查均通过。日志：`dist/phase3-final-checks.log`。
- `scripts/check-koreader-compat.ps1 -Offline` 通过：固定 KOReader v2026.07.1 的 31 个 UI 模块及 FFI/网络/进程边界；12 组原生控件与生命周期规格、37,862 条断言；官方 LJSQLite3 / SQLite 3.45.1 实际读写、回滚、重试检查通过。日志：`dist/phase3-native-checks.log`。
- 独立读取、前后翻页、目录跳章、重开、连续换源、双向模式切换、独立/原生两套排版、精确游标、离线、迟到网络/native 回调、候选显示异常、保存失败、暂停/休眠失败恢复和计时上下文由实际 Session/Adapter/控件规格覆盖。原生 `doShowReader/saveSettings/onClose/onCloseWidget` 与 UIManager 窗口栈使用固定官方代码，文档引擎及屏幕平台仍为替身。
- 高 DPI 专项模拟 2 倍缩放和额外字形高度：页眉/页脚 18、进度字 22、高度 16 时不遮挡；字高测量按字号缓存。顶部全宽 12% 菜单、前灯返回、覆盖层唤醒不提前恢复计时均通过。
- `native_reader_background_test.py` 的真实 BlitBuffer 管线 145 条断言通过；`native_koreader_statistics_test.py` 以实际 SQLite 验证整书身份、事务和原生统计合计。
- 原始集合第 17 源“英文小说网”、关键词“加”一次 4 请求完成搜索/详情/22 章目录/正文。最终运行代码从生产缓存校验并读取 1779 字节正文，完成独立绘制、前后翻页及关闭，ReaderUI 调用 0、遗留任务 0。报告：`staging/phase3/live-reader.json`；该报告不含正文，实际缓存不打包。网络为电脑 HTTP，字体/屏幕/调度有替身，不代表 Kindle 网络或真实分页验收。

安装后按 `docs/reader-library-0.10.0.md` 实机验证启用/关闭、跨章、返回、两套排版、动画和休眠。含图片章节需手动关闭无感阅读；本地 PDF/EPUB 仍由原生阅读器打开。复杂 JavaScript 书源的既有限制未被独立阅读器改变。
## v0.10.2 稳定性、缓存与 Swipe 动画

新增 `cache_management_spec.lua`、`phase3_immersive_settings_stability_spec.lua`：验证缓存容量统计、按最旧文件淘汰、目录元数据和当前书籍保护，以及无感阅读设置回调异常不会冒泡到 KOReader。缓存默认上限 500 MiB，自动清理阈值 300 MiB，保留 200 MiB，设置页可分别调整。

## 2026-09-16 v0.10.8 预读与稳定性

本轮实现、审查发现、真实双网页正文抽样、全量/原生/三遍 UI/500 次跨章验证和实机边界见 [v0.10.8 验收记录](reader-library-0.10.8.md)。授权备用 Pages 只准备代码，未部署；当前域名连通性与物理 Kindle 验收仍待完成。
