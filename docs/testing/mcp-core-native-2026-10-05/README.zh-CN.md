# 核心插件与独立普通 MCP 验收（2026-10-05）

本次实现知识库、ASR、TTS 小型核心插件，以及复用现有编辑执行器的独立普通 `voxstudio_native` MCP。两个端点均检查工具白名单和调用参数；本机完整旧端点继续可用。所有远程 MCP 入口（包括 API 的旧 `/mcp`）均拒绝视频编辑，Cloud 核心还排除音频编辑等高级功能。

## 工具数量和容量

以下字节数为模型可见工具数组的紧凑 UTF-8 JSON；完整目录另含 App-only 工具。App-only 标记通过桌面宿主实际返回的 `ui.visibility` 验证。

| 连接 | 端点 | 模型工具 | 协议定义字节 | 桌面宿主定义字节 | 完整目录工具 / 协议字节 |
| --- | --- | ---: | ---: | ---: | ---: |
| 本地核心 `voxstudio` | `/chatgpt/mcp` | 17 | 15,332 | 16,031 | 44 / 35,660 |
| Cloud `voxstudio_cloud` | `/cloud/mcp` | 17 | 15,098 | 14,448 | 20 / 17,896 |
| 普通 `voxstudio_native` | `/native/mcp` | 64 | 96,476 | 96,476 | 65 / 96,903 |

两个核心均达成 15–18 个模型工具及模型定义 ≤16 KB 的目标，低于 24 KB 发布上限。以上目标针对模型目录；本地完整目录含 27 个面板内部工具，不能将其 35,660 字节算作模型目录。普通 MCP 不进入插件 `mcp.json`，保留高级工具明确 schema 和写入权限标记，工具说明限制长度并排除重复核心入口；其目录仍占模型上下文。

桌面宿主注册表同时加载三个连接，均无 `toolsError`：

- 本地核心属于 `voxstudio@voxstudio-local` 插件。
- Cloud 属于 `voxstudio-cloud@voxstudio-cloud-marketplace` 插件，OAuth 有效。
- 普通 `voxstudio_native` 的 `pluginId` 为空，独立注册。

同名旧 Cloud 普通连接曾遮蔽插件，现已备份移除；OAuth 凭证保留。配置备份位于本机 `~/.codex/voxstudio-cloud-backups/20261005T130144278883Z/config.toml`。核心安装迁移恢复文件位于解压包的 `.migration/20261005T124854244352Z`。

## 流程与隔离

本地 Docker 客户端连接实际运行的签名 macOS App，验证五个端点目录、核心编辑调用拒绝、旧本机完整目录兼容，以及 20 组跨端点 HTTP 会话拒绝。知识库开始、目录浏览、原文读取、引用完成及文本导出均成功；导出资源在普通 MCP 中不可读取。ASR 无效路径被拒绝；TTS 准备草稿保留原文且不会启动任务。

完成状态按媒体种类返回核心内可调用的 `next_call`：ASR 读取 `fetch`，TTS 调用 `media.session_preview`。已用本机已有完成结果验证两种续接，并生成和读取一秒配音音频预览；该预览资源在普通 MCP 中不可读取。试听通过真实 session ID 重新读取结果，并在当前连接注册预览授权。

写入回执、撤销和版本冲突机制继续复用原执行器。workspace、turn、输入、job、文档和预览临时上下文按连接隔离。跨连接使用真实 session/project ID，并在目标连接重新读取和验证。

## 测试

- API 本地 Docker 回归：139 passed、10 skipped；覆盖核心目录预算、权限、旧远程视频编辑拒绝、ASR 提交分支、知识工作区、媒体和 OAuth。
- 插件打包与安装器本地 Docker 测试：8 项通过，包含 ZIP 技能白名单、独立普通 MCP、已有配置策略保留、冲突拒绝及备份。
- Swift App 编译和签名验证成功；本机运行本次构建。
- 真实桌面宿主目录通过 CLI 的只读 app-server 注册表读取；没有启动模型回合或其他代理。

真实 ASR/TTS 新任务未在本次验收中提交；提交路径由上述回归覆盖。三类桌面宿主的完整面板交互未逐项验收。macOS 正式 DMG 与公证发布渠道未在本次重新发布；本机签名构建、App 内置插件和插件下载渠道已更新。

## 发布与生产

本地及 Cloud 核心插件均发布为 **0.3.0**。本地 App 内置 ZIP 与 R2 下载包使用相同字节；核心 ZIP 仅包含四个技能和 `/chatgpt/mcp`，编辑技能位于 `NativeMCP/skills`。

| 插件 | ZIP 字节 | SHA-256 |
| --- | ---: | --- |
| 本地核心 | 231,451 | `417e792fd5c81a28edf727690003f4f0122b4b2086a5d7c6f37233aaf9060143` |
| Cloud 核心 | 10,213 | `3c4d5148e227d9f56edb3226434f16292f03db81d1d616ffbd8dcfe5a472724f` |

R2 发布从 myvps2 执行，验证回读字节和摘要。本地插件还通过不可变 CDN URL 的 GET/HEAD 校验，并推广固定下载入口；历史版本保留。

API 在 myvps2、myvps3 按代码卷挂载方式选择性同步并重启，没有重建镜像。两个运行容器的 API HTTP 检查均为 200；未授权 Cloud 请求均为 401 并返回八项核心权限的 OAuth 挑战，发布元数据均为 0.3.0。两机回滚源码包位于 `/voxella/releases/mcp-core-native-20261005/backups/api-before.tgz`。

## 证据与复核

- [本机端点与工作流结果](local-profiles.json)
- [真实桌面宿主工具与归属](desktop-host.json)
- [已完成 ASR/TTS 结果续接与配音试听](completed-media.json)
- [生产健康检查](production-health.json)
- [Cloud 发布元数据](cloud-release.json)
- [本地 R2 上传](r2-local/upload.json)、[CDN 校验](r2-local/cdn.json)、[发布推广](r2-local/promotion.json)、[当前下载指针](r2-local/latest.json)
- [安装说明](../../plugins/openai-plugin-install.md)

可在本地 Docker 执行 `Tests/scripts/check_mcp_profiles.py` 和 `check_completed_media.py` 复核实际 App；使用 `check_host_mcp_profiles.py` 读取当前桌面宿主注册表。宿主注册表与协议定义采用不同序列化形状，因此分别记录容量，不混用测量结果。
