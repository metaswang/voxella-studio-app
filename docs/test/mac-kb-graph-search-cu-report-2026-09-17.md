# Knowledge Base Graph Search 端到端验证报告

日期：2026-09-17
被测应用：VoxStudio macOS Knowledge 页面
测试方式：Computer Use 操作可见 UI；每次提问后读取 VoxStudio unified log，并人工核对 LLM compose 答案与 Sources 引用。
目的：验证 Graph Search 是否能在 Agent Search 知识库问答中补充召回，尤其是别名、实体关系和多跳关系。

## 1. 测试设置

- UI 显示 29 个可问答的 Local sessions；Cloud session 因当前未登录而不可见。
- `Enable graph recall for Knowledge Base`：开启。
- BYOK：开启。
- Chat model：`openai/gpt-5.4-nano`。
- Graph query understanding：`openrouter/google/gemini-2.5-flash-lite`，fallback `openai/gpt-5-nano`。
- 本地 Search index 只读检查：`graph_entities=49`、`graph_relations=40`、`graph_entity_chunks=75`；已有 graph source state 的 session 为 11 条，因此本报告不把 Graph coverage 解释为全部 session 都已建立图谱。

### 判定口径

只有同时满足以下条件，才计为“Graph Search 对召回有帮助”的有效样本：

1. 日志中的 `graph_attempted=true` 且 `graph_status=used`；
2. `graph_hit_count>0`，并且 query 中确实包含实体、别名或关系路径；
3. 最终 compose 答案引用了预期 session 的 transcript 片段；
4. 答案没有把 graph 推断扩写成 transcript 未支持的事实。

`graph_hit_count` 是 Graph 路径产生的候选数，不等同于最终新增的去重证据数；要证明严格的增量召回，还需要后续 Graph on/off A/B 或记录候选 unit id 的差集。

## 2. Query 设计与端测结果

| ID | Session scope | Query | 预期 Graph 作用 | UI compose / Sources 核验 | 日志与结论 |
|---|---|---|---|---|---|
| G1 | all knowledge | `Dale Carnegie 在哪些 session 中出现？他与《How to Stop Worrying and Start Living》是什么关系？请列出 session、关系和时间引用。` | 通过人物/书名实体和跨 session 关系召回两个 Lemon session 的相关片段。 | 返回 Dale Carnegie、书名及相关内容，但 Sources=8，混入 `Infinity, Mathematics, and Reality`、`Origin of Writing` 等无关引用。 | request `A2F61146-9F34-433B-A791-239F76A84314`；Graph understanding timeout、graph recall timeout、rerank timeout。**不作为有效 Graph 证明；暴露 all-scope 超时和引用污染。** |
| G2 | all knowledge | `从“录制过程”到 Session UI 播放器，Original、Mac本地降噪和增强处理后的音频之间是什么关系？请只引用 Session播放器支持切换原始音频。` | 应从跨 scope 找到播放器 session，并通过 Agent Search 的 `knowledge.search` 取得唯一片段。 | UI 返回证据不足且无 citation，尽管目标 session 已知存在相关 transcript。 | request `D8040185-491C-4CCE-AF36-9C57C4A4232F`；planner/skill selection 完成，但没有观察到 retrieval summary。**Agent tool-loop 未实际调用 search，属于路由问题。** |
| G3 | `Session播放器支持切换原始音频` | `录制时选择 Mac 本地降噪或云端高保真处理后，Session UI 播放器默认播放什么？Original 的作用是什么？` | 识别 `Mac本地降噪`、云端高保真工具、`Original`、播放器实体关系，补召回同一 transcript。 | 回答正确：默认是增强处理后的音频，Original 用来回听原始音频；Sources=1，引用 `Speaker 1 · 0:04`。 | request `A69E0964-D03D-4BD2-8EFD-FE7E9478C446`；`hybrid=1 graph=1 candidate=1 reranker=used`。**Graph 路径成功；结果与引用符合预期。** |
| G4 | `土木工程师转中医师的人生转折` | `吴国斌为什么从台大土木、土木工程研究所转向学士后中医？请按时间顺序说明动机，并指出台大土木与中医学习之间的关系。` | 连接 `台大土木`、`土木工程`、中医转轨和学士后中医相关实体，扩大多片段召回。 | 主要事实和 8 条 Sources 基本符合预期：童年启发、先读台大土木、工作过劳/空虚、准备学士后中医。**问题：** compose 写出“台大土木带来的学习能力对中医考试的直接帮助”，transcript 未明确支持，属于 grounding overreach。 | request `F44B41A5-9009-40B8-A019-D897CEE0B5E5`；`hybrid=11 graph=12 candidate=15 reranker=used`。**最强增量样本：Graph 候选数高于 Hybrid，且最终证据覆盖多个关系节点；需修复无证据推断。** |
| G5 | `颈椎调理与居家手法学习感受` | `这场 session 中，颈椎痛、手法、居家练习和给家人使用之间是什么关系？请只根据 transcript，不要给医疗建议。` | 通过 `颈椎痛` ↔ `手法` ↔ 居家/家人关系召回体验片段。 | 回答正确地区分了说话者体验、手法学习和给孩子/先生/老人使用的描述；Sources=1，引用该 session。没有扩写为医学疗效或建议。 | request `C18790BF-0042-4F18-81D4-FEC79C120164`；`hybrid=1 graph=1 candidate=1 reranker=used`。**Graph 路径成功；引用与安全边界符合预期。** |
| G6 | `土木工程师转中医师的人生转折` | `问题中的“刘宇佳”是否对应 transcript 里的“刘玉佳”？请只根据这场 session，说明她如何介绍吴国斌，以及节目为什么邀请他。` | 验证名字别名 `刘宇佳` ↔ `刘玉佳`，并沿 `刘玉佳`→吴国斌→土木/中医转折关系召回开场片段。 | 回答正确识别别名；说明刘玉佳介绍吴国斌为高中学弟/中医师，并因发现其读过土木研究所后转做中医而产生兴趣、邀请节目；Sources=3，引用 `0:02`、`0:35`、`1:29`。 | request `275CEA47-479A-4707-8EAA-DB1346084BB9`；`hybrid=4 graph=7 candidate=7 reranker=used`。**别名+关系召回成功；这是 Graph Search 帮助召回的直接证据。** |
| G7 | `土木工程师转中医师的人生转折` | `只根据这场 session，吴国斌与吴奇医师、加州中医大学、中国医药学院分别是什么关系？请列出每条关系，并给出 transcript 时间引用；如果某条关系没有足够证据，请明确说没有。` | 从吴国斌出发，沿 `吴国斌`→`吴奇医师`→`加州中医大学`，并召回中国医药学院旁听片段，验证 1–2 hop。 | 返回 3 条关系、4 条 Sources：吴国斌拜吴奇医师为师；吴奇医师是加州中医大学副校长，构成间接关联；相关经历提到旁听中国医药学院；时间引用 `1:29`、`2:15`、`3:50`。整体符合预期，未补充 transcript 外关系。 | request `BBB79BED-1997-4A31-8649-1757B9B6F322`；`hybrid=9 graph=7 candidate=10 reranker=used`。**多跳关系与引用成功；Graph 虽不高于 Hybrid，但提供了可用关系候选。** |
| G8 | `颈椎错位与枕头调整` | `只根据这场 session，是否提到“枕头高度应该根据颈椎曲度精确测量”或具体的枕头高度数值？如果没有，请明确回答没有，不要根据常识补充。` | 负向控制：Graph 可尝试实体匹配，但不应从 `颈椎`、`枕头` 邻近概念生成不存在的数值证据。 | UI 正确返回“没有找到足够证据”，无 Sources，没有生成高度数值或医学常识。 | request `C0123DFC-03AA-4D74-8793-C08703045B36`；`hybrid=1 graph=0 candidate=1 reranker=used`。**负向控制通过；Graph 无命中时 compose 能保持证据边界。** |

