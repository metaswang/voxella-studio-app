# Session Editor 复用 Agent Chat 与 MCP：LLM 协作上下文

## 目标

为 **Session Editor** 加入与 Video Editor 一致的应用内聊天入口，并把本地 MCP 服务从“只能操作 `.palmier` 视频工程”扩展为“也能读取和编辑 Workbench Session”。

用户意图：在 ChatGPT / Codex 的 chat 模式中，可以围绕当前 Session 的转录、字幕、翻译、说话人、摘要、配音及导出进行对话和工具调用；不要求先进入 Video Editor，也不能让 Session 操作绕过现有的 `WorkbenchStore` 域逻辑。

这是一项跨 UI、聊天运行时、持久化和 MCP 的功能，不是把一个 SwiftUI view 复制到另一个页面。

## 当前架构：已确认事实

| 范围 | 当前 owner / 入口 | 关键结论 |
| --- | --- | --- |
| Video Editor | `EditorViewModel` | 每个 `.palmier` 工程各自拥有 `agentService`。 |
| 内置 Agent Chat | `AgentService` + `AgentPanelView` | 支持流式模型输出、工具调用、取消、聊天标签/历史、模型与 reasoning 选择、错误状态。 |
| 输入框 | `AgentInputBox` | 包含 Enter 发送、Stop、拖放/粘贴媒体、以及仅适用于视频素材的 `@mention`。 |
| 视频工具执行 | `ToolExecutor` | 内置 Agent 和外部 MCP 共用同一执行器与 `ToolDefinitions`；实际操作的是 `EditorViewModel`。 |
| 外部 MCP | `MCPService` → `MCPHTTPServer` → 每客户端 `ToolExecutor` | HTTP 端点是 `http://127.0.0.1:19789/mcp`；每个 MCP client 有自己的 project binding。 |
| Session Editor | `WorkbenchSessionDetailView` | 当前没有聊天 UI；数据和写入全部属于 `@MainActor WorkbenchStore.shared`。 |
| Session 领域状态 | `WorkbenchStore` | `sessions` 是由 transcription jobs、dub jobs 和 cloud-only session 派生的计算结果；不能作为独立可随意写入的数组。 |

### 现有 Video Editor Chat 的调用链

```text
EditorView / AgentPanelView
  → EditorViewModel.agentService
  → AgentService (conversation state + model stream + tool-use loop)
  → ToolExecutor(editor: EditorViewModel)
  → ToolExecutor+*.swift
  → 既有 timeline / media / export 域操作 + EditorUndo

外部 ChatGPT/Codex
  → MCP HTTP :19789/mcp
  → MCPService（每 client 建立独立 ToolExecutor）
  → ToolExecutor(projectProvider:)
  → 当前仅绑定 VideoProject / EditorViewModel
```

### Session Editor 的调用链

```text
HomeView
  → WorkbenchStore.shared.openSession(id)
  → WorkbenchStore.route = .session
  → WorkbenchSessionDetailView
  → SessionSegmentEditor / SessionSummaryPanel / SessionExportCenter
  → WorkbenchStore 的更新、任务、持久化和 cloud sync
```

`WorkbenchSession` 是对本地 transcription/dub job 与 cloud-only session 的只读统一视图。对 session 的修改必须通过 `WorkbenchStore` 的具体操作，例如：

- `renameSession`
- `updateSessionCueText` / `updateSessionCueTiming`
- `splitSessionCue` / `mergeSessionCueDown`
- `assignSessionCueSpeaker` / `renameSessionSpeaker`
- `createDub`
- `updateTranscription` / `updateDub`
- 翻译、摘要、导出、cloud sync 的既有工作流

## 必须遵守的设计约束

