# Kindle KOReader 书源阅读插件设计

## 目标

从零开发 `legado.koplugin` v0.1.0，目标设备为 KPW6、Kindle 固件 5.19.5，兼容 KOReader v2026.07.1 及后续版本。插件使用纯 Lua/LuaJIT，实现 Legado JSON 书源的受限兼容层、书源管理、多源搜索、本地书架、在线逐章阅读、离线缓存和整本 EPUB。字体、排版及背景交给 KOReader；听书只预留接口。

## 架构

入口只注册菜单并组装服务。书源导入、兼容性扫描、网络请求、规则解析、图书领域服务、持久化、缓存、阅读适配、EPUB 构建和界面分别保持独立边界。SQLite 保存小型可查询元数据，正文、封面和 EPUB 保存为文件；SQLite 不可用时降级为 Lua 索引。

## 书源兼容范围

首版覆盖 `bookSourceName`、`bookSourceGroup`、`bookSourceUrl`、`searchUrl`、`header`、`ruleSearch`、`ruleBookInfo`、`ruleToc` 和 `ruleContent`。支持常用 CSS、JSONPath、XPath 子集、正则净化、组合规则和安全模板函数。任何 JavaScript、WebView、登录 UI 或 Android/Java API 均不执行，并在兼容性报告中明确说明。

## 阅读与缓存

在线章节净化为本地语义化 HTML 并由 KOReader 原生打开，章节末尾自动切换，默认预取三章。进度按书籍、来源、章节 UID 和章内百分比持久化。整本下载使用单任务队列，全部章节成功后才原子生成 EPUB；失败时保留章节缓存而不留下残缺 EPUB。

## 安全与交付

请求默认超时 20 秒、响应限制 4 MB、重定向限制 5 次、目录/正文分页限制 20 页。日志必须脱敏。插件不附带书源，只访问用户自行导入的配置。项目采用 AGPL-3.0，交付源码、中文文档、自动测试和 `legado.koplugin-v0.1.0.zip`。

