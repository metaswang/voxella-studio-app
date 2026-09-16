# Mac Knowledge Base QA — Skills / Planner / Tools

日期：2026-09-15  
范围：`voxella-studio-app` Knowledge 页 QA；对齐 `voxella-api` chat_agent（skills + router + tool-loop），不照搬 LangGraph 全量。  
相关：`docs/design/mac-knowledge-base-qa.md`、`docs/design/knowledge-base-rag-flow.zh-CN.md`；API `app/services/chat_agent/*`、`app/services/chat_skills.py`

---

## 1. 问题

当前 Mac KB QA（含本地 WIP）本质是 **单路径 RAG**：

| 现状 | 缺口 |
|------|------|
| 固定 Hybrid（+ 可选 Graph）→ Top-K → 一次 Answer | 无多 skill 路由、无 tool-loop |
| WIP planner 仅产出 `{search_query, answer_constraints}` | 总结 / 对比 / 时间线 / session 元数据无法专用取证 |
| Settings → Skills 只注入 **视频编辑 Agent**（`read_skill`） | Knowledge 页不跑 Agent，社区 skill 装了也用不上 |

复杂现实查询需要 **按意图选 skill → 选工具批次 → 证据门禁 → 作答**，而不是永远 `search_query`。

---

## 2. 设计原则（对齐 API，适配 Mac）

1. **复用 API 心智，不复刻整图**：Skill 选择（≤3）→ 简单路由短路 → 否则 contract + **动态 tool-loop** → evidence hard-gate → Composer。不做完整 LangGraph / fast-router（chit-chat/help 可后置）。
2. **Skills 包装沿用 App Settings → Skills**：`SKILL.md` + Community catalog；新增 category **`knowledge`**（社区「知识库 chat」类）。安装路径为 `~/.voxstudio/skills/<id>/`。
3. **运行时桥接必须新建**：Knowledge 页专用 `KnowledgeAgentRuntime`（或等价），**不要**指望编辑器 `AgentService` 直接答 KB。
4. **工具 I/O schema 在 App 内实现**：命名尽量对齐 API 点分工具（Mac 侧可用 `knowledge_search` ↔ `knowledge.search`），能力表驱动证据种类。
5. **Scope 仍由 UI 决定**：`.all` / `.session` / `.sessions` 作为默认 `target_scope`；skill 不得越权扫登录不可见的 cloud。

---

## 3. 目标架构

```
User ask (scope + draft)
  → KnowledgeAgentRuntime
       ├─ load_skill_index (Settings Skills where category∈{knowledge,knowledge-qa} ∪ built-in)
       ├─ select_skills (LLM ≤3)          // 对齐 API skill_selector
       ├─ request_router                  // 简单族短路
       │    ├─ simple_transcript_qa → knowledge.search / session.search_segments
       │    ├─ inventory / metadata   → list + get_metadata
       │    └─ complex → contract + agent_think ⇄ execute_tools
       ├─ evidence_gate (accepted refs only)
       └─ compose_answer + citations → 现有 KnowledgeAnswerEvent 流
```

**Built-in Mac skills（首发，YAML/Markdown frontmatter 与 API 字段对齐子集）：**

| id | 用途 | 典型工具 |
|----|------|----------|
| `mac_kb_content_qa` | 单/多 session 语义问答 | `knowledge.search`, `session.search_segments` |
| `mac_kb_collection_analysis` | 总结 / 分类 / **对比** | `session.recent`, `knowledge.compare_sessions`, `session.get_summary` |
| `mac_kb_session_transcript` | 当前选中 session 精读 | `session.search_segments`, `session.get_segments`, `session.get_timeline` |
| `mac_kb_session_inventory` | 列表 / 按元数据筛选 | `session.list`, `knowledge.get_session_metadata` |
| `mac_kb_timeline_qa` | 时间线条件查询 | `session.get_timeline`, `session.search_segments` |

社区 skill：catalog `category: knowledge`（或 `knowledge-qa`），`allowed_tools` 必须 ⊆ Mac 已实现白名单；未知 tool → 选择阶段剔除或运行时报可恢复错误。

---

## 4. Skill 文档约定（与 Settings 统一）

在现有 `name` / `description` frontmatter 上，**KB skill 扩展字段**（未知字段忽略，兼容编辑类 skill）：

```yaml
---
name: Compare sessions
description: Compare themes across selected knowledge sessions.
category: knowledge
status: published
selection_summary: Multi-session compare / classify / synthesize
applies_when: User asks to compare, contrast, or classify across sessions
allowed_tools:
  - knowledge.search
  - session.get_summary
  - knowledge.compare_sessions
supports_evidence_goals: [semantic_qa, source_summary]
analysis_modes: [summarize, compare, classify, synthesize]
---
# body: tool_guidance / evidence_guidance / answer_guidance（markdown）
```

- **加载**：`SkillStore` 增加 `knowledgeSkills()`（filter category + optional built-in bundle in app resources）。
- **社区**：`SkillCatalog` 已有 `category`；运营侧把 KB chat 类打进 `knowledge`；Installed / Community UI 可筛此类。
- **执行**：KB runtime 读 body 进 selector / think 提示；**不**走编辑器 `read_skill` 主路径（可复用同一读文件 API）。

---

## 5. Mac Tools（须在 App 实现 + JSON Schema）

首期最小集（覆盖 Adam 点名场景）：