1. **一个 mutable source of truth。** Session Agent 不能维护转录、字幕、摘要或配音的副本；所有变更走 `WorkbenchStore` 的域操作。
2. **复用聊天表现层，不复用错误的上下文。** `AgentPanelView` 和 `AgentInputBox` 目前通过 `@Environment(EditorViewModel.self)` 取 editor，并直接读取 media library；Session 不能直接嵌入。
3. **视频工具与 session 工具分开建模。** 现有 `ToolExecutor` 的绝大多数工具假设 timeline、clip、mediaRef、`.palmier` project 和 `EditorUndo` 存在。不可让它们在 Session mode 下以“Editor not available”失败。
4. **MCP 必须显式选择工作上下文。** 当前 MCP session 以 `manage_project` 绑定一个 `VideoProject`。扩展后，外部 LLM 必须能明确选择 `videoProject` 或 `workbenchSession`，不能根据前台窗口猜测写入对象。
5. **会话身份使用稳定 UUID。** Session MCP 请求使用 `WorkbenchSession.id`；不要使用 Recent 列表 index、标题、当前 tab 或 cue 行号作为唯一身份。cue 可使用 scope + cue ID，但 mutation 前必须重新解析并验证。
6. **Mutation、预览和 UI 使用同一规则。** 例如字幕切分、时码编辑、说话人重命名、翻译和创建配音不能在 MCP 实现一份独立算法。
7. **异步任务必须可观察。** 翻译、摘要、配音、导出、cloud sync 需要返回 job/session receipt 与明确的 pending / completed / failed 状态；不能只返回“已开始”。
8. **不要在主线程做文件与媒体工作。** `WorkbenchStore` 已经是主 actor 状态 owner；新 chat/MCP 层应调用其既有异步工作流，而不是在 UI 或 executor 中直接读取媒体、写文件或访问 AVFoundation。
9. **Session 编辑的 undo 需要先决定。** Video Editor 使用 `EditorUndo`。Workbench 现有编辑并未显示同一套 undo 边界；在承诺 Agent 可编辑 Session 前，要么接入共享、可验证的 Workbench undo，要么在工具 contract 中明确此范围暂不支持 undo，不能假装 `undo` 会撤销 Session 改动。
10. **聊天持久化的范围必须明确。** Video Editor chat 保存在 `.palmier/chat/*.json`，由 `VideoProject` 保存快照写入。Session chat 不能落到任意 VideoProject，也不能跟随临时 UI state 丢失。

## 推荐的目标架构

```text
                  ┌──────────────────────────┐
                  │ Shared Chat Presentation │
                  │ tabs / messages / input  │
                  └────────────┬─────────────┘
                               │ ChatContext
          ┌────────────────────┼────────────────────┐
          │                    │                    │
 VideoEditorChatContext   SessionChatContext   (future contexts)
 EditorViewModel          WorkbenchStore +
 + Agent mentions         selected session UUID
          │                    │
          └──────────┬─────────┘
                     │
              AgentConversationService
         stream / cancellation / persistence / tool loop
                     │
              ContextToolExecutor
          ┌──────────┴───────────┐
          │                      │
 VideoEditorToolExecutor   SessionToolExecutor
 ToolDefinitions.video     ToolDefinitions.session
 Editor domain ops         WorkbenchStore domain ops
          │                      │
          └──────────┬───────────┘
                     │
              MCP context router
       explicit context selection; per-client binding
```

### 建议的最小抽象

不要把 `AgentService` 变成依赖大量 `if editor != nil` 的“万能服务”。优先抽取小而明确的协议/值类型：

- `AgentChatContext`：提供上下文 ID、系统提示的 context section、可用工具、工具执行器、聊天持久化位置/adapter、可选输入附件能力。
- `AgentConversationService`：从现有 `AgentService` 提取与 editor 无关的会话管理、模型选择、流式事件归并、工具循环、取消和错误处理。
- `VideoEditorChatContext`：保留现有 `EditorViewModel`、媒体 mention、`ToolExecutor` 和 `.palmier/chat` 持久化。
- `SessionChatContext`：持有 `sessionID`，按请求重新从 `WorkbenchStore.sessions` 解析 session，提供 session 专用系统上下文和 `SessionToolExecutor`。
- `AgentInputCapabilities`：区分纯文本、session/timecode 引用、视频 media mention。Session 首版不应暴露 `AgentInputBox` 中导入到 Video Editor media library 的拖放逻辑。

这允许复用聊天 UI 的大多数视觉部件，同时避免 Session 页面被 `EditorViewModel` 环境依赖污染。

## UI 方案

### 建议首版

在 `WorkbenchSessionDetailView` 中添加可收起的右侧 Agent sidebar，行为与 Video Editor 的 Agent panel 对齐：

- 顶部：chat tabs、新 chat、历史；可沿用 `ChatTabView`、`ChatHistoryList` 的外观。
- 中部：`AgentMessageView`、工具调用收据、流式 thinking/answer、错误和跳转设置 CTA。
- 底部：共享的文本输入、模型/reasoning 选择、发送/停止。
- Session 专属上下文：显示当前 Session 标题和状态；可提供轻量的“引用当前 transcript/subtitles/summary”快捷 chip。
- `@`：首版只支持可稳定解析的 Session 引用（例如当前 session、当前 tab、选中 cue/range）。不要复用 Video Editor 的 `MediaAsset` 搜索和文件拖放。

