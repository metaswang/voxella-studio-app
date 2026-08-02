#!/usr/bin/env python3
"""Transcribe generated TTS WAVs with the locally installed MLX Whisper model."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from mlx_audio.stt import load_model


DEFAULT_ASR_MODEL = Path(
    "/Users/adamwang/Library/Caches/qwen3-speech/models/mlx-community/"
    "whisper-large-v3-turbo-asr-8bit"
)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", nargs="+", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--asr-model", default=DEFAULT_ASR_MODEL, type=Path)
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    if not arguments.asr_model.is_dir():
        raise FileNotFoundError(f"ASR model not found: {arguments.asr_model}")

    model = load_model(arguments.asr_model)
    results = []
    for audio_path in arguments.audio:
        if not audio_path.is_file():
            raise FileNotFoundError(f"Audio not found: {audio_path}")
        result = model.generate(
            str(audio_path),
            language="zh",
            task="transcribe",
            return_timestamps=True,
            verbose=False,
        )
        item = {
            "filename": audio_path.name,
            "text": result.text,
            "language": result.language,
            "segments": result.segments,
        }
        results.append(item)
        print(f"{audio_path.name}: {result.text}")

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(results, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
