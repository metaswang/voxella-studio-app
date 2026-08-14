# Qwen3-Embedding-0.6B Matryoshka retrieval 实验

## 结论

`512d` 是本 app 的默认索引维度：相对 `1024d`，五个官方 MTEB 子集的宏平均
NDCG@10 从 **0.3995** 降至 **0.3879**（**-1.16 个点**），而每条向量从 4,096 B
降至 2,048 B。`256d` 虽可再节省一半存储，但宏平均 NDCG@10 为 **0.3766**
（相对 1024d **-2.29 个点**），在跨语言和英文集上的损失更明显；不建议作为默认。

中文单语任务对降维最稳健（512d 仅 -0.38 点），但中英混合 query 是明显例外：512d
损失 -5.45 点，256d 损失 -10.28 点。因此，若产品的主路径是中英文混合 query，保留
`1024d`；否则采用 `512d`，并将 1024d 作为可选高质量索引档。

## 执行配置

| 项目 | 值 |
|---|---|
| 模型 | `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` |
| 运行时 | Apple `mlx-swift-lm` 3.31.4 / `MLXEmbedders` |
| 设备 | Apple Silicon Mac（M5、32 GB unified memory） |
| 最大 token 数 | 2,048 |
| embedding batch size | 32 |
| 数据集抽样 seed | `20260811` |
| 运行完成时间 | 2026-08-11 03:16:11 UTC |
| 文档 / 查询计数 | 22,078 / 1,120（按任务计，含 derived mixed-query） |

查询使用模型卡建议的检索 instruction 信封：
`Instruct: {task-specific instruction}\nQuery: {query}`；例如中文组为
`Given a Chinese search query, retrieve web passages that answer the question`，跨语言组为
`Given a Chinese question, retrieve English passages that answer the question`。文档不加 query
instruction。

每一个输入只执行一次 1024 维 pooling forward：

```text
e1024 = L2-normalize(pooled embedding)
e512  = L2-normalize(e1024[0..<512])
e256  = L2-normalize(e1024[0..<256])
```

因此三列结果不混入额外模型调用、不同量化模型或随机采样的影响。

## 数据覆盖

所有官方集合均为固定、可重建的 retrieval **子集**，不是可直接与完整 MTEB
leaderboard 对比的结果。每个选中的 query 保留全部已判定正例，再以稳定 hash 采样负例。

| 覆盖 | 任务 | 查询 | 文档 | 备注 |
|---|---:|---:|---:|---|
| 中文 | T2Retrieval-zh | 200 | 8,000 | 官方 MTEB subset |
| 英文 | NFCorpus-en | 200 | 3,000 | 官方 MTEB subset |
| 多语 | MultilingualNanoNFCorpus (en/ja/ko) | 450 | 4,881 | 每种语言 150 query |
| 跨语言 | MLQA zho→eng | 200 | 3,000 | 中文 query、英文文档 |
| 长文本 | LEMBQMSumRetrieval-en | 120 | 197 | QMSum 会议记录 |
| 中英 mixed | MLQA zho→eng mixed query | 200 | 3,000 | 派生集，非官方 MTEB 分数 |

mixed query 将同一问题的中文与英文表述合并为一个 query，检索相同的英文语料及 qrels。

## NDCG@10（主指标）

数值为 0–1；括号是相对 1024d 的绝对变化（百分点）。

| 任务 | 1024d | 512d | 256d |
|---|---:|---:|---:|
| T2Retrieval-zh | 0.5577 | 0.5539 (-0.38) | 0.5479 (-0.98) |
| NFCorpus-en | 0.3707 | 0.3537 (-1.69) | 0.3392 (-3.15) |
| MultilingualNanoNFCorpus | 0.2742 | 0.2618 (-1.23) | 0.2525 (-2.16) |
| MLQA zho→eng | 0.6505 | 0.6321 (-1.84) | 0.6143 (-3.62) |
| LEMBQMSumRetrieval-en | 0.1444 | 0.1377 (-0.67) | 0.1290 (-1.53) |
| **官方五集宏平均** | **0.3995** | **0.3879 (-1.16)** | **0.3766 (-2.29)** |
| MLQA mixed query（派生） | 0.3562 | 0.3016 (-5.45) | 0.2534 (-10.28) |

