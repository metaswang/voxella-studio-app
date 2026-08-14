#!/usr/bin/env python3
"""Create a deterministic, locally runnable MTEB retrieval subset suite."""

from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from datasets import get_dataset_split_names, load_dataset


SEED = 20260811


@dataclass(frozen=True)
class DatasetSpec:
    name: str
    category: str
    path: str
    revision: str
    split: str
    corpus_config: str
    queries_config: str
    qrels_config: str
    instruction: str
    maximum_queries: int
    corpus_size: int
    query_language: str
    document_language: str
    mixed_with_queries_config: str | None = None


SPECS = [
    DatasetSpec(
        name="T2Retrieval-zh",
        category="Chinese retrieval",
        path="mteb/T2Retrieval",
        revision="cf778c0ea4168ec5174a34d888d6453e4cde9222",
        split="dev",
        corpus_config="corpus",
        queries_config="queries",
        qrels_config="default",
        instruction="Given a Chinese search query, retrieve web passages that answer the question",
        maximum_queries=200,
        corpus_size=8_000,
        query_language="Chinese",
        document_language="Chinese",
    ),
    DatasetSpec(
        name="NFCorpus-en",
        category="English retrieval",
        path="mteb/nfcorpus",
        revision="ec0fa4fe99da2ff19ca1214b7966684033a58814",
        split="test",
        corpus_config="corpus",
        queries_config="queries",
        qrels_config="default",
        instruction="Given a question, retrieve relevant documents that best answer the question",
        maximum_queries=200,
        corpus_size=3_000,
        query_language="English",
        document_language="English",
    ),
    DatasetSpec(
        name="MultilingualNanoNFCorpus-en-ja-ko",
        category="Multilingual retrieval",
        path="mteb/MultilingualNanoNFCorpusRetrieval",
        revision="4484b487f178125827f7dda052f1b2f5673548d6",
        split="test",
        corpus_config="en-corpus",
        queries_config="en-queries",
        qrels_config="en-qrels",
        instruction="Given a question, retrieve relevant documents that best answer the question",
        maximum_queries=150,
        corpus_size=1_000,
        query_language="English, Japanese, Korean",
        document_language="English, Japanese, Korean",
    ),
    DatasetSpec(
        name="MLQA-zho-eng",
        category="Chinese-to-English cross-lingual retrieval",
        path="mteb/MLQARetrieval",
        revision="5bef8b6e2601af974fb1a1cca03fd702229be4b6",
        split="test",
        corpus_config="zho-eng-corpus",
        queries_config="zho-eng-queries",
        qrels_config="zho-eng-qrels",
        instruction="Given a Chinese question, retrieve English passages that answer the question",
        maximum_queries=200,
        corpus_size=3_000,
        query_language="Chinese",
        document_language="English",
        mixed_with_queries_config="eng-eng-queries",
    ),
    DatasetSpec(
        name="LEMBQMSumRetrieval-en",
        category="Long-document retrieval",
        path="dwzhu/LongEmbed",
        revision="6e346642246bfb4928c560ee08640dc84d074e8c",
        split="test",
        corpus_config="qmsum::corpus",
        queries_config="qmsum::queries",
        qrels_config="qmsum::qrels",
        instruction="Given a question, retrieve the long document that contains its answer",
        maximum_queries=120,
        corpus_size=1_500,
        query_language="English",
        document_language="English",
    ),
]


def hash_rank(value: str) -> bytes:
    return hashlib.sha256(f"{SEED}:{value}".encode()).digest()


def read_rows(spec: DatasetSpec, config: str) -> list[dict[str, Any]]:
    config, separator, explicit_split = config.partition("::")
    splits = get_dataset_split_names(
        spec.path,
        config_name=config,
        revision=spec.revision,
    )
    split = explicit_split if separator else (spec.split if spec.split in splits else (splits[0] if len(splits) == 1 else None))
    if split is None:
        raise RuntimeError(f"{spec.name}: {config} does not include split {spec.split}: {splits}")
    return list(
        load_dataset(
            spec.path,
            name=config,
            split=split,
            revision=spec.revision,
        )
    )


