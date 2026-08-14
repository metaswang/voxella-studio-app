# Qwen3-Embedding MTEB retrieval subset

This experiment runs `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` through
Apple's `mlx-swift-lm` `MLXEmbedders` implementation. It evaluates one 1024-d
forward embedding per input, then derives the 512-d and 256-d vectors by
prefix truncation and L2 normalization.

Prepare a local suite with the companion exporter:

```bash
python3 prepare_mteb_subset.py --output /private/tmp/qwen3-mteb-suite
```

Run it from this directory:

```bash
swift run Qwen3EmbeddingMTEB /private/tmp/qwen3-mteb-suite /private/tmp/qwen3-mteb-results.json
```

The prepared suite uses fixed seed `20260811`. It is deliberately a retrieval
subset, not an MTEB leaderboard submission: every selected query keeps every
judged relevant document, then a deterministic hash sample fills its corpus to
the configured size.
