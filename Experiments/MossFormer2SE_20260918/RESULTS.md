# MossFormer2-SE FP16 实验结果（供 review）

时间：2026-09-18。独立进程 replay，未改应用降噪路径。

- 候选：`starkdmi/MossFormer2-SE-fp16`（48 kHz，MLX 社区 FP16）
- 基线：`mlx-community/DeepFilterNet-mlx` v3（与当前 speech-swift DeepFilterNet3 同采样率）
- 原始表：`out/results.json`，听音文件：`out/*.wav`
- 机器：本地 Apple Silicon，MLX Swift 0.31.5

## 听什么

优先对比：

1. `out/short__moss_full.wav` vs `out/short__dfn_offline.wav` vs 原始 `Vendor/mlx-audio-swift/Tests/media/noisy_audio.wav`
2. 长音频切块保真：`out/long__moss_full.wav` vs `out/long__moss_chunked_discard_4s_0.25.wav` vs `out/long__moss_chunked_ola_4s_0.50s.wav`
3. 不要把 short 上的 SI-SDR 当成独立质量分：`noisy_audio_target.wav` 是 mlx-audio-swift 的 **DeepFilterNet golden**，所以 DFN 会到 45–48 dB，MossFormer 约 15 dB。跨模型请看波形相关。

## 结论（建议替换参数）

**用 MossFormer2-SE FP16 替换 DeepFilterNet 是可行的。** 短/中片段上 `moss_full` 与 `dfn_offline` 相关 0.986 / 0.994；全部 MossFormer 输出有限，无 NaN。

推荐落地配方（不是云端 16 kHz GAN 的原值）：

| 时长 | 模式 | 参数 | 原因 |
| --- | --- | --- | --- |
| `< 20 s` | full | 一次前向 | 社区 `one_time_decode_length=20`；10 s 上最快（RTF 0.037）且与自身切块几乎一致 |
| `≥ 20 s` | chunked discard-edges | `chunk_seconds=4.0`，`chunk_overlap=0.25` | 社区 MLX 默认；30 s 上相对 full 相关 **0.9996**，82 s 上 **0.9755**，峰值显存锁定约 **356 MB** |

不要用：

- **ClearVoice overlap-add（turbo/fast/balanced）当短音频主路径**：10 s 上与 full 相关掉到 0.92，golden SI-SDR 从 15 dB 掉到 8 dB。
- **社区 segmented（decode_window=3/4/6）作为 20–60 s 主路径**：30 s 上 `w4` 相对 full 只有 0.9877，差过同长度的 chunked discard。
- **DeepFilterNet 全上下文处理长音频**：82 s 上 `dfn_offline` 有 **3.4% NaN**，峰值 2.15 GB。当前 app 的 `enhanceChunked` 避开了这条，替换后也不要回到 full DFN。

备选更省事：一律 `chunked discard 6s / 0.25`（峰值约 443 MB，长音频 splice 仍低）。只是短于 6 s 的片段会退化成单块 full。

## 数字摘要

### 短 10.0 s（有 DFN golden）

| Recipe | RTF | Peak MB | vs moss_full | vs DFN | SI-SDR dB | splice |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| moss_full | 0.037 | 626 | 1.000 | — | 14.94 | — |
| moss_chunked_discard_4s_0.25 | 0.056 | 356 | **0.9997** | — | 15.12 | 0.0024 |
| moss_chunked_discard_6s_0.25 | 0.046 | 433 | 1.000 | — | 14.95 | 0.0021 |
| moss_chunked_ola_4s_0.50s | 0.047 | 356 | 0.917 | — | 8.11 | 0.0006 |
| dfn_offline | **0.008** | 445 | 0.986 | 1.000 | 45.07* | — |
| dfn_stream_0.48s | 0.118 | 324 | 0.986 | 1.000 | 48.63* | — |

\*golden 是 DFN 自己。DFN 比 MossFormer 快约 4×（短音频），但长音频 full DFN 不稳定。

### 中 30.2 s

chunked discard 4s/6s 相对 full 都是 0.9996；OLA 3s 也到 0.9993。segmented_w4 只有 0.9877。moss_full 峰值 1.35 GB，chunked 318–443 MB。DFN offline 0.009 RTF、1.06 GB。

### 长 81.9 s

| Recipe | RTF | Peak MB | vs moss_full | finite |
| --- | ---: | ---: | ---: | ---: |
| moss_full | 0.045 | 1882 | 1.000 | 1.000 |
| moss_chunked_discard_4s_0.25 | 0.059 | **356** | **0.9755** | 1.000 |
| moss_chunked_discard_6s_0.25 | 0.057 | 443 | 0.9753 | 1.000 |
| moss_chunked_ola_4s_0.50s | 0.053 | 356 | 0.9606 | 1.000 |
| moss_segmented_w4 | 0.063 | 356 | 0.9717 | 1.000 |
| dfn_offline | 0.011 | 2151 | — | **0.966** |
| dfn_stream_0.48s | 0.130 | 1572 | 0.9703 | 1.000 |

长音频上社区 discard-edges 比云端 OLA 更接近 full；OLA 稍快一点（RTF 0.053 vs 0.059），但相关更低。

## 参数来源对照

云端 `MossFormerGAN_SE_16K`（16 kHz）speed profile 只作为窗口尺度参考，不能当 48 kHz FP16 的默认值：

| 来源 | chunk | overlap | 重拼 |
| --- | --- | --- | --- |
| MLX 社区 MossFormer2_SE_48K | 4.0 s | 0.25 **比例** | discard-edges |
| 云端 turbo | 3.0 s | 0.25 **秒** | overlap-add |
| 云端 fast | 4.0 s | 0.50 秒 | overlap-add |
| 云端 balanced | 6.0 s | 1.00 秒 | overlap-add |

本实验把三档云端尺寸都在 48 kHz 上跑过。质量赢家是社区 discard 4s/0.25，不是 OLA。

## 下一步（未做）

1. 已在 `AudioEnhancer` / `ListenTrackEnhancer` / `VoiceReferenceCapturePipeline` 把 `SpeechEnhancer` 换成 `MossFormer2SEModel`，并按上面的 20 s 阈值切换 full / chunked discard。
2. 当前仍保留默认 wet mix 0.6；后续如有真实录音反馈，再单独重新标定 wet mix。
3. 用真实会议/现场录音听感确认，本轮夹具是 mlx-audio 测试媒体拼接，不是用户会话。
4. 不要在这次实验里改生产代码，等听感确认。
