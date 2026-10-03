# 不亦阅乎 v0.10.42 安装包

2026-10-03：授权提示顶部增加“插件售价：25 元”。

[下载安装包](https://github.com/bailigebai/legado.koplugin/releases/download/v0.10.42/legado.koplugin-v0.10.42-20261003.zip) · [SHA256 校验](legado.koplugin-v0.10.42-20261003.zip.sha256)

## 本次更新

- 密钥激活窗口直接显示插件售价，沿用现有购买说明及短密钥。
- 包含 v0.10.41 的默认离线缓存目录、真实错误码及缓存目录句柄修复。
- 保留 v0.10.40 的章尾失败重试，以及书架、图片、随文评论和下载进度等功能。

## 安装与验收

完整退出 KOReader，把 ZIP 内的 legado.koplugin/ 复制至 koreader/plugins/，替换插件代码后重启，确认版本 0.10.42。保留用户数据、settings 和已有授权。

未激活时进入密钥激活窗口，第一行应显示“插件售价：25 元”；已有授权升级后继续有效。

微信阅读及整本缓存修复仍需设备实际阅读确认，具体步骤和验证边界见 [v0.10.41 记录](../docs/cache-download-recovery-0.10.41.md)。
