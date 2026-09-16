# 知识库问答（RAG + Skills Agent）流程

日期：2026-09-15  
范围：`voxella-studio-app` macOS 客户端

## 最终问答路径

```text
Controller 发送前门禁（本地 entitlement、回答模型、模型准备、scope）
  → KnowledgeQAService.answer（默认进入 Agent runtime）
  → KnowledgeAgentRuntime
      → 加载 bundled + 已安装的 knowledge skills
      → LLM 选择最多 3 个 skill；失败时启发式选择
      → request router
          ├─ simpleQA：knowledge.search（最多 8）→ 一次回答
          ├─ inventory：JSON tool-loop（最多 4 轮）
          └─ complex：JSON tool-loop（最多 6 轮）
      → finish_with_evidence / ask_clarification 控制
      → 用收集到的 citations 组装最终回答
  → 没有可用 KB skill 时回退到 legacy RAG
  → 有引用的回答，或简单路径的摘录降级
```

`KnowledgeQAService.useAgentRuntime` 默认开启；`legacyAnswer` 保留给无 KB skill 的回退路径和回归测试。Agent runtime 使用独立的 `KnowledgeToolRegistry`/`KnowledgeToolExecutor`，不复用视频编辑 Agent 的 `ToolDefinitions`/`ToolExecutor`。

Agent P0 的 tool-loop 使用 `LLMTextClient.complete` 返回的文本 JSON，而不是 provider 原生 function calling。每轮把模型响应和工具观察结果追加到会话文本；达到 `finish_with_evidence`、模型不再输出 tool call，或达到轮数上限后，调用最终 Answer Composer。`finish_with_evidence` 是当前 P0 的协议控制信号：它记录 accepted ref 数量，但最终 context 仍由 loop 中收集的 citations 构造，尚不是独立的服务端 hard gate。

检索与回答是独立资格：本地 Knowledge Base 沿用 Trial/Lifetime entitlement；回答还需已登录的 Hosted AI，或有效 BYOK。未登录且没有有效 BYOK 时，controller 在写 conversation 前停止：不创建空 assistant 消息、不下载 WeMM/reranker、不启动索引、Graph 或远端请求。输入区提供 Account 与 AI Settings 操作。

每个 `await` 后会重新确认 conversation、scope 与 generation；切换会话、账户或设置、取消任务时不会写入过期回答。

## Skills 路由

`SkillStore.knowledgeSkills()` 合并两类 skill：

- app bundle `Resources/KnowledgeSkills/*/SKILL.md` 中的 5 个内置 skill；
- `~/.voxstudio/skills/<id>/SKILL.md` 中 category 为 `knowledge` 或 `knowledge-qa` 的已安装 skill。

Knowledge skill 在现有 `name`/`description` frontmatter 上增加可选字段：`selection_summary`、`applies_when`，以及 `allowed_tools`、`supports_evidence_goals`、`analysis_modes` 列表。runtime 直接读取 skill body 注入 Agent prompt；它不通过视频编辑 Agent 的 `read_skill` 工具加载。Community catalog 仍以 `sha` 作为版本锚点，安装时只接受合法的单层 skill ID 和可解析的 `SKILL.md`。

首发内置 skill 与路由意图如下：

| Skill ID | 用途 | 典型工具 |
| --- | --- | --- |
| `mac_kb_content_qa` | 单/多 session 事实问答 | `knowledge.search`、`session.search_segments` |
| `mac_kb_collection_analysis` | 多 session 总结、分类、综合与对比 | `session.list`、`session.get_summary`、`knowledge.compare_sessions` |
| `mac_kb_session_transcript` | 单个选中 session 的 transcript 精读 | `session.search_segments`、`session.get_segments`、`session.get_timeline` |
| `mac_kb_session_inventory` | 按日期、类型、时长、来源列出 session | `session.list`、`knowledge.get_session_metadata` |
| `mac_kb_timeline_qa` | 时间点、时间范围和时间线模式查询 | `session.get_timeline`、`session.search_segments` |

