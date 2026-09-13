from __future__ import annotations

import collections
import csv
import html
import json
import statistics
from pathlib import Path

import h1_improvement as experiment
import run as core


HERE = Path(__file__).resolve().parent
OUT = HERE / "nano_h1_improved"


def load_raw(directory):
    return [json.loads(path.read_text()) for path in sorted(directory.glob("*.json"))]


def measured_row(sample, method, lines, **extra):
    return {
        "id": sample["id"],
        "language": sample["language"],
        "split": sample["split"],
        "method": method,
        "lines": lines,
        "metrics": core.metrics(sample, lines, "default"),
        **extra,
    }


def tune(rows, samples, bases, method):
    candidates = []
    for reward in [0.5, 1.0, 1.5, 2.0, 2.5]:
        for penalty in [0.5, 1.0, 1.5, 2.0, 3.0, 4.0]:
            measurements = []
            for row in rows:
                sample = samples[row["id"]]
                if row["method"] != method or row["repeat"] != 1 or sample["split"] != "development":
                    continue
                lines = experiment.weighted_dp(
                    sample,
                    bases[sample["id"]],
                    row.get("prefer_cuts", []),
                    row.get("avoid_cuts", []),
                    reward,
                    penalty,
                )
                measurements.append(core.metrics(sample, lines, "default"))
            candidates.append(
                {
                    "reward": reward,
                    "penalty": penalty,
                    "f1_macro": statistics.mean(item["f1"] for item in measurements),
                    "protected_breaks": sum(item["protected_breaks"] for item in measurements),
                    "short": sum(item["short"] for item in measurements),
                }
            )
    candidates.sort(
        key=lambda item: (-item["f1_macro"], item["protected_breaks"], item["short"], item["reward"], item["penalty"])
    )
    return candidates[0], candidates


def tune_projection(rows, samples, bases):
    candidates = []
    for reward in [0.5, 1.0, 1.5, 2.0, 2.5]:
        measurements = []
        for row in rows.values():
            sample = samples[row["id"]]
            if sample["split"] != "development":
                continue
            projected, _ = experiment.project_boundaries(sample["text"], row.get("lines"))
            lines = core.dp(sample, bases[sample["id"]], "default", projected, proposal_reward=reward)
            measurements.append(core.metrics(sample, lines, "default"))
        candidates.append(
            {
                "reward": reward,
                "f1_macro": statistics.mean(item["f1"] for item in measurements),
                "protected_breaks": sum(item["protected_breaks"] for item in measurements),
                "short": sum(item["short"] for item in measurements),
            }
        )
    candidates.sort(key=lambda item: (-item["f1_macro"], item["protected_breaks"], item["short"], item["reward"]))
    return candidates[0], candidates


def tune_guarded_projection(rows, samples, bases):
    candidates = []
    for salvage_reward in [0.25, 0.5, 1.0, 1.5, 2.0]:
        measurements = []
        for row in rows.values():
            sample = samples[row["id"]]
            if sample["split"] != "development":
                continue
            if row["metrics"]["valid"]:
                cuts = core.locate(sample["text"], row["lines"])[0:-1]
                reward = 1.5
            else:
                cuts, _ = experiment.project_boundaries(sample["text"], row.get("lines"))
                reward = salvage_reward
            lines = core.dp(sample, bases[sample["id"]], "default", cuts, proposal_reward=reward)
            measurements.append(core.metrics(sample, lines, "default"))
        candidates.append(
            {
                "salvage_reward": salvage_reward,
                "valid_reward": 1.5,
                "f1_macro": statistics.mean(item["f1"] for item in measurements),
                "protected_breaks": sum(item["protected_breaks"] for item in measurements),
                "short": sum(item["short"] for item in measurements),
            }
        )
    candidates.sort(
        key=lambda item: (
            -item["f1_macro"],
            item["protected_breaks"],
            item["short"],
            item["salvage_reward"],
        )
    )
    return candidates[0], candidates


