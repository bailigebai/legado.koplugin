# 整本缓存与微信阅读缓存根目录故障

基线 c738648 / v0.10.40。用户设备 GN433W116246017G 已连接，当前插件 145 文件已备份，读取同次 crash.log（末尾 10/03 07:53）。

## 根因和证据

1. 官方 KOReader v2026.07.1 `datastorage.lua` 默认 `getDataDir()` 为 `.`，提供 `getFullDataDir()` 返回绝对路径。bootstrap 用相对目录构建默认离线缓存，而 `download_cache_path.resolve` 拒绝相对目录，导致默认离线缓存未初始化。
2. BookDetail:startCache/startDownload 使用 Lua `and/or`，丢弃下游返回的第二个错误值，并把 nil 替换为占位文字，UI 因无真实错误码显示 DOWNLOAD_ERROR。
3. 微信报错来自 CacheStore:_scan 的 dev/ino 比较。Linux FAT 在 inode 重建时用 iunique 分配 ino，不能把未持有的 ino 当作整个阅读会话的永久身份；KOReader Kindle 启动脚本也注明 FAT/FUSE 存储特点。这是匹配用户错误的根因推断，尚无设备 inode 变化轨迹证明。通过模拟 inode 回收验证持有目录句柄的修复，并保留真实目录替换的拒绝行为。

来源：本地官方 `datastorage.lua`、`platform/kindle/koreader.sh`；https://github.com/torvalds/linux/blob/master/fs/fat/inode.c 的 fat_build_inode。

## 三个方案

1. 推荐：bootstrap 使用官方绝对数据目录；Fs 提供可回收的只读目录句柄，CacheStore 在对象存活期间持有并保留原身份比较；详情页显式转发多返回值。安全写入和路径检查保留。
2. 每次身份变化自动重绑定并重试：可能接受真实替换目录，且无法证明之前缓存的归属。
3. 去掉身份比较：改动少，但破坏原有安全写入约束，不采用。

## 实施和验收

1. 先写行为回归，观察 RED：官方默认 `.` 仍初始化离线缓存；整本/部分/EPUB 错误传到界面；模拟 FAT 空闲 inode 回收后读取及写入正常，真实替换目录仍被拒绝，释放对象后句柄不泄漏。
2. 最小修改 `bootstrap.lua`、`fs.lua`、`cache_store.lua`、`book_detail.lua`；不删除缓存和用户数据，不调整数据库或网络协议。
3. 针对规格、完整回归和官方宿主检查通过后独立审查；打包 v0.10.41，设备安装并完整回读，按既有授权同步安装包/源码和 GitHub 下载目录。
4. 用户验收：重启 KOReader，默认目录缓存一本短书/前若干章并断网读已缓存章节；微信开始阅读及连续翻章。真实帐号/设备阅读结果仍由实机确认。

## 执行结果（2026-10-03）

- 三组故障回归先失败，修改后通过；完整 191 项 Lua 规格、48,209 条断言通过。
- 官方 KOReader v2026.07.1 宿主检查 12 项契约、37,894 条断言通过，官方 SQLite 实际运行检查通过。
- 独立审查未发现重要问题；补充核验目录身份缺失、异常、打开期间被替换的句柄关闭，以及对象释放后仅关闭一次。
- v0.10.41 安装包 145 文件、510,004 字节；SHA256：`a8c12ccf76ccc54db4a80d0af7deb6e5d5f35a64cb52a8e5ca1235406d5f1231`。
- Kindle GN433W116246017G 已安装并独立回读 145 文件，逐文件与安装包一致；旧插件已备份，用户数据保持原位。
- GitHub main 下载目录提交 `7a8027b91d1a91bf8a668593acec3e9d2e4eb111` 已公开读取核验，下载包与本地、设备回读一致。本次更新下载目录，尚未创建 GitHub Release 或合并完整开发分支。
- FAT/FUSE 身份变化仍为根因推断；微信真实帐号开始阅读、整本缓存完成和断网阅读仍需设备重启后验收。
