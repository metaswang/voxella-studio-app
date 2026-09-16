# Whisper alignment investigation

## Incident and evidence boundary

The 2026-09-14 one-hour import reported alignment retries and 23 estimated units before a later, separate diarization crash. The surviving unified log records `coverage retry cores=9 seconds=8.3` at 19:07:54. This is recognition-coverage repair, not a reason code for a rejected forced-alignment result. The old alignment progress messages did not persist rejected ranges or validation errors. Therefore the exact 23 units and their initial model failures cannot be reconstructed from those logs alone.

Whisper output passes through `ASRRecognitionSpans.ownedChunk`, which retains whole text in recognition ownership spans. `LongFormAlignmentEngine` coalesces those spans, calls the Qwen forced aligner, checks timestamps, and recursively retries rejected chunks. Final estimates are counted in existing alignment diagnostics. This investigation does not change routing, Whisper decoding, project persistence, or diarization.

## Deterministic reproduction

Run `swift test --traits BundledSpeech --filter LongFormAlignmentRecoveryTests`.

The first run, before recovery fixes but after adding the injectable model boundary, produced two failing cases and one passing control:

| Case | Original behavior | Required behavior |
| --- | --- | --- |
| Failed 12-unit, 12-second single source span | 7 model calls, 3 recursive retries | No fabricated text/audio boundaries; explicit estimates |
| Single word aligned to 0–8 seconds | Accepted as precise; no rejection | Reject excessive duration and report estimated timing |
| Two source spans lasting 2 and 10 seconds | Retry retains the actual source boundaries | Preserve this behavior |

After the fix, all six recovery tests passed, including out-of-slice rejection, tolerated small boundary drift, and cancellation during inference. The current checkout also passed `swift test --traits BundledSpeech --filter 'LongFormAlignment|AlignmentSpeechGate|AlignmentTimestamp'`: 16 tests in two suites. The full-hour application replay was terminated before a terminal result; it is not evidence of end-to-end success.

## Root causes established in application code

1. Once recursion reached one source span, the old fallback split both text and time in proportion to the number of tokenizer units. Word position is not an acoustic time anchor. Uneven speech, pauses, or missing/hallucinated text can make the resulting slices contain different words from the supplied text. Splitting rejected output cannot establish that missing correspondence.
2. The short-output guard intended for plateau detection also skipped the independent excessive-word-duration check for every output shorter than ten units.
3. Raw validation did not enforce the audio slice bounds. Normalization could hide grossly invalid model times by collapsing them onto the ownership boundary.
4. Cancellation was checked before, but not immediately after, synchronous model inference; a terminal fallback could be returned after cancellation.

The fix retains bounded retries across source spans, stops speculative subdivision inside one source span, and keeps explicit estimated timing when no reliable retry boundary remains. This trades speculative recovery opportunities for truthful timing quality; fewer model calls alone do not prove better timestamp accuracy or fewer estimated words.

## Model context

- [Official Qwen model card](https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B-hf): supports up to five minutes per alignment input. The application target is 120 seconds, so an hour-long source alone does not establish a per-call model-length violation.
- Installed `speech-swift` 0.0.21 `ForcedAligner.swift`: independent timestamp argmax followed by LIS monotonicity correction; timestamp bins are 80 ms. Monotonic output is not sufficient evidence of accurate alignment.
- [Upstream issue 197](https://github.com/QwenLM/Qwen3-ASR/issues/197): a user reports zero-duration lexical outputs and repeated timestamps on English and Chinese datasets. This corroborates a possible failure class, not the cause of the original 23 units. It is not evidence that all zero-duration words should trigger retries.

## Opt-in real-model experiment

Normal tests never read the source audio or load models. Run the integration replay explicitly, in isolation from other MLX inference:

```sh
VOXELLA_ALIGNMENT_REPLAY=1 \
VOXELLA_ALIGNMENT_REPLAY_AUDIO=/absolute/path/to/audio.mp3 \
swift test --traits BundledSpeech --filter WhisperAlignmentReplayTests
```

The replay reads installed Whisper 8-bit and forced-aligner 4-bit models offline. It samples the first, middle, and last two minutes, uses the shared ASR chunk planner and ownership adapter, and calls the production alignment engine. It does not write a workbench task, download models, or print transcript text. It deliberately uses continuous speech ranges without the full VAD/coverage-repair pipeline, so this is a controlled subsystem experiment, not an exact replay of the original import.

Collect `ALIGNMENT_REPLAY` summaries and `Alignment rejected` warnings. Warnings now include chunk, recursion depth, audio range, unit count, source-span count, retry decision, and validation reason, without transcript text. Exact full-import attribution still requires a complete replay with these diagnostics; UI accuracy requires listening against the source, not merely checking monotonicity.

### Observed real-model results

Run on the incident's 3605.028-second MP3, 2026-09-14; integration test completed in 28.132 seconds. Each sample used five ASR spans. These are post-fix subsystem results, not a pre/post quality comparison.

| Source offset (s) | Duration (s) | Words | Rejected / retried / estimated |
| --- | --- | --- | --- |
| 0 | 120 | 321 | 0 / 0 / 0 |
| 1742.514 | 120 | 305 | 0 / 0 / 0 |
| 3485.028 | 120 | 333 | 0 / 0 / 0 |

Cumulative MLX peak reported by the experiment reached 3,606,536,336 bytes. This is not total process RSS or a bound on the complete application's memory use. The sample did not reproduce the original 23-unit degradation. No acoustic ground-truth accuracy claim is made.