def summarize(rows):
    metrics = [row["metrics"] for row in rows]
    latencies = [row["latency_s"] for row in rows if row.get("latency_s") is not None]
    input_tokens = sum(row.get("usage", {}).get("input_tokens", 0) for row in rows)
    output_tokens = sum(row.get("usage", {}).get("output_tokens", 0) for row in rows)
    return {
        "n": len(rows),
        "final_valid": sum(item["valid"] for item in metrics),
        "feasible": sum(item["overlong"] == 0 for item in metrics if item["valid"]),
        "f1_macro": statistics.mean(item["f1"] for item in metrics if item["valid"]),
        "protected_breaks": sum(item["protected_breaks"] for item in metrics if item["valid"]),
        "short": sum(item["short"] for item in metrics if item["valid"]),
        "punctuation_starts": sum(item["punctuation_starts"] for item in metrics if item["valid"]),
        "safe_samples": sum(
            item["overlong"] == 0 and item["protected_breaks"] == 0 and item["punctuation_starts"] == 0
            for item in metrics
            if item["valid"]
        ),
        "advice_valid": sum(row.get("advice_valid") is True for row in rows),
        "advice_usable": sum(row.get("advice_usable") is True for row in rows),
        "fallback_count": sum(row.get("fallback") is True for row in rows),
        "changed_text": sum(row.get("advice_error") == "changed_text" for row in rows),
        "latency_median_s": statistics.median(latencies) if latencies else None,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "estimated_cost_usd": input_tokens * 0.05 / 1_000_000 + output_tokens * 0.40 / 1_000_000,
    }


def stability_for(method, raw, samples, bases, tuning=None):
    stable = []
    grouped = collections.defaultdict(list)
    for row in raw:
        if row["method"] == method and samples[row["id"]]["split"] == "development":
            grouped[row["id"]].append(row)
    for sample_id, rows in sorted(grouped.items()):
        rows.sort(key=lambda item: item["repeat"])
        if len(rows) != 3:
            continue
        if method == "H1_nbest_choice":
            advice = [row.get("choice") for row in rows]
            outputs = [tuple(row.get("lines", [])) for row in rows]
        else:
            advice = [
                (tuple(row.get("prefer_cuts", [])), tuple(row.get("avoid_cuts", [])))
                for row in rows
            ]
            outputs = []
            for row in rows:
                sample = samples[sample_id]
                lines = experiment.weighted_dp(
                    sample,
                    bases[sample_id],
                    row.get("prefer_cuts", []),
                    row.get("avoid_cuts", []),
                    tuning["reward"],
                    tuning["penalty"],
                )
                outputs.append(tuple(lines))
        stable.append(
            {
                "id": sample_id,
                "method": method,
                "advice_all_identical": len(set(advice)) == 1,
                "output_all_identical": len(set(outputs)) == 1,
            }
        )
    return stable


def majority_rating_rows(raw, data, bases):
    grouped = collections.defaultdict(list)
    for row in raw:
        if row["method"] == "H1_boundary_ratings":
            grouped[row["id"]].append(row)
    combined = []
    for sample in data:
        rows = sorted(grouped[sample["id"]], key=lambda item: item["repeat"])
        if len(rows) != 3:
            continue
        _, _, _, positions = experiment.rating_request(sample, bases[sample["id"]])
        prefer = []
        avoid = []
        for position in positions:
            labels = []
            for row in rows:
                if position in row.get("prefer_cuts", []):
                    labels.append("prefer")
                elif position in row.get("avoid_cuts", []):
                    labels.append("avoid")
                else:
                    labels.append("neutral")
            counts = collections.Counter(labels)
            label, count = counts.most_common(1)[0]
            if count < 2:
                label = "neutral"
            if label == "prefer":
                prefer.append(position)
            elif label == "avoid":
                avoid.append(position)
        combined.append(
            {
                "id": sample["id"],
                "method": "H1_boundary_vote3",
                "repeat": 1,
                "prefer_cuts": prefer,
                "avoid_cuts": avoid,
                "advice_valid": all(row.get("advice_valid") for row in rows),
                "advice_usable": bool(prefer or avoid),
                "latency_s": max(row.get("latency_s", 0) for row in rows),
                "latency_sequential_s": sum(row.get("latency_s", 0) for row in rows),
                "usage": {
                    "input_tokens": sum(row.get("usage", {}).get("input_tokens", 0) for row in rows),
                    "output_tokens": sum(row.get("usage", {}).get("output_tokens", 0) for row in rows),
                    "reasoning_tokens": sum(row.get("usage", {}).get("reasoning_tokens", 0) for row in rows),
                },
            }
        )
    return combined


