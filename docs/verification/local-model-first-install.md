# Local model first-install verification

Public model downloads use the official Hugging Face endpoint with no authentication or Hub blob cache. Application license acceptance is independent of Hugging Face authentication. Sortformer is optional; ASR and alignment requirements remain mandatory.

## Cache-free snapshot completion

The signed DMG test exposed an additional swift-huggingface 0.9.0 defect: `downloadSnapshot(to:)` transfers files to the explicit destination, then unconditionally requires a Hub cache when resolving its return path. The local adapter handles only that specific post-transfer error for the requested repository. The model manager still checks required files, pinned artifact hashes, weight size and SHA-256 before writing the install manifest. Transfer, access, path-validation, and cancellation failures remain failures.

References: [pinned SDK implementation](https://github.com/huggingface/swift-huggingface/blob/0.9.0/Sources/HuggingFace/Hub/HubClient%2BFiles.swift), [HF authentication environment variables](https://huggingface.co/docs/huggingface_hub/package_reference/environment_variables#hf_token). `HF_TOKEN` configures server authentication; it does not accept the application's NVIDIA license prompt. The successful developer cache path can hide failures that occur only on a cold download.

Community context: [huggingface_hub issue 4741](https://github.com/huggingface/huggingface_hub/issues/4741) reports proxy-dependent HEAD metadata failures even when GET transfer works. It concerns a different Python client error, not proof of this Swift defect. It supports qualifying the actual transfer on the affected user's network instead of assuming a successful developer-cache load or HEAD request proves first-install behavior.

## Automated checks

```sh
swift build
swift build --traits BundledSpeech
swift test --traits BundledSpeech --filter 'OptionalSpeakerDiarizationTests|LocalModelInstallPlanTests|LocalModelDownloadTests'
swift test
```

Run focused tests with a deliberately invalid `HF_TOKEN` in an isolated process as well. The client must still send no Authorization header. Unit tests must not use real model downloads or personal caches.

## Signed DMG qualification (manual)

Use a fresh macOS user account with no model files, app preferences, HF environment variables, or HF CLI token files. Install the signed DMG and launch from Finder.

1. Select English and automatic speakers. Install only the required ASR/VAD models. Transcribe a two-speaker fixture: all text, word timing, segments, and exported subtitles must remain present; no speaker labels are expected.
2. Open Local Models. Sortformer must be Optional and excluded from Download Recommended. Cancel its license dialog: transcription must remain available and no download may start.
3. Accept and download Sortformer. Interrupt the network, retry, and restart the app. Accepted license state must persist; failures must show a download error rather than request acceptance again.
4. Install Sortformer and retranscribe the same fixture. Verify labels are generated and the earlier unlabeled cache is not reused. Remove Sortformer and repeat: transcription must still complete without labels.
5. Verify explicit single-speaker transcription, automatic language selection, and known-text alignment. Supplied script speaker spans must remain intact.
6. Cancel during recognition and close while a job is active. No partial successful result may be committed. A non-cancellation speaker-model failure must complete the transcript with a visible warning.
7. Restart offline after installation. Required installed models must be reused. Verify exported subtitles and saved/reopened results, not only a success indicator.

Before each release, anonymously verify access to every catalog repository at its pinned revision and its required files. HEAD checks alone do not qualify successful transfer, checksum validation, or inference. Repeat the DMG flow on the affected user's network.

Do not distribute a developer token. Do not infer that an HTTP 401/403 means the app's license was not accepted. Do not clear users' existing models or projects as test setup.

## MCP follow-up

No tool names or schemas change. In an isolated project with installed required models and no Sortformer, call `get_transcript` for a fixture clip using the local provider. Read the returned words and timing independently, then exercise caption creation and undo. Repeat after installing Sortformer and confirm labels are present. This requires an isolated running app/server and test model installation; mocked downloader and policy tests do not establish MCP end-to-end coverage.
