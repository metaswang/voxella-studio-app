# Cursor / VoxStudio local MCP E2E

Date: 2026-09-22. Client: Cursor Agents, existing `palmier-pro` connection at localhost:19789. Tests submitted through Cursor UI with Computer Use. The App remained on Knowledge without an open video editor project. No project edits were delegated to Cursor.

## Source-grounded queries

Sources were read in the App's Knowledge transcript viewer before testing:

- A: **Avoid Overloading Projects with Skills**, `310EC8B8-093B-4697-BAF8-069C4A174113`, 1.948–47.380s. Names/descriptions enter model context; too many skills cause descriptions to be shortened, making selection harder.
- B: **Skill Files for Workflow Guidance**, `E765DEBD-DB3A-4084-AA30-C0B071568A96`, 1.200–36.884s. Skills are prompts in Markdown, sometimes with bundled scripts, for task-specific workflows and plugins. Stored language was incorrectly `da`; transcript is English.

| Case | Query / arguments | Expected |
| --- | --- | --- |
| Inventory | `session.list(query="Skills", origin="local")` | A found; title, UUID and local origin match |
| Metadata / summaries | Read A metadata and A/B summaries | Correct identities and available summaries |
| Bounded segments | A 0–60s; B 0–45s | Original transcript with timestamps |
| Default segments | A, no start/end | Same A transcript |
| Scoped search | A: `skill descriptions context shortening`; B: `markdown workflow plugin` | Hits from requested source only |
| Timeline | A, bucket_seconds=10 | Nonempty chronological bucket with A's transcript |
| Chinese QA | 为什么给项目安装太多 skills 会使模型更难选择正确的 skill？ | Context loading, shortened descriptions, selection difficulty, A citation |
| Follow-up QA | 它们通常以什么文件格式保存，还可以附带什么？ + history about B's skill files | Markdown, bundled scripts, B citation |
| Comparison | A+B, focus_query=`skills workflow context` | Both source identities, summaries and relevant transcript evidence |
| Unsupported fact | A: 这段会话明确说了哪一家公司的季度收入为多少美元？ | No fabricated company or amount |

## Initial Cursor results

Inventory, metadata, summaries, bounded segments and scoped search passed. Timeline and default segment reads were empty. QA A omitted the key fact after the clipped preview; follow-up QA B returned no evidence. Comparison returned both summaries but no B focus hit. Unsupported-fact QA correctly abstained.

## Fixes

- Read transcript units directly with optional bounds and SQL limit; do not send an empty FTS query for timeline/default reads.
- Keep full transcript evidence in citation `matchText`, retaining the short `snippet` for display. Compose agent answers from full evidence.
- Infer source language from a sufficiently long, confidently recognized transcript sample; retain stored language when recognition is uncertain.
- When conjunction-based hybrid lexical recall has no hits, try a disjunction of terms within the same source filters; keep downstream reranking thresholds.

## Verification

Regression tests and post-fix Cursor results are recorded below.

### First post-fix Cursor pass

- Default A transcript read: 1 segment, 1.948–47.380s.
- A timeline: 1 nonempty bucket; preserves the full segment.
- A QA now explicitly explains descriptions being shortened, with an A timestamp citation.
- B follow-up now returns Markdown and bundled scripts, with a B timestamp citation.
- Unsupported revenue question still abstains.
- B comparison focus remained empty: live diagnostics showed one retrieved candidate and reranking in use, so further work continued on relevance scoring.

### Cursor boundary pass

All seven checks passed: a long-session 0–600s read with `limit=1` returned one segment; A with only `end=1` returned no overlap; zero bucket size, an unknown UUID and empty `session_ids` returned errors; clarification and finish controls returned their expected JSON signals.

Initial automated regression: 23 tests plus 33 existing QA/retrieval tests passed. The live model experiment uses `scripts/test-local-models.sh` so its Metal runtime is available.

