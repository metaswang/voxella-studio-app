#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/voxstudio-vote.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/PalmierPro" "$WORK/Tests/PalmierProTests"
for NAME in ASREngine ASREngineRouter ASREngineLanguagePolicy ASRLanguageVote ASRChunkPlanner; do
  cp "$ROOT/Sources/PalmierPro/LocalAI/$NAME.swift" "$WORK/Sources/PalmierPro/"
done
for NAME in ASREngineRouterTests ASRLanguageVoteTests ASREngineCoverageReplayTests; do
  cp "$ROOT/Tests/PalmierProTests/LocalAI/$NAME.swift" "$WORK/Tests/PalmierProTests/"
done
cat > "$WORK/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "LanguageVoteRegression", targets: [.target(name: "PalmierPro"), .testTarget(name: "PalmierProTests", dependencies: ["PalmierPro"])])
SWIFT
cat > "$WORK/Sources/PalmierPro/ModelCatalogStub.swift" <<'SWIFT'
enum LocalModelID { case qwen3ASR17B8Bit, parakeetTDT06Bv3, whisper }
SWIFT
cp "$ROOT/Experiments/language_voting_20260912/results-current-preparation.json" "$WORK/fixture.json"
docker run --rm -v "$WORK:/work" -w /work \
  -e VOXSTUDIO_COVERAGE_FIXTURE=/work/fixture.json \
  -e VOXSTUDIO_COVERAGE_OUTPUT=/work/coverage-results.json \
  swift:6.2 swift test
if [[ -n "${VOXSTUDIO_COVERAGE_OUTPUT:-}" ]]; then
  cp "$WORK/coverage-results.json" "$VOXSTUDIO_COVERAGE_OUTPUT"
fi
