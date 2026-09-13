# Local speech input latency experiment

Compare the existing timed transcription pipeline with a text-only exit after shared speech preparation, language routing, ASR, text cleanup and ownership resolution. The input decoder reads at most ten seconds directly instead of decoding an entire compressed source before slicing. Both paths retain the shared inference gate and cached model owner.

## Inputs and measurement

Use isolated copies of three reference WAV files already in the app's local library: English (9.68 s), Chinese (5 s), and an untranscribed Chinese reference (11.24 s). Keep the user's library unchanged. Restrict recognition to the first ten seconds. Report engine, detected language, transcript and wall time in three paired passes, alternating timed/text and text/timed order. Report the median of the last two passes as warm latency. The first invocation is process-first, not a claim that OS or model caches are cold. Run the model-only streaming experiment separately so it cannot add inference-gate contention to the end-to-end comparison.

Opt-in test: `VOXELLA_RUN_LOCAL_FIXTURES=1 VOXELLA_SPEECH_INPUT_EXPERIMENT=1 VOXELLA_SPEECH_INPUT_CORPUS=/tmp/voxella-speech-input-corpus swift test --traits BundledSpeech --filter SpeechInputBenchmarkTests`. Ensure `mlx.metallib` is beside the test executable. Normal unit tests never load real models or user files.

## Streaming research

The vendored Qwen `generateStream(audio:)` accepts an already available MLXArray and preprocesses/encodes each whole input chunk before yielding generated tokens. It is token streaming, not an incremental microphone PCM session. Its implementation starts a detached task; any experiment must retain the process-wide inference gate until the stream worker actually exits, including cancellation. Do not substitute repeated full-prefix inference for true streaming without measuring redundant work.

- [Vendored upstream Swift implementation](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift)
- [Official Qwen streaming implementation](https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/inference/qwen3_asr.py)
- [Official streaming demo](https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/cli/demo_streaming.py)

The official implementation maintains audio/text context, unfixed chunks and token rollback. The desktop integration currently uses the shared offline recognizer. A streaming experiment must measure first usable text and final latency separately, and verify cancellation before adopting it.

## Correctness and manual UI verification

- Settings contains Voice Library; the main sidebar does not. Management links from voiceover open the settings pane.
- Choose audio with an empty script: recognition starts automatically. Stop recording: waveform stops, finalized audio triggers recognition.
- User-authored script survives import/recording. Typing while recognition runs cancels its result. Replacement and dismissal reject late results.
- Microphone denial, start/stop transitions and repeated clicks show explicit state. Escape/dismissal stops capture.
- Save waits for recognition and recording finalization. Automatically recognized references save only the matching prefix; manually authored scripts preserve full audio.
- Test settings at its minimum size, keyboard focus, empty library, recording on/off, import replacement and model-unavailable errors. UI remains unverified until the user confirms.
