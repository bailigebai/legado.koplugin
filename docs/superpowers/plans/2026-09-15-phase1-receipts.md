# 第一期：新增六款阅读小票

目标：在现有九款基础上新增六种可区分的版式，共十五款。用户已授权本期开发；本文件记录设计、范围和验收，不新增运行依赖。

## 方案比较

| 方案 | 代价与效果 | 结论 |
| --- | --- | --- |
| 复用原生绘制 helper | 继续使用文字、封面、线框和进度条，适合黑白屏并复用公共手势/清理 | 推荐并采用 |
| 图片背景模板 | 增加图片解码和内存，文字尺寸难适应 | 不采用 |
| 通用模板解释器 | 需要新的配置格式与验证，十五个固定版式用不到 | 不采用 |

## 布局

| 保存值 | 菜单名称 | 结构 |
| --- | --- | --- |
| exhibition | 展览入场券 | 粗竖边、展品大封面、作品铭牌及参观统计 |
| passport | 阅读护照 | 双页中缝、书籍身份页、日期印章和阅读签证 |
| contact | 胶片联系表 | 黑色胶片底、三枚编号画格，依次展示封面、今日时长、累计时长 |
| archive | 阅读档案 | 档案题签、编号、摘要字段与小封面、进度归档栏 |
| timeline | 阅读时间轴 | 左侧时间轴，三个节点依次显示开始、最近阅读、当前位置，右上小封面 |
| bookmark | 极简书签 | 狭长居中线框、居中封面、书名、阅读进度与留白 |

所有版式只呈现已有真实阅读数据；胶片格与护照印章是静态装饰，不虚构历史、行程或可扫描编码。

## 文件与边界

- `legado.koplugin/legado/lib/receipt_styles.lua`：增加六个有序项目，设置校验和菜单自动复用。
- `legado.koplugin/legado/ui/receipt_screen.lua`：只增加六个布局分支；保留顶部四分之一根 Tap、`setDirty(widget,'ui')`、Font 额外高度、宽高比例、短评、封面回调及清理逻辑。
- `spec/native_receipt_screen_spec.lua`、`spec/receipt_repaint_spec.lua`、`spec/reading_review_spec.lua`、`spec/default_settings_store_spec.lua`：扩展已有行为测试，覆盖十五款。
- `scripts/preview_receipts.py`：总览行数按数量计算，可筛选本次六款；原参数继续有效。
- 不修改设置层、presenter、README、版本、发布白名单；集成及打包由主任务负责。

## 执行与验收

- [x] 先扩展菜单、JSON 重启、真实 UIManager 重画和原生边界测试，确认新样式缺失导致失败。
- [x] 加入六种原生布局，检查默认数据、空数据、长书名/作者/章节/短评。
- [x] 通过四种分辨率 × 五种宽高配置 × 十五款，以及短评点击、封面加载/失败/迟到与重复关闭。
- [x] 生成默认、最窄及横向宽高预览，查看本次六款效果图。
- [x] 重新检查布局边界、错误处理和资源清理；主任务后续独立复核及集成。

设备验收方法：安装后完全重启 KOReader，从阅读回顾进入小票，点屏幕顶部四分之一 → 样式，逐款查看六个新名称；修改宽高、短评后重开并确认保存。电脑原生控件测试和桌面字体预览不等于 Kindle 实机触控验收。

## 本期验证记录

- 先红：4 项规格均按预期失败（菜单实际只有 9 项、保存新值回退 classic、新样式绘制与重画缺失）。
- 后绿：6 项规格、37,260 项断言通过，包括原生边界 36,070、真实 UIManager 重画 870；原有背景与回顾流程同时通过。
- 原生边界矩阵：600×800、800×600、1200×1600、1600×1200；宽/高为 75/90、50/55、95/95、50/95、95/55；每组都检查十五款的长文本和空数据。
- 预览：`dist/receipt-styles-20260915`、`dist/receipt-styles-20260915-narrow`、`dist/receipt-styles-20260915-wide`；均逐张查看。默认无筛选调用生成十五款总览 1800×4250，筛选六款总览 1800×1700，图片数量核对通过。
- 重跑：`.tools/python/python.exe scripts/run_lua_specs.py --spec spec/reading_review_spec.lua --spec spec/default_settings_store_spec.lua --spec spec/native_receipt_screen_spec.lua --spec spec/receipt_repaint_spec.lua --spec spec/receipt_background_spec.lua --spec spec/reading_review_flow_spec.lua`。
- 未执行：物理 Kindle 验收、主任务全量集成与最终包验证。
