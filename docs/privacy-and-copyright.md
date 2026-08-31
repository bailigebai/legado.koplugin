# 隐私、安全与版权

## 本地数据

书源、书架、目录、阅读进度和下载任务保存在 `${DataStorage:getDataDir()}/legado/legado.sqlite`。SQLite 不可用时，同一路径保存 Lua 降级索引。正文目录/章节缓存位于 `/legado/cache/`，封面位于 `/legado/covers/`，生成的 EPUB 与 `.part` 位于 `/legado/downloads/`。卸载插件目录不会自动删除这些数据；删除前请自行备份。

Cookie Jar 只驻留内存，按书源标识隔离，并在 KOReader 进程结束后丢弃。它不会写入数据库。需要注意：用户导入的书源 JSON 会完整保存书源配置，因此配置中自带的 `Header`、`Cookie`、`Authorization` 或其他凭据字段会持久化到 `legado.sqlite`；这些值用于该书源请求，不应把数据库或原始书源文件分享给他人。插件不会把数据上传到项目作者的服务，也没有遥测、广告或自动更新功能。

## 删除个人数据

1. 完全退出 KOReader，避免数据库或缓存仍在写入。
2. 备份希望保留的 `/legado/downloads/*.epub`。
3. 删除 `koreader/plugins/legado.koplugin/` 以卸载插件。
4. 删除 `${DataStorage:getDataDir()}/legado/` 以清除书源 Header/凭据、书架、进度、任务、Cookie 之外的持久数据、缓存、封面和 EPUB。

若只清缓存，可在退出 KOReader 后分别删除 `/legado/cache/` 和 `/legado/covers/`；若只清导出文件，可删除 `/legado/downloads/`。删除 `legado.sqlite` 不可撤销，并会清除全部书源和阅读状态。运行期 Cookie 无需单独删除，退出 KOReader 即消失。

## 网络与诊断

网络只在用户导入远程书源、搜索、阅读、预取封面/章节或下载时访问相应地址。默认限制为 20 秒、4 MB 和 5 次重定向；最大并发由设置限制。HTTP 明文书源会收到警告，建议使用 HTTPS。

日志与诊断只保留步骤状态、耗时、HTTP 状态、字符集、字段数量和结构化错误代码。以下内容严禁写入诊断报告或普通日志：Cookie、Authorization、查询参数中的密钥、请求正文、响应正文、章节正文和登录凭据。分享诊断前仍应检查书源名称是否包含个人信息。

插件不执行 JavaScript，不启动 WebView，不调用 Java/Android API，不提供绕过登录、付费、访问控制或数字版权保护的功能。

## 版权与责任

项目不附带书源，不维护书源目录，也不保证第三方站点可用。书源 JSON、网页内容、封面和图书版权属于各自权利人。使用者必须确认自己有权访问、缓存和导出相关内容，并遵守网站服务条款及所在地法律。

若权利人要求停止访问，请停用或删除相应书源和本地缓存。生成 EPUB 仅用于用户获授权的个人离线阅读，不应传播、出售或公开上传受保护内容。
