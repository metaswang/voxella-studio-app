# Long-audio Sortformer investigation

Status: validated Sortformer/cancellation/alignment fixes are in production source. Full-hour pipeline and persistence passed. Further memory analysis and audio replays are paused at the user's request; do not resume them without user direction. See RESULTS.md for verification boundaries.

## Incident evidence

- Input: 3605.05-second English MP3; session 087E7676-38F9-46EB-87BE-069506457388.
- 2026-09-14 19:08:12 +0800: diarization began with chunk=15.04s, fifoMax=0, spkcacheMax=188.
- 19:08:14.6659: PID 44735 aborted. Crash report identifies SIGABRT on Metal completion queue in mlx::core::gpu::check_error.
- Another thread was evaluating Sortformer.swift:895, the full-file pre-encoding for right context, before any diarization chunk was emitted.
- Persisted session after restart: interrupted, no result. Earlier recognition and alignment did not survive the crash.
- Earlier process samples near 4.9 GB do not measure the transient crash-time peak. System swap counters are system-wide and do not establish process attribution or an OOM cause.

## Hypotheses to discriminate

1. Full-file convolutional pre-encoding allocates duration-proportional intermediate tensors despite the streaming API.
2. Whole-file feature extraction has an additional independent duration-dependent peak.
3. MLX/Metal command-buffer failure escapes as a C++ exception from the asynchronous completion callback; Swift optional-diarization catch cannot recover from process abort.
4. Model residency after ASR/alignment aggravates the peak but is not necessarily the original defect.

## Experiment matrix

Run a separate process per case, without opening or changing a real app project. Explicitly supplied real audio is an integration fixture, not an ordinary unit-test dependency.

- Baseline duration sweep: 15s, 60s, 300s, 900s, 3605s, preserving the installed model revision and streaming parameters.
- Record first-output latency, completion, emitted frame count, finite probabilities, process peak RSS, MLX active/cache/peak memory, system swap deltas, and terminal error.
- Stop scaling the baseline after a demonstrated unsafe allocation/command-buffer failure; do not repeatedly exhaust the host.
- Compare bounded right-context pre-encoding with full-file pre-encoding on short inputs. Preserve convolution halo, stride phase, true-file padding, and last partial chunk. Verify numerical agreement before the full-length run.
- Preserve one speaker cache over the entire recording. Do not restart speaker identities at chunk boundaries or drop right context merely to reduce memory.
- Test cancellation before start, during preprocessing, and after first output; await producer teardown before releasing the inference gate.
- Replay the full hour after the fix, then verify app-level result persistence and speaker/timestamp invariants. UI verification remains manual.

## Upstream sources to audit

- https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/vad/models/sortformer/README.md — bounded streaming state, model limits, memory guidance.
- https://github.com/Blaizzy/mlx-audio/discussions/520 — user reports of extra speakers and maintainer report of three-hour runs; anecdotal, not a benchmark for this Swift path.
- https://github.com/Blaizzy/mlx-audio-swift/releases — inspect current releases and Sortformer fixes against the vendored source.

## Completion requirements

Executed reproduction or a bounded experiment establishing the failing operation; reviewed upstream progress and limitations; implemented fix with regression coverage; required ordinary and BundledSpeech builds; long-audio replay and cancellation evidence; explicit persistence verification or a concrete remaining blocker. This document alone satisfies none of the execution gates.
