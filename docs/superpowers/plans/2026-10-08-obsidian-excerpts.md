# Obsidian 摘录实现计划

Goal: 三种阅读入口划选后持久保存并后台同步到用户 Obsidian。
Architecture: 复用阅读选区、Storage 和后台 RequestEngine；上下文提取、Markdown、同步客户端、服务与 UI 分工。
Tech Stack: Lua/LuaJIT、SQLite、LuaSocket/LuaSec、Markdown；不新增设备运行依赖。
Spec: ../specs/2026-10-08-obsidian-excerpts-design.md
Global Constraints: 只保存用户选择的文字；不覆盖已有笔记；保留本地摘录；凭据不进入仓库/交付包；网络不阻塞阅读。
Review Focus: 原生/合成阅读入口重叠、保存错误、重试去重、目标绑定、TLS 凭据发送时机、配置隐私。

- [x] 1. 摘录上下文、Markdown 与持久集合。文件：excerpt_context.lua、excerpt_markdown.lua、storage.lua、sqlite_backend.lua。先写行为测试并观察 RED，再实现到 GREEN。
- [x] 2. Obsidian 客户端、后台队列。文件：obsidian_client.lua、excerpt_service.lua、socket_transport.lua、request_engine.lua。测试断网/重启/超时/响应丢失、证书拒绝、目标改变与冲突。
- [x] 3. 接入长按划选及管理界面。文件：main.lua、leko_reader.lua、leko_reader_ui.lua、koreader_reader_ui.lua、bootstrap.lua、app.lua、presenter.lua、settings.lua。测试三条路径入口和关闭/保存失败生命周期。
- [ ] 4. 安装配置已授权的 Obsidian 接收插件，生成私有设备配置；真实读写验收；不把凭据放入源代码或压缩包。
- [ ] 5. 新上下文审查、全量检查、官方 KOReader 兼容、打包和两处交付同步。GitHub 发布延续既有授权，发布前报告影响。

## 执行记录

- BASE: cfaed3acd7df951f300f251b0817ba2f2702e8fe，codex/moon-integration，工作区干净。
- 已核实 KOReader highlight 工厂可取得 text/pos0/pos1，原生文档 doc_props 和 toc 可提供来源。无感 selection 提供段落/字符范围。
- 已核实当前仓库原未安装 Local REST API；用户授权安装到当前 Obsidian 仓库。
- Ruling: 使用已有 SQLite 持久集合，避免每次摘录重写整个 JSON 队列；fallback 只补充缺失 excerpts 空集合，已有书架数据不变。
- 四个新增 Lua spec 共 79 项断言，覆盖选区、持久化、同步和 TLS。独立审查修复异步结果提示被吞掉、本地文档关闭后旧选区可保存、长摘录读回超限；复验无未解决 Critical/Important。
- 2026-10-08 最终全量检查：227 specs / 49,253 assertions，命名空间、网络探针、真实 HTML 文件、EPUB/安装包检查通过；私有连接导出另有 5 项测试通过。
- 官方 KOReader v2026.07.1：37 UI 模块兼容检查、12 specs / 37,894 assertions；官方 SQLite 3.53.1 摘录落盘、重开及错误回滚通过。
- 接收插件 5.4.0 文件和 HTTPS 设置已安装，未生成证书：Obsidian 命令行界面仍关闭，待用户开启后启用插件及真实写入读回。当前未识别到 Kindle，实机触控与局域网同步未验证。
- `scripts/obsidian_connection.py` 只向仓库外的新目录导出设备私有连接文件；不显示密钥，不覆盖已有配置，不导出服务器私钥。
