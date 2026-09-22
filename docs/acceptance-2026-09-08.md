# 0.2.0 阶段验收报告

日期：2026-09-08。开发分支：`codex/legado-koplugin`，基线提交：`0665557`。

## 当前结果

插件在 Kindle KOReader 上独立运行的实现已完成本阶段开发与自动检查，无需手机或后端。沿用已有书源管理、多源搜索、书架、章节缓存和整本 EPUB 下载，新增静态分类发现、结果翻页以及常用 Legado 默认选择器支持。

本阶段交付是“常用书源规则版本”，不是整个 Legado_Max 的完整移植，也未完成物理 Kindle 验收。

## 本次改动

- `main.lua`、`koreader_reader_ui.lua`：注册原生主菜单，使用 KOReader 实际的章尾事件格式，保留最后一章结束后的原生行为。
- `rule_engine.lua`、`book_service.lua`：保留列表元素，支持 `class/tag/id/children` 链式取值和静态发现分类，收集完整多段正文并拒绝空正文。
- `compatibility_scanner.lua`、`rule_capabilities.lua`、`url_template.lua`：接受对象形式核心规则，识别更多不兼容构造，修复带分页模板的相对网址解析。
- `reader_session.lua`、`bootstrap.lua`：离线重开恢复章节及章内进度；未缓存章节显示错误，离线操作不触发网络请求。
- `app.lua`、`search.lua`、`presenter.lua`：加入发现入口、分页、错误详情及导入统计；修复菜单堆叠、迟到详情响应、取消翻页状态与下载菜单刷新计时器释放。
- 更新版本、中文说明、参考版本与许可证记录、原生契约测试和相关行为测试。

## 验证证据

以下命令均在本开发目录实际运行，退出码均为 0：

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 完整测试 | `powershell -ExecutionPolicy Bypass -File scripts/run-specs.ps1` | 60 组 Lua 规格，3390 项断言，0 失败；命名空间、入口、EPUB、打包行为及兼容检查器测试通过 |
| 官方兼容基线 | `powershell -ExecutionPolicy Bypass -File scripts/check-koreader-compat.ps1 -Offline` | 固定 KOReader v2026.07.1 源码与 kindlehf 包通过；15 个 UI 模块；真实 `ui/event.lua` 的 13 项断言通过 |
| 敏感信息检查 | `powershell -ExecutionPolicy Bypass -File scripts/scan-sensitive.ps1` | 83 个发布相关文件通过 |
| 代码格式差异 | `git diff --check` | 无错误 |
| 安装包构建 | `powershell -ExecutionPolicy Bypass -File scripts/package.ps1 -Version 0.2.0 -SkipTests` | 已在同一轮完整测试后生成 ZIP |
| 安装包验证 | `powershell -ExecutionPolicy Bypass -File scripts/verify-package.ps1 -Archive dist/legado.koplugin-v0.2.0.zip -Version 0.2.0` | 65 个条目、唯一顶层目录、版本与命名空间检查通过 |

独立只读代码审查发现的迟到详情响应、取消翻页、`children.0` 层级、列表 `##` 清理以及下载视图计时器问题均已修复。相应测试先复现失败，再验证修复；最终全量结果包含这些回归检查。

交付文件：`dist/legado.koplugin-v0.2.0.zip`，162610 字节。

SHA256：`11ed8d97d43bdec53dea571ec032cf3cd04a6191f62205b0f6268bed43c8a262`。

旧版 `dist/legado.koplugin-v0.1.0.zip` 保留。本次未操作真机、推送、发布或合并分支。

## 我的验收方法

1. 解压安装包，将其中的 `legado.koplugin` 目录放到 Kindle 的 `koreader/plugins/` 下。
2. 重启 KOReader。主菜单应出现“书源阅读”，其中有书架、搜索、书源管理和发现入口。
3. 导入自己的常用 JSON 书源，搜索一本书，打开目录并开始阅读；使用有静态发现分类的书源检查“发现”。
4. 缓存章节后断网重开，应恢复阅读位置；未缓存章节应明确提示。更多项目见 `docs/kpw6-checklist.md`。

## 未解决事项

- **尚未验证：物理 Kindle 的显示、触摸、休眠、网络及实际安装。** 当前未连接设备，没有可用 KOReader 模拟器；需在设备上按上述方式和手工清单验收。
- **尚未验证：真实网站书源。** 自动流程使用可控 HTML/JSON 响应；实际站点可能改变结构、限制访问或使用当前不支持的规则，需导入自己的书源运行四步诊断。
- 不执行 JavaScript、WebView、Java/Android API，不支持复杂默认索引区间、步长或排除语法。`##` 使用 Lua 模式匹配，不能视为完整 Java 正则兼容。
- 听书仍是既有占位入口。下一阶段应依据真机和实际常用书源的诊断结果，有针对性地补充规则兼容。
