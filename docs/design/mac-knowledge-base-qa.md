# Mac Knowledge Base QA — 功能与实现设计

日期：2026-09-14  
范围：`voxella-studio-app`  
参照：`voxella-web` `KnowledgeBasePage` / `KnowledgeChatBubble`；附件《Vox Studio Knowledge Base QA 设计文档》v1.0（本地 Hybrid Search + WeMM + Reranker）

## 1. 产品目标

在 Mac App 新增 **Knowledge Base** 工作台页：

| 区域 | 行为 |
| --- | --- |
| 左侧 | 知识列表；顶栏 **Search + Filter**；首行 **所有知识 (All)** |
| 右侧 | Q/A Chatbox（流式回答 + 引用） |
| 选「所有」 | RAG scope = 全部已索引 session/知识源 |
| 选某一 session | RAG scope = 该 session，快速 QA |
| ⌘/⇧ 多选 sessions | RAG scope = 选中集合；独立对话 key；非 QA-able 跳过 |

Mac 路径为 **本地优先**：复用已有 `Search/RAG`（Hybrid + WeMM），按附件补 Reranker → Context → Answerability → LLM，不重做检索层。

## 2. Web 对齐（交互契约）

Web 语义（`docs/kb-chatbot-eval/00-overview.md`）：

```
selectedSourceId == null  → scope = all
selectedSourceId != null  → scope = source + sourceId
```

Mac 选中语义映射为：

```
0 selected                 → KnowledgeQAScope.all
1 selected id              → KnowledgeQAScope.session(id)
≥2 selected (ordered uniq) → KnowledgeQAScope.sessions([ids…])
                             storageKey = sorted(ids).joined(",")
```

交互（无 checkbox）：

- 单击：单选互斥
- ⌘-click：toggle 多选
- ⇧-click：anchor → 当前行 range
- 点 **All knowledge**：清空多选，`scope = .all`

（Web 的 `source` 多为已入库 session 源；Mac 本地索引以 `SessionCard` / transcript chunks 为主，v1 以 session 为知识单元，文件上传入库可放 P1。）

右侧对话：

- `all`：用户级 KB 对话（跨 session 连续多轮）
- `session`：每 session 独立对话线程（切换 session 切换线程，不串台）
- `sessions`：多选集合独立 conversation key（同集合不串台；与 all / 单 session 隔离）

## 3. UI 信息架构（Mac）

### 3.1 入口

- 侧栏 / Home 增加 **Knowledge** 项（对齐 Web `/workbench/knowledge`）
- 新 SwiftUI 页：`KnowledgeBaseView`（可拆 `KnowledgeSourceList` + `KnowledgeChatPane`）

### 3.2 左栏

1. 顶部：Search field + Filter（类型：全部 / 录音 / 会议 / 上传…；状态：已索引（approx.）/ 索引中）+ **显示全部**
2. 固定首行：**所有知识** — 副文案 `Ask across N sessions`（N = 有 transcript / 可检索）
3. 列表行：标题、来源类型、时长/日期、索引状态（approx.）；默认隐藏未索引；「显示全部」下未索引行变灰且不可 QA
4. 可选（P1）：「添加 session 到知识库」、自动入库设置（Web 有；Mac 可默认「转录完成即索引」沿用 `SessionIndexCoordinator`）
5. 选中态：leading accent bar + Accent fill ~12–18% + inset ring；spring；hover 略亮（不用系统 List 灰条）
6. 标题单行 ellipsis（`.lineLimit(1)` + `.truncationMode(.tail)`），Local/Cloud badge 保可见
7. 左右分栏：默认 ratio `0.28`，min left `220`，min right ~`400`；可拖拽分割条（hit ~12）；ratio 持久化 `voxella.kb.panel-ratio.v1`

### 3.3 右栏