## 3. 日志与 UI 对照证据

成功样本的统一日志形态为：

```text
knowledge retrieval path=agent
  hybrid_hit_count=...
  graph_attempted=true
  graph_status=used
  graph_hit_count=...
  candidate_count=...
  reranker_status=used
```

关键可复核记录：

- G3：`hybrid=1, graph=1, candidate=1`，UI 1 个正确 citation。
- G4：`hybrid=11, graph=12, candidate=15`，UI 覆盖多段人生转折证据，但有 1 个无证据推断。
- G5：`hybrid=1, graph=1, candidate=1`，UI 1 个正确 citation，医疗边界正确。
- G6：`hybrid=4, graph=7, candidate=7`，UI 正确处理 `刘宇佳`/`刘玉佳` 别名并引用 3 个时间点。
- G7：`hybrid=9, graph=7, candidate=10`，UI 返回多跳关系和 4 个 Sources。
- G8：`hybrid=1, graph=0, candidate=1`，UI 对无证据问题拒答。

## 4. 结论

本轮可以支持一个有边界的结论：**Graph Search 在 Agent Search 的单 session、简单 QA 路径中能够帮助召回实体别名和关系相关 transcript。** G4、G6、G7 尤其证明了关系候选可以进入最终 rerank/compose；G6 的别名 Query 是最直接的正向证据，G4 还出现 `graph_hit_count=12` 高于 `hybrid_hit_count=11` 的样本。

但目前不能据此声称 Graph Search 对所有 Agent Search 问题都稳定提升：

1. all-scope 的 G1 出现 graph understanding/recall/rerank timeout 和无关引用污染。
2. all-scope 的 G2 planner 虽完成，但 Agent tool-loop 没有实际搜索，导致已知存在的证据没有 citation。
3. G3/G5 中 Graph 与 Hybrid 命中数相同，尚未证明严格的“Graph 独有新增证据”。
4. G4 的 compose 将关系证据扩写成“台大土木带来的学习能力”，需要 claim-level grounding 检查。
5. 目前只有 11 个 session 有 graph source state，且 Cloud sessions 在未登录状态下隐藏；Graph coverage 仍不完整。

## 5. 问题与后续建议

### 已记录问题

- Graph query understanding 的模型和超时配置会直接影响 Graph 是否可观察到；原配置曾出现 timeout，本轮切换到更快模型后才稳定得到 `graph_status=used`。
- Agent Search 的 all-scope 路由没有保证调用 `knowledge.search`，应补 tool invocation 的强断言和日志。
- citation 集合在超时/跨 session 路径可能混入无关 session，应按 scope、source id 和最终 claim 做过滤。
- 日志当前只记录 Graph 命中数量，没有记录解析出的实体、关系、别名和候选 unit id，因而难以完整审计“Graph 为什么命中”。
- compose 需要禁止把“Graph 关系”自动改写成 transcript 未说出的因果或能力结论。

### 建议下一轮补测

1. 对 G3、G4、G6、G7 做 Graph on/off A/B，记录最终候选 unit id 差集、首个 rank 和 citation 差集，才能量化增量召回。
2. 为 all-scope Agent Search 增加“必须发生 `knowledge.search` 或明确 no-search reason”的断言。
3. 在检索日志中打印 query-understanding 的实体/别名/关系摘要（脱敏即可）。
4. 加入 citation precision 检查：引用必须属于当前 scope，且能支撑答案中的每个关系断言。
5. 完成剩余 session 的 graph ingestion/state 后，再测试跨 session 的人物、书名和主题查询。
