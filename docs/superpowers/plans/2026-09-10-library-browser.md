# 独立图书浏览与聚合搜索实施计划

**目标**：实现用户已要求并确认的独立插件方向。输入书名即跨启用书源搜索、结果逐步出现；发现按站点→分类→图书浏览；搜索、分类列表、详情展示封面和简介；去掉听书入口。交付新的可区分版本安装包。

**参考**：Legado_Max SearchModel/SearchViewModel 的并发搜索、渐进结果与同书多来源；item_search.xml 的左封面右作者/简介/来源数量；ExploreAdapter/ExploreShowActivity 的站点分类导航；BookInfoActivity 的图书详情。现有项目位于隔离分支 codex/legado-koplugin。

**实施技能**：writing-plans、subagent-driven-development、verification-before-completion。沿用已授权实现，不新增设计确认关口；分工仅限相互独立文件。保护全部已有用户数据和未提交改动，不提交他人改动。

## 界面与模块约定

- 新 `legado/ui/library_screen.lua`：原生 KOReader 控件组成的插件全屏容器，白色背景、页标题、状态、图书卡片、操作栏、书架/搜索/发现/书源导航。与 FileManager 完全无数据耦合。
- `LibraryScreen.new(options)`：`title, subtitle, items, mode`（cards/grid/detail）、`actions, navigation, on_back, on_close, on_select, cover_loader, page, on_prev, on_next, empty_text`。item 字段为 `book,title,subtitle,intro,cover_url,source_count,callback,enabled`；book 为 Models.book。普通来源/分类 item 无 book/封面，显示选择按钮。
- 屏幕方法 `closeForReplacement()`：只关闭控件、取消封面，不销毁控制器；`onClose()`：关闭控件再执行 on_back 或 on_close；`kind=library_screen`。选书与 action 回调由 Presenter 管理页面栈，控件本身不抢先销毁模型。`items` 由 Presenter 分页（卡片3、封面6、选项8）；屏幕可按空间减少显示并报告容量给 Presenter。
- Presenter 管理可返回的插件页面栈。以隐藏/替换而非层层叠加方式更新屏幕；屏幕关闭取消封面，离开控制器取消网络。阅读开始前移除所有插件浏览页面，失败在原详情展示并可换源。
- 来源/规则不支持是页面状态，保留搜索/返回/其它来源入口，不伪装为空结果或删除用户书源。无 JavaScript 引擎的限制继续明确展示，不执行来自书源的任意脚本。

## 1. 搜索和分类数据

- [x] `book_service.lua` 增加向后兼容的 `search(keyword, ids, page, complete, on_progress)`；每个来源完成后给累计快照（groups/errors/total/completed/succeeded/failed），失败不影响其它源；同步失败不会递归栈溢出。
- [x] 按书名/作者聚合、书籍 URL 去重，优先关键词完全匹配。无结果、无启用源、取消与全部失败有区别。
- [x] `ui/search.lua` 在进度回调更新可见结果，取消保留已有结果；未完成时可选书。
- [x] 分类解析支持已存在的静态字符串/JSON/table 形式，搜索规则可作未给 ruleExplore 时的原版兼容回退；各分类分别诊断。核心字段失败仍报告；简介/封面等辅助字段不支持时保留能识别的书。
- [x] 有意义的失败→通过测试：一个失败+两个成功源聚合；慢源不阻塞早期展示；停止后回调无效；静态分类及辅助规则失败。

## 2. 独立全屏图书控件

- [x] LibraryScreen 实际绘制白色背景和边框、封面占位、卡片简介与来源计数；本地存在封面可重用，异步图片失败保持占位。
- [x] 屏幕宽高按设备计算，按钮和卡片均可触摸/按键操作；无封面和零本书保留明确操作入口。
- [x] 验证原版 TextWidget/Button/Frame/Group/Image 合同，关闭/替换取消封面且忽略迟到回调；输出可审查的布局验证产物。

## 3. 完整页面流程

- [x] Presenter/App/Bootstrap 接入新控件，默认独立书架首页、输入书名即搜索全部启用源。原 sourceChoices 仅可作为后续筛选，不作为前置步骤。
- [x] 发现显示站点及分类可用状态，点击站点进入分类页，分类进入封面简介卡片，详情独立展示封面/作者/简介/来源，支持目录/阅读/收藏/换源。
- [x] 结果卡片复用详情中取得的元信息，加入书架将完整 book 保存至插件 SQLite；封面缓存复用。
- [x] 移除菜单和 App 听书入口及启动依赖，不删除其它用户数据。

## 4. 验证和交付

- [x] 测试生产 App→Presenter→Screen 的搜索、发现、详情、返回、换源、收藏、阅读窗口退出。
- [x] 对实际合集以及已适配站点运行受限联网查询，保留每步结果和失败理由，不把导入数量当作可读网站数量。
- [x] 全量回归、固定 KOReader 官方合同、真实 SQLite 919源持久化、原生布局绘制审查、安装包校验。
- [x] 新版 0.3.0（不覆盖已交付0.2.7），更新操作/测试文档，给安装包和真实验证边界。
