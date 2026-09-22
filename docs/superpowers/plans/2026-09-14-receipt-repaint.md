# 小票实机故障排查（临时规划）

目标：屏幕上方四分之一点击后真正画出控制栏，返回、尺寸、样式可操作。

## 设备证据

- 已通过 Windows MTP 读取 Kindle Paperwhite 6；设备不分配盘符。
- 证据目录：`../../device_tmp/legado_receipt_20260914/`。只读取插件代码、日志、补丁和原生 UI 文件，不修改书籍数据。
- `version.log`：KOReader v2026.07.1。设备与本地 receipt_screen.lua 的 SHA256 同为 B8534A5B905B13D4D127DABF805565684A8112D9377CFC706AC7806957709660。
- 日志更新到 9 月 14 日，但没有记录小票点击与重画状态，不能仅凭日志断定手势丢失。
- 设备 UIManager 的 setDirty 文档明确：nil 只排队屏幕刷新，不标记任何窗口重画。小票切换控制栏后传 nil。
- 旧测试手工调用 paintTo，且 UIManager 是只计数的替身，未检查实际调度后的重画。

## 方案比较

1. 扩大热区：修改少，但设备已有全宽热区，不能解释已切换状态却未重画。
2. 修正重画目标，使用原生 UIManager 复现和回归：推荐，保留布局及操作，范围仅限小票。
3. 重写为另一套弹窗：影响范围大，当前证据不足以支持重写。

## 执行与验收

1. 新增通过原生 show / sendEvent / _repaint 的失败用例，不手工绘制小票。
2. 修正 receipt_screen.lua 中内容发生变化时的重画目标，同步覆盖封面与焦点。
3. 用官方 UIManager 和设备导出的 UIManager 分别验证白底与阅读悬浮入口、各样式、点击边缘、显隐、三个按钮、关闭和延迟封面。
4. 全量测试、打包及校验。保留旧包与设备代码备份。
5. 在本次设备排错和可恢复修复范围内，仅安装经过验证的小票文件，先备份、后上传、再回读校验。实体触屏仍需用户验收。

## 完成记录

- 已复现旧代码：controls_visible 为 true，但原生 UIManager 没有绘制“宽度 / 高度”。官方与设备导出的 UIManager 均失败于相同断言。
- 内容变化后改为 setDirty(widget, 'ui')；小票内封面与焦点的相同错误一并修正。新增 build / requested / painted 日志，不包含书名、正文或账号信息。
- 新测试不主动调用小票 paintTo，通过原生 show / sendEvent / _repaint 完成整段流程。官方与设备 UIManager 均通过 174 项断言。
- 全量 97 specs / 9723 assertions；原生兼容 11 specs / 5263 assertions；SQLite 检查通过。
- 已安装单个 receipt_screen.lua。MTP 复制是异步的，必须等待上传完成再回读；已核对最终文件 SHA256：98F9A9CF31EC5615BEA461C3F18FEF77766CDF6A37398A285CC38771FAF019CA。
- 设备同目录保留 receipt_screen.before-repaint-20260914.lua 原文件；电脑原插件备份仍位于证据目录中。
- 新安装包：AA/dist/legado.koplugin-v0.7.1-receipt-repaint-20260914.zip。补充文档后的最终 SHA256：B8390521739122543180AA74C0C9EC6B46ECC6FAF796DB8F5EF5A7840E3B70A9。
- 尚未验证：物理触屏验收。已请用户断开 USB、完全重启 KOReader 后操作；电脑只能通过 MTP 读写文件，未远程控制设备运行界面。