| Tool | 输入（要点） | 输出 | 场景 |
|------|--------------|------|------|
| `knowledge.search` | `query`, `session_ids?`, `limit` | hits + citations | 语义/关键词 |
| `session.list` | `query?`, `type?`, `origin?`, `date_from/to?` | session cards | 元数据 / 库存 |
| `knowledge.get_session_metadata` | `session_id` | title, type, duration, dates, origin, has_transcript | 元数据问答 |
| `session.get_summary` | `session_id` | summary markdown | **只靠总结就够** |
| `session.get_segments` | `session_id`, `start?`, `end?`, `limit` | transcript slices | 精读 |
| `session.search_segments` | `session_id(s)`, `query` | timed hits | 单 session QA |
| `session.get_timeline` | `session_id`, `bucket_seconds?` | bucketed timeline | **时间线条件** |
| `knowledge.compare_sessions` | `session_ids` (≥2), `focus_query?`, `mode` | structured compare evidence | **对比** |
| `finish_with_evidence` / `ask_clarification` | refs / question | control | 对齐 API |

实现落点建议：

- `Sources/PalmierPro/Knowledge/Agent/KnowledgeToolRegistry.swift` — schema + allowlist  
- `KnowledgeToolExecutor.swift` — 调现有 `SearchService` / `WorkbenchStore` / SessionIndex / summary 字段  
- `KnowledgeAgentRuntime.swift` — select → route → loop → gate → 接上 `KnowledgeQAService` 事件流或替换其 `answer` 入口  

`KnowledgeQAService` 现有 Hybrid/Rerank/MMR 可降为 **`knowledge.search` 内部实现**，而不是唯一外层流程。

---

## 6. Planner / Router（精简版）

### 6.1 Skill 选择

- 输入：user 问句、当前 scope、已装 knowledge skills 的 `selection_summary` 列表。  
- 输出：`selected_skill_ids`（≤3）+ reason。  
- 偏好（对齐 API）：collection_analysis（多 session 对比/总结）→ timeline → transcript QA → inventory/metadata → 默认 content_qa。

### 6.2 Request router

| 条件 | Route | 行为 |
|------|-------|------|
| 单 session + 纯问答 skill | `simple_qa` | 1–2 次 search_segments / search，无长 loop |
| inventory / metadata skill | `inventory` | list + get_metadata，少 round |
| compare / summarize / timeline / 多 skill | `complex` | contract + tool-loop（预算 e.g. 6 tool rounds） |

### 6.3 Contract（可选轻量）

对齐 API 子集字段：`candidate_query`, `analysis_mode` (`summarize|extract|compare|classify|synthesize|timeline`), `content_topics`, `evidence_goal`。  
由启发式 + 一次小 LLM 补全；失败则用问句作 `candidate_query`。

### 6.4 Evidence gate

仅 `hard_gate_accepted` 引用可进 Composer；不足则 `ask_clarification` 或不足证据文案（保留现有 localized insufficient）。

---

## 7. 与现有 WIP planner 的关系

| WIP `{search_query, answer_constraints}` | 新设计 |
|------------------------------------------|--------|
| 只服务检索串 | 升为 **contract.candidate_query** + answer_constraints 仍只进 Composer |
| 无 tool | 被 skill + tools 取代为默认路径之一 |
| 可保留为 `simple_qa` 快速路径内部优化 | 复杂查询不再只用它 |

---

## 8. 分阶段

### P0 — 可演示复杂查询（建议下一实现波次）

1. Built-in 5 skills + ToolRegistry/Executor（上表工具）。  
2. Runtime：select_skills → router → simple 或 loop（上限 6）→ gate → answer。  
3. Settings Skills：`category: knowledge` 安装后出现在 KB selector 索引。  
4. UI：可选展示 “Using skill: …” / tool 轨迹折叠（调试用，可默认关）。  
5. 回归：现有单 session / all / multi-select 语义问答不回退。

### P1

- Community catalog 正式 `knowledge` 分区与校验（`allowed_tools` ⊆ Mac）。  
- `knowledge.run_skill_recipe` 可选（API recipe 子集）。  
- Timeline / compare 专用 UI 芯片。

### P2

- 与 API chat_skills 双向同步（登录用户拉取 published YAML）。  
- Fast-router（闲聊/能力边界）若需要再加。

---

## 9. 非目标（本设计不做）

- 把视频编辑 Agent 与 KB Agent 合成一个进程。  
- 完整移植 API LangGraph / help_center / account tools。  
- 无 schema 的自由 Python / 任意 shell skill。  
- 用社区 skill 绕过 `source_origin` / 登录可见性。

---

## 10. 验收场景（设计验收清单）

1. 「总结上周所有会议」→ inventory/metadata + get_summary，而非仅 Top-8 碎片。  
2. 「对比 session A 和 B 的结论」→ compare skill + `knowledge.compare_sessions`。  
3. 「找出 10:15 左右讲预算的部分」→ timeline / search_segments。  
4. 「有哪些本地录音还没转录」→ session.list + metadata。  
5. 普通事实问答 → simple_qa，延迟接近当前 RAG。  
6. 安装社区 `category: knowledge` skill 后，下一问可选中并只调用白名单工具。

---

## 11. 实现交接

- 设计稿路径：`docs/design/mac-kb-qa-skills-planner.md`  
- 建议实现方：Coding Bot；先 P0，不改 API 除非要同步 chat_skills 种子。  
- 测试：Skill 选择 fixture + 各 tool 单测 + 2–3 条端到端（mock LLM tool calls）。
