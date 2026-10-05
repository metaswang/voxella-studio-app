#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
experiment="$root/Experiments/EmmaMossFormer48k_20261005"
cd "$root"
swift build --product mlx-audio-swift-sts --traits BundledSpeech
python3 "$experiment/experiment.py" prepare
export HF_HUB_CACHE="$experiment/model-cache"
bin="$root/.build/arm64-apple-macosx/debug/mlx-audio-swift-sts"
"$bin" --model starkdmi/MossFormer2-SE-fp16 --audio "$experiment/audio/02_original_resampled_48k.wav" --output-target "$experiment/audio/01_mossformer_pure_raw_48k.wav" > "$experiment/inference.log" 2>&1
"$bin" --model starkdmi/MossFormer2-SE-fp16 --audio "$experiment/audio/03_original_hpf80_48k.wav" --output-target "$experiment/audio/04_mossformer_hpf_raw_48k.wav" > "$experiment/inference-hpf.log" 2>&1
python3 "$experiment/experiment.py" finish
