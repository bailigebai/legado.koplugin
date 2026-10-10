# 不亦阅乎 v0.10.54 安装包

2026-10-10：新增手动 AI 密钥、模型切换和选区读书模板。

[下载安装包](https://github.com/bailigebai/legado.koplugin/releases/download/v0.10.54/legado.koplugin-v0.10.54-20261010.zip) · [SHA256 校验](legado.koplugin-v0.10.54-20261010.zip.sha256)

## 本次更新

- 保留密钥 JSON 文件，新增掩码手动输入；密钥独立保存在设备上，不写入普通设置。
- 各服务商分别选择并记忆模型，支持自定义模型 ID；MiMo 默认更新为 2.6 Pro。
- 书源、微信与可选中文字的本地书，滑动选区后可选择八种读书提示词模板，保留原文与补充要求，确认后才发送。
- 包含 v0.10.52 的 Obsidian 摘录及之前的功能；电脑接收端仍需启用并配置私有连接文件。

## 安装与验收

完整退出 KOReader，把 ZIP 内的 `legado.koplugin/` 复制至 `koreader/plugins/`，替换插件代码后重启，确认版本 0.10.54。保留用户数据、settings 和已有授权。

详细配置及验收步骤见 [AI 使用说明](../docs/ai-configuration-0.10.54.md)。桌面与官方兼容检查用于验证配置和请求流程；Kindle 触控和真实 AI 网络回答仍需设备验收，无感跨页拖选尚未实现。
