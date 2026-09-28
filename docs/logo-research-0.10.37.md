# “不亦阅乎”书架图标核对

核对日期：2026-09-29。目标是在 Kindle 的黑白墨水屏上，用一个清楚的图形标识插件书架。以下只比较外部候选；安装包没有复制这些图标。

| 方案 | 来源与许可 | 在本插件中的取舍 |
| --- | --- | --- |
| [Lucide `book-open`](https://lucide.dev/icons/book-open) | Lucide 当前图标页注明 ISC | 线条简洁，直接表达阅读；默认线宽较细，缩到书架标题栏后辨识度需实机确认。 |
| [Phosphor `book-open-text`](https://github.com/phosphor-icons/core/blob/main/assets/regular/book-open-text.svg) | 官方 SVG 图标库为 MIT | 有不同线重可选，但引入现成图标会增加许可声明和后续资产管理。 |
| [Google Material Symbols](https://github.com/google/material-design-icons) 的 `menu_book` | 官方仓库为 Apache-2.0 | 实心版本在墨水屏上醒目，但较常见，作为“不亦阅乎”独立标识的区分度较低。 |
| 当前项目原创 [开卷 SVG](../legado.koplugin/assets/logo.svg) | 项目自有资源 | 黑白对比明确，方形轮廓适合 30 像素标题栏；无需加入第三方图标资产。**采用此方案。** |

代码原先只按页面标题“不亦阅乎”加载 SVG，实际主书架标题是“书架”或“本地书架”。现在主书架显式传入 `brand_logo`，首页、后续分页和本地书架都显示同一个图标；功能子页仍只显示自己的标题。KOReader 的 `ImageWidget` 支持从 SVG 文件渲染，桌面原生控件规格确认标题栏宽度不超过 600 像素。Kindle 上的物理对比度与触控位置仍需设备验收。