选择器输入用户问题、scope 和每个 skill 的 `selection_summary`（缺失时使用 description），只允许返回最多 3 个已加载的 skill ID。LLM 输出无效、为空或请求失败时，按多 session 对比 → 时间线 → inventory → 单 session transcript → content QA 的启发式顺序选择；仍无选中项时进入 legacy RAG。

路由规则是轻量的 P0 router：inventory skill 或明显的列表/计数问题进入 `inventory`；单 session 且只有 transcript skill 时进入 `simpleQA`；出现 collection/timeline skill 时进入 `complex`；其他情况也进入 `simpleQA`。因此，当前 Agent simpleQA 直接把原问题交给 `knowledge.search`，不会先执行 legacy RAG 的 `search_query/answer_constraints` planner。P0 的文字 heuristic 目前识别 `how many`、`list all`、`which sessions` 等英文短语，其他语言主要依赖 LLM skill selection。

## 注册 tools

`KnowledgeToolRegistry.allTools` 是 KB Agent 的固定 schema 和 allowlist；`KnowledgeToolExecutor.execute(toolName:arguments:)` 负责调用现有 `SearchService`、`SessionIndexCoordinator`、`WorkbenchStore` 和 summary/index 数据。未知名称由 executor 拒绝，不会调用编辑器工具；当前 runtime 会把这类抛错结束为 failed event。

| Tool | 输入与默认值 | 输出 / 用途 |
| --- | --- | --- |
| `knowledge.search` | `query`；`session_ids?`；`limit?`（默认 8） | hybrid transcript hits + `citations` |
| `session.list` | `query?`、`type?`、`origin?`、`date_from?`、`date_to?`、`limit?`（默认 20） | 按可见性过滤的 session cards 与 count |
| `knowledge.get_session_metadata` | `session_id` | title、type、duration、modified_at、origin、has_transcript |
| `session.get_summary` | `session_id` | summary markdown、title、tag |
| `session.get_segments` | `session_id`、`start?`、`end?`、`limit?`（默认 20） | 连续 transcript segments；给定时间范围时取该范围 |
| `session.search_segments` | `session_ids`、`query`、`limit?`（默认 8） | 带时间和 speaker 的 transcript hits |
| `session.get_timeline` | `session_id`、`bucket_seconds?`（默认 60） | 按时间桶聚合的 segments |
| `knowledge.compare_sessions` | `session_ids`（至少 2）、`focus_query?`、`mode?`（默认 themes） | 每个 session 的 summary，以及可选 focus hits |
| `finish_with_evidence` | `accepted_refs` | 控制 loop 结束，并记录接受的引用 ID 数量 |
| `ask_clarification` | 非空 `question` | 控制 loop 结束并向 UI 返回 clarification failure |

tool 返回的 JSON 中，搜索类结果携带 `KnowledgeSourceRef` 的 source、时间、speaker 和 snippet；最终回答只应把这些证据当作事实来源。内置 skill 的 `allowed_tools` 可由 `KnowledgeToolRegistry.validateSkill` 校验，必须是 registry 中的名称子集；当前 P0 的 Agent prompt 暴露全局 registry，尚未按每个 skill 的 `allowed_tools` 再缩小工具集合。

## 数据边界与可见性

`Search/index.sqlite` 是 legacy RAG 的唯一检索数据库。`sessions`、FTS5、sqlite-vec 与图表共享该文件。查询默认使用当前 UI scope（`.all`、`.session` 或 `.sessions`）和 `originFilter`；搜索 executor 通过 `SessionSearchFilter.visible` 继承登录可见性，cloud source 的 `owner_user_id` 必须与当前用户匹配。工具不得把回答扩展到 UI 未选择或登录不可见的 cloud source。

登出不会删除本地 cloud index 或图，但它们不可召回。关闭 BYOK 也不删除图数据，只暂停 graph ingestion 与 recall。图不复制 transcript 全文，只保存实体、别名、关系、关系证据、entity-to-chunk 链接以及 source generation/schema 指纹。

## RAG core（legacy fallback 与 search 内部）

Legacy Hybrid Search 使用 FTS5 与 WeMM text embedding 的 RRF，最多 30 个 transcript chunk。Graph query understanding 与 Hybrid 并行：只产出实体/别名和 hop 建议，不回答问题。图扩展默认最多 2 跳、硬上限 3 跳；每跳最多 20 个节点、总节点最多 80，最终最多 20 个关联 chunk。

