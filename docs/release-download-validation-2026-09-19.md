# VoxStudio 下载缓存上线记录 — 2026-09-19

状态：代码、发布流程及生产缓存已上线；下列未覆盖客户端环境仍需补充验收。

## 已部署

- 原公开 Worker 版本：`c8ae4e21-cfd3-48d2-a6f1-ad15d4725cde`。
- 修复后的 origin 网关：`f4d8e90e-3d9a-4e01-8084-d8c968646e7e`。
- 初次 cache 网关：`c2b41159-a8fc-4f5b-9efc-a5393e0caf7f`。
- 最终 cache 网关（HIT 不读 R2 元数据）：`b15ce9f4-53a4-4ce1-9fc0-1a8d760ae0e4`。
- 私有下载缓存 Worker：`voxstudio-release-cache`，版本 `b0d9b11d-8a94-4ea1-821d-6d9123a9a4b9`。
- 临时 `voxstudio-release-cache-probe` 已删除。

公开网关关闭 Workers Cache，使用私有 Service Binding 获取不可变 DMG 缓存。正常 versioned 缓存命中不读取 R2 manifest；MISS 时由私有源校验对象。latest 仍需读取 stable，HEAD 和无效 Range 处理可能读取 R2 元数据。已有模型和主路由的打包代码在部署前逐段比对，与原线上版本一致。音视频签名和 Referer 检查仍由原网关执行。

没有重建或上传 DMG，没有写 stable，没有部署网站，没有更改 HTTP/3 或 Zone 缓存规则。

## 当前包与线上验证

- 版本：7.0.16，build 97。
- 字节数：91,824,974。
- SHA-256：`ec61144222827d4393ba8b7ac057e2f2b5292cdfda262e117a7febf795a7b58a`。
- POP：SIN。
- origin 和 cache 两种交付模式均通过公开 URL 检查。
- 普通 latest GET/HEAD 返回不可缓存的 302，目标是当前不可变 URL。
- HEAD 忽略 Range。
- latest 缺失、错误、弱或日期型 If-Range 返回完整 200，无 Content-Range；匹配强 ETag 返回 206。
- 不可满足的范围返回 416 及正确总长度。
- 实际完整下载在 20 MiB 处关闭后继续 Range 下载，最终字节数和 SHA-256 正确。
- 公开 cache 网关完整下载及后续范围请求确认内部 HIT；缓存部署标识正确。
- 7.0.15/build 96 的并发请求中，一条取消，另一条从 MISS 完整下载并通过 SHA-256；后续范围请求 HIT。没有切换生产 stable 来进行跨版本测试。
- 发布脚本的真实 `verify`、`cache-check` 均通过；只读 postcheck 确认 latest 和 appcast 一致。未执行新的渠道提升。

## Safari 验证

本机 macOS 26.6.1、Safari 27.0。从 latest URL 开始下载，在约 51.6 MB 处暂停，退出并重开 Safari 后点击恢复；界面显示从约 51.8 MB 继续，最终完成 91.8 MB。

完成文件 `/Users/adamwang/Downloads/VoxStudio.dmg` 的 SHA-256 与发布包一致。使用 appcast 的 Ed25519 签名及应用 Info.plist 中的 SUPublicEDKey 验证该文件，签名通过。

此结果不代表 Safari 18/macOS 15、其他故障网络、没有可靠校验器的历史失败任务或旧版 Sparkle 安装器已通过实机验收。VoxStudio 当时未运行，未启动新的应用构建，也未操作应用内更新 UI；当前应用打开浏览器更新链接的实现未改动。

## 自动检查

- Worker：43 项测试通过，含跨版本续传、生产 origin 路径、缓存请求隔离、故障回退、源对象大小不匹配、Range 语法及 R2 元数据不可用时的缓存下载。
- TypeScript：通过。
- R2 发布脚本：16 项测试通过。
- 版本发布测试：10 项通过。
- `bash -n scripts/release.sh`：通过。
- `RELEASE_RESUME=1 RELEASE_DRY_RUN=1 ./scripts/release.sh`：通过；使用暂存包，不加版本、不构建、不写远端或模拟成功状态。

## 发布与回退

未来发布顺序为 prepare → upload → verify → cache-check → promote → postcheck。完整 verify GET 同时预热；缓存检查失败或部署变化会阻止新的 promote。状态绑定具体文件身份、公开 origin 和 R2 目标；并发 stable 改变导致条件写入失败。postcheck 失败保留已经完成的 promote，恢复执行不会重复构建。

需要回退交付时，在公开 Worker 的 `wrangler.jsonc` 设置 `RELEASE_DELIVERY_MODE=origin` 后部署，保留 `RELEASE_DOWNLOAD_MODE=origin` 和已修复的续传校验。不要直接恢复含日期型 If-Range 缺陷的旧 Worker。

详细操作见 Worker 仓库的 `docs/release-cdn-runbook.md`，以及本仓库 `skills/voxstudio-release/references/release-runbook.md`。原始 HTTP 验证结果保存在 `docs/release-download-validation/2026-09-19.json`。