def normalize_document(row: dict[str, Any]) -> dict[str, str]:
    identifier = str(row.get("id", row.get("_id", row.get("doc_id"))))
    title = str(row.get("title") or "").strip()
    text = str(row.get("text") or row.get("contents") or "").strip()
    return {"id": identifier, "text": f"{title}\n{text}".strip()}


def normalize_query(row: dict[str, Any]) -> dict[str, str]:
    return {
        "id": str(row.get("id", row.get("_id", row.get("qid")))),
        "text": str(row.get("text", row.get("query", ""))).strip(),
    }


def normalize_qrel(row: dict[str, Any]) -> tuple[str, str, int]:
    if "query-id" not in row:
        return str(row["qid"]), str(row["doc_id"]), 1
    return (
        str(row["query-id"]),
        str(row["corpus-id"]),
        int(row["score"]),
    )


def prepare_single(spec: DatasetSpec, output: Path) -> dict[str, Any]:
    queries = [normalize_query(row) for row in read_rows(spec, spec.queries_config)]
    qrels = [normalize_qrel(row) for row in read_rows(spec, spec.qrels_config)]
    qrels_by_query: dict[str, dict[str, int]] = {}
    for query_id, corpus_id, score in qrels:
        if score > 0:
            qrels_by_query.setdefault(query_id, {})[corpus_id] = score

    selected_queries = [query for query in queries if query["id"] in qrels_by_query]
    selected_queries.sort(key=lambda query: hash_rank(query["id"]))
    selected_queries = selected_queries[: spec.maximum_queries]
    selected_query_ids = {query["id"] for query in selected_queries}
    selected_qrels = {
        query_id: qrels_by_query[query_id]
        for query_id in selected_query_ids
    }
    positive_ids = {doc_id for qrels in selected_qrels.values() for doc_id in qrels}

    corpus = [normalize_document(row) for row in read_rows(spec, spec.corpus_config)]
    corpus_by_id = {document["id"]: document for document in corpus}
    missing = positive_ids - corpus_by_id.keys()
    if missing:
        raise RuntimeError(f"{spec.name}: {len(missing)} relevant documents are absent")

    remaining = max(spec.corpus_size - len(positive_ids), 0)
    negatives = [document for document in corpus if document["id"] not in positive_ids]
    negatives.sort(key=lambda document: hash_rank(document["id"]))
    selected_documents = [corpus_by_id[doc_id] for doc_id in sorted(positive_ids)]
    selected_documents.extend(negatives[:remaining])
    selected_documents.sort(key=lambda document: document["id"])

    payload = {
        "name": spec.name,
        "category": spec.category,
        "source": {"path": spec.path, "revision": spec.revision, "split": spec.split},
        "instruction": spec.instruction,
        "query_language": spec.query_language,
        "document_language": spec.document_language,
        "queries": selected_queries,
        "documents": selected_documents,
        "qrels": selected_qrels,
    }
    if spec.mixed_with_queries_config:
        parallel = {
            query["id"]: query["text"]
            for query in [normalize_query(row) for row in read_rows(spec, spec.mixed_with_queries_config)]
        }
        mixed_queries = []
        for query in selected_queries:
            english = parallel.get(query["id"])
            if english:
                mixed_queries.append({
                    "id": query["id"],
                    "text": f"中文：{query['text']}\nEnglish: {english}",
                })
        if len(mixed_queries) < len(selected_queries):
            raise RuntimeError(f"{spec.name}: parallel English queries are incomplete")
        mixed_payload = payload | {
            "name": "MLQA-zho-eng-mixed-query",
            "category": "Chinese-English mixed query retrieval (derived)",
            "instruction": "Given a Chinese-English mixed question, retrieve English passages that answer the question",
            "query_language": "Chinese-English mixed",
            "queries": mixed_queries,
        }
        (output / "MLQA-zho-eng-mixed-query.json").write_text(
            json.dumps(mixed_payload, ensure_ascii=False), encoding="utf-8"
        )

    destination = output / f"{spec.name}.json"
    destination.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    return {
        "name": spec.name,
        "file": destination.name,
        "queries": len(selected_queries),
        "documents": len(selected_documents),
        "relevant_documents": len(positive_ids),
    }


