#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
pkg="$root/Experiments/MossFormer2SE_20260918"
out="${1:-$pkg/out}"

swift build --package-path "$pkg" -c release --product MossFormerReplay

bin="$(swift build --package-path "$pkg" -c release --product MossFormerReplay --show-bin-path)/MossFormerReplay"
bin_dir="$(dirname "$bin")"

metallib="$(find "$pkg/.build" -name 'default.metallib' -o -name 'mlx.metallib' | head -n 1 || true)"
if [[ -n "$metallib" ]]; then
  cp "$metallib" "$bin_dir/default.metallib"
  cp "$metallib" "$bin_dir/mlx.metallib"
fi

mkdir -p "$out"
exec "$bin" --media-dir "$root/Vendor/mlx-audio-swift/Tests/media" --out-dir "$out"
