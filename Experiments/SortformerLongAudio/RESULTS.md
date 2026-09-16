# Baseline measurements

2026-09-14, isolated release executable, MLX Swift 0.31.5, installed v2.1 fp16 model, lex_60min.mp3 prefix, 15.04-second streaming chunks, cache=188, FIFO=0.

| Input seconds | Output frames | MLX peak bytes | First output seconds | Diarization seconds |
| ---: | ---: | ---: | ---: | ---: |
| 15 | 188 | 594284396 | 2.713 | 2.854 |
| 60 | 751 | 932628428 | 0.284 | 1.219 |
| 300 | 3751 | 2373289016 | 0.606 | 2.025 |

All three exited 0, with finite probabilities in [0,1] and expected frame coverage. First run includes cold GPU kernel overhead; timings are not a speedup comparison. The harness currently loads the whole source before selecting its prefix, so process RSS is confounded by full-file decoding (~3.52 GB peak RSS). MLX peak rises with prefix duration, reaching 2.37 GB for five minutes despite a fixed streaming chunk size. The 300-second peak was already reached at the first emitted chunk.

The incident supplies an existing full-hour abort at full-file pre-encoding; no repeated full-hour unsafe baseline has been run.

## Bounded right-context prototype

Release build succeeded. Same executable protocol, same model and input:

| Input seconds | Output frames | MLX peak bytes | First output seconds | Diarization seconds |
| ---: | ---: | ---: | ---: | ---: |
| 300 | 3751 | 909676492 | 0.189 | 1.587 |
| 3605.028 | 45063 | 3425139788 | 0.259 | 17.790 |

Both runs exited 0 with valid probabilities and full frame coverage. The full-hour run emitted 240 chunks. Whole-process elapsed time was 21.07 seconds, maximum RSS 3518906368 bytes, peak footprint 5398857720 bytes. These process metrics include decoding, model loading, and GPU allocations; they are not interchangeable with MLX peak active memory. The experiment decoder reported 3605.028 seconds, slightly different from the app decoder's 3605.05 seconds.

The 300-second MLX peak decreased by approximately 62% under this workload. Whole-file feature extraction remains and the full-hour peak must not be described as constant memory. Numerical parity, cancellation, ordinary/BundledSpeech builds, and app persistence verification remain outstanding.

Commands: `swift build --package-path Experiments/SortformerLongAudio -c release`, then `/usr/bin/time -l .../SortformerReplay MODEL_DIRECTORY AUDIO_PATH SECONDS` for 15, 60, and 300 seconds. The matching existing mlx.metallib was colocated with the executable.

## Isolated convolution parity verification — 2026-09-14 20:02

The saved patch and experiment were extracted from stash into `/private/tmp/sortformer-parity.6oCH28` without modifying the concurrently edited application worktree.

`swift test --package-path /private/tmp/sortformer-parity.6oCH28/Experiments/SortformerLongAudio -c release -Xswiftc -enable-testing --filter ContextParityTests` built successfully in 206.46 seconds. The first launch failed because the XCTest executable could not locate its Metal library; this was a test-bundle resource issue, not a numerical failure. After colocating the existing matching `mlx.metallib` inside the test bundle's `Contents/MacOS`, the `--skip-build` rerun exited 0.

All ten parameterized convolution-parity cases passed in 0.132 seconds: feature lengths 1, 7, 8, 9, 15, 16, 17, 1504, 1505, 3013. Each compares selected beginning, middle and end embedding ranges against full convolution with an absolute-error threshold of 1e-4 and exact output shapes.

This proves the tested stride/halo boundary geometry for the small FP32 convolution fixture. It does not yet prove full-model FP16 output parity, cancellation completion, or application persistence. The main worktree still needs the memory fix restored after concurrent work is reconciled.

## Precision matrix and restoration — 2026-09-14 20:04

