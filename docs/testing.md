# 测试与发布验证

## 自动测试环境

Windows 测试由 `scripts/run-specs.ps1` 启动，首次运行会把 Lupa 2.8 的 `luajit21` 测试运行时安装到未跟踪的 `.tools/python/`。测试覆盖插件入口、持久化、规则、网络、UI、阅读缓存、EPUB、下载恢复、诊断与听书占位，并执行命名空间、入口冒烟和 EPUB ZIP 自检。

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run-specs.ps1
```

固定 KOReader 基线检查使用：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check-koreader-compat.ps1
```

该脚本只接受 KOReader v2026.07.1 的固定 commit，将官方源码及固定 `koreader-base` 子模块放入忽略的 `.tools/koreader/`（已有完全一致且干净的检出时复用），并校验官方 `kindlehf` ZIP 的固定 SHA256。它静态核对插件实际引用的 ReaderUI、UI、FFI/archiver、Socket/LuaSec/Ltn12、SQLite 与子进程相关模块路径；不会启动 Kindle 二进制，也不代替真机运行。

## 构建发布包

`package.ps1` 默认先运行全部自动测试，然后仅把运行时、README、文档和许可证放进单一顶层目录。`-SkipTests` 只用于已经由同一流水线完成测试的开发场景。

```powershell
powershell -ExecutionPolicy Bypass -File scripts/package.ps1 -Version 0.1.0
powershell -ExecutionPolicy Bypass -File scripts/verify-package.ps1 -Archive dist/legado.koplugin-v0.1.0.zip -Version 0.1.0
powershell -ExecutionPolicy Bypass -File scripts/scan-sensitive.ps1
```

验证器检查顶层结构、必需文件、版本、禁入目录、凭据/书源 JSON、命名空间和入口加载。ZIP 使用排序条目和固定时间戳，以便相同提交生成相同 SHA256。

## 未执行范围

当前开发机未连接物理 KPW6，也没有使用真实书源进行联网验收。因此自动测试通过只能说明 Lua 行为、KOReader v2026.07.1 源码/`kindlehf` 模块契约和包结构符合预期；不能宣称 Kindle 固件 5.19.5 真机、站点规则或网络环境已经通过。真机步骤见 `docs/kpw6-checklist.md`，发布前必须逐项手工记录。
