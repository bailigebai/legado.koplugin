# v0.10.9 授权连通性修复与验收

2026-09-16：已修复本机可复现的授权入口不可达问题，并完成真实签名授权联调。本版沿用已有 Legado 产品、1000 条销售密钥、D1、公钥和服务端签名私钥；只锁定小票展示与阅读回顾数据。919 个默认书源、自行导入、免费阅读与书架规则不变。

## 原因与本次修改

同电脑禁用代理对照：Legado 原 `workers.dev/health` 能解析 DNS，但 TCP 连接 5.01 秒超时，未进入 TLS；可用的推箱子 Pages 地址 HTTP 200，约 1.33 秒。两个插件的 TLS 代码同源，固定入口不同。这证明当前网络的失败发生在密钥校验前，不能把它误报为错误密钥，也不能由此推断 Kindle 的具体网络状态。

采用规划中的方案 B：本产品独立 `legado-receipt-shelf-gateway.pages.dev`，经 `LICENSE` Service Binding 转发到现有 Legado Worker。另两方案为原域名延时重试（当前不通，没有改善依据）和自有域名（需要额外 DNS/域名配置）。网关不保存销售密钥、不配置私钥或 D1，未复用其他产品服务。

- `license_transport.lua` 固定端点、SNI 和主机校验统一切换到新域名；保持 TLS 证书校验、无自动跳转、不重放 POST、10 秒总超时、512/8192 字节大小上限。
- `license_store.lua` 在原子写盘后用生产 Settings 读取器重新读盘，核对授权和安装标识；不再只比对内存。
- `license.lua` 和 Store 补齐失败内存回滚：即使读回失败且回滚写也失败，仍恢复此前授权状态。无授权保持锁定，旧有效授权保持可用；不会拿新 receipt 伪报解锁。
- 服务端区分 `invalid_key`（密钥不存在）和 `bound_to_other_device`（已绑定其他设备），客户端已有对应中文提示。
- 保留 v0.10.8 的 KOReader 原生联网准备、子进程 HTTPS、等待可取消及保活机制，不修改设备 Wi-Fi 省电偏好。

## 验证证据

1. Pages 直连 TLS 1.2、保留证书校验，health 三次 HTTP 200：1.445 / 0.976 / 0.885 秒。health 仅验证路由和 product，真实授权另测。
2. 真实线上激活测试通过：首次激活、同设备重复激活、外部 ASCII 空白、小写、去横线、异设备拒绝、不存在密钥拒绝、两设备并发首次绑定。对两份真实返回签名使用插件 Lua/RSA 验签，再经生产 Settings/Fs 写入临时磁盘目录，用新的 Lua runtime 离线读取授权，共 68 个客户端断言；篡改 version/product/device_id/key_id/issued_at/signature 均拒绝。最终回滚修复后再对保存的真实签名运行 34 个断言通过。
3. 线上只插入两条独立测试 hash，测试后已清除，1000 条原销售密钥记录与测试前逐行相同。4000 个随机测试候选及 hash 唯一，且不与库存重叠；候选仅在内存中，不是新销售批次。未读取生产私钥。最初联调的分类测试夹具类型错误已修正，失败轮次临时记录同样清理。
4. 授权回归包含 DNS/TCP/TLS/接收超时、错误证书、缺失 CA、跳转、超大响应、服务端错误、保存丢失、损坏、读失败、回滚失败以及旧授权保留。最终全量 Lua：**129 组、44,635 断言，0 失败**。
5. KOReader v2026.07.1 宿主兼容：32 个 UI 模块；原生界面 12 组、37,875 断言，全部通过。真实 SQLite、网站正文写入 HTML、命名空间、EPUB、恶意 ZIP、版本检查与可重现构建检查通过。网关 6 测试，Worker 3 测试（真实 SQLite 与临时 RSA）通过。授权读取/回滚代码经独立上下文复审，发现的问题已修复并复验。

可复核命令（工作区根目录）：

```powershell
.tools/python/python.exe scripts/run_lua_specs.py --spec spec/legado_license_spec.lua --spec spec/license_transport_spec.lua --spec spec/license_activation_flow_spec.lua --spec spec/license_dialog_spec.lua --spec spec/license_scope_spec.lua
powershell -ExecutionPolicy Bypass -File scripts/run-specs.ps1
powershell -ExecutionPolicy Bypass -File scripts/check-koreader-compat.ps1 -Offline
node --test staging/legado-license-pages/test/forwarder.test.js
node --test ../../legado-license-server/worker.test.cjs
```

线上复验脚本 `staging/legado-license-pages/verify_live.py --live` 会临时写入本产品 D1，仅用于已授权的线上联调。普通测试不要运行它。私有探测材料不随包分发。

## 安装与用户验收

1. 完全退出 KOReader。解压 `legado.koplugin-v0.10.9-20260916.zip`，将其中 `legado.koplugin` 覆盖到 `koreader/plugins/`。保留阅读数据和设置，勿删除 `koreader/legado`、书架或缓存目录。
2. 重启 KOReader，确认插件版本 **0.10.9**。开启 Kindle Wi-Fi，打开“阅读小票”或“阅读回顾数据”，输入自己的 **Legado 专属短密钥**。
3. 成功后断网，完全退出再启动 KOReader，确认小票与阅读回顾仍可用。已有授权无需重新输入；其他插件的短密钥不能用于 Legado。
4. 若失败，保留屏幕上完整中文错误和该次 `koreader/crash.log`，不要公开密钥。现在“网络连接/证书/密钥/绑定其他设备/签名/保存”应有相应提示。

## 未完成的设备验收

本次未识别可用 Kindle。电脑 curl 的真实 HTTPS、宿主 LuaJIT/系统 OpenSSL、官方 KOReader 生命周期与测试替身不等于 Kindle 的 LuaSec、ARM LibreSSL 和物理 Wi-Fi 验收。因此不能声称已在 Kindle 完成激活，也没有证据证明设备此前自动断网的具体原因已消除。实机验收按上面步骤进行；本版不承诺消除所有网络阻断或原生崩溃。