1. 顶栏：当前 scope 标题（All / session 名 / `N sessions selected`）；副文案 `Ask across N selected sessions`
2. 消息流：user / assistant；assistant 带 citation chips
3. 输入区：文本 + Voice Input（ASR final 后才触发 QA，partial 只预览）
4. 空态：未选 scope 时引导选「所有」或某个 session
5. 证据不足：明确文案 + 列出最接近来源，不编造

### 3.4 Citation 点击（Mac 差异化）

| 来源 | 展示 | 点击 |
| --- | --- | --- |
| Transcript | session · speaker · mm:ss | 打开 session / 播放器跳转 |
| 视频项目 | project · clip · timeline | 编辑器定位（P2） |
| 文件（P1） | 文件名 · 页/段 | 打开本地文件 |

## 4. 数据与 Scope 模型

```swift
enum KnowledgeQAScope: Hashable, Sendable {
    case all
    case session(UUID)        // workbench session id
    case sessions([UUID])     // ordered unique; storageKey = sorted ids
}

struct KnowledgeQARequest: Sendable {
    var queryText: String
    var conversationID: UUID
    var scope: KnowledgeQAScope
    var selectedContext: [SourceRef]?  // 可选：当前选区/时间线
    var answerMode: AnswerMode         // concise | normal | detailed
    var allowCloud: Bool
}

struct SourceRef: Sendable {
    var sourceID: String
    var sourceType: SourceType       // sessionTranscript | meeting | file | project…
    var title: String
    var uri: String?
    var page: Int?
    var startTime: Double?
    var endTime: Double?
    var parentID: String?
    var chunkIndex: Int?
    var language: String?
    var speaker: String?
}
```

对话持久化（本地）：

- `KnowledgeConversation`：`id, scope, sessionID?, updatedAt`
- `KnowledgeMessage`：`id, conversationID, role, content, citations[], createdAt`
- 建议 SQLite（可旁路现有 `SessionSQLite` 或独立 `KnowledgeChatStore`）

## 5. QA Pipeline（对齐附件，绑定现有代码）

```
normalize → query rewrite → Hybrid Search (reuse) → RRF Top30
  → Qwen3-Reranker-0.6B MLX 4bit → threshold+MMR → Top6–8
  → ContextBuilder (parent/neighbor/merge)
  → Answerability gate
  → Answer LLM stream + citations
```

| 模块 | Mac 现状 | v1 动作 |
| --- | --- | --- |
| Index / Chunk | `SessionIndexCoordinator` / `TranscriptChunkPacker` | 保留；补 parent/neighbor metadata（附件 §15） |
| Embedding | `WeMMEmbeddingProvider` | 继续用 |
| Hybrid Search | `SearchService.hybridSearch` + RRF | 继续；scope filter 优先 |
| Reranker | 无 | **新增** `RerankerService`（MLX Qwen3-Reranker-0.6B-4bit） |
| Context Builder | 弱 / `transcriptContext` | **新增** expand/merge |
| Answerability | 无 | **新增** Strong / Uncertain / Insufficient |
| Answer LLM | `LLM` provider 层 | Knowledge QA 走 local-first；可 allowCloud |
| Citation | 部分 WordSpan | **新增** `CitationResolver.open(SourceRef)` |

默认参数（附件 §18）：vector/keyword top 50；rerank candidates 30；threshold 0.25；min keep 3；MMR λ=0.70；strong top1≥0.65。

**运行时**：Reranker 常驻；同进程单 active rerank；新 query 取消旧任务；不与 ASR/DUB 抢死 GPU（优先级：播放 > Voice > QA > background index）。

## 6. 服务边界（Swift）

```
KnowledgeBaseStore          // 列表：sessions as knowledge rows + search/filter
KnowledgeChatStore          // conversations / messages
KnowledgeQAService          // answer(request) -> AsyncStream<AnswerEvent>
  ├─ SearchService          // existing
  ├─ RerankerService        // new
  ├─ ContextBuilder         // new
  ├─ AnswerabilityService   // new
  └─ LLMProvider            // existing
CitationResolver            // open media / editor
```

