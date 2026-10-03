# 知识库 Agentic QA v2 实施记录

2026-10-03：正文选择、QA/素材路由、分通道索引和 Work/Codex 证据入口已按 [用途路由实施说明](knowledge-qa-purpose-routing.zh-CN.md) 更新。以下记录保留此前阶段背景；关联配音静默 fallback、未经标定的 reranker 硬过滤及强制 skill 流程以新说明为准。

本分支将 macOS 正常问答路径切换为共享证据工作区及供应商原生流式循环；旧 RAG 仅作为完整的开发对照路径。此记录描述代码能力，不宣称真实资料质量、线上延迟或费用已达标。

| 阶段 | 本仓库实现 | 验证边界 |
| --- | --- | --- |
| M0 | 首轮授权卡片；媒体总长/口播/转录范围及 provenance；原生数组和嵌套 schema；逐调用完整 observation；首轮和后续工具注册；按需 skill；真实 delta；去除正常路径 planner/selector/composer 及下载门禁 | 注入 native event 的契约回放及既有 Responses/Messages/兼容端传输测试；真实 Hosted 网关须联调 |
| M1 | 原始短转录直读；长来源摘要/时间结构分页；来源搜索；时间/说话人过滤及连续原文读取；hybrid/graph RRF；最多 32 个结果及相关候选来源覆盖；图显式启用 | 精确位置、分页、原文、未知/未完成状态的确定性检查；语义效果须绑定真实标注资料 |
| M2 | 来源 × 维度分析视图；未检查/没找到/明确不存在/冲突分别记录；完整目录 count/sum/group/sort；最多 4 个 I/O 分支、2 个单层深读 job；共同请求/时间/上下文预算；补充条件取消旧 run；账户 epoch/来源版本缓存 | 多来源未知行、跨页统计、分支失败、worker job、预算、取消与迟到事件测试；worker 语义判断仍须人工复核 |
| M3 | 开发消融开关 B0–B4、60 个真实形态问题模板和结果统计脚本 | 尚未取得真实 provider 的同模型/同预算质量及成本对照；来源地图、contextual retrieval、持久派生缓存、async/steering 不默认启用 |

## 可见性、版本与引用

所有读取以当前 scope、来源过滤和账户快照为边界。检索仍沿用索引的 cloud owner 过滤。账户会话 epoch 改变、资料删除/修改/重转录、媒体文件版本改变，使旧 run 或缓存失效。重用内容只含有来源的工具观察及派生覆盖视图；供应商私有 reasoning 不进入跨轮缓存。

工具响应及 UI 使用同一 citation_number 映射，原始证据具有稳定 evidence_id。摘要标记为生成摘要；原文引用保留原子 segment 或原索引 chunk 的时间。Worker 返回发现、已有证据 ID、统一引用编号的有界索引及关联原文 payload 句柄。主 agent 可重读完整 observation 后综合；索引明确标注节选和列表是否完整。来源之外的 ID 和重读 payload 句柄会被拒绝；覆盖以实际工具读取记录替换 worker 自报的完整性。

目录列表、摘要、原文与时间结构均显式返回 complete/next_cursor。complete 指当前过滤后的可用资料读完，不能证明全媒体已经转录，也不能证明语义上不存在某事件。旧索引连续读取直接查询原文 units，不依赖空 FTS 搜索。

媒体时长列是 additive migration。旧 duration_sec 保留 legacy 语义，新媒体字段在实际元数据读取时补齐，不触及 vectors 或 ingest generation。明确按 duration 排序的目录聚合会以最多四个并发读取探测完整筛选集合的本地媒体；其余目录操作使用已缓存探测值或来源明确的 hint。不可读媒体的总长算 unknown，不用转录终点填补。

## 开发对照与预算

Debug 构建中通过 `VOXELLA_KB_QA_VARIANT` 选择完整对照路径或工具能力：B0=legacy，B1=native 基础，B2=自适应读取/来源发现，B3=覆盖表/聚合，B4=有限 worker（默认）。关闭能力不回退文本 JSON 协议。Release 使用完整能力，是否调用 worker 仍由主 agent 决定。这些开关比较当前分支的工具能力；共用已重构的 retrieval/读取实现，不能冒充冻结的旧版基线。严格 B0 基线须单独构建重构前 `f2d9f81b`，并记录其源码 revision。

