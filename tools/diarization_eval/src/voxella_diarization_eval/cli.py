"""Score diarization RTTM files with the pyannote reference metrics.

This is a development/evaluation tool only. It is not linked into the macOS app
and never receives or uploads audio.
"""

from __future__ import annotations

import argparse
import json
import math
from collections.abc import Iterable, Sequence
from numbers import Real
from pathlib import Path
from typing import Any

from pyannote.core import Annotation, Segment, Timeline
from pyannote.metrics.detection import DetectionPrecisionRecallFMeasure
from pyannote.metrics.diarization import DiarizationErrorRate, JaccardErrorRate


class EvaluationInputError(ValueError):
    """Raised when an RTTM/UEM input is ambiguous or malformed."""


def _data_lines(path: Path) -> Iterable[tuple[int, list[str]]]:
    try:
        contents = path.read_text(encoding="utf-8")
    except OSError as error:
        raise EvaluationInputError(f"Unable to read {path}: {error}") from error

    for line_number, raw_line in enumerate(contents.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        yield line_number, line.split()


def _finite_number(value: str, *, path: Path, line_number: int, field: str) -> float:
    try:
        number = float(value)
    except ValueError as error:
        raise EvaluationInputError(
            f"{path}:{line_number}: {field} must be numeric, got {value!r}"
        ) from error
    if not math.isfinite(number):
        raise EvaluationInputError(
            f"{path}:{line_number}: {field} must be finite, got {value!r}"
        )
    return number


def load_rttm(path: Path) -> dict[str, Annotation]:
    """Load standard SPEAKER RTTM records grouped by recording URI."""

    annotations: dict[str, Annotation] = {}
    for line_number, fields in _data_lines(path):
        if len(fields) < 8:
            raise EvaluationInputError(
                f"{path}:{line_number}: expected at least 8 RTTM fields, got {len(fields)}"
            )
        if fields[0] != "SPEAKER":
            raise EvaluationInputError(
                f"{path}:{line_number}: unsupported RTTM record {fields[0]!r}; expected SPEAKER"
            )

        uri = fields[1]
        speaker = fields[7]
        if not uri or not speaker:
            raise EvaluationInputError(
                f"{path}:{line_number}: recording URI and speaker label must be non-empty"
            )

        start = _finite_number(
            fields[3], path=path, line_number=line_number, field="start"
        )
        duration = _finite_number(
            fields[4], path=path, line_number=line_number, field="duration"
        )
        if start < 0 or duration <= 0:
            raise EvaluationInputError(
                f"{path}:{line_number}: start must be >= 0 and duration must be > 0"
            )

        annotation = annotations.setdefault(uri, Annotation(uri=uri))
        annotation[Segment(start, start + duration), f"line-{line_number}"] = speaker

    if not annotations:
        raise EvaluationInputError(f"{path}: no SPEAKER RTTM records found")
    return annotations


def load_uem(path: Path) -> dict[str, Timeline]:
    """Load a standard four-column UEM file grouped by recording URI."""

    timelines: dict[str, Timeline] = {}
    for line_number, fields in _data_lines(path):
        if len(fields) != 4:
            raise EvaluationInputError(
                f"{path}:{line_number}: expected 4 UEM fields, got {len(fields)}"
            )
        uri = fields[0]
        start = _finite_number(
            fields[2], path=path, line_number=line_number, field="start"
        )
        end = _finite_number(fields[3], path=path, line_number=line_number, field="end")
        if start < 0 or end <= start:
            raise EvaluationInputError(
                f"{path}:{line_number}: start must be >= 0 and end must be greater than start"
            )
        timeline = timelines.setdefault(uri, Timeline(uri=uri))
        timeline.add(Segment(start, end))

    if not timelines:
        raise EvaluationInputError(f"{path}: no UEM regions found")
    return timelines


def _number(value: Any) -> float:
    return float(value)


def _metric_details(
    details: dict[str, Any], metric_name: str, *, value: float | None = None
) -> dict[str, float]:
    output = {
        key.replace(" ", "_"): _number(value)
        for key, value in details.items()
        if isinstance(value, Real)
    }
    raw_name = metric_name.replace("_", " ")
    output[metric_name] = _number(details[raw_name]) if value is None else value
    output[f"{metric_name}_percent"] = output[metric_name] * 100.0
    return output


def _overlap_details(
    metric: DetectionPrecisionRecallFMeasure, details: dict[str, Any]
) -> dict[str, float]:
    precision, recall, f1 = metric.compute_metrics(detail=details)
    return {
        "precision": float(precision),
        "recall": float(recall),
        "f1": float(f1),
        "precision_percent": float(precision) * 100.0,
        "recall_percent": float(recall) * 100.0,
        "f1_percent": float(f1) * 100.0,
        **{
            key.replace(" ", "_"): _number(value)
            for key, value in details.items()
            if isinstance(value, Real)
        },
    }


def _full_extent_uem(
    reference: Annotation, hypothesis: Annotation, uri: str
) -> Timeline:
    support = reference.get_timeline(copy=False).union(
        hypothesis.get_timeline(copy=False)
    )
    return Timeline(segments=[support.extent()], uri=uri)


def evaluate(
    reference_path: Path,
    hypothesis_path: Path,
    *,
    uem_path: Path | None = None,
    collar: float = 0.0,
    skip_overlap: bool = False,
) -> dict[str, Any]:
    """Compute per-recording and micro-aggregated DER/JER."""

    if not math.isfinite(collar) or collar < 0:
        raise EvaluationInputError(
            "collar must be a finite number greater than or equal to zero"
        )

    references = load_rttm(reference_path)
    hypotheses = load_rttm(hypothesis_path)
    extra_hypotheses = sorted(set(hypotheses) - set(references))
    if extra_hypotheses:
        raise EvaluationInputError(
            "Hypothesis contains recording URI(s) absent from reference: "
            + ", ".join(extra_hypotheses)
        )

    evaluation_maps = load_uem(uem_path) if uem_path is not None else {}
    if uem_path is not None:
        missing_uem = sorted(set(references) - set(evaluation_maps))
        extra_uem = sorted(set(evaluation_maps) - set(references))
        if missing_uem or extra_uem:
            messages = []
            if missing_uem:
                messages.append("missing UEM URI(s): " + ", ".join(missing_uem))
            if extra_uem:
                messages.append("unknown UEM URI(s): " + ", ".join(extra_uem))
            raise EvaluationInputError("; ".join(messages))

    der = DiarizationErrorRate(collar=collar, skip_overlap=skip_overlap)
    jer = JaccardErrorRate(collar=collar, skip_overlap=skip_overlap)
    overlap = DetectionPrecisionRecallFMeasure(collar=collar, skip_overlap=False)
    per_file: list[dict[str, Any]] = []

    for uri in sorted(references):
        reference = references[uri]
        hypothesis = hypotheses.get(uri, Annotation(uri=uri))
        uem = evaluation_maps.get(uri)
        der_details = der(reference, hypothesis, uem=uem, detailed=True)
        jer_details = jer(reference, hypothesis, uem=uem, detailed=True)
        overlap_uem = uem or _full_extent_uem(reference, hypothesis, uri)
        overlap_details = overlap(
            reference.get_overlap().to_annotation(),
            hypothesis.get_overlap().to_annotation(),
            uem=overlap_uem,
            detailed=True,
        )
        reference_count = len(reference.labels())
        hypothesis_count = len(hypothesis.labels())
        per_file.append(
            {
                "uri": uri,
                "reference_speakers": reference_count,
                "hypothesis_speakers": hypothesis_count,
                "speaker_count_correct": reference_count == hypothesis_count,
                "der": _metric_details(der_details, "diarization_error_rate"),
                "jer": _metric_details(jer_details, "jaccard_error_rate"),
                "overlap_detection": _overlap_details(overlap, overlap_details),
            }
        )

    der_aggregate = _metric_details(
        der[:], "diarization_error_rate", value=float(abs(der))
    )
    jer_aggregate = _metric_details(jer[:], "jaccard_error_rate", value=float(abs(jer)))
    overlap_aggregate = _overlap_details(overlap, overlap[:])
    speaker_count_accuracy = sum(
        int(record["speaker_count_correct"]) for record in per_file
    ) / len(per_file)

    return {
        "configuration": {
            "collar_seconds": collar,
            "overlap_included": not skip_overlap,
            "uem": str(uem_path) if uem_path is not None else None,
            "metric_backend": "pyannote.metrics 4.1.0",
        },
        "files": per_file,
        "aggregate": {
            "recording_count": len(per_file),
            "speaker_count_accuracy": speaker_count_accuracy,
            "speaker_count_accuracy_percent": speaker_count_accuracy * 100.0,
            "der": der_aggregate,
            "jer": jer_aggregate,
            "overlap_detection": overlap_aggregate,
        },
    }


def parser() -> argparse.ArgumentParser:
    argument_parser = argparse.ArgumentParser(
        description="Compute overlap-aware DER and JER from reference/hypothesis RTTM files."
    )
    argument_parser.add_argument("--reference", type=Path, required=True)
    argument_parser.add_argument("--hypothesis", type=Path, required=True)
    argument_parser.add_argument("--uem", type=Path)
    argument_parser.add_argument("--collar", type=float, default=0.0)
    argument_parser.add_argument(
        "--skip-overlap",
        action="store_true",
        help="Exclude reference overlap regions (default: score overlap inclusively).",
    )
    argument_parser.add_argument(
        "--pretty", action="store_true", help="Indent JSON output for review."
    )
    return argument_parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        result = evaluate(
            arguments.reference,
            arguments.hypothesis,
            uem_path=arguments.uem,
            collar=arguments.collar,
            skip_overlap=arguments.skip_overlap,
        )
    except EvaluationInputError as error:
        parser().error(str(error))
    print(
        json.dumps(result, ensure_ascii=False, indent=2 if arguments.pretty else None)
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
