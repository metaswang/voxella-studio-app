#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${VOXELLA_MLX_AUDIO_PYTHON:-/private/tmp/voxella-mlx-audio-experiment/bin/python}"
OUTPUT_DIRECTORY="${1:-$ROOT/artifacts/official-mlx-audio-qwen3-$(date +%Y%m%d-%H%M%S)}"

if [[ ! -x "$PYTHON" ]]; then
    echo "mlx-audio environment not found: $PYTHON" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIRECTORY"
HF_HOME="${VOXELLA_HF_HOME:-/private/tmp/voxella-hf-cache}" \
HF_HUB_CACHE="${VOXELLA_HF_HOME:-/private/tmp/voxella-hf-cache}/hub" \
"$PYTHON" "$ROOT/scripts/run_official_mlx_audio_qwen3_experiment.py" \
    --output-directory "$OUTPUT_DIRECTORY"

echo "Official mlx-audio experiment outputs: $OUTPUT_DIRECTORY"