同一问答主 agent 与 worker 共用最多 16 次原生模型回合、180 秒运行时间、240,000 的保守上下文/输出预留单位。每个请求输出 cap 为 4,096；主循环最多 8 回合，worker 最多 4 回合、深度 1。BYOK 初次路由失败仍允许既有 fallback/retry；这些传输尝试及 Hosted 内部 fallback 的精确 token/费用由实际 provider 和网关计量，目前不是硬费用上限。不能将客户端预留量冒充账单。

`Tests/Fixtures/Knowledge/agentic-qa-v2-cases.jsonl` 提供 60 个问题和验收 rubric，涵盖媒体尾部静音、部分转录、缺摘要、同名来源、跨账户与来源修改。模板必须先绑定具体可回放资料及人工 ground truth，然后各变体使用相同模型、预算、来源集合。`scripts/summarize-knowledge-qa-eval.py` 接收经复核的结果 JSONL，保留未测指标，不制造评测成绩。

## Hosted 网关核对

已只读核对相邻 API 仓库的 `app/routers/llm.py`：当前 `/api/v1/llm/responses` 过滤客户端选模型等路由字段，透传其余 Responses payload 并转发 SSE；模型及 fallback 属于服务端默认配置。当前未声明 KB 的版本化 capabilities，也未按本次 `knowledgeQA` header 分流。

客户端新增 KB use-case header、沿用服务端默认模型及原有 401/402 请求语义，并为各模型回合/worker 使用独立请求 ID。本 PR 不修改相邻 API 仓库或 commons 的 vendored 副本。服务端 KB policy/capabilities、断连取消和计费幂等的真实链路验收需单独的 API/commons 变更；async/steering 保持未声明。BYOK run 固定原生 continuation 的模型/协议，避免跨供应商回放私有状态。

## 验证

知识库、索引、检索及 Agent provider/transport 的契约测试；随后按照 AGENTS.md 执行 `./scripts/bundle.sh debug --sign` 并打开本分支的 VoxStudio.app。具体测试数及构建结果在 PR 的验证记录中给出。带 `BundledSpeech,SparkleUpdates` traits 的 `swift test` 另行尝试时，受到既有 `AppUpdaterTests.swift:33` 构造器不兼容阻断；标准测试配置和签名应用构建分别验证。


评测结果输入示例（仅表示格式，不是成绩）：

```json
{"case_id":"bound-case-id","variant":"B2","model":"same-provider-model","budget_id":"shared-budget-profile","metrics":{"citation_precision":null,"coverage":null,"false_refusal":null,"source_omissions":null,"first_grounded_answer_ms":null,"cost_usd":null}}
```

执行 `python3 scripts/summarize-knowledge-qa-eval.py results.jsonl`。缺失/null 指标保留为未测；相邻变体的差值只配对相同 case/model/budget，不将不同来源或模型的总体平均当作收益。semantic_count 尚无通用转录事件计数器；目录聚合只用于明确的来源属性，语义事件穷举必须读取全部相关来源并保留覆盖限制。


## 本次最终验证记录

- 与最新 `312d576f` main（PR #29 本地会议录制、PR #30 启动导航修复）集成后的相关回归：205 tests / 43 suites 通过，覆盖知识库/provider/索引、来源版本、输出耗尽、worker 证据编号与原文重读，以及导航、媒体语言/播放和本地会议录制。
- `./scripts/bundle.sh debug --sign` 成功，codesign 验证 valid on disk / designated requirement；签名应用已启动并检查知识库入口、元数据范围计数和提示。
- 最终分支采用 main PR #30 的窗口初始化和导航监听修复；这些文件在最终 PR 中无额外改动。
- BYOK OpenAI Responses 真实单来源元数据问答通过：总长 1000 秒、最后口播结束 999.912 秒分别给出并带一个来源引用；日志记录一次 native request、未执行检索工具。单次 smoke 不构成质量/延迟/费用对照，精确首个 delta 和 token/费用未测。
- 真实摘要读取请求未执行：自动审批因缺少将本地摘要/转录发往 OpenAI 的明确授权拒绝发送。完整摘要 observation 和原生续接仅完成契约回放验证。

