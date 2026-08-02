#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIRECTORY="${1:-$ROOT/artifacts/tts-clone-experiment-$(date +%Y%m%d-%H%M%S)}"

mkdir -p "$OUTPUT_DIRECTORY"
cd "$ROOT"

VOXELLA_RUN_LOCAL_FIXTURES=1 \
VOXELLA_RUN_TTS_CLONE_EXPERIMENT=1 \
VOXELLA_TTS_EXPERIMENT_OUTPUT="$OUTPUT_DIRECTORY" \
swift test --traits BundledSpeech --filter TTSCloneExperimentTests/adReferenceComparesCloneConditioningAndSampling

echo "TTS experiment outputs: $OUTPUT_DIRECTORY"
