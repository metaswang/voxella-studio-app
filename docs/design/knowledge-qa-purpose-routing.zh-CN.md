# 知识库 QA 按用途选择证据

当前完整调用链、工具边界与预算见 [知识库问答流程（2026-10-04 核对）](knowledge-base-rag-flow.zh-CN.md)。

本次实现保留字幕、mediaClip、text/video/mixed 向量和独立帧索引。QA 默认读取权威 Transcript，缺失时使用同来源当前字幕 fallback；素材和通用搜索继续调用原来的媒体路径。此设计取代删除字幕或素材索引的方案。

## 查询与材料

`KnowledgeTranscriptMaterial` 统一 App、索引、MCP、读取、查词、时间线的正文选择与字符映射。原会话只使用原 Transcript/字幕；独立配音使用自己的当前投影和 revision。非空 text-only Transcript 可读，部分 Transcript 不混字幕补尾；旧 words 不得覆盖当前编辑文本。

`SearchService.hybridSearch` 严格遵守 kinds，KNN 的授权、scope、kind、canonical generation 在候选前筛选。`KnowledgeRetrievalService` 的无命中通用 clip 回退已移除。Graph 默认关闭，显式启用后仍回当前正文核验。新 MCP 素材候选先筛选当前 media manifest，过期素材 locator 拒绝读取；通用素材搜索保持自身用途。素材默认按 clip ID 融合 text/video/mixed 排名并保留命中模态；有媒体路径的纯文本 embedding 分支继续生成。独立帧索引和预览管线保持原有实现。

新只读 profile `/knowledge/mcp` 提供 search/fetch/list_sources/aggregate/find_text/methods，支持显式字幕、翻译和 media_clips。旧 `/mcp`、knowledge.ask 及媒体工具保留。两个 profile 的 factory、session、无状态回退隔离。返回原材料 locator、generation、provenance、revision、原文范围和可信时间；素材摘录不会改写成 Transcript 原话。

## 长段与时间

正文窗口复用 TranscriptSegmenter 的句界、speaker 变化及 45–60 秒软窗选择，短尾合并最多约 66 秒。目标 512 tokens、最大 768、独立前文 context 最多 64；模型文本输入包括模板及 query 最多 1,024 tokens。加载当前 WeMM/reranker 的实际 tokenizer 校验；模型文件缺失时，当前 ByteLevel tokenizer 可用 NFC UTF-8 字节数作保守上界，不采用字符数除以四。

长同 label 的展示分组继续保留，但索引可在句界或 Unicode 安全边界继续拆分。子块全文无丢失，保存 UTF-16 原文范围、父 segment/cue 和真实时间映射。可信 words 只细化定位，不重建权威文字；没有细时间时使用父范围，完全无时间则未知。原生分页的 segment cursor 保持兼容；新 MCP 使用 tokenizer 限定 read units 和版本化 cursor。find_text 区分 occurrence 与匹配 read unit，历史引用不把旧 chunkIndex 当新行号。

分块在独立 CPU task 中计算，共享 tokenizer actor 可继续服务其他读取；加载合并、缓存有界且支持取消。已匹配 manifest 的来源直接跳过分块；时间映射按原文范围顺序扫描。安全前缀先缩小搜索区间，再用实际 tokenizer 求边界，并再次校验最终句界，避免 BPE 合并造成的非单调 token 数突破硬上限。

超长 reranker 候选按全文拆窗取相关性最高分；超长 query 显式降级。仅取最终 yes/no logits，取消未经本域标定的分数硬过滤，保留 5 秒超时和 RRF/MMR 回退。分数只是排序信号；MMR 将相关性按当前 query 最大值缩放到与相似度同一范围，避免小分数下多样性盖过相关性。

## 通道迁移与 App

`index_lane_state` 分开记录 knowledge/media manifest 和词法、embedding 就绪状态。正文变化只替换 transcript units、FTS/向量及图证据；media manifest 变化才替换 clips 与媒体向量。强制 QA 重建仍保留未变化媒体 lane；真正删除 session 才统一删除。首次迁移校验旧素材窗口、文本、cue/speaker、路径及文件时间，匹配时接管旧 media lane 并保留向量。逐模态补齐仅推理缺失通道：已有 video/mixed 的 clip 只补 text。无字幕视频缺少时长时读取实际媒体时长生成视频窗口。字幕独立编辑不使可用 Transcript 正文失效，字幕 fallback 编辑则重建正文；配音修改当前 Transcript/revision 会使对应 lane 失效。

正文替换和 manifest 更新在 SQLite 事务中原子切换，后台可 pause/resume，取消后从当前资料重新 reconcile。generation 筛选阻止不匹配旧材料进入 QA。缓存 namespace 包含资料版本、reader/chunker/tokenizer 与模型 revision。图证据 freshness 使用正文 lane manifest，不因单独摘要编辑重建。

App Agent/B0、provider、预算、计费、流式、取消和追问接口保留。内置 skills 改为薄的材料/引用/覆盖指导，去掉每题强制 metadata-first、固定命中数和强制 App 回答流程。新 plugin 同样不替高级宿主模型规定推理步骤；methods 按需读取。全文、时间线和历史引用使用共享原文映射。UI 显示真实索引状态、字幕 fallback 和历史材料变更提示。

## 检索质量与验证边界

CJK 分词补充双字词元，英文保留词级分词，自然语言用 OR 排序召回；字面短语、计数与引用通过 find_text/fetch 核验。英文也受益于范围预过滤和长段全文覆盖。标题/摘要以 session card 和正文 kind 区分，默认 QA 不将摘要当原话证据。默认每路 30、融合 40、返回 8，最多 32。

受控 60 题已绑定模型判定参考答案和 98 个精确证据范围，详情见 [fixture](../../Tests/Fixtures/Knowledge/purpose-qa-v1/README.md)。质量评测分别记录检索排序与答案质量，不把单元测试、受控语料的检索 Recall 或同一实现的 B0 当成真实用户回答正确率或旧版收益。现有答案评测/能力开关可继续用于同 provider、资料和预算的实验；只有实际跑完宿主模型回答与四种 skill 条件才可声称 skill 消融收益。