## PR #31 审查修复

- Sources 按来源 ID 分组和计数。同一来源的元数据、说话人及转录证据只显示一行，多个原文时间点保留在该行的跳转菜单；底层 citation_number 映射不变，同名但不同 ID 的来源仍分别显示。
- ASR segments 为空时，读取现有原始字幕 cues 或配音内容，并提供对应 provenance 与媒体位置。没有可读原文的范围保留 unavailable，不将空结果标为完整阅读；配音转录和字幕变化进入来源版本。
- 聚合证据 ID 包含筛选条件、分组及排序页的完整结果，防止不同统计共用引用、保存为第一份统计结果。
- Hybrid/graph 融合结果保留统一的 RRF 分数，重排器不可用时 MMR 不再按不可比较的通道原始分数覆盖融合排序。
- 原生流式回答失败时保留已经发布的文字，单独显示错误并结束当前回合。
- 审查后知识库/provider/索引及相邻功能回归：213 tests / 43 suites 通过。新增测试包含上述故障复现、引用分组与时间点保留、字幕读取、聚合证据身份、检索回退和配音缓存版本。
- 审查修复版本执行 `./scripts/bundle.sh debug --sign` 成功并启动；在原 Donald Hoffman 对话中确认 Sources 从两条重复项变为一个来源。说话人计数按用户确认保留，未修改识别或计数逻辑。

## 提问后无响应与内存增长

- 无响应现场的主线程采样停留在 SwiftUI `GraphHost.flushTransactions`、`LazySubviewPlacements` 和 `LazyStack.measureEstimates`，包含聊天列表的滚动几何回调。CPU 接近 100%；两次采集之间约 33 秒，physical footprint 从 2.1 GB 增至 2.4 GB，峰值 5.0 GB，主要增长位于 malloc heap。该回合日志只有 chat started，没有后续模型请求；本地搜索模型已卸载。
- 消除消息列表的懒高度估计与持续底部锚定：消息使用实际高度的 VStack，滚动通过 ScrollViewReader 在布局后合并更新，一次性定位明确的末尾标记。保留用户向上阅读时的跟随控制、取消和会话切换检查。最多八行的 Sources 也改为普通 VStack，避免嵌套懒布局。
- 新增持续增长的多轮聊天窗口回归。原有循环每轮重置历史，本次保留 24 轮的消息，并经过原生 run-loop observer 验证布局、流式更新、等待和内存；可用 `VOXSTUDIO_KB_STRESS_SECONDS` 延长等待，用 `VOXSTUDIO_KB_LAYOUT_FIXTURE` 在本地回放保存的对话。回放使用受控响应，不发送 provider 请求、不修改原对话存储。保存的对话回放未稳定复现原版挂起，故现场采样与回放验收分别记录，不将回放通过当作确定性的前后复现证明。
- 修复后的原对话回放通过 24 轮连续提问及 120 秒等待检查，主线程心跳和各次窗口布局均低于 500 ms。预热后 footprint 基线及峰值均为 190 MB，等待期间为 167–170 MB；等待时采样的主线程以 run-loop 等待为主，进程 CPU 约 0.8%。这些数字属于本地受控窗口回放，不代表真实模型问答延迟或费用。
- 修复后知识库、provider、索引及相邻导航/播放/录制回归：214 tests / 43 suites 通过，包含长回答底部可见性、输入换行/缩放、取消与晚到事件、持续多轮消息和内存检查。
- `./scripts/bundle.sh debug --sign` 成功且签名验证通过，已启动新版本。原 Rethinking Skills 对话完整加载，输入框编辑/发送按钮启用及上下滚动响应正常；没有重新发送原问题到云模型。
