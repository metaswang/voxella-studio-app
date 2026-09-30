# Local MCP 知识库

App 启动后，已有 `http://127.0.0.1:19789/mcp` 同时提供视频编辑和知识库工具。知识库操作无需打开项目，复用 App chatbot 的工具执行器、检索服务及 QA/agent pipeline。

| 工具 | 操作 |
| --- | --- |
| `knowledge.ask` | 完整 QA，返回回答、引用、澄清问题及恢复操作 |
| `knowledge.search` | 跨会话混合检索 |
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
