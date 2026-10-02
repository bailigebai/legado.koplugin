# 不亦阅乎 v0.10.40 安装包

2026-10-02 已更新本项目下载目录，并安装到 Kindle GN433W116246017G。

[下载安装包](https://github.com/bailigebai/legado.koplugin/raw/refs/heads/main/downloads/legado.koplugin-v0.10.40-20261002.zip) · [SHA256 校验文件](legado.koplugin-v0.10.40-20261002.zip.sha256)

## 本次修复

- 原生模式：下一章异步打开失败后解除章尾翻章限制，保留仍可用的旧章节，允许再次翻页重试。
- 无感模式：补齐目录后的切章若保存进度、请求启动或打开失败，结束界面等待，同一章可重试；错误只通知一次。
- 保留 v0.10.39 的书架排版、图片、评论、选字、缓存下载和 EPUB 导出功能。

## 安装与验收

本次连接设备已完成安装；安全弹出后完全退出并重启 KOReader，确认版本 0.10.40。
自行安装时，退出 KOReader，将 ZIP 中的 legado.koplugin/ 复制到 koreader/plugins/，替换代码后重启。保留用户数据和 settings 目录。

用原来的在线、未整本缓存书源，在两种阅读模式分别连续跨过至少 30 章。失败后再次翻页应允许重试，不应永久停在章节末尾。

## 验证范围

两个故障均观察到修复前测试失败、修复后通过。完整 190 项 Lua 规格、48,193 条断言，12 项官方 KOReader 契约、37,894 条断言及官方 SQLite 检查通过。安装后完整回读 145 个文件，全部与本 ZIP 一致。

桌面测试证明具体失败路径已修复，设备偶发问题是否完全消失仍待连续阅读确认。若仍发生，请保留大致时间、章号、模式和同次 koreader/crash.log。[修复记录](../docs/chapter-end-recovery-0.10.40.md)

本次更新仓库 downloads；GitHub Releases 当前仍为 v0.10.36，应用商店自动下载以已发布版本为准。

SHA256：f58e8db60d40533b8020cc2d5ce4059dc253c9c20cc9261b24f04fe8012a392e
