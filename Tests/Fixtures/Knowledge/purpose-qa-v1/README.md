# Purpose QA v1

这是可公开、可回放的受控资料集，绑定原 `agentic-qa-v2-cases.jsonl` 的 60 个问题形态。9 个授权来源覆盖 local/cloud、原会话/独立配音、仅字幕、text-only、缺正文、同名来源、过期摘要及不同字幕/翻译材料。另保留一个其他账户来源用于授权反例。

`gold.jsonl` 的参考答案和证据由实现者按完整资料逐题判断，标记 `annotation_origin=model_assisted_source_review`。它们不是人工独立标注，也不是用户真实资料的标准答案。共有 60 个参考答案、98 个精确原文证据范围；无正文问题保留明确的覆盖限制。

字符范围为 UTF-16、左闭右开，匹配 Swift/NSString 定位；证据保留来源 alias、材料类型及原文摘录。固定日期为 2026-10-03、Asia/Singapore。媒体时长总计 11,122 秒、2 个未知；字幕/Transcript 结束时间不能代替媒体时长。

普通测试逐条验证 `fetch`、`find_text`、材料可读性、完整目录和聚合事实。实际模型测试使用本地安装的 WeMM 256 维与 Qwen3 reranker，临时 SQLite 索引，比较当前 Native、B0 与新 MCP 的检索路径。仅带 canonical 正文证据的问题参加排序评测；它不测回答模型、skills 消融或素材定位质量。B0 与 Native 共用本次改造的检索层，不是冻结旧版基线。

```bash
swift test --disable-sandbox --traits BundledSpeech --no-parallel --filter KnowledgePurposeQuality
VOXELLA_RUN_LOCAL_FIXTURES=1 RUN_KNOWLEDGE_PURPOSE_EVAL=1 \
  swift test --disable-sandbox --traits BundledSpeech --no-parallel --filter KnowledgePurposeQuality
```

实际推理需本机模型和测试 executable 同目录可加载的 `mlx.metallib`。默认结果写入 `/private/tmp/voxstudio-purpose-qa-eval.json`，可用 `KNOWLEDGE_PURPOSE_EVAL_OUTPUT` 覆盖。报告保留每题 Recall@8、nDCG@8、scope、延迟和 reranker 降级；Recall 按证据 span，nDCG 按相关正文 passage，避免同一 passage 的多条摘录重复计分。

另有 3 个英文/跨语言探针，分别测英文产品/版本条件、中文查英文材料、英文查中文决定。它们与原 60 题分别汇总；样本规模不能支持广泛语言质量结论。实际模型评测应串行运行，避免其他测试加载模型影响严格内存断言。
