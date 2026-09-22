# 第二期：书源受限表达式与网络工作流

基线：919 条真实用户书源，静态扫描 usable 348、partial 86、unsupported 485；不是网络可用率。规则字段中发现 120 处递归 JSONPath、11 处目录倒序、少量 result.trim / 字面量 split / replace、7 处 page 算术。复杂 Java/Android、循环、WebView 规则占多数。

| 方案 | 范围 | 结论 |
| --- | --- | --- |
| 仅修复四个样例站 | 最小但不能覆盖共用规则缺口 | 不作为全部交付 |
| 共用有界规则及服务修复 | 明确受限表达式文法、递归 JSONPath 边界、目录倒序；搜索超时、批量更新、封面与换源状态修复 | 实施 |
| 引入完整 JavaScript 引擎/平台 API | 新依赖、进程和设备访问边界显著扩大 | 本期不做 |

目标与范围：

1. 受限表达式使用词法和语法解析，不把任意 JavaScript 文本替换为 Lua。支持范围逐条测试；超出文法拒绝。保留语法长度、操作数、递归深度和结果大小上限。文案明确不支持完整 JavaScript。
2. 递归 JSONPath 只添加已观察到的命名字段递归；目录倒序由 BookService 整理最终目录，不伪装成 CSS。保留节点、深度和输出限制。
3. 搜索使用 search_timeout（默认 10，1..20）并在请求前拒绝不支持的必要规则；普通正文沿用现有 timeout。保持并发边界及六秒 UI 节流。
4. 新增 checkUpdates(books, callback, on_progress)：最多现有普通并发，逐书检查详情；最新章未变且已有计数则复用计数，否则读取有界目录。只用 updateBook 补丁写 last_chapter、chapter_count、updated_at，保护阅读进度。单书失败不终止其它书，可取消。
5. 封面仅缓存受支持图片签名，合并同图在途请求，避免 HTML 被缓存为 jpg；换源启动失败退出加载态、取消/完成恢复临时并发，不泄露过期结果。

checkUpdates 结果：{total, checked, updated, failed, books, updates, errors}。books 是成功持久化后的书目，updates 仅含变化记录，errors 是 {book_id, code, message} 数组。最终 callback(result, err)，逐书终态 on_progress(result)；全失败给汇总错误。

验证：每项先红再绿；现有 Lua/真实 IO 回归；真实 919 源重新静态扫描，少量来源串行执行搜索→详情→目录→正文探测，记录超时/站点拒绝真实结果。桌面网络结果不视为 Kindle 实机验收。版本及发布说明由主任务统一更新。

## 2026-09-15 实现及验收记录

- 新增 `legado/lib/rule_expression.lua`，仅解析 result/key/page/baseUrl、字符串/数字、算术及括号、一元正负、trim、字面量首替换、非空分隔符 split 后固定下标。所有 @js 后缀须含受支持的字符串转换；未知方法、JS 正则、替换组、多个语句、动态调用、Java/Android/WebView 仍拒绝。URL 后缀和 parse/parseElements 复用同一文法。
- 表达式上限：4096 字节、128 token、16 层、单值 4 MiB、split 下标 0..1000；递归 JSONPath 仅命名字段，整个查询共享 10000 节点预算、64 层、1000 输出，拒绝循环。字符串裁剪与 @js 标记扫描避免反复复制剩余长字符串。
- 倒序目录必须取得完整目录后整体反转、重排 index，不改变 URL 身份。忽略启动 `max_chapters` 截断，保留调用者 `max_pages` 页数预算；若到预算仍有下一页，明确返回 PARSE_ERROR、无法定位首章，不提供带有错误全书索引的局部目录。倒序源首次打开可能更慢，普通顺序目录仍保留首批章节优先行为。
- 检查更新过滤本地书、复用源列表的模型 ID；详情输入副本清空旧 last_chapter，避免 getBookInfo 回填旧值后误判无需目录。空目录、不完整目录、启动失败、存储失败均保留旧记录并报告错误；取消后的回调不再落盘。
- 封面缓存按 PNG/JPEG/GIF/WebP 签名识别扩展名，拒绝 HTML；同图并发订阅共用请求，最后订阅取消才终止底层请求；二进制标记绕过字符集转换，写盘异常释放在途状态并返回 STORAGE_ERROR。签名检查不是完整图片解码，也未新增站点防盗链凭据。
- 换源搜索结束立即恢复普通并发；搜索和目录请求返回 nil 也进入终态。保留六秒刷新合并，不扩大普通并发。

本轮复现并修复：跨页面倒序无翻页、倒序启动截断把最新片段当作全书开头、parseElements 后缀静态放行但运行未转换、递归 JSONPath 多根预算重置、空目录覆盖旧计数、旧最新章回填被当作新数据、封面写盘失败无错误/在途不释放。测试回调只收集结果，断言置于回调外，避免 pcall 吞掉失败。

验证证据：

- 倒序修正后共享工作树全量快照：108 组、42919 断言通过；二期规则/服务/封面专项 59 + 41 + 23 = 123 断言。倒序修正同时通过 catalog_startup_limit、phase1_prefetch 和 source_matches 回归。最终发布以主任务的冻结回归数为准。
- `spec/reader_document_io_test.py` 通过：网站提取 → 真实 HTML 文件 → 阅读器入口。
- `staging/phase2/static-after.json`：919 条均导入，usable 349 / partial 86 / unsupported 484，较基线 usable +1。这是静态规则覆盖，绝不是网络可用率。
- `staging/phase2/live-before.json`：原始 #17 关键词“三国”在正文 PARSE_ERROR；#44 搜索 NETWORK_ERROR，如实保留失败。
- `staging/phase2/live-after-original.json`：原始 #17 英文小说网，关键词“加”，`--require-success` 通过；搜索、详情、目录、正文均 HTTP 200，3 本结果、完整 22 章、正文 1779 bytes。单站串行、8 秒请求上限、6 次总请求预算，实际 4 请求；未泛扫网站。
- 以上网络证据使用桌面 urllib 与生产 Lua RequestEngine/规则解析；未验证 Kindle 的 TLS、LuaSocket/iconv、真机触摸或电子墨水刷新体验。