UI 不得直接调 MLX；经 service。

## 7. 分阶段实现（给 Coding Bot）

### P0 — UI 壳 + 本地 RAG 主路径（1–2 周）

1. `KnowledgeBaseView` 左右分栏；左：All + session 列表 + search/filter  
2. 右：chat UI；scope 切换创建/加载对话  
3. 接 `SearchService` hybrid（先可无 rerank，用 TopK 直出）打通端到端  
4. 流式答案 + 基础 citation（session + timestamp）  
5. 门禁：与现有 App Access 一致（试用/Lifetime 可用本地 KB；云 LLM 仍要登录/额度）

### P1 — 附件完整检索质量

1. MLX Reranker 接入与常驻  
2. Query rewrite、MMR、parent/neighbor、Answerability  
3. 证据不足文案与二次检索  
4. Index metadata 补齐（parent/prev/next/chunk_index/source_type）

### P2 — 媒体闭环

1. Voice Input → QA  
2. Citation 跳播放器 / 编辑器时间线  
3. Ask this project / selected range（`selected_context`）

### P3 — 评估与调度

1. 小型 gold set；阈值校准  
2. score cache；memory pressure 卸载 Answer LLM  

## 8. 明确不做（v1）

- 不引入独立向量库、不重写 Hybrid Search  
- 不用 Chat LLM 代替 Reranker 打分  
- 不做复杂 Agent/ReAct / 强制联网工具  
- Mac v1 不强制对齐 Web 的云端 upload/Pro 门禁矩阵；本地索引优先；若日后同步云 KB 再开单独 PR  

## 9. 验收清单

- [ ] 选「所有」提问 → 答案可引用多个 session  
- [ ] 选单 session 提问 → 检索与引用不越界  
- [ ] 切换 scope 不串对话历史  
- [ ] 左栏 search/filter 可用  
- [ ] 无证据时不编造；有 citation 可点击回跳（P0 至少打开 session）  
- [ ] 提交问题才跑 rerank；输入防抖不触发完整 QA  
- [ ] 与 ASR/播放同时开时 UI 不永久卡死（可取消）  

## 10. 建议文件落点

```
Sources/PalmierPro/Knowledge/
  KnowledgeBaseView.swift
  KnowledgeSourceListView.swift
  KnowledgeChatPane.swift
  KnowledgeQAService.swift
  KnowledgeChatStore.swift
  RerankerService.swift
  ContextBuilder.swift
  Answerability.swift
  CitationResolver.swift
docs/design/mac-knowledge-base-qa.md  // 本文件
```

复用：`Search/RAG/*`、`LLM/*`、`SpeechInput/*`、`Workbench` session 模型。

## 11. P0 产品裁定（Research Bot，2026-09-14）

落地在本 PR，不阻塞合并。

### 11.1 Indexed 近似（P0）

P0 **不**读取 `SessionIndexStore.lexicalReady` / `embeddingReady`。

左栏「Indexed」= **有 transcript / 可检索结果** 的近似。UI 与代码注释均标为 `Indexed (approx.)`。真实 lexical/embedding 标志放 **P1**。

### 11.2 WorkbenchSessionType vs Web `source_type`

仅作 **best-effort 展示标签**，**不要求 1:1 enum**。不要为了对齐 Web 而加 case。

| Mac `WorkbenchSessionType` | 展示 `KnowledgeSourceType` | 说明 |
| --- | --- | --- |
| `record`, `live` | `recording` | 录屏/麦、Live transcribe |
| `meetingRecord`, `googleMeet` | `meeting` | Meet bot |
| `upload` | `upload` | 文件转写 |
| `netVideo` | `net_video` | YouTube 等 |
| `dub` | `dub` | AI 配音；Web 无强制对应 |

