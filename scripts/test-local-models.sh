#!/bin/zsh

set -euo pipefail

repo_dir=${0:A:h:h}
cd "$repo_dir"
requested_filter=${1:-LocalModelInferenceTests}
if [[ "$requested_filter" != */* && "$requested_filter" != *Tests ]]; then
  test_filter="PalmierProTests.LocalModelInferenceTests/$requested_filter()"
else
  test_filter=$requested_filter
fi

# Build the opt-in tests without invoking MLX, then place the SwiftPM-generated
# Metal library beside the XCTest executable where the MLX runtime searches first.
swift test --traits BundledSpeech --filter '__voxella_build_only__'
build_dir=$(swift build --traits BundledSpeech --show-bin-path)
test_bundle=$(find "$build_dir" -maxdepth 1 -name '*.xctest' -type d -print -quit)
test_executable=$(find "$test_bundle/Contents/MacOS" -maxdepth 1 -type f -perm +111 -print -quit)

if [[ -z "$test_executable" || ! -f "$build_dir/mlx.metallib" ]]; then
  print -u2 'Could not locate the test executable or mlx.metallib.'
  exit 1
fi

cp "$build_dir/mlx.metallib" "${test_executable:h}/mlx.metallib"
VOXELLA_RUN_LOCAL_FIXTURES=1 swift test \
  --skip-build \
  --traits BundledSpeech \
  --filter "$test_filter"