官方五集宏平均的辅助指标如下：

| 指标 | 1024d | 512d | 256d |
|---|---:|---:|---:|
| Recall@10 | 0.3499 | 0.3390 | 0.3316 |
| MRR@10 | 0.5184 | 0.5146 | 0.4984 |

## 解释与产品取舍

1. **512d 是稳定的存储/质量折中。** 它将 float32 原始向量存储减半，且所有五个官方
   任务的 NDCG@10 损失都不超过 1.84 点。中文单语保真度尤其高。
2. **256d 只适合强存储约束。** 英文、跨语言和多语均呈现 2–4 点的 NDCG@10 损失；混合
   query 的损失更大。这不是推荐的默认产品质量档。
3. **mixed query 应单独配置。** 其结果来自派生集，不可作为 MTEB 分数宣传，但足以说明
   query 语言混合会放大低维前缀的信息损失。产品若允许用户混用中英，应默认 1024d，或在
   保存 1024d 的情况下以 512d 作为快速候选、1024d 复排。
4. **长文本结论受截断限制。** QMSum 有 196/197 文档在 2,048 token 上限处截断，中文
   T2 也有 403/8,000 文档截断。这里测量的是“首 2,048 token”的 retrieval，而不是完整
   长文档检索。导入长转录稿时应采用分块 embedding 与文档级融合，而不是提高单段上限。
5. **本机批量性能需要另行设计。** 此运行的 embedding 阶段累计 3,803.7 秒（约 63.4 分钟），
   32×2,048 的批次峰值约 24 GB unified memory。它用于质量实验而非产品吞吐基准。app 的
   后台索引器应按 token 长度分桶、设置内存预算、可取消，并避免在 main actor 上执行。

## app 接入建议

- 以一个后台、串行的 embedding/index service 持有 `EmbedderModelContainer`；沿用现有 MLX
  推理互斥约束，不在 SwiftUI 或 main actor 中加载模型、tokenize、写文件或构建索引。
- 对每条 source 文本只保留一次 canonical 1024d 输出；索引写入时派生并归一化目标前缀。
  若只持久化 512d，后续切换到 1024d 需要重嵌入；若持久化 1024d，可无 forward 地重建
  512d/256d 索引，但磁盘占用为 2×/4×。
- 默认存储 `512d`（2 KiB/条 float32）；对 mixed-query 或高质量模式存储 `1024d`（4 KiB/条）。
  `256d` 为 1 KiB/条，但只应作为明确的低存储模式。
- 将模型 ID、量化变体、instruction、最大 token 数、chunk 策略与 embedding dimension 写入
  索引 metadata。任何这些值改变时使索引失效并后台重建。
- 长转录稿以固定 token chunk（带小重叠）写多个向量；检索时做 chunk-to-document 的 max 或
  top-k fusion。不要把完整项目脚本直接截断为一个向量。

## 可复现命令与验证

```bash
cd Experiments/Qwen3EmbeddingMTEB
python3 prepare_mteb_subset.py --output /private/tmp/qwen3-mteb-suite
swift build
./.build/arm64-apple-macosx/debug/Qwen3EmbeddingMTEB \
  /private/tmp/qwen3-mteb-suite /private/tmp/qwen3-mteb-results.json \
  --max-tokens 2048 --batch-size 32
```

已完成：`python -m py_compile prepare_mteb_subset.py`、该独立实验包的 `swift build`、以及上面的
完整本机评测。主 app 未改动，因此未运行主 app build 或 UI 验证。

原始结果：`/private/tmp/qwen3-mteb-results.json`。