### Reranker diagnosis

The 0.6B local reranker discarded the recalled B candidate. Adding the source title to its document context changed the actual installed model's scores:

| Query | Transcript only | Title + transcript |
| --- | ---: | ---: |
| skills workflow context | 0.00205 | 0.40733 |
| workflow | 0.01799 | 0.29421 |
| quarterly revenue | 0.000199 | 0.000080 |

The existing 0.25 primary / 0.15 minimum thresholds were retained. An opt-in local model regression (`VOXSTUDIO_RERANK_E2E=1` with `scripts/test-local-models.sh 'KnowledgeRerankLiveExperiment/topicQueryScoresWithTranscriptTitle'`) checks both positive queries and the unrelated negative query.


### Reranker post-fix Cursor pass

All five checks passed after the final signed rebuild and MCP reload:

- B `skills workflow context`: 1 transcript hit (returned search score 0.724), 1.200–36.884s.
- B `workflow`: 1 transcript hit (returned search score 0.679).
- Original A+B comparison: 2 sessions, each with 1 focus hit; 4 citations (both transcript and summary sources). Returned search scores are separate from the reranker probabilities above.
- B follow-up with history: “Skill files 通常以 Markdown 文件保存，也可以附带捆绑的脚本。” B timestamp citation preserved.
- A unsupported revenue question: no evidence; no fabricated company or amount.

Automated verification at this stage: **56 tests in 9 suites passed**, plus **1 opt-in installed-model regression passed**.

### Natural-language composite QA

Cursor independently chose `knowledge.ask` for a combined question. Its first call returned no citations and claimed that only the two session titles were available. Shortening the question worked, but that did not satisfy the original acceptance case. The exact failing query was retained for regression:

> Skill files 通常是什么文件、能附带什么、适合哪些工作流？为什么不应该给项目安装太多 skills？请用中文根据 Avoid Overloading Projects with Skills 和 Skill Files for Workflow Guidance 这两条会话回答，并给出引用。

Parameters: `answer_mode=normal`, `origin=local`, `session_ids=[A,B]`, no history.

Code inspection found that deterministic segment/timeline tools returned transcript bodies without the `citations` array consumed by the agent's evidence collector. Both now return full transcript citations. The agent also performs retrieval if it reaches answer composition with no evidence, including when the model stops before calling a tool.

A regression checks full, timestamped citations from both deterministic tools. The updated automated suite passed **57 tests in 9 suites**. The installed-model relevance regression above also passed. The app was built with `./scripts/bundle.sh debug --sign`, signature verification succeeded, and the final process start time was explicitly checked to be newer than the signed executable before reloading Cursor's MCP connection.

### Final acceptance (20:16 SGT)

The final app process started at 20:14:09, after the signed executable timestamp of 20:10:50. Cursor showed Connected with 58 tools and 2 resources. After this reload, the three actual calls all passed; their tool cards were expanded to inspect the arguments and raw results:

- The exact original composite query above, without history or a rewritten query, returned `status=completed`: Markdown prompts/instructions, bundled scripts, task-specific workflows/plugin guidance, and the context/description-shortening/selection explanation. It returned two citations: A 1.948–47.380s and B 1.200–36.884s.
- `session.get_segments(B, limit=1, origin=local)` without time bounds returned one segment and one citation, with B's source ID, 1.200–36.884s and complete `match_text` covering Markdown, scripts, workflow and plugin guidance.
- `session.get_timeline(A, bucket_seconds=10, origin=local)` returned one bucket and one citation, with A's source ID, 1.948–47.380s and complete `match_text`, including “shortening their descriptions”.

The end-to-end coverage includes all 11 knowledge MCP operations: QA, search, session listing, metadata, summary, segment reading/search, timeline, comparison, clarification and finish controls. These checks used local sessions; cloud-backed session retrieval was not exercised. The transcript language correction affects search planning and does not rewrite stored ASR metadata.