def legacy_repeat_stability(label, directory, samples, bases, reward, guarded_tuning):
    grouped = collections.defaultdict(list)
    for row in load_raw(directory):
        if row["method"] == "L1_semantic" and row["budget"] == "default":
            grouped[row["id"]].append(row)
    cases = []
    for sample_id, rows in sorted(grouped.items()):
        if len(rows) < 2:
            continue
        rows.sort(key=lambda item: item["repeat"])
        sample = samples[sample_id]
        strict_outputs = []
        projected_outputs = []
        guarded_outputs = []
        projected_advice = []
        for row in rows:
            valid = row["metrics"]["valid"]
            strict_cuts = core.locate(sample["text"], row["lines"])[0:-1] if valid else []
            strict_outputs.append(
                tuple(core.dp(sample, bases[sample_id], "default", strict_cuts, proposal_reward=1.5))
            )
            projected_cuts, _ = experiment.project_boundaries(sample["text"], row.get("lines"))
            projected_advice.append(tuple(projected_cuts))
            projected_outputs.append(
                tuple(core.dp(sample, bases[sample_id], "default", projected_cuts, proposal_reward=reward))
            )
            guarded_cuts = strict_cuts if valid else projected_cuts
            guarded_reward = guarded_tuning["valid_reward"] if valid else guarded_tuning["salvage_reward"]
            guarded_outputs.append(
                tuple(core.dp(sample, bases[sample_id], "default", guarded_cuts, proposal_reward=guarded_reward))
            )
        cases.append(
            {
                "id": sample_id,
                "reasoning": label,
                "strict_output_identical": len(set(strict_outputs)) == 1,
                "projection_advice_identical": len(set(projected_advice)) == 1,
                "projection_output_identical": len(set(projected_outputs)) == 1,
                "guarded_output_identical": len(set(guarded_outputs)) == 1,
                "valid_model_runs": sum(row["metrics"]["valid"] for row in rows),
                "runs": len(rows),
            }
        )
    return cases


