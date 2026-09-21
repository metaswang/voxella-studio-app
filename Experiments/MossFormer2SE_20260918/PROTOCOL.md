# MossFormer2-SE FP16 local denoise parameter experiment

Status: replay complete and app migration implemented. See RESULTS.md.

## Goal

Find and validate a local MossFormer2-SE FP16 inference recipe for replacing the current on-device DeepFilterNet3 denoise path. The app now uses the validated recipe while this document retains the quality, speed, and memory evidence.

## Models

| Role | Model | Sample rate | Notes |
| --- | --- | --- | --- |
| Current local baseline | `mlx-community/DeepFilterNet-mlx` v3 | 48 kHz | Same rate as the app's speech-swift DeepFilterNet3 bake |
| Replacement candidate | `starkdmi/MossFormer2-SE-fp16` | 48 kHz | MLX community FP16 of `alibabasglab/MossFormer2_SE_48K` |

Cloud `voxella-modal-audiotools` uses a different checkpoint: `MossFormerGAN_SE_16K` at 16 kHz. Its speed-profile numbers are mapped, not copied.

## Parameter sources

### MLX community (`mlx-audio` MossFormer2 SE)

- Full pass if duration `< one_time_decode_length` (20 s)
- Segmented pass if `20 s ≤ duration < auto_chunk_threshold` (60 s): `decode_window` seconds, 75% stride, discard-edges
- Chunked pass if duration `≥ 60 s`: `chunk_seconds=4.0`, `chunk_overlap=0.25` (ratio), discard-edges
- Community claim: full mode is faster and higher quality when RAM allows; chunked mode is for long audio / lower RAM

### Cloud ClearVoice (`worker/processor.py` speed profiles)

| Mode | decode_window / one_time_decode_length | chunk_sec | overlap_sec | Reassembly |
| --- | ---: | ---: | ---: | --- |
| turbo | 3 | 3.0 | 0.25 | overlap-add |
| fast | 4 | 4.0 | 0.50 | overlap-add |
| balanced | 6 | 6.0 | 1.00 | overlap-add |

## Recipe matrix

MossFormer recipes keep the 48 kHz FP16 weights fixed and only vary windowing.

1. `moss_full` — community full-context pass
2. `moss_segmented_w3` / `w4` / `w6` — ClearerVoice segmented windows, 75% stride, discard-edges
3. `moss_chunked_discard_3s_0.25` / `4s_0.25` / `6s_0.25` — community chunked discard-edges
4. `moss_chunked_ola_3s_0.25s` / `4s_0.50s` / `6s_1.00s` — cloud overlap-add mapped to 48 kHz

DeepFilterNet baselines:

5. `dfn_offline` — full-context offline (quality baseline)
6. `dfn_stream_0.48s` — streaming at 0.48 s chunks (CLI documented latency path)

## Fixtures

Built from `Vendor/mlx-audio-swift/Tests/media` at 48 kHz:

- `short` — `noisy_audio.wav`, with `noisy_audio_target.wav` as a spectrogram-style reference
- `medium` — concatenated media until ≥ 24 s (segmented path)
- `long` — concatenated media until ≥ 72 s (auto-chunk threshold)

## Metrics

- Wall time and real-time factor after one warmup
- MLX peak active memory
- Waveform correlation vs `moss_full` (chunking fidelity)
- Waveform correlation vs `dfn_offline` (cross-model agreement, not a quality score)
- SI-SDR vs golden target on `short`
- Residual RMS ratio vs input (denoise strength proxy)
- Splice jump RMS at intended chunk boundaries

## Out of scope

App UI replacement, dry/wet mix retuning, speech-swift `SpeechEnhancer` source changes, and 16 kHz GAN checkpoint conversion.
