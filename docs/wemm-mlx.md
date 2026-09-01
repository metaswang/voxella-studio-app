# WeMM Embedding on MLX

This integration runs Tencent WeMM-Embedding-2B locally on Apple Silicon with a 4-bit MLX checkpoint. The Swift path keeps the model's `<embedding>` hidden state, applies the supported Matryoshka dimensions, and supports text, image, and sampled video inputs.

## Convert the checkpoint

The conversion uses `mlx-vlm` and keeps the official WeMM configuration and tokenizer files:

```bash
PYTHON_BIN=/tmp/wemm-mlx-venv/bin/python \
HF_HUB_DISABLE_XET=1 \
./scripts/convert_wemm_to_mlx.sh \
  tencent/WeMM-Embedding-2B \
  "/Users/adamwang/Library/Application Support/PalmierPro/Models/WeMM-Embedding-2B-4bit" \
  4 64
```

`HF_HUB_DISABLE_XET=1` is useful when the Hugging Face Xet transfer path is unavailable. The converter refuses to overwrite an existing output directory.

## Run the Swift evaluation

```bash
swift run --traits BundledSpeech VoxStudio --wemm-eval \
  --model-dir "/Users/adamwang/Library/Application Support/PalmierPro/Models/WeMM-Embedding-2B-4bit" \
  --video "/Users/adamwang/Downloads/signal-2026-08-14-17-26-29-163.mp4" \
  --dimension 256 \
  --frames 4 \
  --segments 6
```

The CLI reports the full-video score and the best temporal segment for each query. The model does not consume audio; use visual or caption-visible concepts for queries.

Suggested queries for the supplied video:

1. `a person describing foot pain and going for treatment`
2. `someone says their forehead feels more relaxed`
3. `vision becoming brighter and clearer`
4. `an interview with an audience in a crowded hall`
5. `two women demonstrating how to rotate and gently pull the ears`
6. `a woman talking about treatment for herself and her children`
7. `a cooking demonstration` (negative control)

The Swift implementation lives in `Sources/PalmierPro/Search/Models/` and is compiled only with the existing `BundledSpeech` trait. The current app search UI is unchanged; `--wemm-eval` is an isolated evaluation entry point for validating model quality before replacing or augmenting the production index.

## Joint subtitle + video search

The optional `--srt` mode follows the official [Transformers inference example](https://github.com/Tencent/WeMM-Embedding/blob/main/examples/transformers_inference.py): a joint message contains the video item and its overlapping subtitle text, then WeMM produces one embedding from that multimodal input. It does not average two separately encoded vectors. The embedding is truncated to the requested Matryoshka dimension and L2-normalized, matching the example.

Each temporal segment collects SRT cues that overlap its time range. The full-video mixed embedding uses the complete SRT text. If a segment has no cue, the evaluation falls back to its video-only embedding.

```bash
swift run --traits BundledSpeech VoxStudio --wemm-eval \
  --model-dir "/Users/adamwang/Library/Application Support/PalmierPro/Models/WeMM-Embedding-2B-4bit" \
  --video "/Users/adamwang/Downloads/signal-2026-08-14-17-26-29-163.mp4" \
  --srt "/Users/adamwang/Downloads/手法治疗与居家应用体验_subtitle.srt" \
  --dimension 256 \
  --frames 4 \
  --segments 6 \
  --query "脚底很痛，走路站起来会痛" \
  --query "颈椎按了之后松了" \
  --query "眼前一亮，看得很远很亮" \
  --query "在家里给孩子先生和老人使用" \
  --query "转动和拉耳朵" \
  --query "治疗手法" \
  --query "做饭"
```

## Joint search observed on the supplied video and SRT

With dimension 256, 4 visual frames per segment, and 6 equal temporal segments:

| Query | Video-only top | Joint text+video top |
| --- | --- | --- |
| `脚底很痛，走路站起来会痛` | 0.00–8.71 s, 0.5278 | 0.00–8.71 s, 0.7071 |
| `颈椎按了之后松了` | 8.71–17.42 s, 0.6604 | 8.71–17.42 s, 0.8138 |
| `眼前一亮，看得很远很亮` | 17.42–26.13 s, 0.0115 | 26.13–34.83 s, 0.3453 |
| `在家里给孩子先生和老人使用` | 34.83–43.54 s, 0.4842 | 34.83–43.54 s, 0.5264 |
| `转动和拉耳朵` | 0.00–8.71 s, 0.4420 | 43.54–52.25 s, 0.5946 |
| `治疗手法` | 0.00–8.71 s, 0.4402 | 8.71–17.42 s, 0.5331 |
| `做饭` (negative control) | 0.00–8.71 s, -0.3850 | 8.71–17.42 s, -0.4915 |

The joint mode corrected the ear-action query and made the treatment-related queries more text-sensitive. The eye query spans the 17.42–34.83 s boundary because its subtitles run from 22.16 to 31.68 s; the joint top half is therefore the later part of the correct region. Scores are cosine similarities, not calibrated probabilities.

## Evaluation observed on the supplied video

With dimension 256, 4 visual frames per segment, and 6 equal temporal segments, the following queries ranked the expected regions first:

| Query | Top segment | Cosine |
| --- | --- | ---: |
| `a person describing foot pain and going for treatment` | 0.00–8.71 s | 0.5353 |
| `someone says their forehead feels more relaxed` | 17.42–26.13 s | 0.5394 |
| `vision becoming brighter and clearer` | 17.42–26.13 s | 0.4408 |
| `an interview with an audience in a crowded hall` | 34.83–43.54 s | 0.5934 |
| `two women demonstrating how to rotate and gently pull the ears` | 43.54–52.25 s | 0.5182 |

The more visual Chinese variants `脚痛和治疗`, `额头更放松`, `视力更明亮清晰`, `人群中的采访`, and `两名女性示范耳部动作` also ranked their expected regions first. The literal Chinese query `转动并轻拉耳朵` and the abstract query about treatment for “herself and her children” were weaker; prefer concrete visual nouns and actions. The cooking query acted as a low-scoring negative control, but scores are not calibrated probabilities.
