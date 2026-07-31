from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from voxella_diarization_eval.cli import EvaluationInputError, evaluate, load_rttm


class DiarizationEvaluationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write(self, name: str, lines: list[str]) -> Path:
        path = self.directory / name
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path

    @staticmethod
    def turn(uri: str, start: float, duration: float, speaker: str) -> str:
        return f"SPEAKER {uri} 1 {start} {duration} <NA> <NA> {speaker} <NA> <NA>"

    def test_perfect_permuted_labels_score_zero(self) -> None:
        reference = self.write(
            "reference.rttm",
            [self.turn("meeting", 0, 5, "alice"), self.turn("meeting", 5, 5, "bob")],
        )
        hypothesis = self.write(
            "hypothesis.rttm",
            [
                self.turn("meeting", 0, 5, "speaker-2"),
                self.turn("meeting", 5, 5, "speaker-1"),
            ],
        )

        result = evaluate(reference, hypothesis)

        self.assertAlmostEqual(result["aggregate"]["der"]["diarization_error_rate"], 0)
        self.assertAlmostEqual(result["aggregate"]["jer"]["jaccard_error_rate"], 0)
        self.assertEqual(result["aggregate"]["speaker_count_accuracy"], 1)

    def test_missing_half_of_single_speaker_is_counted(self) -> None:
        reference = self.write("reference.rttm", [self.turn("meeting", 0, 10, "alice")])
        hypothesis = self.write(
            "hypothesis.rttm", [self.turn("meeting", 0, 5, "local-1")]
        )

        result = evaluate(reference, hypothesis)

        self.assertAlmostEqual(result["aggregate"]["der"]["missed_detection"], 5)
        self.assertAlmostEqual(
            result["aggregate"]["der"]["diarization_error_rate"], 0.5
        )
        self.assertAlmostEqual(result["aggregate"]["jer"]["jaccard_error_rate"], 0.5)

    def test_overlap_is_included_by_default_and_can_be_excluded(self) -> None:
        reference = self.write(
            "reference.rttm",
            [self.turn("meeting", 0, 10, "alice"), self.turn("meeting", 5, 5, "bob")],
        )
        hypothesis = self.write(
            "hypothesis.rttm", [self.turn("meeting", 0, 10, "local-1")]
        )

        inclusive = evaluate(reference, hypothesis)
        exclusive = evaluate(reference, hypothesis, skip_overlap=True)

        self.assertAlmostEqual(
            inclusive["aggregate"]["der"]["diarization_error_rate"], 1 / 3
        )
        self.assertAlmostEqual(
            exclusive["aggregate"]["der"]["diarization_error_rate"], 0
        )
        self.assertAlmostEqual(inclusive["aggregate"]["overlap_detection"]["f1"], 0)
        self.assertTrue(inclusive["configuration"]["overlap_included"])
        self.assertFalse(exclusive["configuration"]["overlap_included"])

    def test_overlap_detection_f1_is_scored_on_full_recording_extent(self) -> None:
        reference = self.write(
            "reference.rttm",
            [self.turn("meeting", 0, 10, "alice"), self.turn("meeting", 5, 5, "bob")],
        )
        hypothesis = self.write(
            "hypothesis.rttm",
            [
                self.turn("meeting", 0, 10, "local-1"),
                self.turn("meeting", 5, 5, "local-2"),
            ],
        )

        result = evaluate(reference, hypothesis)

        self.assertAlmostEqual(result["aggregate"]["overlap_detection"]["precision"], 1)
        self.assertAlmostEqual(result["aggregate"]["overlap_detection"]["recall"], 1)
        self.assertAlmostEqual(result["aggregate"]["overlap_detection"]["f1"], 1)

    def test_uem_limits_scored_region(self) -> None:
        reference = self.write("reference.rttm", [self.turn("meeting", 0, 10, "alice")])
        hypothesis = self.write(
            "hypothesis.rttm", [self.turn("meeting", 0, 5, "local-1")]
        )
        uem = self.write("score.uem", ["meeting 1 0 5"])

        result = evaluate(reference, hypothesis, uem_path=uem)

        self.assertAlmostEqual(result["aggregate"]["der"]["diarization_error_rate"], 0)

    def test_malformed_or_unknown_recordings_are_rejected(self) -> None:
        malformed = self.write("malformed.rttm", ["SPEAKER meeting 1 0 nope"])
        with self.assertRaises(EvaluationInputError):
            load_rttm(malformed)

        reference = self.write("reference.rttm", [self.turn("meeting", 0, 1, "alice")])
        hypothesis = self.write(
            "hypothesis.rttm", [self.turn("other", 0, 1, "local-1")]
        )
        with self.assertRaises(EvaluationInputError):
            evaluate(reference, hypothesis)


if __name__ == "__main__":
    unittest.main()
