# KOReader 书源阅读插件

`legado.koplugin` 是面向 Kindle KOReader 的安全书源阅读插件。v0.1.0 可导入用户自行提供的 Legado JSON 书源，完成多源搜索、书架管理、在线逐章阅读、离线章节缓存与整本 EPUB 下载。阅读字体、字号、行距和背景继续使用 KOReader 原生设置；听书仅预留接口。

目标设备是 Kindle Paperwhite 第 6 代（KPW6）、Kindle 固件 5.19.5。自动兼容基线为 KOReader v2026.07.1，并尽量只使用长期存在的 Lua/LuaJIT、UI、网络和文件接口。物理 KPW6 尚未连接，安装包所附清单中的设备项目仍需手工验证。

## 安装

1. 安装并确认 KOReader 能在 Kindle 上正常启动。
2. 解压 `legado.koplugin-v0.1.0.zip`；压缩包只有一个顶层目录 `legado.koplugin/`。
3. 将该目录完整复制到 KOReader 的 `koreader/plugins/` 下，最终应存在 `koreader/plugins/legado.koplugin/main.lua`。
4. 重启 KOReader，在主菜单的“书源阅读”中打开书架、搜索或书源管理。

插件不附带书源。请只导入自己有权使用的书源配置；优先使用 HTTPS 导入地址。导入 HTTP 地址时插件会显示安全警告。

## 功能与边界

- 导入单个或数组形式的 Legado JSON 书源，扫描搜索、详情、目录和正文规则兼容性。
- 按书名搜索已启用书源，聚合同名同作者结果，同时保留来源切换。
- 保存书架、章节目录、阅读位置、缓存和下载任务；SQLite 不可用时降级为原子 Lua 索引文件。
- 逐章阅读、预取 0–10 章、断网读取已有缓存；整本 EPUB 下载支持取消、重试和重启恢复。
- 字体与背景由 KOReader 控制，本插件不向正文写入固定字体、颜色或背景。
- 听书入口当前只显示“听书功能尚未配置”，不会启动网络或音频服务。

本插件只实现受限、可审计的 CSS、JSONPath、XPath、模板和正则净化规则。它不执行任何 `@js:`、`<js>` 或其他 JavaScript，不提供 WebView、登录界面、Java/Android API，也不会绕过网站权限控制。详细规则见 [规则兼容表](docs/rule-compatibility.md)。

## 隐私与版权

Cookie 按书源隔离保存在本地；诊断和日志不记录 Cookie、Authorization、查询密钥、请求正文或章节正文。缓存、封面和 EPUB 均保存在设备本地。使用者应遵守网站条款与当地版权法律；项目不提供、推荐或托管任何书源。详见 [隐私与版权说明](docs/privacy-and-copyright.md)。

## 开发与验证

Windows 自动测试：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run-specs.ps1
powershell -ExecutionPolicy Bypass -File scripts/check-koreader-compat.ps1
powershell -ExecutionPolicy Bypass -File scripts/package.ps1 -Version 0.1.0
powershell -ExecutionPolicy Bypass -File scripts/verify-package.ps1 -Archive dist/legado.koplugin-v0.1.0.zip -Version 0.1.0
```

测试依赖放在未跟踪的 `.tools/`，发布物写入未跟踪的 `dist/`。更多说明见 [测试文档](docs/testing.md) 和 [KPW6 手工验收清单](docs/kpw6-checklist.md)。

## 许可证

本项目采用 AGPL-3.0-only。第三方组件许可证与固定版本见 `THIRD_PARTY_NOTICES.md`；vendored `lua-htmlparser` 的 LGPL 文本保留在插件目录中。
