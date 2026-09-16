# Upstream audit (2026-09-14)

## Findings and limits of evidence

The vendored Swift streaming path calls `fcEncoder.preEncode(features, ...)` on the entire recording to produce right context. The incident's blocked evaluation is at that call. The initial convolution produces approximately `[1, ceil(melFrames / 2), 64, 256]` for the installed 128-mel model: about 2.95 billion elements for 3605 seconds, or 5.9 GB at float16 / 11.8 GB at float32, before other intermediates and workspaces. These are shape-derived estimates, not measured allocation peaks. Feature dtype and Metal workspace behavior require runtime verification.

Bounded right-context extraction must retain the global stride phase and convolution halo. For three kernel-3 stride-2 layers the receptive field is 15 mel frames, centered on an 8-frame grid. Simply independently encoding adjacent chunks changes edge padding and is not an equivalence-preserving fix. Resetting the speaker cache at boundaries would also change speaker identity semantics.

## Community experience

[MLX Audio #496](https://github.com/Blaizzy/mlx-audio/issues/496) reports a Metal internal-error abort on a 4579-second MP3 using v2.1 fp16, including file mode at 5 seconds and iterable mode at 120 seconds. The reporter had 192 GB RAM. The maintainer recommended smaller chunks (5/15/20 seconds), citing a 90-second training ceiling and a 70-minute run at about 0.8 GB on another machine. The issue was closed February 11, 2026. This is relevant precedent, but the reply does not independently establish that Swift full-file pre-encoding is safe or explain the file-mode case.

[Discussion #520](https://github.com/Blaizzy/mlx-audio/discussions/520) reports extra speaker identities, with cosine embedding merging improving speaker counts on two examples; a third reference has five speakers, beyond Sortformer's four output slots. The maintainer reports successful three-hour use. These are user/maintainer observations, not controlled evidence for accuracy on this recording. Do not silently merge speakers or change backend based on those anecdotes.

[Python model README](https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/vad/models/sortformer/README.md) recommends small chunks with a persistent AOSC speaker cache and explains attention scaling. Total file length and model input chunk length are different quantities; long recordings are supported through retained state, not through a single unbounded tensor pass.

## Latest Swift status checked through GitHub API

- Latest published release returned: [v0.1.3](https://github.com/Blaizzy/mlx-audio-swift/releases/tag/v0.1.3), July 9, 2026.
- Most recent commit returned for `Sortformer.swift`: [d2035cdb / #193](https://github.com/Blaizzy/mlx-audio-swift/pull/193), June 5, 2026. It replaces per-frame GPU readbacks with one bulk readback; the author reports roughly 1.8x throughput and identical output on a 32-minute example. This does not address full-file convolution preprocessing.
- Release also includes [MOSS-Transcribe-Diarize #221](https://github.com/Blaizzy/mlx-audio-swift/pull/221). Its resource/accuracy suitability needs separate evaluation; availability is not evidence that replacing the current pipeline solves this crash.

### Additional upstream checks

- [MOSS quantized KV cache #225](https://github.com/Blaizzy/mlx-audio-swift/pull/225) merged July 22, 2026, after the release above. Optional KV quantization is off by default. The contributor reports a 56-minute meeting comparison with 8-bit/group-64 KV using about 30% lower peak memory and matching speaker structure; 4-bit/group-32 produced repetitive output on long input. These are contributor results, not local measurements. This is an alternative-model development, not a Sortformer memory fix.
- [NVIDIA v2.1 model card](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1) describes the four-speaker model. [NeMo issue 15711](https://github.com/NVIDIA-NeMo/Speech/issues/15711) reports extra third/fourth identities on two-speaker audio and asks for maximum-speaker control. A requested count is not by itself a guarantee of correct identities; do not suppress identities merely to make counts look correct.
- Local full-model comparisons uncovered another pitfall: a mathematically correct minimal convolution halo can still alter floating-point accumulation and downstream cache decisions. A minimum 256-embedding calculation window reduced the measured five-minute probability differences without changing the requested right context or resetting speaker state. See RESULTS.md for failed small-window experiments as well as successful comparisons.

## Python developments checked on 2026-09-14

- Python [`mlx-audio` v0.5.3](https://github.com/Blaizzy/mlx-audio/releases/tag/v0.5.3) was published September 7. Its own change is Granite keyword handling, not a Sortformer repair; Python and Swift release numbers must not be conflated.
- [VibeVoice-ASR-Streaming #940](https://github.com/Blaizzy/mlx-audio/pull/940), merged September 3 and included in v0.5.2, adds 1.5B/7B streaming ASR plus speaker IDs through interleaved audio/text blocks. It is a relevant alternative architecture, not evidence of Swift availability, bounded hour-long memory, or superior DER on this file.
- [DialogueSidon #948](https://github.com/Blaizzy/mlx-audio/pull/948), merged September 6, adds 24 kHz mono speaker separation/restoration. Producing separated audio is different from diarization's time/identity labels; it is not a drop-in replacement for this timeline.
- [MOSS performance #826](https://github.com/Blaizzy/mlx-audio/pull/826), merged July 10, reuses attention masks and changes prefill sizing. The author's 66-minute M5 Max example reports first-token latency 13.9→12.4 seconds and decode 55.9→68.9 tokens/second. These are upstream measurements, not local comparisons or a reason to enlarge Sortformer chunks.

The official GitHub API was rechecked in this pass: Swift latest release remains v0.1.3 (July 9), and the newest commit affecting Swift Sortformer remains d2035cdb (#193, June 5). No automatic dependency upgrade or model migration was performed.

## Verification still in progress

The complete one-hour application pipeline, speaker/timestamp invariants, temporary-file persistence round trip, and real-model preparation/first-output cancellation with gated reuse passed; see RESULTS.md. Cancellation remains cooperative, not preemption of an already submitted GPU kernel. Do not interpret process-wide SIGABRT as proof of an OOM without a captured Metal error or controlled allocation evidence. The full pipeline's separate 24.2-GiB graphics-accounted footprint deserves an allocator/cache investigation; it is not resolved by the bounded convolution patch.