Web `source_type`（file / url / youtube / meeting …）留在 Web。映射实现：`KnowledgeSourceType.from(sessionType:)`。

### 11.3 「所有知识」列表默认与「显示全部」

- **默认**：只列出有 transcript / 可检索结果的 session；空/未索引隐藏。
- **「显示全部」**（`showAllSessions`，默认关）：包含未索引行。未索引行 **变灰**、**不可 QA**；选中后右栏提示需先转写。
- 关掉「显示全部」时，若当前选中的未索引 session 已不在列表中，回退到「所有知识」。

### 11.4 Streaming

P0 允许 **完整 `complete` 后再按 chunk 伪流式**（`chunkForStreaming`）。真正 token SSE 推迟到 P1+，**不阻塞本 PR**。

## 12. 模型 Ready 门禁（发问前）

对齐现有转录/配音：`LocalModelInstallPlan` + `LocalModelRequirementCard` + `LocalModelManager.ensureModels` / license 规则。

### 规则

1. **发问前必须 ready**（用户点 Send / Voice final 触发 QA 时检查），不是仅进页面就强弹（进页可静默预检并显示状态条）。
2. **P0 必下模型**：`weMMEmbedding2B4Bit`（Hybrid/RAG）。本地 Answer LLM 按现有 LLM provider / local-first 配置的模型 ID 一并纳入 plan（与 Settings 所选一致）。
3. **P1+**：Reranker（Qwen3-Reranker MLX）加入同一 plan，缺则一并下载。
4. **复用 UI**：缺模型时在 Chat 输入区上方或 sheet 内展示 `LocalModelRequirementCard(plan:)`；主按钮文案：
   - 未在下：`Download and ask`
   - 下载中：`Preparing…` + Progress（`isPreparing(plan)`）
5. **许可**：`requiresLicenseAcceptance && !isLicenseAccepted` → `LocalModelManager.presentManager()`，与 `ProcessingOptionsSheet.prepareAndSubmit` 一致，不静默下。
6. **自动继续**：用户确认下载后 `ensureModels(plan.ids)`；**全部 installed 后自动用挂起的 `pendingQuery` 继续跑 QA**，无需再点一次 Send。下载失败保留 pending，展示错误可重试。
7. **取消**：取消下载清空/保留 pending 由现有 cancel 行为决定；取消后不自动发问。
8. **云端 Answer**：若 `allowCloud` 且用户选云 LLM，仍要 WeMM（本地检索）；云 LLM 凭证走现有 `ensureCloudAccess` / credential 检查，与模型下载门禁分开。

### 建议 API

```swift
extension LocalModelInstallPlan {
  static func knowledgeQAPlan(
    answerModelID: LocalModelID?, // local answer; nil if cloud-only answer
    includeReranker: Bool
  ) -> LocalModelInstallPlan
}

func ensureKnowledgeQAReady(plan:) async throws
// missing → throw / return .needsDownload(plan)
// ready → .ready
```

ChatPane 持有 `pendingQuery: String?`；ready 后 `flushPendingQuery()`。

## 13. Index Item Entity：local / cloud source + 登录态过滤

### 问题

现有 `SessionCard` / `sessions` 表无 **来源归属**。登录后云 session 也会落到本机 Index；未登录时若不过滤，KB「所有」可能掺入仅登录可见的云内容，或登出后仍可搜到不应暴露的云索引。

### 原则

1. **索引始终在本地 SQLite**（登录或不登录都能建本地向量/词法索引）。
2. 每条 session（及下属 unit）必须带 **`source_origin: local | cloud`**，在 ingest 时写入，不靠运行时猜。
3. **Runtime filter 结合登录态**：
   - 未登录：`origin == local` only
   - 已登录：默认 `local + cloud`；UI Filter 可只选其一
4. 云 session 登录后 **照样 index 到本地**，但 `source_origin = cloud`，并保留 `remote_session_id`（若有）便于回跳/去重。

