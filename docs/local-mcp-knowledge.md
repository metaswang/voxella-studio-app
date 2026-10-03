# Local MCP 知识库

App 启动后，同一端口提供两个独立 profile。`http://127.0.0.1:19789/mcp` 保留视频编辑、素材工具和 `knowledge.ask`；`http://127.0.0.1:19789/knowledge/mcp` 为 Work/Codex 提供只读知识证据，由宿主模型自行回答。profile 的 factory、session 和无状态回退隔离，跨入口复用 session ID 返回 404。

## Work/Codex 证据入口

独立 `voxstudio-knowledge` plugin 使用 `/knowledge/mcp`，不要求调用 App 回答模型。安装方法见 [plugin 安装说明](plugins/openai-plugin-install.md)。

| 工具 | 操作 |
| --- | --- |
| `search` | `target=passages` 默认检索当前权威正文；另支持 `sources`、`subtitle_passages`、`media_clips` |
| `fetch` | 读取当前正文，或显式字幕、翻译、摘要、元数据、时间线、素材定位 |
| `list_sources` | 完整授权目录的分页，正文可读性、材料版本及正文/素材索引状态 |
| `aggregate` | 对完整筛选目录计数、汇总已知媒体时长、分组和排序 |
| `find_text` | 字面查词，返回 occurrence 数量及原文字符范围；可指定字幕材料 |
| `methods` | 按需列出/读取启用的知识库方法，返回版本、工具绑定和分页 |

默认原话检索与素材检索分别调用：

```json
{"name":"search","arguments":{"query":"最后决定什么时候发布？","target":"passages","limit":8}}
{"name":"search","arguments":{"query":"讲解发布计划的镜头","target":"media_clips","limit":8}}
```

`source_id`/`source_ids`、`origin`、语言、日期及时间范围受当前账户授权限制。`fetch` 可传 `search` 返回的 `evidence_id`；来源、配音 revision 或正文变化后，旧 ID 返回材料过期错误。分页 `cursor` 同样绑定查询与来源版本。`search` 是候选集合，不能用于穷举计数。

默认正文选择为 Transcript → 同一来源、角色及当前 revision 的字幕 fallback。text-only Transcript 有效；部分 Transcript 不由字幕补尾。关联配音、翻译轨及旧 revision 不静默补位。显式询问字幕实际内容时使用 `target=subtitle_passages` 或 `fetch material=subtitles`；翻译另传 `material=translation, language=en`。fallback 返回 `provenance=subtitle_fallback`，仍保留原字幕对应的 mediaClips。

QA 的 kind/scope/generation 限制进入向量候选预过滤，不扩散到通用 Workbench 或素材工具。`media_clips` 默认融合可用 text/video/mixed 通道，返回命中模态和定位；独立视频帧索引继续可用。素材字幕和 embedding 分数用于定位，不证明画面事实。

正文按约 60 秒软窗及 tokenizer 硬预算拆分；长 segment 不再成为不可拆边界。返回 UTF-16 原文字符范围、父 segment/cue、可信时间及定位精度。缺少细时间时继承真实粗范围或返回未知，不按字数推算时码。工具的 JSON 文本与 `structuredContent` 一致，声明真实只读 annotations 和 output schema。

## 兼容入口

| 工具 | 操作 |
| --- | --- |
| `knowledge.ask` | 完整 QA，返回回答、引用、澄清问题及恢复操作 |
| `knowledge.search` | 跨会话权威正文 QA 检索；不自动扩大到 mediaClip |
| `session.list` | 按标题、类型、来源、日期列出会话 |
| `knowledge.get_session_metadata` | 会话元数据 |
| `session.get_summary` | 会话摘要 |
| `session.get_segments` | 转录片段及时间范围 |
| `session.search_segments` | 指定会话内检索 |
| `session.get_timeline` | 分桶时间线 |
| `knowledge.compare_sessions` | 跨会话比较证据 |
| `finish_with_evidence` | 返回已接受的引用 ID（调用方控制信号） |
| `ask_clarification` | 返回澄清问题（调用方控制信号） |

所有工具可传 `origin: "all" | "local" | "cloud"`，默认 `all`，受当前账户可见性限制。指定不可见或不存在的 session ID 返回 MCP tool error。两个控制工具只返回结构化信号，不终止 MCP 连接，也不修改 App UI。

## 完整问答

```json
{
  "name": "knowledge.ask",
  "arguments": {
    "query": "上次会议决定了哪些后续行动？",
    "answer_mode": "detailed",
    "origin": "local",
    "allow_cloud": true,
    "history": [
      {"role": "user", "content": "请总结产品规划会议"},
      {"role": "assistant", "content": "会议讨论了新版发布计划。"}
    ]
  }
}
```

可选 `session_ids` 为非空 UUID 数组，不传则覆盖当前可见会话。`answer_mode` 支持 `concise`、`normal`（默认）、`detailed`。`allow_cloud` 控制模型路由，`origin` 控制资料来源，二者独立。`history` 由调用方传入，支持 user/assistant 消息，不写入 App 的聊天记录。

MCP 等待 QA pipeline 完成后返回 JSON 文本；`status` 为 `completed` 或 `clarification`。回答包含 `answer` 和 `citations`，澄清包含 `question`，需要配置时可包含 `recovery_actions`。执行失败通过 MCP `isError` 返回。QA 引用使用 `KnowledgeSourceRef` 的 Codable 字段（如 `sourceID`、`startTime`），低层工具保留原 chatbot 工具的字段（如 `source_id`、`start_time`）。
