#!/usr/bin/env python3
"""Summarize evidence retrieval; never infer answer or skill-ablation quality."""
import argparse
import collections
import json
import math
from pathlib import Path
import statistics


def summarize(report):
    results = report["results"]
    identities = [(row["variant"], row["case_id"]) for row in results]
    if len(set(identities)) != len(identities):
        raise ValueError("Duplicate case/variant results")
    for row in results:
        for name in ("recall_at_8", "ndcg_at_8"):
            value = row[name]
            if not math.isfinite(value) or not 0 <= value <= 1:
                raise ValueError(f"Invalid {name}: {row['case_id']}")
        if not math.isfinite(row["latency_ms"]) or row["latency_ms"] < 0:
            raise ValueError("Invalid latency")
    variants = {}
    for variant in sorted({row["variant"] for row in results}):
        sections = {}
        for group, rows in (
            ("gold", [r for r in results if r["variant"] == variant and r["category"] != "language_probe"]),
            ("language_probes", [r for r in results if r["variant"] == variant and r["category"] == "language_probe"]),
        ):
            latency = sorted(row["latency_ms"] for row in rows)
            sections[group] = {
                "cases": len(rows),
                "mean_recall_at_8": statistics.mean(r["recall_at_8"] for r in rows) if rows else None,
                "mean_ndcg_at_8": statistics.mean(r["ndcg_at_8"] for r in rows) if rows else None,
                "latency_p50_ms": statistics.median(latency) if latency else None,
                "latency_p95_ms": latency[math.ceil(.95 * len(latency)) - 1] if latency else None,
                "scope_violations": sum(not r["scope_valid"] for r in rows),
                "reranker_status": dict(collections.Counter(r["reranker"] for r in rows)),
                "incomplete_evidence_cases": [r["case_id"] for r in rows if r["recall_at_8"] < 1],
            }
        variants[variant] = sections
    return {
        "corpus": report["corpus"], "annotation_origin": report["annotation_origin"],
        "gold_cases": report["gold_cases"], "result_limit": report["result_limit"],
        "embedding_model": report["embedding_model"], "embedding_dimension": report["embedding_dimension"],
        "rerank_budget_seconds": report["rerank_budget_seconds"],
        "percentile_method": "nearest_rank",
        "answer_model_metrics_measured": report["answer_model_metrics_measured"],
        "method_ablations_measured": report["method_ablations_measured"],
        "media_metrics_measured": report["media_metrics_measured"],
        "cost_usd": None, "variants": variants,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    data = json.dumps(summarize(json.loads(args.report.read_text())), ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(data)
    else:
        print(data, end="")