建议将现有 `AgentPanelView` 重构为“无 owner 的表现组件”加两个 host：

- `VideoEditorAgentPanelHost`：注入 editor context。
- `SessionAgentPanelHost`：注入 session context。

不要让 `WorkbenchSessionDetailView` 创建第二套聊天消息渲染、输入、历史或模型选择 UI。

### Session 级聊天生命周期

- 一个 session 至少有一个独立聊天空间；不能因为切换 Recent Session 而把消息错误发送到上一个 session。
- 切换 session、删除 session、远端 session 尚未 hydrate、Session 任务运行中、关闭 app 时都需要取消或安全结束当前 stream。
- 每次工具提交前，以 `sessionID` 重新验证 session 仍存在、允许该操作、且未被删除或替换。
- 可选：把聊天按 session 保存为 `sessionChat/<sessionUUID>/*.json`，放在 Workbench 自己的持久化根（当前 `workbench.json` 所在数据目录），而非 `.palmier` package。保存采用现有 Workbench persistence 的后台/原子写入策略。

## Session MCP 设计

### 设计原则

外部 MCP 客户端当前只能服务于 Video Editor。新增 Session 支持后，应保持当前 video tool 名和 schema 稳定，并新增明确的 Session tool family；不要给 `get_timeline`、`add_clips` 等工具偷偷改变意义。

推荐把 MCP 的绑定模型升级为：

```text
MCP client session
  └─ active target = .videoProject(projectID) | .workbenchSession(sessionID) | nil
```

新增一个显式上下文选择工具（名字可讨论，建议 `manage_context`），或把 `manage_project` 演化为兼容的 `manage_workspace`。为了不破坏现有客户，优先保留 `manage_project` 语义，并新增 `manage_session`：

- `manage_session(action: list | open | close, id?)`
- `list`：返回稳定 session ID、标题、类型、状态、可用内容、是否 active/visible。
- `open`：将当前 MCP client binding 切换到指定 Session；不根据标题做有歧义的自动匹配。必要时可允许 title 只用于只读搜索、返回候选后要求 ID。
- `close`：解除 Session binding；不删除任何资料。

`ToolExecutor` 不应直接兼容两种数据模型。可以保留其作为 Video Editor executor，并新增 session executor / router；每个 MCP session 根据 active target 选择合法的 tools。若 MCP transport 的 `list_changed` 能可靠通知，则在切换 target 后刷新 tools；否则让两个 family 同时可 discover，但 session tools 在无 binding 时返回结构化 `no_session_selected`，video tools 在无 video project binding 时返回结构化 `no_video_project_selected`。

### 首版 Session 工具建议

工具以用户意图而不是 UI setter 命名。下表是建议 API，不等于已实现 schema。

| 工具 | 读取/写入 | 应复用的 Workbench 操作 | 说明 |
| --- | --- | --- | --- |
| `get_session` | 读 | `WorkbenchStore.sessions` | 返回 session metadata、state、来源、tracks、摘要状态、可用 actions；可带 `include` 控制载荷。 |
| `get_session_transcript` | 读 | session 的 transcript/subtitle/translation/dub track | 支持 `scope`、分页/时间窗口，返回 cue ID、时码、文本、speaker。 |
| `update_session_cues` | 写 | `updateSessionCueText`、`updateSessionCueTiming` | 批量原子更新；先验证全部 cue、scope、时码和冲突，再提交。 |
| `split_session_cue` | 写 | `splitSessionCue` | 输入 cue ID 与左右文本；返回新 cue receipt。 |
| `merge_session_cue` | 写 | `mergeSessionCueDown` | 合并当前 cue 和后续 cue；无后续 cue 时明确 no-op/refusal。 |
| `manage_session_speakers` | 写 | `assignSessionCueSpeaker`、`renameSessionSpeaker` | `assign` / `rename` 是同一说话人管理意图；可选批量 assign。 |
| `translate_session` | 异步写 | 既有翻译工作流 | 启动/读取状态；必须返回 session/job 状态与目标语言，不能另写翻译引擎。 |
| `generate_session_summary` | 异步写 | `regenerateSummary` / 既有 enrichment | 生成或根据 instruction 精炼摘要；返回明确状态。 |
| `create_session_dub` | 异步写 | `createDub` + 既有 dub workflow | 用现有 voice / track / storage / compute 选择；不得绕过 admission 与 cloud 规则。 |
| `export_session` | 异步写 | `SessionExportCenter` 的底层 export operation | 导出 transcript、subtitle 或 audio，返回可轮询 job。 |
| `get_session_jobs` | 读/取消（如现有 UI 支持） | Workbench job 状态 | 查询翻译、摘要、dub、export 等长任务的 terminal receipt。 |