### Schema 建议

```swift
enum KnowledgeSourceOrigin: String, Codable, Sendable {
    case local
    case cloud
}

// sessions 表增量字段（SessionIndexStore / SessionCard）
source_origin TEXT NOT NULL DEFAULT 'local'   -- local | cloud
remote_session_id TEXT NULL                    -- 云端 id；local 可空
owner_user_id TEXT NULL                        -- 可选：写入时的账号；登出过滤的辅助
indexed_at REAL
```

`SessionSearchFilter` 增加：

```swift
var sourceOrigins: Set<KnowledgeSourceOrigin>?  // nil = 由 Account 默认策略填充
```

`units` 行可 **冗余** `source_origin`（ingest 时从 session 复制），避免 join 漏滤；或以 `session_id` join `sessions.source_origin` 为准（v1 推荐 join，少冗余）。

### Ingest 规则

| 场景 | source_origin | 行为 |
| --- | --- | --- |
| 本机录音/导入，storage=local | `local` | 始终可索引、未登录可见 |
| 登录后打开/同步的云 session | `cloud` | 下载/缓存 transcript 后 **本地建索引**，标记 cloud |
| 登出 | — | **不删** cloud 索引行；查询层滤掉 |
| 切换账号 | — | 若 `owner_user_id` 不匹配当前用户，cloud 行不可见（可 P1 再清或重建） |

来源判定优先读 Workbench session 的 `storage` / `remoteSessionID`（已有 `TaskStorageDestination`），写入 snapshot：

```swift
SessionIndexSnapshot.sourceOrigin =
  (storage == .cloud || remoteSessionID != nil) ? .cloud : .local
```

### Runtime Filter（KB + SearchService）

```swift
func effectiveOrigins(isSignedIn: Bool, uiFilter: Set<KnowledgeSourceOrigin>?) -> Set<KnowledgeSourceOrigin> {
  let allowed: Set = isSignedIn ? [.local, .cloud] : [.local]
  return uiFilter.map { $0.intersection(allowed) } ?? allowed
}
```

- KB 左栏列表、Hybrid Search、`scope=all` QA 全部走同一 filter。
- `scope=session(id)`：先校验该 session 对当前登录态可见，再检索。

### UI

- 列表行角标：`Local` / `Cloud`
- Filter：All visible / Local only / Cloud only（Cloud only 未登录禁用）
- 「所有知识」副文案反映当前可见数量（已过滤）

### 迁移

- 旧行无字段 → DEFAULT `local`（保守：未登录仍可见；若需更严，P1 按 `remote_session_id` 回填 cloud）
- `SessionIndexSnapshot.ingestFormat` bump，触发必要 rebuild 时写 origin

### 验收

- [ ] 未登录：搜不到 `source_origin=cloud` 的 chunk
- [ ] 登录：云 session 新转录会本地入库且标 cloud；「所有」QA 可命中
- [ ] 登出：同一库文件下 cloud 命中消失，local 仍在
- [ ] 单 session scope 对不可见 cloud session 拒绝/提示登录

### Cloud Recent ↔ Index 闭环

登录后云端增删改必须反映到本地 Recent，并 sync 到本地 Index（`source_origin=cloud`）：

| 云端变化 | Recent | Index |
| --- | --- | --- |
| 新增 | `refreshRemoteSessions` 合并进列表 | 有 transcript/summary 则 `syncCloudSessions` ingest |
| 编辑 | 打开/刷新后更新 `remoteSessions` | `replaceLexical`（generation 变则重建） |
| 删除 | 从 `remoteSessions` 移除 | `SessionIndexCoordinator.remove` |
| 登出 | `clearRemoteSessions` 清空 Recent 云条目 | **不删** cloud 行；查询/KB filter 隐藏 |

`reconcile(localJobs)` 只清理 **local-origin** 孤儿；cloud 行仅显式 `remove`。