候选按 `unitID` 去重后截断为 40，统一送入 reranker。Graph path 仅作为内部 provenance，绝不传给 reranker，也不作为 LLM 事实。Agent 的 `knowledge.search` 复用现有 `SearchService.transcriptSearch`，无结果时回退 `SearchService.search`，由传入的 `limit` 控制结果数；Agent 外层不再追加一轮独立 rerank。

本地 reranker 固定为 `mlx-community/Qwen3-Reranker-0.6B-4bit` revision `5f324548f1d20c2b5a450f126fc6ef2fb1126524`，模型与 tokenizer 资产由 catalog 的 SHA-256 验证。它通过共享 MLX inference gate 执行，支持取消；输入严格是 query 与原始 chunk 文本，不包含标题、摘要、邻居或 graph path。

先保留 `>= 0.25`；无命中时单次放宽至 `>= 0.175`；仍无命中时只保留 `>= 0.15` 的 Top-1，否则返回证据不足。模型缺失、下载失败或推理失败不会令 legacy 检索失败：保留融合候选，继续去重、MMR 与上下文构造并记录诊断。

MMR 最多 8 个，`λ = 0.7`。优先读取已存 WeMM 向量；无向量时才用词项 Jaccard，不为 MMR 重嵌入 chunk。

## Graph ingestion 与 BYOK

图开关默认关闭。开启时只回填当前可见 source，之后按 session source generation 增量更新。每个 source 的 transcript chunk 按 6 个一批，使用 `Graph extraction & ingestion` 路由生成受控 JSON。输出只接受本批 chunk ID、固定 entity type 与 predicate schema；无效项丢弃。

source 图重建使用一个 SQLite transaction：先删除该 source 的关系证据、entity-chunk 链接与 state，再写入全部新抽取结果，最后清理孤儿实体和关系。source 更新、删除或 lexical replace 时同步清理旧图证据。取消或抽取失败不会提交半张图，也不会阻塞 lexical/embedding 索引。

Settings → AI 提供独立路由：

| 类别 | 默认超时 | 每模型尝试 | 初始退避 |
| --- | ---: | ---: | ---: |
| Graph extraction & ingestion | 90 秒 | 2 | 0.75 秒 |
| Graph query understanding | 15 秒 | 1 | 0.5 秒 |

Hosted 模式沿用服务端默认链。BYOK 分别要求 graph extraction、graph query 和 chat 路由有效；Graph 开启而路由无效时在提交前显示配置状态，而不是依赖异常控制流。

## Context、引用和语言

Legacy RAG 的每个 session 标题只加入一次，标题和摘要合计每 session 最多 360 字，全部 metadata 最多 1,500 字。anchor chunk 少于 350 字时，按 transcript 顺序补前后邻居；合并块最多 850 字。去重后的 metadata 和 evidence 共同计入 10,000 字上下文预算。

Agent tool-loop 的最终 context 由已收集的 citation snippet 编号组成，最多 10,000 字；simpleQA 也通过 `KnowledgeQAService.buildContext` 进入同一回答提示。引用永远指向 anchor/segment；标题、摘要、timeline bucket 和邻居只帮助理解，不应产生新的 transcript 引用。Prompt 要求回答使用提问语言；回答模型不可用时，legacy/simple 路径使用带引用的摘录降级。

## Legacy RAG 的 query planning 与 prompt 实验

没有进入 Agent runtime 的请求在 legacy RAG 路径中，先经过一次结构化 query planning。planner 使用固定的 `gpt-5-nano` chat route，只返回 `search_query` 与 `answer_constraints` JSON；`search_query` 只保留主题、实体、关系和时间等语义信息。单个目标 session（或所有选中 session 语言明确一致）时，优先使用索引记录的原始转录语言和文字脚本生成 `search_query`，因为 transcript 原文以该语言存储；实体、缩写和专有名词保留原拼写。多 session 语言混合、全库范围或缺少语言元数据时，回退为当前问题语言。`answer_constraints` 承载“3 句话”、语言、格式等输出要求，不能进入召回。Hybrid、Graph、reranker 只接收 `search_query`；完整原问题和约束只进入回答 prompt。planner 失败时保留原问题作为检索输入并记录诊断，不使用针对某个语言后缀的字符串规则。