首版不应包含：导入到 Video Editor 时间线、任意本地文件读写、从外部 URL 创建 session、删除 session、或把任意自然语言直接写进结构化摘要/字幕而不经验证。这些需要独立的域设计和安全边界。

### MCP 返回格式要求

所有写工具应返回机器可读 receipt，至少包括：

```json
{
  "sessionId": "UUID",
  "status": "completed | pending | no_op | refused | failed",
  "changed": [{"kind": "cue", "id": 42}],
  "warnings": [],
  "jobId": "UUID or null"
}
```

对错误，返回可行动的 machine-facing code，例如 `session_not_found`、`session_not_ready`、`scope_unavailable`、`cue_not_found`、`invalid_time_range`、`session_remote_read_only`、`operation_in_progress`。UI 文案和本地化错误文案保持在客户端层，不写入 MCP contract。

## Session Agent 的系统提示上下文

每个请求只注入与当前 Session 有关且容量受限的摘要，而不是把全部 transcript 和完整 Workbench JSON 塞进 system prompt：

- `sessionId`、标题、类型、状态、可否编辑、是否 remote-only。
- 当前 tab/track/scope（transcript、source subtitle、translation language、dub）。
- 媒体时长、语言、speaker 列表、cue 数量、摘要是否可用。
- 用户显式引用的 cue/time range 的完整数据。
- 引导模型先调用 `get_session` / `get_session_transcript` 再做判断；长 transcript 使用 pagination/time window。

系统提示需要明确：

- 不猜测或编造未读取的 transcript 内容。
- 对写操作先读取稳定 ID 和当前版本；遇到冲突、remote-only、处理中或失效上下文时停止并说明。
- 需要多 cue 修改时使用原子批量工具，避免逐条写入造成部分更新。
- 任何耗时任务应报告已启动，并在用户要求或后续 turn 中查询状态；不能把“开始”描述为“完成”。

## 实施阶段

### Phase 0：先定 contract 和不变量

1. 列出 Session 的可读内容、可写内容、remote-only 限制和每项操作的 job 生命周期。
2. 决定 Workbench undo 策略；未具备可靠 undo 时，Session agent 写操作不要承诺 `undo`。
3. 定义 session chat 的持久化位置、删除/关闭策略和 cloud/private-data 边界。
4. 为每个 Session MCP tool 写 schema、成功 receipt、no-op、失败、取消、重试与幂等性说明。

### Phase 1：抽取共享 Chat UI 与运行时

1. 将消息列表、tab/history、model/reasoning controls、错误呈现从 `EditorViewModel` 环境依赖中分离。
2. 为 input 拆分附件能力；Video Editor 保持现有 media mention，Session 使用 session/cue 引用。
3. 抽取通用 conversation state machine，并保留视频聊天的 UX、模型/凭据与已有存储行为不变。
4. 添加 `SessionChatContext`，首版仅支持安全的只读 `get_session` / `get_session_transcript`。

### Phase 2：Session 侧栏与持久化

1. 在 `WorkbenchSessionDetailView` 提供可收起 sidebar 与当前 session badge。
2. 连接 per-session chat store；切换、删除、远端加载、关闭时正确取消 stream 和防止 stale commit。
3. 加入 cue/range reference 的 UI；验证其不会触发 Video Editor 的文件导入或 media mention。

### Phase 3：Session MCP router 与只读工具

1. 新增 MCP session binding（`manage_session`），不改变 `manage_project` 的既有 contract。
2. 实现 `SessionToolExecutor` / router；使用 `WorkbenchStore` 的公开/稳定域 seam。
3. 实现并端到端测试 `get_session`、`get_session_transcript` 和 jobs/status 读取。

### Phase 4：受控写工具

按风险由低到高加入 cue 文本、cue timing、split/merge、speaker、翻译/摘要、dub、export。每项先确保 UI 与 MCP 调用相同的 domain operation、验证规则、持久化、cloud sync 和 job receipt。

