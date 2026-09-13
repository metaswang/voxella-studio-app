import json
import unittest

import h1_improvement as experiment
import run as core


class H1ImprovementTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.samples = json.loads((experiment.HERE / "dataset.json").read_text())
        baselines = json.loads((experiment.HERE / "baseline.json").read_text())
        cls.bases = {(item["id"], item["budget"]): item for item in baselines}

    def test_every_rerank_option_is_exact_and_length_feasible(self):
        for sample in self.samples:
            base = self.bases[sample["id"], "default"]
            options = experiment.segmentation_options(sample, base)
            self.assertGreaterEqual(len(options), 2, sample["id"])
            for option in options:
                measured = core.metrics(sample, option["lines"], "default")
                self.assertTrue(measured["valid"], sample["id"])
                self.assertEqual(measured["overlong"], 0, sample["id"])

    def test_boundary_schema_cannot_return_text(self):
        sample = self.samples[0]
        base = self.bases[sample["id"], "default"]
        _, _, schema, cuts = experiment.boundary_request(sample, base)
        self.assertEqual(set(schema["properties"]), {"prefer", "avoid"})
        self.assertNotIn("lines", schema["properties"])
        self.assertEqual(schema["properties"]["prefer"]["items"]["enum"], list(range(1, len(cuts) - 1)))

    def test_rating_schema_requires_one_closed_label_per_boundary(self):
        sample = next(item for item in self.samples if item["id"] == "zh-Hans-01")
        base = self.bases[sample["id"], "default"]
        _, _, schema, positions = experiment.rating_request(sample, base)
        self.assertEqual(len(schema["required"]), len(positions))
        self.assertEqual(set(schema["required"]), set(schema["properties"]))
        self.assertTrue(
            all(value["enum"] == ["prefer", "neutral", "avoid"] for value in schema["properties"].values())
        )

    def test_weighted_dp_ignores_text_generation(self):
        sample = next(item for item in self.samples if item["id"] == "zh-Hans-01")
        base = self.bases[sample["id"], "default"]
        cuts = core.candidates(sample, base)
        lines = experiment.weighted_dp(sample, base, prefer=cuts[2:4], avoid=cuts[4:6])
        measured = core.metrics(sample, lines, "default")
        self.assertTrue(measured["valid"])
        self.assertEqual(measured["overlong"], 0)

    def test_projection_recovers_exact_boundaries_after_omission(self):
        text = "第一句。被遗漏的内容。第三句。"
        cuts, stats = experiment.project_boundaries(text, ["第一句。", "第三句。"])
        self.assertEqual(cuts, [4])
        self.assertEqual(stats, {"matched_lines": 2, "skipped_lines": 0, "resyncs": 1})

    def test_projection_skips_changed_lines(self):
        cuts, stats = experiment.project_boundaries("重复。中间。重复。", ["重复。", "改写。", "重复。"])
        self.assertEqual(cuts, [3])
        self.assertEqual(stats["skipped_lines"], 1)

    def test_jobs_use_fixed_model_and_hold_repeats_to_development(self):
        work = experiment.jobs()
        self.assertEqual(experiment.MODEL, "gpt-5-nano-2025-08-07")
        self.assertEqual(experiment.REASONING, "minimal")
        self.assertEqual(len(work), 377)
        self.assertTrue(
            all(
                method == "H1_boundary_ratings" or sample["split"] == "development"
                for sample, _, method, repeat in work
                if repeat > 1
            )
        )


if __name__ == "__main__":
    unittest.main()
