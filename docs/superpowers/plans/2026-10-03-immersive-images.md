# 无感阅读图片支持 Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 微信图文章节在无感阅读中按原文顺序显示图片，修复截图中的合法图片请求被拒绝，保留离线阅读、翻章和评论定位。

**Architecture:** 保留字符串段落模型，图片占用空字符串段落并通过 `model.images[paragraph]` 存放经缓存校验的路径和尺寸。图片位置长度为 1，文字仍沿用 UTF-8 字符位置；图片不增加随文评论原文偏移。分页只计算尺寸，当前页面使用宿主 ImageWidget 绘制并释放。

**Tech Stack:** LuaJIT、现有 CacheStore、KOReader v2026.07.1 ImageWidget；不增加依赖。

**Spec:** 本文设计与用户 2026-10-03 的图片和要求。

## 设计比较

| 方案 | 收益 | 代价 |
|---|---|---|
| 正文内图文块（推荐） | 顺序自然，保留文字选择和评论 | 分页增加一个图片块分支 |
| 每图独立整页 | 排版简单 | 小插图也中断阅读 |
| 整章转图片 | 接近源网页 | 内存、速度及文字选择不适合 Kindle |

## Global Constraints

- 图片只从现有经过完整性、格式、尺寸、解码和路径校验的缓存读取。
- 按比例缩小，不拉伸，不裁去正文图片；本页放不下时从下一页显示。
- 保留文字段落的旧接口，图片段落为空字符串，图片位置长度为 1。
- 分页后台不得持有图片位图；当前页替换、失败、关闭都释放 ImageWidget。
- 合法微信资源 URL 必须有真实接口或项目参考证据，不能放开任意网址。
- 暂不新增图片放大手势或设置；现有翻页、划词和随文评论手势保持。

## Review Focus

- 图片前后文字与评论原文范围正确，不因图片分段增加原文偏移。
- 连续图片、纯图片章节、页尾图片始终前进，返回和恢复不丢图。
- 横竖屏及字体变化重新排版，不保留旧页面图片位图。
- 缓存损坏或本地路径越界不能交给图片组件；新章失败保留旧页。
- 真实宿主 ImageWidget 的 lazy decode/free 契约被测试覆盖。

### Task 1：可信资源与缓存描述

**Files:** weread_images.lua、weread_client.lua（URL 根因确定后）；cache_store.lua；spec/weread_image_cache_spec.lua、spec/weread_client_spec.lua。

**Interfaces:** `CacheStore:chapterImages(source, book, chapter, body) -> assets, error`；assets 以正文 src 为键，值 `{path,width,height}`；`verifyChapterImages` 复用此校验。

- [x] 从设备日志、缓存和微信官方网页确认被拒绝的合法资源形式，写 RED 测试。
- [x] 最小 URL 规则修复，恶意主机、路径和协议仍拒绝。
- [x] 增加经过校验的图片描述，覆盖不可用和损坏缓存。

### Task 2：解析、分页与绘制

**Files:** leko_text.lua、leko_paginator.lua、ui/leko_reader.lua；新 spec/phase3/leko_images_spec.lua。

**Interfaces:** `Text.parse(body,title,map_positions,assets)`；`Text.positionLength(model,index)`；Paginator image element `{type='image',path,width,height,paragraph}`。

- [x] RED：图文顺序、纯图片、分页前进、尺寸边界、评论范围、图片进度。
- [x] 解析图像块，保留原文文字偏移；分页加入图片比例及剩余高度判断。
- [x] 绘制先检查预适配尺寸的解码结果，再把唯一位图交给 ImageWidget；不进入文件位图缓存，替换、失败和关闭释放。
- [x] 对真实宿主 ImageWidget 做契约探针，运行关联 specs。

### Task 3：会话接入与交付

**Files:** reader_session.lua、leko_reader_ui.lua、ui/app.lua、ui/presenter.lua；对应 reader_entry_defaults 等 specs；版本、README、发布说明。

**Interfaces:** openChapter payload 增加 images；prepareChapter 增加 images 参数；prepared 记录保留图片描述供样式重排。

- [x] RED：图片章保持无感、恢复已含图书、两种模式自由切换。
- [x] 获取正文时保留其缓存所属对象，传递图片描述；去除强制原生与过期提示。
- [x] 全部回归和官方兼容验证；独立只读审查后修复发现的问题。
- [ ] 打包 v0.10.44，同步原交付位置；连接设备时逐文件备份安装并读取核对。
- [ ] 按用户既有授权更新 GitHub 对应项目和正式 Release；发布后读取校验。

## 实机验收

重启 KOReader，开启无感，阅读《生育制度》等含图章节；正文图片完整、顺序正确。跨图片章前后翻页；退出重开恢复位置。已缓存章节断网可看图片。切换原生并翻页，返回无感继续阅读。桌面与安装验证不能代替真实账号与设备触控验收。

## 实施裁定与证据

- `weread_client.fetchResource` 只接受规范化后的绝对 HTTPS URL；相对路径归一化留在 Images 层，因为该层持有 book.remote_id。没有放宽下载器的主机或协议。
- `note.png` 的引用文本转换是针对现场旧 EPUB 的兼容判断；原标签没有微信官方新脚注属性。普通插图仍完整下载。
- 图片缓存清单协议只应用于微信来源，普通书源原生 HTML 沿用原入口。其他书源的远程图片规则不在本次截图证据覆盖范围。
- 属性边界审查并未证明正式微信网络流程的任意文件漏洞：正文 Cleaner 会去掉 data-src。本次修复独立缓存与解析边界，让校验和绘制都读取真实 src。
- 宿主 ImageWidget 的 nil 解码棋盘格回退会误提交候选页面；先检查解码，再交付唯一位图所有权，并启用实际透明通道混合。
- 最终桌面全量：192 specs / 48,312 assertions；官方兼容 12 / 37,894 及 SQLite 通过。设备安装和发布读取证据保留在本地 `.tools/immersive-images-20261003/`，不发布账号、日志或正文。
- 已验证设备安装：13 个修改文件逐个备份替换，145 个文件整体读取与 v0.10.44 安装包完全一致。原位置同步和 GitHub 正式发布在源码提交后执行；其是否完成以发布页、下载资产和本地读取记录为准。
