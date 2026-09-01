#!/usr/bin/env bash
set -euo pipefail

source_model="${1:-tencent/WeMM-Embedding-2B}"
output_dir="${2:-$PWD/.models/WeMM-Embedding-2B-4bit}"
q_bits="${3:-4}"
q_group_size="${4:-64}"
python_bin="${PYTHON_BIN:-python3}"

if [[ -e "$output_dir" ]]; then
    echo "Refusing to overwrite existing output: $output_dir" >&2
    exit 2
fi

if ! "$python_bin" -c 'import mlx_vlm' >/dev/null 2>&1; then
    echo "Install mlx-vlm first, for example: python3 -m pip install mlx-vlm" >&2
    exit 3
fi

mkdir -p "$(dirname "$output_dir")"

"$python_bin" -m mlx_vlm convert \
    --hf-path "$source_model" \
    --mlx-path "$output_dir" \
    --trust-remote-code \
    --quantize \
    --q-bits "$q_bits" \
    --q-group-size "$q_group_size"

curl --fail --location --silent --show-error \
    "https://huggingface.co/${source_model}/resolve/main/embedding_chat_template.jinja?download=true" \
    --output "$output_dir/embedding_chat_template.jinja"

test -f "$output_dir/config.json"
test -f "$output_dir/embedding_chat_template.jinja"
if ! find "$output_dir" -name '*.safetensors' -print -quit | grep -q .; then
    echo "Conversion produced no safetensors files: $output_dir" >&2
    exit 4
fi

echo "Converted WeMM to MLX ${q_bits}-bit:"
echo "  $output_dir"
