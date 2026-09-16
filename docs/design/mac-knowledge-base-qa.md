# Mac Knowledge Base QA

日期：2026-09-15
范围：`voxella-studio-app`

## 行为契约

Knowledge Base 的 scope 为 all、单 session 或已选 sessions。每个 scope 有独立 conversation storage key；scope、会话或账户切换会取消活跃回答，并拒绝过期 completion。citation 使用稳定的 anchor chunk ID、session ID 与时间范围；点击后定位原始 transcript，而不是 metadata 或邻居。

发送前的状态机：

1. 检查本地 KB entitlement；失败时显示本地访问说明。
2. 检查回答模型：Hosted 登录态或有效 BYOK chat route。没有任一项时显示“登录或配置 BYOK”，不写入消息也不开始模型下载/检索。
3. Graph 开启时，BYOK 还必须有 Graph extraction 与 Graph query 路由；无效配置在发送前显示 AI Settings 操作。
4. WeMM 与 Qwen reranker 未安装时，用户确认后按现有安装计划下载；取消和失败不会创建 conversation message。

Hosted 已知额度耗尽也是显式状态。它在回答前阻止新请求；若 `402 insufficient_credits` 发生在检索完成之后，保留引用和摘录结果，并持久化 Account/AI Settings 恢复操作。

## 实现边界

`KnowledgeBaseController` 管理 UI state、conversation identity、安装准备与 event 持久化；`KnowledgeQAService` 执行检索、rerank、context 与回答；SwiftUI 只渲染状态并转发操作。UI 与服务不得分别实现 scope、权限、时间或引用规则。

`SessionIndexCoordinator` 负责 lexical、embedding 与可选 graph ingestion 队列。SQLite、模型推理和 provider 请求不在 MainActor 同步执行；任务使用共享 MLX gate、检查取消，并在 commit 前验证 source generation。

## RAG 配置

| 阶段 | 限制 |
| --- | --- |
| Hybrid recall | 30 transcript candidates |
| Graph recall | 20 chunks，默认关闭 |
| 融合 | unit ID 去重后最多 40 |
| Qwen rerank | 原始 chunk only；0.25 → 0.175 → 0.15 Top-1 |
| MMR | 最多 8，λ = 0.7 |
| metadata | 每 session 360 字、全局 1,500 字 |
| 短 anchor 扩展 | `<350` 字时前后邻居；合并块 850 字 |
| LLM context | 去重后 10,000 字 |

Graph schema 位于 `Search/index.sqlite`，由 entity、alias、relation、relation evidence、entity-chunk link 和 graph source state 组成。结构化抽取只接受当前 6-chunk 批次的 ID 和受控 schema；source 变更/删除以事务替换并清理孤儿，保证旧 evidence 不可召回。

检索 query 与回答约束分离：结构化 planner 固定使用 `gpt-5-nano` 与中等思考强度，输出 `search_query` 和 `answer_constraints`。单 session 或语言一致的选中 sessions 优先传入索引中的 raw transcript language，使 `search_query` 与 transcript 原文语言/脚本一致；混合语言、全库或缺少元数据时才保留问题语言。只有 `search_query` 进入 Hybrid/Graph/reranker；“3 句话”、语言和格式要求只进入回答 prompt。planner 不回答问题，也不复制 transcript 内容。planner 失败时软降级为原问题检索并记录诊断。实验验证关闭 fallback 以固定模型；生产请求仍遵循 resilience policy。

Prompt 回归矩阵固定模型、reasoning、temperature、token 上限和 session snapshot，仅切换 query planning 与 prompt 版本：B0（原问题直检索）、P1（JSON 分离）、P2（P1 + evidence-only/语言/引用约束）、P3（P2 + 先证据归纳再输出）。验收记录召回、空证据、精确句数、语言一致性、引用质量、延迟与 token/cost；不得用模型切换解释 prompt 结果。

完整数据流、模型 revision、降级与额度语义见 [`knowledge-base-rag-flow.zh-CN.md`](./knowledge-base-rag-flow.zh-CN.md)。

## 手工验收

- 纯 Hosted、完整 BYOK、未登录无 BYOK、BYOK 路由缺失。
- Graph 关闭、启用后回填、登出后暂停，以及 source 更新后旧 evidence 不可检索。
- Hosted 402 后保留引用摘录、显示两个恢复操作；429/超时不显示额度耗尽。
- 短 anchor 前后文、中文、英文与第三语言提问。
- scope/账户/设置切换和 Escape 取消期间不写入过期消息。
