# Studio language vote qualification

The implementation uses ECAPA's complete posterior. Historical margin-squared results are retained in `results-current-preparation.json` and `results-committed-preparation.json`; the current policy evaluates overlapping ASR language coverage with capped speech-duration weights.

## Acceptance criteria

- Sum each engine's supported-language probabilities, retaining overlap between Qwen and Parakeet. Coverage scores are not mutually exclusive engine probabilities; the Whisper score is mass outside both preferred engines.
- Weight normalized windows by `min(speech seconds, 5)`. Single-language confidence or margin must not amplify a window's routing weight.
- An engine qualifies when pooled coverage is >0.50 and exceeds uncovered mass for that engine by >=0.15, every sampled window has >0.50 coverage, and all strong language anchors are supported. Anchors retain confidence >=0.75 and margin >=0.15. These configurable thresholds are engineering defaults, not calibrated accuracy.
- Prefer Parakeet when both engines qualify. If Qwen qualifies, Chinese/English anchors in different windows, or a window with each >=0.25 and combined >=0.75, select Qwen for Chinese/English conflict protection.
- Other switches within an engine's supported languages are normal coverage routing. Unresolved evidence falls back to unprompted Whisper; Qwen is not the universal uncertainty fallback.
- Short nonempty speech follows normal LID and routing. Three seconds is a target for dividing sampling windows, not a minimum model input or voting eligibility gate. Empty, malformed, non-finite, overlapping, or conflicting duplicate evidence must not route to a specialized engine.
- Exact repeated windows must not add weight. Samples must not overlap even when VAD ranges overlap or speech lasts 6–15 seconds.
- Automatic language detection only selects the ASR engine: even unanimous high-confidence evidence must not supply a Whisper language hint or preassign the transcript's language. Resolve the output language from the ASR result, with text-language detection as the fallback.
- Explicit user language selection remains authoritative.

## Automated checks

`./Experiments/language_voting_20260912/check-docker.sh` compiles the actual production Swift policy/router/planner and their Swift Testing suites in a local Swift 6.2 Docker container, including a replay of saved posteriors. Only the unrelated model catalog enum is stubbed; no current voting logic is copied or translated. Set `VOXSTUDIO_COVERAGE_OUTPUT` to retain the replay report.

Native integration: `swift test --traits BundledSpeech --filter 'ASREngineRouterTests|ASRLanguageVoteTests'`.

## Session experiment

Provide a private JSON manifest containing `[{"id":"anonymous-case", "path":"/absolute/path/to/isolated.wav", "reference":"en"}]`. Run:

```
VOXELLA_RUN_LOCAL_FIXTURES=1 VOXSTUDIO_LID_MANIFEST=/absolute/path/to/manifest.json \
  swift test --traits BundledSpeech --filter LanguageVoteSessionExperiment
```

Place the repository's `mlx.metallib` beside the native test executable. Inputs and outputs remain local. The opt-in test writes `results.json` next to the manifest, including window slices, full 107-class probabilities, weights, anchors, routes and timing. Normal unit tests do not load personal files or models.

Compare old averaging/engine-mass routing and new pooling on identical model windows to isolate the decision change. The sampler is independently covered by non-overlap tests; this comparison does not represent the old end-to-end sampler. Preserve each source pipeline's VAD implementation: the committed baseline uses Core ML VAD; the current working tree uses its existing speech-probability preparation. Do not merge those unrelated implementations with this feature.

The September 12 corpus uses the first up to 90 seconds of 20 available, distinct session media inputs. Copies are mono 16 kHz WAV, decoded locally with ffmpeg, originally preferring `listenAudioPath`. Include a two-second English prefix, English at 0.03 amplitude (about -30.5 dB), and a 15-second English + 15-second Chinese concatenation. The user confirms the original sessions are Chinese or English, but stored transcript labels (including `da`) are not independent ground truth. Do not tune thresholds to those labels or report calibration from them. A zero-Whisper count is not the acceptance criterion: unresolved evidence may use Whisper. Verify source-track equivalence separately before attributing errors to production audio preparation.

Model coverage sources: [Parakeet v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) and [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-1.7B). Latin is outside both preferred models; Burmese is outside Qwen, while Malay is supported.

For broader qualification, independently annotate languages and switches across multiple meetings, noise levels and durations; measure wrong specialized routes, fallback frequency, language-hint errors, and full ASR content quality. This experiment qualifies routing safeguards, not calibrated accuracy or full transcription WER/CER.
