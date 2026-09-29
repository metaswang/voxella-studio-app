#!/usr/bin/env python3
"""Summarize reviewed KB QA runs; never impute unmeasured metrics.

Input JSONL: case_id, variant (B0..B4), model, budget_id, metrics.
Supported metrics: citation_precision, coverage, false_refusal,
source_omissions, first_grounded_answer_ms, total_latency_ms,
input_tokens, output_tokens, cost_usd. Null/missing means unmeasured.
Variants are compared only within the same case/model/budget_id.
"""
import argparse
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path

METRICS = (
    "citation_precision", "coverage", "false_refusal", "source_omissions",
    "first_grounded_answer_ms", "total_latency_ms", "input_tokens",
    "output_tokens", "cost_usd",
)


def summarize(path):
    groups = defaultdict(list)
    cohorts = defaultdict(set)
    seen = set()
    for line_no, line in enumerate(Path(path).read_text().splitlines(), 1):
        if not line.strip():
            continue
        row = json.loads(line)
        for key in ("case_id", "variant", "model", "budget_id"):
            if not isinstance(row.get(key), str) or not row[key]:
                raise ValueError(f"line {line_no}: {key} must be a nonempty string")
        if row["variant"] not in {f"B{i}" for i in range(5)}:
            raise ValueError(f"line {line_no}: variant must be B0..B4")
        cohort = (row["case_id"], row["model"], row["budget_id"])
        identity = (*cohort, row["variant"])
        if identity in seen:
            raise ValueError(f"line {line_no}: duplicate case/model/budget/variant")
        seen.add(identity)
        metrics = row.get("metrics", {})
        if not isinstance(metrics, dict):
            raise ValueError(f"line {line_no}: metrics must be an object")
        for key, value in metrics.items():
            if key not in METRICS:
                raise ValueError(f"line {line_no}: unknown metric {key}")
            if value is not None and (not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0):
                raise ValueError(f"line {line_no}: {key} must be nonnegative or null")
            if value is not None and key in ("citation_precision", "coverage", "false_refusal") and value > 1:
                raise ValueError(f"line {line_no}: {key} must be in 0..1")
        groups[(row["model"], row["budget_id"], row["variant"])].append(row)
        cohorts[cohort].add(row["variant"])
    results = []
    for (model, budget, variant), rows in sorted(groups.items()):
        measured = {}
        for metric in METRICS:
            values = [r["metrics"][metric] for r in rows if r.get("metrics", {}).get(metric) is not None]
            measured[metric] = {"measured": len(values), "unmeasured": len(rows) - len(values),
                                "mean": statistics.mean(values) if values else None}
        results.append({"model": model, "budget_id": budget, "variant": variant,
                        "cases": len(rows), "metrics": measured})
    # Paired differences use only measured pairs from the same cohort; an
    # unpaired overall mean is descriptive and cannot establish improvement.
    paired = []
    indexed = {}
    for rows in groups.values():
        for row in rows:
            indexed[(row["case_id"], row["model"], row["budget_id"], row["variant"])] = row
    for baseline, treatment in zip(("B0", "B1", "B2", "B3"), ("B1", "B2", "B3", "B4")):
        deltas = defaultdict(list)
        for cohort, variants in cohorts.items():
            if not {baseline, treatment} <= variants:
                continue
            a, b = indexed[(*cohort, baseline)], indexed[(*cohort, treatment)]
            for metric in METRICS:
                av, bv = a.get("metrics", {}).get(metric), b.get("metrics", {}).get(metric)
                if av is not None and bv is not None:
                    deltas[(cohort[1], cohort[2], metric)].append(bv - av)
        for (model, budget, metric), values in sorted(deltas.items()):
            paired.append({"baseline": baseline, "treatment": treatment, "model": model,
                           "budget_id": budget, "metric": metric, "paired_cases": len(values),
                           "mean_treatment_minus_baseline": statistics.mean(values)})
    return {"descriptive_results": results, "paired_comparisons": paired,
            "cohorts_without_comparison": sum(len(v) < 2 for v in cohorts.values())}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results_jsonl")
    args = parser.parse_args()
    try:
        print(json.dumps(summarize(args.results_jsonl), ensure_ascii=False, indent=2))
    except (ValueError, OSError, KeyError) as error:
        parser.exit(2, f"Invalid evaluation input: {error}\n")