Agent runtime 的 skill selector 是另一轮独立调用：它只选择 skill ID，不生成 `search_query`。complex/inventory tool-loop 使用原问题、scope、skill body 和工具观察结果取证，最终 Composer 再接收原问题与 citations。

验收 legacy planner 使用固定模型 `openai/gpt-5-nano`、固定 `reasoning.effort=medium`、固定 temperature 与 token 上限，并关闭实验路由 fallback；一次只改变 prompt/检索策略，避免把模型能力变化误判为 prompt 效果。生产路由仍可按现有 resilience policy fallback。

| 实验组 | Query planning | Answer prompt | 目的 |
| --- | --- | --- | --- |
| B0 | 原问题直接检索 | 当前 grounded prompt | 复现基线 bad case |
| P1 | JSON 分离 `search_query` / `answer_constraints` | 当前 grounded prompt | 验证“3 句话”不再污染召回 |
| P2 | P1 | 明确 evidence-only、约束优先级、引用规则、提问语言 | 验证回答格式与引用稳定性 |
| P3 | P1 | P2 + 要求先在证据内归纳再输出，不暴露 planner 字段 | 验证无证据时不编造 |

固定测试集至少包含：中文“讲的主要是什么主题？ 3句话”、英文等价问题、第三语言问题、无长度约束的问题、把“3句话”作为 transcript 内容实体的问题。记录 recall@30、reranker admission、MMR 覆盖、空证据率、精确句数、语言一致性、引用 precision/recall、端到端延迟、输入/输出 token 和成本。每组重复相同 session snapshot；接受 P2/P3 的前提是空证据率下降且引用 precision 不下降，格式指标只在有证据样本上统计。

## 降级与额度

- skill selector 失败：使用本地启发式选择；没有 eligible skill 或选择结果为空：回退 legacy RAG。
- Agent tool 返回的业务错误：写入 observation，继续下一轮；未知 tool 或抛出的参数错误会使当前 stream 以 failed event 结束。
- `ask_clarification`：结束当前 Agent stream 并返回 clarification failure；不伪造答案。
- Graph query、图 SQLite、Graph 模型或 reranker 故障均软降级到 Hybrid/融合候选；`429`、超时和 provider 故障使用现有有限重试，耗尽后显示带引用摘录，不误报额度不足。
- simpleQA/legacy 的回答生成失败时保留 citations 并显示摘录；complex/inventory 的最终 Composer 失败则由 runtime 以 failed event 返回，后续可补统一 excerpt fallback。

Hosted `/api/v1/llm/responses` 的 `402` 且嵌套 `error.type/code = insufficient_credits` 映射为 `LLMClientError.insufficientCredits`，绝不重试，也不自动切换 BYOK。已完成检索仍保存带引用摘录，并附“管理额度”和“配置 BYOK”恢复操作；`KnowledgeMessage` 持久化可选 actions，旧 JSON 仍可解码。已知额度耗尽期间暂停 Graph 后台请求，账户刷新后才清除状态。

## 代码落点

- Agent runtime：[`KnowledgeAgentRuntime.swift`](../../Sources/PalmierPro/Knowledge/Agent/KnowledgeAgentRuntime.swift)
- tool schema/allowlist：[`KnowledgeToolRegistry.swift`](../../Sources/PalmierPro/Knowledge/Agent/KnowledgeToolRegistry.swift)
- tool 执行：[`KnowledgeToolExecutor.swift`](../../Sources/PalmierPro/Knowledge/Agent/KnowledgeToolExecutor.swift)
- skill 解析与加载：[`Skill.swift`](../../Sources/PalmierPro/Agent/Skills/Skill.swift)、[`SkillStore.swift`](../../Sources/PalmierPro/Agent/Skills/SkillStore.swift)
- legacy RAG 与回答 composer：[`KnowledgeQAService.swift`](../../Sources/PalmierPro/Knowledge/KnowledgeQAService.swift)
