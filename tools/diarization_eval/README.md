# Voxella diarization evaluation

This development-only tool scores reference and hypothesis RTTM files with the
official `pyannote.metrics` DER and JER implementations, plus overlap-detection
precision/recall/F1. DER and JER include overlapping speech by default. The tool
supports a UEM and configurable reference-boundary collar, and emits
machine-readable JSON with both per-recording and aggregate results.

Run tests:

```sh
uv run --project tools/diarization_eval python -m unittest discover \
  -s tools/diarization_eval/tests
```

Score a system output:

```sh
uv run --project tools/diarization_eval voxella-diarization-score \
  --reference reference.rttm \
  --hypothesis hypothesis.rttm \
  --collar 0.25 \
  --pretty
```

Run once with `--collar 0` and once with `--collar 0.25`. Do not use
`--skip-overlap` for the primary Voxella metric because both Sortformer and the
legacy segmentation path are expected to preserve overlapping speech.