Expanded the same ten lengths across FP32, FP16, and FP16 weights with FP32 input (the right-context path's mixed precision). All 30 cases passed in 1.198 seconds, exit 0. Thresholds were absolute error below 1e-4 for FP32/mixed and 0.002 for FP16, with finite errors and identical shapes. This remains a small-convolution fixture, not full pretrained-model output parity.

After PRs 11 and 10 merged, the main worktree was clean and the Sortformer source was unchanged relative to the stash base. Restored only the bounded right-context source patch and experiment files using patches; did not apply the complete stash or restore unrelated account/workbench/alignment changes. Cancellation and application-level verification remain open.

The restored main-worktree patch passed `swift build --traits BundledSpeech` in 6.12 seconds (exit 0). The preceding attempt was invalidated by a concurrent edit to `WorkbenchSessionView.swift`, not a compiler error in Sortformer; only the completed retry is counted as build evidence.

## Caller-owned chunk processing and cancellation — 2026-09-14 20:09

Extracted the existing streaming loop into synchronous throwing `forEachChunk`, which runs on the caller's executor with a nonescaping callback. The application calls it from an explicit `@concurrent` diarization method while its existing shared MLX inference gate remains held. No detached producer remains in the application's diarization call path, and callback failure/cancellation unwinds before the caller returns. The public stream adapter reuses the same loop, catches errors, and cancels its producer on termination; stream termination alone still must not be treated as an awaited producer join by external consumers.

The changed application passed `swift build --traits BundledSpeech` in 49.96 seconds. Three isolated lifecycle tests passed in 0.225 seconds using small random models and synthetic audio: cancellation before processing emits nothing; cancelling in the first callback emits no later chunks; a throwing callback returns after one chunk and the same model can then run to completion. These are deterministic callback/task-boundary checks, not a GPU preemption-latency benchmark or a full UI cancellation test. Full-model output comparison and application persistence verification remain pending.

## Full-model numerical drift investigation — 2026-09-14

Exported all 15,004 Float32 probabilities (3,751 frames × 4 speakers) for the same first 300 seconds using the installed FP16 weights. The original implementation was repeated and its output matched byte-for-byte. The first minimal-halo optimization did **not** pass the full-model comparison: max absolute error 0.529922, mean 0.00895110, and 145 individual probabilities crossed 0.5. This supersedes any inference of full-model equivalence from the small convolution fixture.

| Bounded pre-encoding window | Max absolute probability error | Mean error | 0.5 threshold crossings | MLX peak bytes |
| --- | ---: | ---: | ---: | ---: |
| Minimal convolution halo | 0.529922 | 0.00895110 | 145 | 909676492 |
| At least 64 embeddings | 0.529872 | 0.00894943 | 145 | 909752268 |
| At least 256 embeddings | 0.000888884 | 0.0000129855 | 0 | 910145484 |

The production patch now uses the tested minimum 256-embedding window, extending left near EOF while retaining global stride phase. It remains bounded and requests only the required right-context outputs. Source inspection of MLX 0.31.5 `backend/metal/matmul.cpp` shows shape-dependent split-K dispatch and partition counts (around lines 548–563 and 929–937), consistent with accumulation-order differences. Numerical amplification through recurrent speaker-cache selection is the working explanation, not a GPU trace proving the exact dispatched kernels.

This full-model comparison establishes close agreement on this five-minute sample, **not bitwise equivalence or a general DER accuracy guarantee**. The raw comparison files are `/private/tmp/sortformer-parity.6oCH28/{original-300,original-repeat-300,fixed-300,window64-300,window256-300}.f32`. The original single-run peak was 2188644408 bytes; repeat peak was 2373289016 bytes. No comparative speed claim is made because other machine activity differed.

Full application test run after the cancellation change: 1967 tests in 293 suites, with five failed assertions across three tests (`higherWhisperFallbackPrecisionChangesWhisperDomainPlanSize`, `unsignedCloudFilterReturnsEmpty`, `exposesOnlyFirstReleaseRoutes`). These cover model installation and newly merged knowledge/workbench behavior, outside the edited diarization path; no clean pre-change baseline for the entire concurrently edited tree was established.

## Updated full-hour verification

With the 256-embedding window and shared caller-owned core, the isolated replay again completed all 3605.028 seconds: 240 chunks, 45063 frames, finite probabilities in [0,1], exit 0. Diarization elapsed 18.071 seconds and MLX peak was 3425139788 bytes. The complete probability export is `/private/tmp/sortformer-parity.6oCH28/window256-hour.f32`. This was not an app/workbench persistence run, and the unsafe original full-hour path was not repeated for a probability reference.

The updated 30-case precision/geometry suite passed in 0.805 seconds. Final production builds passed: `swift build --traits BundledSpeech` in 12.85 seconds and `swift build` in 45.60 seconds. These builds do not resolve the three full-suite failures recorded above. No GUI app replacement, deployment, or UI acceptance is claimed.

## Persistence component tests

Made the existing `WorkbenchSnapshot` and `WorkbenchPersistence` internal (no behavior change) so isolated tests can exercise the production file writer/loader. `swift test --traits BundledSpeech --filter 'DiarizationPersistenceTests|OptionalSpeakerDiarizationTests|DiarizationSpeechPackerTests'` passed: 20 tests in three suites, 0.005 seconds after a 155.72-second build.

Coverage includes applying completed transcription artifacts with two speaker labels, confidence values and exact word/segment times, atomic file save, loading through a fresh persistence actor, and equality of result/diarization diagnostics after reload. It also checks failed/cancelled status rejection by the shared commit policy and rejection of a stale revision attempting to erase an existing result. Synthetic fixture files are unique and cleaned off-main. These component tests do not invoke the GUI event dispatcher or simulate clicking Cancel.

An additional opt-in `DiarizationImportIntegrationTests` test runs the full local speech pipeline on an explicitly selected file and then exercises the same temporary-file save/reload path. Invoke with `VOXELLA_RUN_LOCAL_FIXTURES=1 VOXELLA_DIARIZATION_IMPORT=1 VOXELLA_DIARIZATION_IMPORT_AUDIO=/absolute/audio.mp3 swift test --traits BundledSpeech --filter DiarizationImportIntegrationTests`. The normal suite skips this integration test; it does not create a live workbench session. Completion is not claimed until the test's terminal result is recorded.

## Full application pipeline and persistence — 2026-09-14 20:56

The earlier interrupted run was terminal (exit 143), not a success. A subsequent fresh run completed with exit 0: `VOXELLA_RUN_LOCAL_FIXTURES=1 VOXELLA_DIARIZATION_IMPORT=1 VOXELLA_DIARIZATION_IMPORT_AUDIO=/Users/adamwang/Downloads/lex_60min.mp3 swift test --traits BundledSpeech --filter DiarizationImportIntegrationTests`. Test PID 58144 ran from 20:46:21 to 20:56:53. The current production pipeline reproduced 80 speech ranges and the original Whisper route with 176 ASR chunks; requested speaker count was explicitly two.

- The full test passed in 631.431 seconds. The application decoder supplied 57,680,811 samples / 3605.05 seconds.
- Sortformer loaded revision e23e6404bd9859e93edbf94a740eb1c7fc58f12e, kept identity packing, chunk=15.04 seconds, FIFO=0, cache=188, and completed all 240 chunks in 21.16 seconds without the incident's abort.
- Final result: 9,963 words and two speaker IDs, finite/nonnegative/monotonic word times. Shared completion-artifact application, temporary-file atomic save and fresh-actor reload preserved the result, speaker labels, diarization diagnostics and alignment diagnostics exactly.
- Reported MLX peak was 5,370,967,820 bytes. This counter covers the process lifetime, including ASR/alignment; it is not a reset, diarization-only measurement.
- A one-second 10-ms stack sample during alignment showed the main thread waiting in its run loop and alignment on a cooperative worker. This is not a GUI responsiveness acceptance test.

Resource caveat: the same sample and a later `vmmap -summary` reported physical footprint peak **24.2 GiB** while RSS samples were much smaller. At 20:56:05, vmmap attributed about 23.6 GiB to IOAccelerator graphics accounting; most ordinary malloc memory was only hundreds of MiB. This establishes substantial GPU/driver-accounted occupancy during the preceding pipeline, not a diagnosed leak or proof that all of it is reusable MLX cache. The current MLX allocator defaults its cache allowance to its large overall memory allowance; the app clears cache before diarization but does not bound it throughout ASR/alignment. A dedicated active/cache/footprint experiment is needed before changing global allocator policy. `/usr/bin/time` wrapped SwiftPM and reported the wrapper's much smaller footprint, so that field is not used as the test-host peak.

Evidence files: `/private/tmp/diarization-import-verification-20260914.log`, `/private/tmp/diarization-import-58144.sample.txt`, `/private/tmp/diarization-import-58144.vmmap.txt`. No real workbench session was created or modified. No GUI deployment, acoustic DER measurement, or user UI acceptance is claimed.

## Real-model cancellation and gated reuse

`VOXELLA_RUN_LOCAL_FIXTURES=1 VOXELLA_DIARIZATION_CANCELLATION=1 swift test --traits BundledSpeech --filter DiarizationCancellationIntegrationTests` exited 0. Both parameter cases passed in 0.809 seconds, using the installed model and synthetic 31-second silence, not user audio. Cancellation is triggered synchronously by the application's preparation progress callback or its first chunk callback, with no sleeps or races. The former emits only `.preparing`; the latter emits `.preparing` and exactly one `.diarizing` event; both throw CancellationError and emit no postprocessing result. After awaiting the cancelled task, a new inference-gate acquisition reuses the same model and completes all three chunks with finite probabilities. This supplements the three isolated small-model lifecycle tests. The preparation case cancels after speech packing and before mel inference; it does not claim mid-kernel GPU preemption or verify a GUI Cancel button.

Evidence: `/private/tmp/diarization-cancellation-verification-20260914.log`. The normal suite skips the test unless explicitly enabled.

## Current full-suite result

`swift test --traits BundledSpeech` completed on the current tree: 1979 tests in 298 suites, 6.645 seconds, exit 1. The same five assertions in the same three tests failed: `unsignedCloudFilterReturnsEmpty`, `exposesOnlyFirstReleaseRoutes`, and `higherWhisperFallbackPrecisionChangesWhisperDomainPlanSize`. No additional failures were reported. The run also emitted a Core ML zero-shape diagnostic; no additional test failure was attributed to it. These failures are outside the changed Sortformer/cancellation/persistence cases, but a clean baseline has not been established, so the entire suite is not claimed green. Log: `/private/tmp/diarization-full-suite-20260914.log`.

## Next resource experiment

The crash-path repair and full-pipeline/persistence checks now pass. Remaining resource investigation: distinguish live MLX tensors from reusable allocator cache and graphics-driver accounting throughout the complete Whisper/aligner/Sortformer sequence. Record active bytes, cache bytes, configured cache allowance and physical footprint at stage boundaries; compare the unchanged allocator policy with a scoped smaller cache allowance on the same audio/model configuration. Do not lower the overall live-allocation limit or change production process-global policy without evidence and inference-gate ownership. Preserve the same speaker cache and verify result invariants, runtime and cancellation after any allocator change.

Manual UI acceptance, not yet performed: with a disposable workbench session, import the hour-long file with two-speaker analysis enabled, verify completion and seek/playback around several speaker changes, close/reopen and verify saved labels, then cancel a second run during preparation or speaker analysis and retry. Expected: no crash, no late result committed after cancellation, and one completed result after retry. Acoustic speaker correctness still requires listening or reference labels; two detected IDs alone is not proof.

## User-requested pause and production reconciliation

Further memory analysis and audio reproduction were paused at the user's request. The new memory-instrumented baseline was explicitly stopped (test PID 68754 and SwiftPM parent 65320, exit 143); it is not a completed experiment. The added, unvalidated memory instrumentation was removed from the integration fixture, and no new allocator/cache policy was applied to production.

The validated Sortformer 256-embedding bounded context, caller-owned cancellable core, and alignment recovery changes are present in production files. Package.swift directly references the local vendored MLX package, so these are not experiment-only copies. Audit also found the earlier LID improvements still in `stash@{1}` rather than the current source. Restored only ASREngineRouter.swift, ASRLanguageVote.swift and their two regression-test files to that exact saved version: five/seven stratified windows and confidence-qualified unsupported-window veto. No entire-stash application was used. LocalSpeechPipeline.swift and LanguageVoteSessionExperiment.swift remained byte-identical during reconciliation. The earlier full-hour completion exercised the pre-restoration LID route; it must not be described as an end-to-end run of the newly combined LID code.

Combined verification: 67 focused tests in six suites passed; `swift build --traits BundledSpeech` passed in 5.97 seconds and `swift build` passed in 38.81 seconds. The full BundledSpeech suite ran 1982 tests in 298 suites and retained the same five assertions across the same three failed tests listed above, with no additional failures. The four restored LID files exactly match the saved versions (`git diff stash@{1} -- <four paths>` is empty). Shared pipeline SHA-256 remained fdb608ec4f3fa8fb99a6964bd1041413e7414b5847b6831a6c443cbc7a101176. Verification logs are `/private/tmp/verified-production-{integration-tests,speech-build,full-suite,default-build}.log`. No new real-audio replay, app installation, commit or unrelated stash restoration was performed.
