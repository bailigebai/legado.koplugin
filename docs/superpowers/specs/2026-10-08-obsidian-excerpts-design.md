# 不亦阅乎 Obsidian 摘录设计

## 目标与范围

书源、微信读书无感阅读，以及 KOReader 原生 MOBI/EPUB/PDF 等可选文字文档，长按拖选后使用同一“摘录到 Obsidian”入口。先完成设备本地持久保存，再后台 Wi-Fi 同步。扫描图片只有 KOReader 能提供选中文字时才能摘录，本期不新增 OCR。

## 方案比较与已确认决定

1. Wi-Fi + Obsidian Local REST API：阅读时操作少，需电脑运行 Obsidian；离线排队。推荐，用户已选。
2. USB 导入：免网络，需连接电脑操作。
3. Markdown 手动导入：最容易迁移，但每次需要搬运文件。

用户已同意使用当前 Obsidian 仓库并安装配置 Local REST API。统一默认目录“阅读摘录/不亦阅乎”，可配置。按书建立目录，每条摘录一篇 Markdown，保留独立批注空间。

## 数据与接口边界

- 复用 Storage/SqliteBackend，增加 excerpts 集合；持久字段：id、quote、title、author、source、book_key、chapter、location、captured_at、status、destination、remote_path。只摘录显式选择内容。
- excerpt_context：只负责从无感章节或 KOReader 文档与 selection 提取来源。不得把插件临时 HTML 文件误认为本地书籍。
- excerpt_service：保存、去重、排队、同步状态；obsidian_client：配置验证、HTTPS、REST 请求；excerpt_markdown：安全文件名和 Markdown。
- 插件合成原生页面与普通本地阅读共用一个划词按钮键，避免重复按钮。每次保存时先取得位置，再关闭选区。
- 使用稳定 id + 内容身份校验防止重复与 hash 碰撞覆盖。同步 GET 查看目标：不存在才 PUT；有本条摘录标记则视为已到达，保留用户修改；无标记报告冲突，绝不覆盖。
- 设置改变后已绑定的待同步记录保留原目标，阻止自动发送到另一个仓库；需要明确重定向时另行设计，本期不新增。
- 后台单任务串行；每轮失败停止，不循环轰炸。新摘录、打开管理页、手动同步触发有限重试。界面关闭不丢队列，不阻塞翻页。
- HTTPS 验证证书链并固定 SHA-256 服务器证书指纹，握手完成且指纹一致后才发送密钥。禁用重定向。配置 JSON 作为设备私有文件，设置只保存路径；不把密钥打入安装包、日志、GitHub。

## 用户交互

长按文字 → 拖选 → “摘录到 Obsidian” → “已保存摘录，后台同步中/待同步”。“不亦阅乎 → Obsidian 摘录”可查看摘录、状态、配置 JSON 文件、测试连接、同步。设置页有同一管理入口。连接失败显示具体类别，原摘录仍在。

## 验收

- 三条阅读路径可保存正确原文和来源；读者在关闭文档后不能保存过期选区。
- 保存失败保留选区；断网、重启、上传后响应丢失、同步状态写入失败都不丢原句或产生重复。
- 路径穿越、特殊书名、空文本、超长内容、恶意 Markdown、错误证书、重定向、已有笔记冲突有可验证处理。
- 测试插件兼容 KOReader 官方版本；真实 Obsidian 接口写入并读回专用测试笔记；设备端验收以实际连接情况报告。

## 资料

- https://github.com/coddingtonbear/obsidian-local-rest-api
- https://github.com/coddingtonbear/obsidian-local-rest-api/blob/main/docs/openapi.yaml
- https://obsidian.md/help/data-storage
- https://github.com/lunarmodules/luasec/blob/master/src/https.lua
