#!/usr/bin/env python3
"""Compare Qwen3-TTS cloning through the current official mlx-audio implementation."""

from __future__ import annotations

import argparse
import json
import math
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path

import mlx.core as mx
import numpy as np
from mlx_audio.audio_io import write as write_audio
from mlx_audio.tts.utils import load_model


DEFAULT_REFERENCE = Path(
    "/Users/adamwang/Library/Application Support/Voxella Studio/VoiceLibrary/"
    "D0AA2E85-0D7C-4157-8424-47FE656D7750/reference.wav"
)
APP_MODEL_ROOT = Path(
    "/Users/adamwang/Library/Caches/qwen3-speech/models/aufklarer/"
    "Qwen3-TTS-12Hz-1.7B-Base-MLX-8bit"
)
APP_TOKENIZER_ROOT = Path(
    "/Users/adamwang/Library/Caches/qwen3-speech/models/Qwen/"
    "Qwen3-TTS-Tokenizer-12Hz"
)
TARGET_TEXT = "我从2000年开始出现咳嗽的现象，到2017年12月咳嗽加重，感觉好像整天都在咳嗽。"
REFERENCE_TRANSCRIPT_MANIFEST = "这时一个测试， 这个音色会被用作参考"
REFERENCE_TRANSCRIPT_ALTERNATIVE = "这是一个测试，这个音色会被用作参考"
SEED = 0x564F5845


@dataclass(frozen=True)
class Case:
    name: str
    description: str
    temperature: float
    reference_text: str


@dataclass(frozen=True)
class Measurement:
    filename: str
    duration_seconds: float
    sample_rate: int
    rms: float
    peak: float


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-directory", required=True, type=Path)
    parser.add_argument(
        "--model",
        help="Optional Hugging Face model ID or local model directory. Defaults to app weights.",
    )
    parser.add_argument("--reference-audio", default=DEFAULT_REFERENCE, type=Path)
    parser.add_argument("--target-text", default=TARGET_TEXT)
    return parser.parse_args()


def measure(audio: np.ndarray, sample_rate: int, filename: str) -> Measurement:
    mono = np.asarray(audio, dtype=np.float32).reshape(-1)
    rms = float(math.sqrt(float(np.mean(np.square(mono))))) if mono.size else 0.0
    peak = float(np.max(np.abs(mono))) if mono.size else 0.0
    return Measurement(
        filename=filename,
        duration_seconds=float(mono.size / sample_rate),
        sample_rate=sample_rate,
        rms=rms,
        peak=peak,
    )


def prepare_app_model_bundle() -> tuple[tempfile.TemporaryDirectory[str], Path]:
    if not APP_MODEL_ROOT.is_dir() or not APP_TOKENIZER_ROOT.is_dir():
        raise FileNotFoundError("The app Qwen3-TTS model or tokenizer is not installed")

    temporary_directory = tempfile.TemporaryDirectory(prefix="voxella-official-mlx-audio-")
    bundle = Path(temporary_directory.name)
    speech_tokenizer = bundle / "speech_tokenizer"
    speech_tokenizer.mkdir()

    for filename in ("model.safetensors", "vocab.json", "merges.txt", "tokenizer_config.json"):
        (bundle / filename).symlink_to(APP_MODEL_ROOT / filename)
    for filename in ("config.json", "model.safetensors"):
        (speech_tokenizer / filename).symlink_to(APP_TOKENIZER_ROOT / filename)

    config = json.loads((APP_MODEL_ROOT / "config.json").read_text(encoding="utf-8"))
    config["speaker_encoder_config"] = {"enc_dim": 2048, "sample_rate": 24_000}
    (bundle / "config.json").write_text(
        json.dumps(config, ensure_ascii=False), encoding="utf-8"
    )
    return temporary_directory, bundle


def resolve_model_path(model_argument: str | None) -> tuple[object, str, tempfile.TemporaryDirectory[str] | None]:
    if model_argument is not None:
        local_model = Path(model_argument)
        return (
            local_model if local_model.is_dir() else model_argument,
            model_argument,
            None,
        )
    temporary_directory, bundle = prepare_app_model_bundle()
    return bundle, str(APP_MODEL_ROOT), temporary_directory


def generate_case(model, case: Case, target_text: str, output_directory: Path) -> Measurement:
    mx.random.seed(SEED)
    results = list(
        model.generate(
            text=target_text,
            voice=None,
            ref_audio=str(arguments.reference_audio),
            ref_text=case.reference_text,
            lang_code="Chinese",
            temperature=case.temperature,
            top_k=50,
            top_p=1.0,
            repetition_penalty=1.05,
            max_tokens=4096,
            verbose=False,
            stream=False,
        )
    )
    if not results:
        raise RuntimeError(f"{case.name} produced no audio")

    audio = np.concatenate([np.asarray(result.audio) for result in results])
    output_path = output_directory / f"{case.name}.wav"
    write_audio(output_path, audio, results[0].sample_rate, format="wav")
    return measure(audio, results[0].sample_rate, output_path.name)


def main() -> None:
    global arguments
    arguments = parse_arguments()
    if not arguments.reference_audio.is_file():
        raise FileNotFoundError(f"Reference audio not found: {arguments.reference_audio}")

    output_directory = arguments.output_directory
    output_directory.mkdir(parents=True, exist_ok=True)
    model_path, model_identifier, temporary_directory = resolve_model_path(arguments.model)
    try:
        model = load_model(model_path)

        cases = (
            Case(
                name="E-official-mlx-audio-icl-cli-temperature",
                description="Official mlx-audio ICL with its generic CLI temperature (0.7)",
                temperature=0.7,
                reference_text=REFERENCE_TRANSCRIPT_MANIFEST,
            ),
            Case(
                name="F-official-mlx-audio-icl-qwen-default-temperature",
                description="Official mlx-audio ICL with Qwen3-TTS native temperature (0.9)",
                temperature=0.9,
                reference_text=REFERENCE_TRANSCRIPT_MANIFEST,
            ),
            Case(
                name="G-official-mlx-audio-icl-alternative-reference-text",
                description="Official mlx-audio ICL with plausible spoken transcript variant",
                temperature=0.9,
                reference_text=REFERENCE_TRANSCRIPT_ALTERNATIVE,
            ),
        )
        measurements = []
        for case in cases:
            measurement = generate_case(model, case, arguments.target_text, output_directory)
            measurements.append({"case": asdict(case), "measurement": asdict(measurement)})
            print(
                f"{case.name}: duration={measurement.duration_seconds:.3f}s "
                f"rms={measurement.rms:.6f} peak={measurement.peak:.6f}"
            )

        manifest = {
            "implementation": "Blaizzy/mlx-audio (installed from GitHub main)",
            "model": model_identifier,
            "reference_audio": str(arguments.reference_audio),
            "target_text": arguments.target_text,
            "seed": SEED,
            "requested_sampling": {
                "top_k": 50,
                "top_p": 1.0,
                "repetition_penalty": 1.05,
                "note": "mlx-audio raises Qwen3-TTS ICL repetition_penalty to at least 1.5.",
            },
            "results": measurements,
        }
        (output_directory / "official-mlx-audio-manifest.json").write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
    finally:
        if temporary_directory is not None:
            temporary_directory.cleanup()


if __name__ == "__main__":
    main()
