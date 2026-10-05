# VoxStudio 0.3.0：核心插件与独立普通 MCP

核心 OpenAI 插件 `voxstudio` 仅提供知识库、ASR、TTS，连接本机 `/chatgpt/mcp`。视频编辑、文档修改、调色、音频处理、多机位和媒体生成通过独立普通 MCP `voxstudio_native` 接入 `/native/mcp`。保持 Mac App 运行并开启 Settings → MCP。

## 安装核心插件

从 App 设置中的 **Download latest VoxStudio plugin** 下载并完整解压。固定[下载地址](https://assets.voxstudio.me/downloads/voxstudio/plugins/voxstudio/VoxStudio-OpenAI-Plugin.zip)提供已发布版本；**Save bundled plugin (offline)** 保存当前 App 内置版本。新端点需要支持 0.3.0 核心协议的 App。

```sh
bash "$HOME/Downloads/VoxStudio-OpenAI-Plugin/install.sh"
```

安装器先验证核心端点及面板，再备份旧插件、不可变缓存和偏好，安装核心插件并移除旧 Knowledge 插件；失败时回滚。保留解压目录及其中 `.migration/` 恢复文件。默认不会注册普通 MCP。可用 `--cli /实际路径/codex` 指定桌面 CLI。

在桌面客户端 Plugins 页面启用 VoxStudio Local 下的 VoxStudio，开启新对话。已有停用偏好会保留。避免同时注册指向完整目录的同名普通 `voxstudio` 连接。

## 独立安装普通 MCP

需要原生编辑能力时，单独运行：

```sh
bash "$HOME/Downloads/VoxStudio-OpenAI-Plugin/install.sh" --native-only
```

或在 `~/.codex/config.toml` 添加：

```toml
[mcp_servers.voxstudio_native]
url = "http://127.0.0.1:19789/native/mcp"
```

`--native` 可在一次运行中先安装核心、再独立注册普通 MCP。安装器保留已有普通连接的启用状态和策略，遇到不同 URL 或传输类型时停止覆盖。普通连接不进入插件的 `mcp.json` 或 `.mcp.json`，独立卸载和管理。

## 工作流与权限

知识问题先用 `app_knowledge` 开始，随后调用明确 schema 的 search、fetch、list_sources、aggregate、find_text、methods，读取原文后用 knowledge.complete_turn 完成引用。没有 MCP Apps 时可直接读证据。

ASR 使用 `app_transcription` 提交用户提供的本地路径或 ChatGPT 附件；TTS 使用 voice.list 和 `app_dubbing`。跟随 next_call，以返回的 job_id/session_id 查询进度。fetch 读取转录原文，media.session_preview 试听，media.export 导出文本、字幕或配音音频。面板内部操作按 App-only 暴露，通用文档修改仅在普通 MCP。

各端点独立维护 HTTP 会话、workspace、turn、输入、job、文档和预览授权。跨连接只能使用真实 session/project ID，必须在目标连接重新读取并验证；临时令牌不能跨连接。每次写入使用新的 UUID request_id，重试保留同一个 ID。回执保留一小时且不跨 App 重启；未知状态的写入在过期或重启后不能盲目重试。原生编辑继续使用撤销与版本冲突检查。

## Cloud 与兼容

`voxstudio_cloud` 的 `/cloud/mcp` 同样只提供知识库、ASR、TTS。视频编辑、渲染、clip project 和 editor bridge 不在 Cloud 核心目录及权限中。Cloud 的真实 session ID 与知识 source ID 需要按返回类型使用，不能互换。

本机 `/mcp`、`/app/mcp` 和 `/knowledge/mcp` 保留旧客户端契约。Claude MCPB、Claude Code、Cursor 的原有完整接入继续使用 `/app/mcp`；新 OpenAI 插件使用核心端点。Web 或远程会话无法连接 Mac 的 loopback 地址。

普通 MCP 配置依据：[OpenAI MCP 文档](https://learn.chatgpt.com/docs/extend/mcp)。模型工具数和容量以实际 tools/list 的紧凑 UTF-8 JSON 为准，分别记录模型可见目录和包含 App-only 的完整目录。