def prepare_multilingual(output: Path) -> dict[str, Any]:
    base = next(spec for spec in SPECS if spec.name.startswith("Multilingual"))
    languages = ["en", "ja", "ko"]
    combined_queries: list[dict[str, str]] = []
    combined_documents: list[dict[str, str]] = []
    combined_qrels: dict[str, dict[str, int]] = {}
    for language in languages:
        spec = DatasetSpec(
            **(base.__dict__ | {
                "corpus_config": f"{language}-corpus",
                "queries_config": f"{language}-queries",
                "qrels_config": f"{language}-qrels",
                "query_language": language,
                "document_language": language,
            })
        )
        queries = [normalize_query(row) for row in read_rows(spec, spec.queries_config)]
        qrels = [normalize_qrel(row) for row in read_rows(spec, spec.qrels_config)]
        relevant = {
            query_id: {} for query_id, _, score in qrels if score > 0
        }
        for query_id, document_id, score in qrels:
            if score > 0:
                relevant[query_id][document_id] = score
        selected = [query for query in queries if query["id"] in relevant]
        selected.sort(key=lambda query: hash_rank(f"{language}:{query['id']}"))
        selected = selected[:base.maximum_queries]
        ids = {query["id"] for query in selected}
        positives = {doc_id for query_id in ids for doc_id in relevant[query_id]}
        corpus = [normalize_document(row) for row in read_rows(spec, spec.corpus_config)]
        corpus_by_id = {document["id"]: document for document in corpus}
        negatives = [document for document in corpus if document["id"] not in positives]
        negatives.sort(key=lambda document: hash_rank(f"{language}:{document['id']}"))
        documents = [corpus_by_id[document_id] for document_id in sorted(positives)]
        documents.extend(negatives[:max(base.corpus_size - len(positives), 0)])
        for query in selected:
            new_id = f"{language}:{query['id']}"
            combined_queries.append({"id": new_id, "text": query["text"]})
            combined_qrels[new_id] = {f"{language}:{doc_id}": score for doc_id, score in relevant[query["id"]].items()}
        combined_documents.extend({"id": f"{language}:{doc['id']}", "text": doc["text"]} for doc in documents)

    payload = {
        "name": base.name,
        "category": base.category,
        "source": {"path": base.path, "revision": base.revision, "split": base.split, "languages": languages},
        "instruction": base.instruction,
        "query_language": base.query_language,
        "document_language": base.document_language,
        "queries": sorted(combined_queries, key=lambda row: row["id"]),
        "documents": sorted(combined_documents, key=lambda row: row["id"]),
        "qrels": combined_qrels,
    }
    destination = output / f"{base.name}.json"
    destination.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    return {
        "name": base.name,
        "file": destination.name,
        "queries": len(combined_queries),
        "documents": len(combined_documents),
        "relevant_documents": sum(len(qrels) for qrels in combined_qrels.values()),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = {"seed": SEED, "datasets": []}
    for spec in SPECS:
        if spec.name.startswith("Multilingual"):
            manifest["datasets"].append(prepare_multilingual(args.output))
        else:
            manifest["datasets"].append(prepare_single(spec, args.output))
    manifest["datasets"].append({
        "name": "MLQA-zho-eng-mixed-query",
        "file": "MLQA-zho-eng-mixed-query.json",
        "derived_from": "MLQA-zho-eng",
    })
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
