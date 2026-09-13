import collections
import json

import h1_improvement as experiment
import run as core


def main():
    samples = {
        sample["id"]: sample
        for sample in json.loads((experiment.HERE / "dataset.json").read_text())
    }
    raw = [json.loads(path.read_text()) for path in sorted(experiment.RAW.glob("*.json"))]
    assert len(raw) == 377
    counts = collections.Counter((row["method"], row["repeat"]) for row in raw)
    assert counts == {
        ("H1_sparse_ids", 1): 65,
        ("H1_sparse_ids", 2): 13,
        ("H1_sparse_ids", 3): 13,
        ("H1_nbest_choice", 1): 65,
        ("H1_nbest_choice", 2): 13,
        ("H1_nbest_choice", 3): 13,
        ("H1_boundary_ratings", 1): 65,
        ("H1_boundary_ratings", 2): 65,
        ("H1_boundary_ratings", 3): 65,
    }
    assert all(row["requested_model"] == experiment.MODEL for row in raw)
    assert all(row["reasoning_effort"] == experiment.REASONING for row in raw)
    assert all(row["advice_valid"] for row in raw)
    results = json.loads((experiment.OUT / "results.json").read_text())
    for row in results:
        measured = core.metrics(samples[row["id"]], row["lines"], "default")
        assert measured["valid"]
        assert measured["overlong"] == 0
    print(
        json.dumps(
            {
                "raw_receipts": len(raw),
                "strict_schema_valid": sum(row["advice_valid"] for row in raw),
                "result_rows": len(results),
                "all_results_exact": True,
                "all_results_length_feasible": True,
            }
        )
    )


if __name__ == "__main__":
    main()
