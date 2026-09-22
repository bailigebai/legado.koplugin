# 真实书源适配记录：2026-09-08

## 当前结果

输入为用户提供的 260114.json 合集（历史测试样本，新版不提供下载链接或内置合集），共 919 条网站书源配置，每条配置可以搜索该网站的多本书。合集不是一本书，也不等于 919 本书。

原始文件 4,465,023 字节，生产导入器接受全部 919 条。静态检查为 `usable` 348、`partial` 86、`unsupported` 485。这些数字表示规则初步兼容性，不表示网站存活率。网络请求最大值已从 4 MiB 对齐至本地导入器的 5 MiB，普通阅读请求默认仍为 4 MiB，避免该合集从网址导入时被截断。

对原集合中的 59 条来源进行过联网抽查，依照实际失败修复共用解析器。下面是单独四站适配文件的最终复测结果，每站选搜索结果中的第一本书，仅获取其首章；没有遍历全站或下载整书。

| 原合集序号 / 源名 | 搜索词 / 结果数 | 详情 | 目录链接数 | 首章正文 | 重复章节链接 |
| --- | --- | --- | --- | --- | --- |
| 17 英文小说网 | 加 / 3 | 通过 | 22 | 1 页，1779 字节 | 0 |
| 44 何以笙箫默 | 三国 / 50 | 通过 | 208 | 1 页，13358 字节 | 0 |
| 71 画本阅读（话本网站） | 三国 / 30 | 通过 | 227 | 1 页，6247 字节 | 0 |
| 94 殓师灵异 | 三国 / 100 | 通过 | 208 | 1 页，13354 字节 | 0 |

四站对应 `yingyuxiaoshuo.com`、`yetianlian.net`（跳转 `xyetianlian.com`）、`so.ihuaben.com`、`rulianshi.org`（跳转 `rulianshi.cc`）。正文计数是提取结果的 UTF-8 字节数，可能包含 HTML，不是汉字数量或整书字数。后两类 208 条目录的章节标号从 1 到 221，原网页本身存在缺号，因此不能宣称取得完整无缺的整书。

## 本次修正

- 共用规则：当前属性、混合 CSS/默认 `@` 链、文本选择、离散索引、`first-child` 和常用 `nth-child`；保留裸 CSS 标签的既有含义。
- HTML：规范化实际标签位置的旧 `</br>`；修复等号前后空格及无引号属性的取值，避免章节网址丢失。
- 网址：书籍、封面、目录、章节与翻页链接取第一个匹配，重复链接不会再拼成无效网址。
- 诊断：真实访问书籍详情后再解析目录；搜索规则错误保留实际错误码。正常网页引用验证码脚本不会直接被判为验证码拦截。

独立样本由 `scripts/adapt_sources.py` 从原合集生成，原文件保持原样，不把合集打进插件 ZIP。样本只复制所需公开规则，省略 Header、登录与发现配置；当前四条配置不含 JavaScript。

| 样本 | 额外规则修正 |
| --- | --- |
| 英文小说网 | 保留原规则，依靠共用解析器修正 |
| 何以笙箫默、殓师灵异 | 目录改为 `.listmain dd:nth-child(n+15)`，排除页面顶部 12 条最新章节，首章恢复到第 1 章 |
| 何以笙箫默 | 清空错误的 `nextContentUrl=text.下一章@href`，避免把下一章或返回目录拼进本章 |
| 话本 | 目录改为当前 `#hbListChaptersWrap a`；当前页面正序且包含全部 227 个链接，去掉旧倒序前缀和旧分页选择器 |

这些适配依赖已观察到的网站布局。两个站点的顶部最新章节数量、话本目录容器或分页方式改变时，需要重新校验。部分原 Java 正则清理未转换，例如殓师的分类前缀与页尾文字可能残留；四步通过不代表所有辅助字段都完全等同于 Legado_Max。

## 验收方式

1. 安装修复菜单入口的 `legado.koplugin-v0.2.2.zip`，解压后的 `legado.koplugin` 目录放入 KOReader 的 `plugins`。重启后从顶部菜单“工具 → 书源阅读”打开。
2. 将 `legado-sources-adapted-20260908.json` 放到 Kindle 的 `documents` 目录。在“书源阅读 → 书源管理 → 从本地 JSON 导入”输入 `/mnt/us/documents/legado-sources-adapted-20260908.json`。
3. 应出现 4 条 `KOReader live sample` 分组书源。分别运行诊断，英文小说网填“加”，其他填“三国”，应依次显示搜索、详情、目录、正文成功。
4. 实际打开一本书，检查目录首章、翻章、加入书架和重启后的进度。此步骤必须在设备上完成，当前尚未验证。

若已导入同一原合集，样本保留相同书源地址，会更新对应四条配置。只导入原始合集时则仍使用其原始网站规则，不会自动套用这些修正。

## 开发复测

```powershell
& .tools/python/python.exe scripts/probe_sources.py --source-json .tools/yuedu-260114.json --report .tools/source-probe/inventory-new.json
& .tools/python/python.exe scripts/adapt_sources.py --source-json .tools/yuedu-260114.json --output dist/adapted-new.json
& .tools/python/python.exe scripts/probe_sources.py --source-json dist/adapted-new.json --report .tools/source-probe/recheck.json --online --limit 4 --timeout 10
```

适配脚本拒绝覆盖已有输出。探测使用生产 Lua 导入器、解析器、请求标准化/响应处理、BookService 和 Diagnostics；桌面 HTTP/编码来自 Python。每源最多 8 次请求，耗尽时独立标记 `probe_limited`。报告不保存正文、请求路径或凭据。Socket 超时和正文循环截止已检查，但 DNS、响应头和分块头不保证严格的墙钟总截止。

原集合 SHA256：`8ca6123043aa9d694a65420827ae144c6f498f097688476d40e53d4c44dc29f5`。
适配集合 SHA256：`550d52dd368aa5703f7bc342daf0dc954fe0c2babb3a8aa9506e8374bf94eb68`。

## 未解决事项

- SF 轻小说两个源已通过搜索和详情，但样例目录有 2919 条，超过现有 1000 项规则上限；当前不算完整通过。扩大限制前需要测 Kindle 内存和耗时。
- 连城与晋江部分规则使用变量存取、递归 JSONPath；大量其他源依赖 JavaScript、登录或 WebView，仍未支持。
- 读书网样例遇证书校验失败，未关闭证书验证；飞卢样例遇编码转换错误，未用乱码替代。多个旧域名超时、断连或返回空结果。
- 没有连接 Kindle，也没有运行模拟器；设备 TLS、原生编码转换、界面排版、阅读进度、整书下载及登录状态均尚未通过真实网站设备验收。桌面样例通过不保证站点所有书、所有章节或长期可用。
