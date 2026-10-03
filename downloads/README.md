# 不亦阅乎 v0.10.41 安装包

2026-10-03 更新本项目下载目录，已安装到 Kindle GN433W116246017G。

[下载安装包](https://github.com/bailigebai/legado.koplugin/raw/refs/heads/main/downloads/legado.koplugin-v0.10.41-20261003.zip) · [SHA256 校验](legado.koplugin-v0.10.41-20261003.zip.sha256)

## 修复

- 默认离线缓存使用 KOReader 的绝对数据目录，修复整本缓存未初始化。
- 整本、部分缓存及 EPUB 导出保留真实错误码，避免错误被吞掉后只显示 DOWNLOAD_ERROR。
- 缓存对象存活期间保持只读目录句柄，针对 FAT inode 回收造成的目录身份变化；真实目录替换、链接和路径越界仍被拒绝。
- 保留 v0.10.40 的章尾失败重试，以及书架、图片、随文评论和下载进度等功能。

## 安装与验收

已连接设备安装完成；安全弹出后完全退出并重启 KOReader，确认版本 0.10.41。
手动安装时，把 ZIP 内的 legado.koplugin/ 复制至 koreader/plugins/，替换代码后重启，保留用户数据和 settings。

默认目录缓存一本短书或前 5 章，查看下载管理进度，断网读已缓存章节；微信书架开始阅读，闲置后继续翻章。整本完整成功才显示已下载封面标记，自定义目录可保留原设置。

## 验证范围

191 项 Lua 规格、48,209 条断言，12 项官方宿主契约、37,894 条断言及官方 SQLite 检查通过。设备完整读回 145 个文件，全部与 ZIP 一致。

FAT/FUSE 引起微信目录身份变化仍是根因推断；桌面模拟和安装字节校验不能代替设备实际阅读。若仍失败，保留错误码、时间、默认或自定义目录选择和同次 crash.log。[详细记录](../docs/cache-download-recovery-0.10.41.md)

本次更新仓库 downloads；GitHub Releases 当前仍为 v0.10.36，应用商店自动下载以已发布版本为准。

SHA256：a8c12ccf76ccc54db4a80d0af7deb6e5d5f35a64cb52a8e5ca1235406d5f1231