def main():
    data = json.loads((HERE / "dataset.json").read_text())
    samples = {sample["id"]: sample for sample in data}
    baseline_data = json.loads((HERE / "baseline.json").read_text())
    bases = {
        item["id"]: item
        for item in baseline_data
        if item["budget"] == "default"
    }
    improved_raw = load_raw(OUT / "raw")
    first_runs = [row for row in improved_raw if row["repeat"] == 1]
    vote_rows = majority_rating_rows(improved_raw, data, bases)
    old_runs = {}
    for label, directory in [
        ("minimal", HERE / "nano" / "raw"),
        ("low", HERE / "nano_low" / "raw"),
    ]:
        old_runs[label] = {
            row["id"]: row
            for row in load_raw(directory)
            if row["method"] == "L1_semantic" and row["budget"] == "default" and row["repeat"] == 1
        }
    sparse_tuning, sparse_sweep = tune(improved_raw, samples, bases, "H1_sparse_ids")
    rating_tuning, rating_sweep = tune(improved_raw, samples, bases, "H1_boundary_ratings")
    vote_tuning, vote_sweep = tune(vote_rows, samples, bases, "H1_boundary_vote3")
    projection_tuning = {}
    projection_sweep = {}
    guarded_tuning = {}
    guarded_sweep = {}
    for label in ["minimal", "low"]:
        projection_tuning[label], projection_sweep[label] = tune_projection(old_runs[label], samples, bases)
        guarded_tuning[label], guarded_sweep[label] = tune_guarded_projection(old_runs[label], samples, bases)
    (OUT / "tuning.json").write_text(
        json.dumps(
            {
                "H1_sparse_ids": {"selected": sparse_tuning, "sweep": sparse_sweep},
                "H1_boundary_ratings": {"selected": rating_tuning, "sweep": rating_sweep},
                "H1_boundary_vote3": {"selected": vote_tuning, "sweep": vote_sweep},
                "H1_projection_minimal": {
                    "selected": projection_tuning["minimal"],
                    "sweep": projection_sweep["minimal"],
                },
                "H1_projection_low": {
                    "selected": projection_tuning["low"],
                    "sweep": projection_sweep["low"],
                },
                "H1_guarded_projection_minimal": {
                    "selected": guarded_tuning["minimal"],
                    "sweep": guarded_sweep["minimal"],
                },
                "H1_guarded_projection_low": {
                    "selected": guarded_tuning["low"],
                    "sweep": guarded_sweep["low"],
                },
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n"
    )

    result_rows = []
    for sample in data:
        base = bases[sample["id"]]
        result_rows.append(measured_row(sample, "R1_dp", core.dp(sample, base, "default")))

    for label, directory in [
        ("H1_text_minimal", HERE / "nano" / "raw"),
        ("H1_text_low", HERE / "nano_low" / "raw"),
    ]:
        old = old_runs["minimal" if label.endswith("minimal") else "low"]
        for sample in data:
            raw = old[sample["id"]]
            valid = raw["metrics"]["valid"]
            proposed = core.locate(sample["text"], raw["lines"])[0:-1] if valid else []
            lines = core.dp(sample, bases[sample["id"]], "default", proposed, proposal_reward=1.5)
            result_rows.append(
                measured_row(
                    sample,
                    label,
                    lines,
                    advice_valid=valid,
                    advice_usable=valid,
                    advice_error=raw["metrics"].get("error"),
                    fallback=not valid,
                    latency_s=raw.get("latency_s"),
                    usage={
                        "input_tokens": raw.get("usage", {}).get("promptTokenCount", 0),
                        "output_tokens": raw.get("usage", {}).get("candidatesTokenCount", 0),
                    },
                )
            )

    for label in ["minimal", "low"]:
        for sample in data:
            raw = old_runs[label][sample["id"]]
            projected, projection_stats = experiment.project_boundaries(sample["text"], raw.get("lines"))
            lines = core.dp(
                sample,
                bases[sample["id"]],
                "default",
                projected,
                proposal_reward=projection_tuning[label]["reward"],
            )
            result_rows.append(
                measured_row(
                    sample,
                    f"H1_projection_{label}",
                    lines,
                    advice_valid=True,
                    advice_usable=bool(projected),
                    source_advice_valid=raw["metrics"]["valid"],
                    source_advice_error=raw["metrics"].get("error"),
                    fallback=not projected,
                    latency_s=raw.get("latency_s"),
                    usage={
                        "input_tokens": raw.get("usage", {}).get("promptTokenCount", 0),
                        "output_tokens": raw.get("usage", {}).get("candidatesTokenCount", 0),
                    },
                    projection=projection_stats,
                    tuning=projection_tuning[label],
                )
            )

            if raw["metrics"]["valid"]:
                guarded_cuts = core.locate(sample["text"], raw["lines"])[0:-1]
                guarded_reward = guarded_tuning[label]["valid_reward"]
            else:
                guarded_cuts = projected
                guarded_reward = guarded_tuning[label]["salvage_reward"]
            guarded_lines = core.dp(
                sample,
                bases[sample["id"]],
                "default",
                guarded_cuts,
                proposal_reward=guarded_reward,
            )
            result_rows.append(
                measured_row(
                    sample,
                    f"H1_guarded_projection_{label}",
                    guarded_lines,
                    advice_valid=True,
                    advice_usable=bool(guarded_cuts),
                    source_advice_valid=raw["metrics"]["valid"],
                    source_advice_error=raw["metrics"].get("error"),
                    fallback=not guarded_cuts,
                    latency_s=raw.get("latency_s"),
                    usage={
                        "input_tokens": raw.get("usage", {}).get("promptTokenCount", 0),
                        "output_tokens": raw.get("usage", {}).get("candidatesTokenCount", 0),
                    },
                    projection=projection_stats,
                    tuning=guarded_tuning[label],
                )
            )

    for raw in first_runs:
        sample = samples[raw["id"]]
        base = bases[raw["id"]]
        common = {
            "advice_valid": raw["advice_valid"],
            "advice_usable": raw["advice_usable"],
            "advice_error": raw.get("error"),
            "fallback": not raw["advice_usable"],
            "latency_s": raw.get("latency_s"),
            "usage": raw.get("usage", {}),
        }
        if raw["method"] == "H1_nbest_choice":
            result_rows.append(measured_row(sample, raw["method"], raw["lines"], **common))
            oracle = max(
                (option["lines"] for option in raw["options"]),
                key=lambda lines: core.metrics(sample, lines, "default")["f1"],
            )
            result_rows.append(measured_row(sample, "H1_nbest_oracle", oracle))
        else:
            tuning = sparse_tuning if raw["method"] == "H1_sparse_ids" else rating_tuning
            lines = experiment.weighted_dp(
                sample,
                base,
                raw.get("prefer_cuts", []),
                raw.get("avoid_cuts", []),
                tuning["reward"],
                tuning["penalty"],
            )
            result_rows.append(measured_row(sample, raw["method"], lines, tuning=tuning, **common))

    for raw in vote_rows:
        sample = samples[raw["id"]]
        lines = experiment.weighted_dp(
            sample,
            bases[raw["id"]],
            raw["prefer_cuts"],
            raw["avoid_cuts"],
            vote_tuning["reward"],
            vote_tuning["penalty"],
        )
        result_rows.append(
            measured_row(
                sample,
                raw["method"],
                lines,
                advice_valid=raw["advice_valid"],
                advice_usable=raw["advice_usable"],
                fallback=not raw["advice_usable"],
                latency_s=raw["latency_s"],
                latency_sequential_s=raw["latency_sequential_s"],
                usage=raw["usage"],
                tuning=vote_tuning,
            )
        )

    result_rows.sort(key=lambda row: (row["id"], row["method"]))
    (OUT / "results.json").write_text(json.dumps(result_rows, ensure_ascii=False, indent=2) + "\n")
    grouped = collections.defaultdict(list)
    for row in result_rows:
        for split in [row["split"], "ALL"]:
            for language in [row["language"], "ALL"]:
                grouped[row["method"], split, language].append(row)
    summaries = [
        {"method": key[0], "split": key[1], "language": key[2], **summarize(rows)}
        for key, rows in sorted(grouped.items())
    ]
    (OUT / "summary.json").write_text(json.dumps(summaries, ensure_ascii=False, indent=2) + "\n")
    with (OUT / "summary.csv").open("w") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(summaries[0]))
        writer.writeheader()
        writer.writerows(summaries)

    stability = []
    stability.extend(stability_for("H1_sparse_ids", improved_raw, samples, bases, sparse_tuning))
    stability.extend(stability_for("H1_boundary_ratings", improved_raw, samples, bases, rating_tuning))
    stability.extend(stability_for("H1_nbest_choice", improved_raw, samples, bases))
    (OUT / "stability.json").write_text(json.dumps(stability, indent=2) + "\n")
    legacy_stability = []
    for label, directory in [("minimal", HERE / "nano" / "raw"), ("low", HERE / "nano_low" / "raw")]:
        legacy_stability.extend(
            legacy_repeat_stability(
                label,
                directory,
                samples,
                bases,
                projection_tuning[label]["reward"],
                guarded_tuning[label],
            )
        )
    (OUT / "legacy_repeat_stability.json").write_text(json.dumps(legacy_stability, indent=2) + "\n")

    shown_methods = [
        "R1_dp",
        "H1_text_minimal",
        "H1_text_low",
        "H1_projection_minimal",
        "H1_projection_low",
        "H1_guarded_projection_minimal",
        "H1_guarded_projection_low",
        "H1_sparse_ids",
        "H1_nbest_choice",
        "H1_boundary_ratings",
        "H1_boundary_vote3",
        "H1_nbest_oracle",
    ]
    page = [
        '<!doctype html><html lang="zh-CN"><meta charset="utf-8">',
        "<title>H1 改进实验</title>",
        "<style>body{font:16px system-ui;max-width:1500px;margin:40px auto;padding:0 24px;background:#f7f7f8;color:#182033}select{font:inherit;padding:8px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(330px,1fr));gap:14px}section{margin:32px 0}article{background:white;padding:16px;border:1px solid #d7dce5;border-radius:10px}li{margin:7px 0}.meta{color:#5d6677}.bad{color:#a12619}pre{white-space:pre-wrap}</style>",
        "<h1>GPT-5 nano：H1 稳定前置协议</h1>",
        "<p>固定模型快照与 minimal reasoning；development 仅用于选择 DP 奖惩权重，evaluation 用于最终比较。Oracle 只表示 n-best 候选上限。</p>",
        '<label>样本 <select id="pick"><option value="">全部</option>',
    ]
    for sample in data:
        page.append(f'<option value="{sample["id"]}">{sample["id"]} · {html.escape(sample["topic"])}</option>')
    page.append("</select></label>")
    for sample in data:
        page.append(
            f'<section id="{sample["id"]}"><h2>{sample["id"]} · {html.escape(sample["topic"])}</h2>'
            f'<pre>{html.escape(sample["text"])}</pre><div class="grid">'
        )
        by_method = {row["method"]: row for row in result_rows if row["id"] == sample["id"]}
        for method in shown_methods:
            row = by_method[method]
            metric = row["metrics"]
            advice = "—" if row.get("advice_valid") is None else ("有效" if row.get("advice_usable") else "降级")
            page.append(
                f'<article><h3>{method}</h3><p class="meta">F1 {metric["f1"]:.3f} · '
                f'保护断裂 {metric["protected_breaks"]} · 短 cue {metric["short"]} · 建议 {advice}</p><ol>'
            )
            for line in row["lines"]:
                page.append(f"<li>{html.escape(line)}</li>")
            page.append("</ol></article>")
        page.append("</div></section>")
    page.append(
        '<script>document.querySelector("#pick").addEventListener("change",e=>document.querySelectorAll("section").forEach(s=>s.hidden=!!e.target.value&&s.id!==e.target.value));</script></html>'
    )
    (OUT / "comparison.html").write_text("".join(page))
    selected = [row for row in summaries if row["language"] == "ALL" and row["split"] in ["ALL", "evaluation"]]
    print(
        json.dumps(
            {
                "tuning": {
                    "sparse": sparse_tuning,
                    "ratings": rating_tuning,
                    "vote3": vote_tuning,
                    "projection_minimal": projection_tuning["minimal"],
                    "projection_low": projection_tuning["low"],
                    "guarded_projection_minimal": guarded_tuning["minimal"],
                    "guarded_projection_low": guarded_tuning["low"],
                },
                "summary": selected,
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