## 关键代码导航

| 目的 | 文件 |
| --- | --- |
| Video Editor chat UI host | `Sources/VoxstudioPro/Agent/Panel/AgentPanelView.swift` |
| Chat input / Video Editor media mentions | `Sources/VoxstudioPro/Agent/Panel/AgentInputBox.swift` |
| 会话、流式、工具调用 loop | `Sources/VoxstudioPro/Agent/AgentService.swift` |
| Chat JSON model / 编解码 | `Sources/VoxstudioPro/Agent/ChatSessionStore.swift` |
| Chat message / tool result renderer | `Sources/VoxstudioPro/Agent/Panel/AgentMessageView.swift` |
| 工具清单与 MCP / in-app 可见性 | `Sources/VoxstudioPro/Agent/Tools/ToolDefinitions.swift` |
| 视频工具的共享 executor | `Sources/VoxstudioPro/Agent/Tools/ToolExecutor.swift` 与 `ToolExecutor+*.swift` |
| MCP HTTP service / 每 client executor | `Sources/VoxstudioPro/Agent/MCP/MCPService.swift`、`MCPHTTPServer.swift` |
| Video Editor 的 agent owner | `Sources/VoxstudioPro/Editor/ViewModel/EditorViewModel.swift` |
| `.palmier` chat 保存和恢复 | `Sources/VoxstudioPro/Project/VideoProject.swift` |
| Session Editor 页面 | `Sources/VoxstudioPro/Workbench/WorkbenchSessionView.swift` |
| Session state、持久化、任务、写操作 | `Sources/VoxstudioPro/Workbench/WorkbenchStore.swift` |
| Session cue 编辑 UI | `Sources/VoxstudioPro/Workbench/SessionSegmentEditor.swift` |
| Session 导出 UI / 逻辑入口 | `Sources/VoxstudioPro/Workbench/SessionExportCenter.swift`、`SessionExport.swift` |

## ChatGPT 协作时可直接使用的任务提示

```text
请在 Voxella Studio（Swift 6.2 / SwiftUI + AppKit）中设计并实现 Session Editor Agent Chat 的第一阶段。

目标：复用 Video Editor 现有 Agent Chat 的视觉与流式对话体验，同时让它以 Workbench Session 为上下文；不要把 EditorViewModel 或 video-only media mention 硬塞进 Session Editor。

事实：
- Video Editor 的 AgentService、AgentPanelView、ToolExecutor 和 MCP 当前只绑定 EditorViewModel / VideoProject。
- Session Editor 的 source of truth 是 @MainActor WorkbenchStore.shared，WorkbenchSession 是由 transcription/dub/cloud 数据派生的视图。
- Session 的编辑必须复用 WorkbenchStore 的 updateSessionCueText、updateSessionCueTiming、splitSessionCue、mergeSessionCueDown、assignSessionCueSpeaker、renameSessionSpeaker 等域操作。
- 现有 Video Editor MCP contract 必须保持兼容。

本阶段：
1. 提出最小的 ChatContext / shared presentation 拆分；
2. 在 WorkbenchSessionDetailView 加可收起的 Session Chat sidebar；
3. 为每个 session 隔离聊天、取消和持久化生命周期；
4. 仅实现只读 session context 和只读工具，不实现 Session 写 MCP；
5. 写 focused tests，并运行 swift build。

请先给出 source-of-truth、actor isolation、persistence、stale completion 和 cancellation 的设计，再修改代码。不要复制一套聊天 UI 或复制 Workbench 的业务规则。
```

## 验收标准

- Video Editor 的内置聊天、聊天持久化、MCP URL、工具名和既有行为保持可用。
- 打开两个不同 Session 时，聊天记录、工具上下文和 stream 不会串台。
- Session UI 不再依赖 `EditorViewModel` 或 `.palmier` project 来工作。
- 外部 MCP 能明确列出并选择 Session；未选择 Session 时不会误写前台 Video Editor。
- Session 工具不暴露/调用 video timeline 工具；video tools 也不对 Session 静默执行。
- Session 字幕/说话人等变更可在 UI 独立读回，持久化和 cloud sync 状态正确。
- 每个长操作可查到完成、失败或取消；每个拒绝/no-op 有准确 receipt。
- 新增 UI 有手动验证计划：空 session、长 transcript、remote-only session、任务处理中、切换 session、关闭侧栏、Escape/Stop、删除 session、网络/cloud sync 失败。
