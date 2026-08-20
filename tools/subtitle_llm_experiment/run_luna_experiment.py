#!/usr/bin/env python3
"""Run independent gpt-5.6-luna experiments for ASR post-processing."""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import difflib
import json
import math
import os
import re
import statistics
import sys
import time
import unicodedata
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Iterable


MODEL = "gpt-5.6-luna"
DEFAULT_ENDPOINT = "https://api.openai.com/v1/chat/completions"
PAUSE_THRESHOLD_SECONDS = 0.25
MAX_LINE_CHARACTERS = 18
PREFERRED_LINE_CHARACTERS = 16
MINIMUM_LINE_CHARACTERS = 8
CJK_PUNCTUATION = frozenset("，。？！")
LATIN_PUNCTUATION = frozenset(",.?!")
BOUND_PARTICLES = frozenset("的地得了着过们の의")
CONDITION_NAMES = ("C1", "C2", "C3", "C4", "C5")


class ExperimentError(RuntimeError):
    """Raised when the independent experiment cannot produce a valid result."""


@dataclasses.dataclass(frozen=True)
class Word:
    word_id: int
    text: str
    start: float
    end: float
    pause_after: float | None


@dataclasses.dataclass(frozen=True)
class Sample:
    sample_id: str
    speaker: str
    language: str
    words: tuple[Word, ...]
    context_before: str | None
    context_after: str | None

    @property
    def source_text(self) -> str:
        return join_text((word.text for word in self.words), self.language)

    @property
    def pause_ids(self) -> tuple[int, ...]:
        return tuple(
            word.word_id
            for word in self.words
            if word.pause_after is not None and word.pause_after >= PAUSE_THRESHOLD_SECONDS
        )


@dataclasses.dataclass(frozen=True)
class RequestResult:
    request_path: str
    parsed: Any | None
    raw: str | None
    error: str | None


class LunaClient:
    def __init__(
        self,
        api_key: str,
        endpoint: str = DEFAULT_ENDPOINT,
        timeout_seconds: float = 180.0,
        max_attempts: int = 2,
        retry_delay_seconds: float = 1.5,
    ) -> None:
        if not api_key.strip():
            raise ExperimentError("The API key is empty.")
        self.api_key = api_key
        self.endpoint = endpoint
        self.timeout_seconds = timeout_seconds
        self.max_attempts = max(1, max_attempts)
        self.retry_delay_seconds = max(0.0, retry_delay_seconds)

    def complete(self, system: str, user: str) -> str:
        payload = {
            "model": MODEL,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        }
        request = urllib.request.Request(
            self.endpoint,
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            method="POST",
        )
        last_error: Exception | None = None
        for attempt in range(1, self.max_attempts + 1):
            try:
                with urllib.request.urlopen(
                    request,
                    timeout=self.timeout_seconds,
                ) as response:
                    body = json.loads(response.read().decode("utf-8"))
                content = body["choices"][0]["message"]["content"]
                if isinstance(content, list):
                    content = "".join(
                        part.get("text", "")
                        for part in content
                        if isinstance(part, dict)
                    )
                if not isinstance(content, str) or not content.strip():
                    raise ExperimentError("The model returned empty content.")
                return content
            except urllib.error.HTTPError as error:
                detail = error.read().decode("utf-8", errors="replace")[:800]
                last_error = ExperimentError(
                    f"HTTP {error.code}: {detail}"
                )
            except (urllib.error.URLError, TimeoutError, OSError, KeyError, IndexError) as error:
                last_error = ExperimentError(str(error))
            except json.JSONDecodeError as error:
                last_error = ExperimentError(f"Invalid provider JSON: {error}")
            if attempt < self.max_attempts:
                time.sleep(self.retry_delay_seconds * attempt)
        raise ExperimentError(str(last_error or "LLM request failed."))


def parse_json_response(raw: str) -> Any:
    """Match the app's tolerant JSON extraction without importing app code."""
    text = raw.strip()
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.IGNORECASE | re.DOTALL)
    candidates: list[str] = [text]
    candidates.extend(
        match.group(1).strip()
        for match in re.finditer(
            r"```(?:json)?\s*([\s\S]*?)```",
            text,
            flags=re.IGNORECASE,
        )
    )
    for opening, closing in (("{", "}"), ("[", "]")):
        start = text.find(opening)
        end = text.rfind(closing)
        if start >= 0 and end > start:
            candidates.append(text[start : end + 1])
    seen: set[str] = set()
    errors: list[str] = []
    for candidate in candidates:
        if candidate in seen or not candidate:
            continue
        seen.add(candidate)
        try:
            return json.loads(candidate)
        except json.JSONDecodeError as error:
            errors.append(str(error))
    raise ExperimentError(
        "Could not extract JSON from model output: "
        + (errors[-1] if errors else "empty response")
    )


def load_samples(workbench_path: Path, task_id: str) -> tuple[str, list[Sample]]:
    try:
        root = json.loads(workbench_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ExperimentError(f"Could not load workbench data: {error}") from error

    jobs = root.get("transcriptions", [])
    job = next(
        (
            item
            for item in jobs
            if str(item.get("id", "")).casefold() == task_id.casefold()
        ),
        None,
    )
    if not isinstance(job, dict):
        raise ExperimentError(f"Task {task_id} was not found.")

    result = job.get("result") or {}
    language = str(
        result.get("language")
        or job.get("languageCode")
        or "unknown"
    )
    raw_words = result.get("words") or []
    ordered_words: list[tuple[str, float, float, str]] = []
    for raw_word in raw_words:
        if not isinstance(raw_word, dict):
            continue
        text = str(raw_word.get("text") or "").strip()
        start = finite_float(raw_word.get("start"))
        end = finite_float(raw_word.get("end"))
        if not text or start is None or end is None or end <= start:
            continue
        speaker = str(raw_word.get("speaker") or "Unknown").strip() or "Unknown"
        ordered_words.append((text, start, end, speaker))
    if not ordered_words:
        raise ExperimentError("The task has no usable timed words.")

    runs: list[list[tuple[str, float, float, str]]] = []
    for item in ordered_words:
        if not runs or runs[-1][0][3] != item[3]:
            runs.append([])
        runs[-1].append(item)

    samples: list[Sample] = []
    for run_index, run in enumerate(runs, start=1):
        speaker = run[0][3]
        words: list[Word] = []
        for local_id, (text, start, end, _) in enumerate(run):
            next_start = run[local_id + 1][1] if local_id + 1 < len(run) else None
            pause = (
                max(0.0, next_start - end)
                if next_start is not None
                else None
            )
            words.append(
                Word(
                    word_id=local_id,
                    text=text,
                    start=start,
                    end=end,
                    pause_after=pause,
                )
            )
        samples.append(
            Sample(
                sample_id=f"run_{run_index}_{slug(speaker)}",
                speaker=speaker,
                language=language,
                words=tuple(words),
                context_before=join_text(
                    (item[0] for item in runs[run_index - 2]),
                    language,
                )
                if run_index > 1
                else None,
                context_after=join_text(
                    (item[0] for item in runs[run_index]),
                    language,
                )
                if run_index < len(runs)
                else None,
            )
        )
    return language, samples


def finite_float(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def slug(value: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9_-]+", "_", value).strip("_")
    return normalized or "unknown"


def is_dense_language(language: str) -> bool:
    primary = language.split("-", 1)[0].split("_", 1)[0].lower()
    return primary in {"zh", "yue", "ja", "ko"}


def join_text(values: Iterable[str], language: str) -> str:
    separator = "" if is_dense_language(language) else " "
    return separator.join(value.strip() for value in values if value.strip())


def punctuation_for(language: str) -> frozenset[str]:
    return frozenset(CJK_PUNCTUATION if is_dense_language(language) else LATIN_PUNCTUATION)


def terminal_punctuation_for(language: str) -> frozenset[str]:
    return frozenset("。？！" if is_dense_language(language) else ".?!")


def context_block(sample: Sample) -> str:
    blocks: list[str] = []
    if sample.context_before:
        blocks.append(f"<context_before>\n{sample.context_before}\n</context_before>")
    if sample.context_after:
        blocks.append(f"<context_after>\n{sample.context_after}\n</context_after>")
    return "\n".join(blocks)


def common_user_header(sample: Sample) -> str:
    return (
        f"language: {sample.language}\n"
        f"speaker: {sample.speaker}\n"
        "subtitle_line_limits: "
        f"minimum={MINIMUM_LINE_CHARACTERS}, "
        f"preferred={PREFERRED_LINE_CHARACTERS}, "
        f"maximum={MAX_LINE_CHARACTERS}\n"
        "This is a same-language spoken transcript. Keep the spoken wording; "
        "do not translate or summarize.\n"
    )


def render_word_list(
    sample: Sample,
    *,
    include_pauses: bool,
    corrected: dict[int, str] | None = None,
    punctuation: dict[int, str] | None = None,
) -> str:
    corrected = corrected or {}
    punctuation = punctuation or {}
    lines: list[str] = []
    for word in sample.words:
        value = corrected.get(word.word_id, word.text)
        pause = ""
        if include_pauses and word.pause_after is not None and word.pause_after >= PAUSE_THRESHOLD_SECONDS:
            pause = f' <pause duration="{word.pause_after:.2f}"/>'
        entry = {
            "id": word.word_id,
            "text": value,
            "display_characters": display_length(value, sample.language),
        }
        if word.word_id in punctuation:
            entry["punct_after"] = punctuation[word.word_id]
        lines.append(json.dumps(entry, ensure_ascii=False) + pause)
    return "\n".join(lines)


def render_corrected_word_list(
    sample: Sample,
    corrected: dict[int, str],
    punctuation: dict[int, str],
) -> str:
    lines: list[str] = []
    for word in sample.words:
        entry = {
            "id": word.word_id,
            "text": corrected.get(word.word_id, word.text),
            "punct_after": punctuation.get(word.word_id, ""),
            "display_characters": display_length(
                corrected.get(word.word_id, word.text),
                sample.language,
            ),
        }
        pause = ""
        if word.pause_after is not None and word.pause_after >= PAUSE_THRESHOLD_SECONDS:
            pause = f' <pause duration="{word.pause_after:.2f}"/>'
        lines.append(json.dumps(entry, ensure_ascii=False) + pause)
    return "\n".join(lines)


def prompt_c1(sample: Sample) -> tuple[str, str]:
    system = (
        "Correct ASR, restore natural spoken punctuation, and split the result "
        "into readable subtitle lines. Return JSON only as "
        '{"lines":["..."]}. Make minimal corrections: keep the source wording '
        "and order, change only likely recognition errors, word boundaries, "
        "or names. Use the language's natural punctuation. Every line must be "
        "a contiguous part of the corrected transcript; do not omit, repeat, "
        "translate, summarize, or invent content. Do not put a bound particle "
        "at the start of a clause or line. For Chinese, use only ，。？！, "
        "not 、. End each complete line with punctuation, keep unpunctuated "
        "runs short, and end the final line with terminal punctuation. Prefer "
        "phrase boundaries over fixed character cuts."
    )
    user = (
        common_user_header(sample)
        + context_block(sample)
        + "\n<asr_input>\n"
        + sample.source_text
        + "\n</asr_input>\n"
        + "Return the corrected, punctuated lines."
    )
    return system, user


def prompt_c2_a(sample: Sample) -> tuple[str, str]:
    system = (
        "Correct this spoken ASR transcript and restore natural punctuation. "
        'Return JSON only as {"text":"..."}. Make minimal corrections and '
        "preserve the source language, wording, order, repetitions, and "
        "meaning. Do not split into subtitle lines yet. Do not translate, "
        "summarize, or invent. Punctuation belongs after the phrase it closes; "
        "do not place punctuation before a bound particle. For Chinese, use "
        "only ，。？！, not 、. Punctuate clause boundaries, keep every "
        "unpunctuated content run at or below 16 display characters, including "
        "subtitle-sized continuing clauses, and end the final sentence with "
        "terminal punctuation. Use ， for list or item separators as well; "
        "never use 、. If a correction is uncertain, preserve the source "
        "wording instead of inventing a phrase."
    )
    user = (
        common_user_header(sample)
        + context_block(sample)
        + "\n<asr_input>\n"
        + sample.source_text
        + "\n</asr_input>\n"
        + "Return one corrected transcript string."
    )
    return system, user


def prompt_c2_b(sample: Sample, corrected_text: str) -> tuple[str, str]:
    system = (
        "Split the supplied finalized transcript into readable subtitle lines. "
        'Return JSON only as {"lines":["..."]}. This is a segmentation-only '
        "operation: do not change, correct, translate, normalize, add, or "
        "remove any character or punctuation. Joining the lines must reproduce "
        "the supplied transcript apart from line whitespace. Break at "
        "punctuation, phrase, and pause boundaries; never break a bound "
        "particle away from its phrase. Punctuation is not a mandatory cue "
        "boundary: avoid very short 2–4 character cues when the phrase can "
        "stay with the next clause, keep lexical compounds intact, target "
        "14–16 display characters, and never exceed 18. The maximum is hard: "
        "count visible characters and split at an earlier coherent phrase "
        "boundary when needed. Do not break immediately before an existing "
        "punctuation mark."
    )
    user = (
        common_user_header(sample)
        + context_block(sample)
        + "\n<finalized_transcript>\n"
        + corrected_text
        + "\n</finalized_transcript>\n"
        + "Return only the unchanged transcript split into lines."
    )
    return system, user


def prompt_c3(sample: Sample, include_pauses: bool) -> tuple[str, str]:
    system = (
        "Edit an ASR word sequence without generating a replacement paragraph. "
        "Return JSON only with exactly these arrays: "
        '{"replace":[{"word_id":0,"text":"..."}],'
        '"punct_after":[{"word_id":0,"mark":"..."}],'
        '"break_after":[0]}. '
        "Use replace only for a minimal likely ASR correction. Use punct_after "
        "to insert punctuation after an existing word. Use break_after for the "
        "last word id of every subtitle cue, including the final word id. "
        "Every source word must remain represented exactly once; punctuation "
        "is insertion only. Use natural spoken punctuation for the language; "
        "for Chinese use only ，。？！, never 、. Punctuate each complete "
        "clause and the final word. Do not leave a content run longer than 16 "
        "display characters without punctuation; use a comma at a natural "
        "continuing-clause boundary. Choose semantic and pause boundaries "
        "rather than fixed character cuts. Target 14–16 display characters, "
        "never exceed 18, and count display_characters rather than word ids. "
        "Avoid very short cues unless a phrase cannot be joined naturally. "
        "Never put a bound particle at a new line's start."
    )
    pause_note = (
        "The word list contains explicit pause markers. Treat pauses as "
        "evidence, not mandatory breaks."
        if include_pauses
        else "No pause durations are provided. Infer boundaries from language only."
    )
    user = (
        common_user_header(sample)
        + context_block(sample)
        + "\n"
        + pause_note
        + "\n<word_sequence>\n"
        + render_word_list(sample, include_pauses=include_pauses)
        + "\n</word_sequence>\n"
        + f"final_word_id: {sample.words[-1].word_id}\n"
        + "Use only the listed word ids in your JSON."
    )
    return system, user


def prompt_c5_b(
    sample: Sample,
    corrected: dict[int, str],
    punctuation: dict[int, str],
) -> tuple[str, str]:
    system = (
        "Choose subtitle boundaries for an already corrected and punctuated "
        "word sequence. Return JSON only as {"
        '"break_after":[0]}. This is segmentation-only: do not change the '
        "words or punctuation and do not return replacements. Include the "
        "final word id. Prefer phrase and pause boundaries; punctuation is "
        "evidence, not an automatic break. When a punctuation mark is attached "
        "to a word, end the cue after the marked word whenever including it "
        "keeps the cue at or below 18 characters. If it would exceed 18, "
        "break at the previous coherent phrase boundary. Count the supplied "
        "display_characters, not word ids. Keep lexical compounds, names, and "
        "idioms intact. Target 14–16 display characters, never exceed 18, and "
        "avoid 2–4 character cues when the phrase can remain with its neighbor. "
        "For this transcript-style experiment, every non-final break must be "
        "after a word with non-empty punct_after; the final break must carry "
        "terminal punctuation. Choose break ids only from the candidate list "
        "provided in the input. Never start a line with a bound particle."
    )
    user = (
        common_user_header(sample)
        + context_block(sample)
        + "\n<corrected_word_sequence>\n"
        + render_corrected_word_list(sample, corrected, punctuation)
        + "\n</corrected_word_sequence>\n"
        + f"final_word_id: {sample.words[-1].word_id}\n"
        + "candidate_break_after_ids: "
        + json.dumps(
            sorted(set(punctuation) | {sample.words[-1].word_id}),
        )
        + "\n"
        + "Return only the break_after array."
    )
    return system, user


def save_request(
    output_dir: Path,
    condition: str,
    sample_id: str,
    step: str,
    system: str,
    user: str,
    result: RequestResult,
) -> None:
    path = output_dir / "requests" / condition / sample_id / f"{step}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "condition": condition,
        "sample_id": sample_id,
        "step": step,
        "model": MODEL,
        "system": system,
        "user": user,
        "raw_response": result.raw,
        "parsed_response": result.parsed,
        "error": result.error,
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def call_and_save(
    client: LunaClient,
    output_dir: Path,
    condition: str,
    sample: Sample,
    step: str,
    system: str,
    user: str,
) -> RequestResult:
    try:
        raw = client.complete(system, user)
        parsed = parse_json_response(raw)
        result = RequestResult(
            request_path="",
            parsed=parsed,
            raw=raw,
            error=None,
        )
    except Exception as error:
        result = RequestResult(
            request_path="",
            parsed=None,
            raw=None,
            error=str(error),
        )
    path = output_dir / "requests" / condition / sample.sample_id / f"{step}.json"
    save_request(output_dir, condition, sample.sample_id, step, system, user, result)
    return dataclasses.replace(result, request_path=str(path))


def as_string_list(value: Any, key: str) -> list[str]:
    if not isinstance(value, dict) or not isinstance(value.get(key), list):
        raise ExperimentError(f"Expected JSON object with array '{key}'.")
    values = value[key]
    if not all(isinstance(item, str) and item.strip() for item in values):
        raise ExperimentError(f"Array '{key}' must contain non-empty strings.")
    return [item.strip() for item in values]


def corrected_text_from_response(response: Any) -> str:
    if not isinstance(response, dict) or not isinstance(response.get("text"), str):
        raise ExperimentError("Expected JSON object with string 'text'.")
    value = response["text"].strip()
    if not value:
        raise ExperimentError("Corrected text is empty.")
    return value


def operation_from_response(response: Any) -> tuple[dict[int, str], dict[int, str], list[int]]:
    if not isinstance(response, dict):
        raise ExperimentError("Expected JSON object for word operations.")
    replacements = parse_operations(response.get("replace", []), "text")
    punctuation = parse_operations(response.get("punct_after", []), "mark")
    break_after = response.get("break_after", [])
    if not isinstance(break_after, list) or not all(
        isinstance(item, int) and not isinstance(item, bool) for item in break_after
    ):
        raise ExperimentError("'break_after' must be an array of integer ids.")
    return replacements, punctuation, break_after


def parse_operations(value: Any, field: str) -> dict[int, str]:
    if not isinstance(value, list):
        raise ExperimentError("Operation arrays must be arrays.")
    result: dict[int, str] = {}
    for item in value:
        if not isinstance(item, dict):
            raise ExperimentError("Operation entries must be objects.")
        word_id = item.get("word_id")
        text = item.get(field)
        if (
            not isinstance(word_id, int)
            or isinstance(word_id, bool)
            or not isinstance(text, str)
            or not text.strip()
            or word_id in result
        ):
            raise ExperimentError(f"Invalid operation entry for '{field}'.")
        result[word_id] = text.strip()
    return result


def apply_operations(
    sample: Sample,
    replacements: dict[int, str],
    punctuation: dict[int, str],
    break_after: list[int],
) -> dict[str, Any]:
    ids = [word.word_id for word in sample.words]
    id_set = set(ids)
    errors: list[str] = []
    if any(word_id not in id_set for word_id in replacements):
        errors.append("replace contains unknown word id")
    if any(word_id not in id_set for word_id in punctuation):
        errors.append("punct_after contains unknown word id")
    if len(set(break_after)) != len(break_after):
        errors.append("break_after contains duplicate ids")
    if any(word_id not in id_set for word_id in break_after):
        errors.append("break_after contains unknown word id")
    if break_after != sorted(break_after):
        errors.append("break_after is not ordered")
    if not break_after or break_after[-1] != ids[-1]:
        errors.append("break_after does not cover the final word")
    allowed = punctuation_for(sample.language)
    for mark in punctuation.values():
        if mark not in allowed:
            errors.append(f"unsupported punctuation mark: {mark}")
    if errors:
        return {"valid": False, "errors": errors}

    corrected: dict[int, str] = {
        word.word_id: replacements.get(word.word_id, word.text)
        for word in sample.words
    }
    transcript_parts: list[str] = []
    cues: list[dict[str, Any]] = []
    current: list[Word] = []
    break_set = set(break_after)
    for word in sample.words:
        current.append(word)
        value = corrected[word.word_id] + punctuation.get(word.word_id, "")
        transcript_parts.append(value)
        if word.word_id in break_set:
            cues.append(
                {
                    "word_ids": [item.word_id for item in current],
                    "text": join_text(
                        (
                            corrected[item.word_id]
                            + punctuation.get(item.word_id, "")
                            for item in current
                        ),
                        sample.language,
                    ),
                    "start": current[0].start,
                    "end": current[-1].end,
                }
            )
            current = []
    if current:
        return {"valid": False, "errors": ["unconsumed words after breaks"]}
    return {
        "valid": True,
        "errors": [],
        "replacements": replacements,
        "punctuation": punctuation,
        "break_after": break_after,
        "corrected_words": corrected,
        "transcript": join_text(transcript_parts, sample.language),
        "cues": cues,
    }


def normalize_core(text: str) -> str:
    return "".join(
        character
        for character in text
        if not character.isspace()
        and not unicodedata.category(character).startswith("P")
    )


def display_length(text: str, language: str) -> int:
    if is_dense_language(language):
        return sum(not character.isspace() for character in text)
    return len(text.strip())


def edit_distance(left: str, right: str) -> int:
    previous = list(range(len(right) + 1))
    for left_index, left_character in enumerate(left, start=1):
        current = [left_index]
        for right_index, right_character in enumerate(right, start=1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[right_index] + 1,
                    previous[right_index - 1] + (left_character != right_character),
                )
            )
        previous = current
    return previous[-1]


def punctuation_metrics(
    text: str,
    lines: list[str],
    language: str,
) -> dict[str, Any]:
    allowed = punctuation_for(language)
    terminals = terminal_punctuation_for(language)
    foreign = {
        character
        for character in text
        if unicodedata.category(character).startswith("P")
        and character not in allowed
    }
    punctuation_count = sum(character in allowed for character in text)
    disallowed = [character for character in text if character in foreign]
    line_lengths = [display_length(line, language) for line in lines]
    lines_with_punctuation = sum(
        any(character in allowed for character in line)
        for line in lines
    )
    long_unpunctuated_run = 0
    current_run = 0
    for character in text:
        if character.isspace():
            continue
        if character in allowed:
            current_run = 0
        else:
            current_run += 1
            long_unpunctuated_run = max(long_unpunctuated_run, current_run)
    visible = text.rstrip()
    terminal = bool(visible and visible[-1] in terminals)
    stranded = False
    for index, character in enumerate(text[:-1]):
        if character in allowed and text[index + 1] in BOUND_PARTICLES:
            stranded = True
            break
    return {
        "punctuation_count": punctuation_count,
        "punctuation_density_per_100_chars": round(
            100 * punctuation_count / max(1, len(normalize_core(text))),
            2,
        ),
        "lines": len(lines),
        "lines_with_punctuation": lines_with_punctuation,
        "line_punctuation_coverage": round(
            lines_with_punctuation / max(1, len(lines)),
            3,
        ),
        "longest_unpunctuated_run": long_unpunctuated_run,
        "foreign_punctuation": disallowed,
        "terminal_punctuation": terminal,
        "stranded_bound_particle": stranded,
        "line_lengths": line_lengths,
        "maximum_line_length": max(line_lengths, default=0),
        "mean_line_length": round(statistics.mean(line_lengths), 2)
        if line_lengths
        else 0,
        "lines_over_preferred": sum(
            length > PREFERRED_LINE_CHARACTERS for length in line_lengths
        ),
        "lines_over_maximum": sum(
            length > MAX_LINE_CHARACTERS for length in line_lengths
        ),
        "bad_line_starts": sum(
            bool(line)
            and (
                line[0] in allowed
                or line[0] in BOUND_PARTICLES
            )
            for line in lines
        ),
        "line_end_punctuation_ratio": round(
            sum(
                bool(line.rstrip())
                and line.rstrip()[-1] in allowed
                for line in lines
            )
            / max(1, len(lines)),
            3,
        ),
    }


def content_metrics(source: str, output: str) -> dict[str, Any]:
    source_core = normalize_core(source)
    output_core = normalize_core(output)
    distance = edit_distance(source_core, output_core)
    matcher = difflib.SequenceMatcher(a=source_core, b=output_core)
    return {
        "source_core_length": len(source_core),
        "output_core_length": len(output_core),
        "edit_distance": distance,
        "edit_rate": round(distance / max(1, len(source_core)), 4),
        "sequence_similarity": round(matcher.ratio(), 4),
        "changed_content": source_core != output_core,
    }


def approximate_alignment_metrics(source: str, output: str) -> dict[str, Any]:
    source_core = normalize_core(source)
    output_core = normalize_core(output)
    matching_characters = sum(
        block.size
        for block in difflib.SequenceMatcher(
            a=source_core,
            b=output_core,
        ).get_matching_blocks()
    )
    return {
        "source_match_ratio": round(
            matching_characters / max(1, len(source_core)),
            4,
        ),
        "output_match_ratio": round(
            matching_characters / max(1, len(output_core)),
            4,
        ),
        "monotonic_character_match": True,
        "is_timestamp_alignment": False,
    }


def pause_metrics(sample: Sample, break_after: list[int]) -> dict[str, Any]:
    pauses = set(sample.pause_ids)
    breaks = set(break_after[:-1])
    return {
        "pause_word_ids": sorted(pauses),
        "break_after": break_after,
        "breaks_on_pause": sorted(breaks & pauses),
        "break_pause_precision": round(
            len(breaks & pauses) / max(1, len(breaks)),
            3,
        ),
        "pause_break_recall": round(
            len(breaks & pauses) / max(1, len(pauses)),
            3,
        ),
    }


def evaluate(
    sample: Sample,
    *,
    lines: list[str],
    transcript: str,
    indexed: bool,
    operation_valid: bool = True,
    break_after: list[int] | None = None,
) -> dict[str, Any]:
    result = {
        "content": content_metrics(sample.source_text, transcript),
        "punctuation": punctuation_metrics(
            transcript,
            lines,
            sample.language,
        ),
        "operation_valid": operation_valid,
        "alignment": {
            "word_index_contract": indexed and operation_valid,
            "timestamp_anchor": indexed and operation_valid,
            "source_word_coverage_verifiable": indexed and operation_valid,
        },
    }
    if indexed:
        result["timing"] = pause_metrics(sample, break_after or [])
        result["coverage"] = {
            "all_source_word_ids_covered": operation_valid
            and bool(break_after)
            and break_after[-1] == sample.words[-1].word_id,
            "source_word_count": len(sample.words),
        }
    else:
        result["alignment"]["approximate_monotonic_content_match"] = (
            approximate_alignment_metrics(sample.source_text, transcript)
        )
    return result


def quality_score(metrics: dict[str, Any]) -> dict[str, Any]:
    content = metrics["content"]
    punctuation = metrics["punctuation"]
    penalties = {
        "content_edit_rate": content["edit_rate"] * 100,
        "invalid_operation": 100 if not metrics.get("operation_valid", True) else 0,
        "missing_terminal_punctuation": 12
        if not punctuation["terminal_punctuation"]
        else 0,
        "stranded_bound_particle": 20
        if punctuation["stranded_bound_particle"]
        else 0,
        "foreign_punctuation": 10 * len(punctuation["foreign_punctuation"]),
        "underpunctuated_run": max(
            0,
            punctuation["longest_unpunctuated_run"] - MAX_LINE_CHARACTERS,
        ),
        "overlong_lines": 5 * punctuation["lines_over_maximum"],
        "bad_line_starts": 4 * punctuation["bad_line_starts"],
    }
    total = round(sum(penalties.values()), 3)
    return {"penalty": total, "penalties": penalties}


def run_c1(
    client: LunaClient,
    output_dir: Path,
    sample: Sample,
) -> dict[str, Any]:
    system, user = prompt_c1(sample)
    response = call_and_save(client, output_dir, "C1", sample, "lines", system, user)
    if response.error:
        return {"condition": "C1", "sample_id": sample.sample_id, "error": response.error}
    try:
        lines = as_string_list(response.parsed, "lines")
        transcript = join_text(lines, sample.language)
        metrics = evaluate(
            sample,
            lines=lines,
            transcript=transcript,
            indexed=False,
        )
        return {
            "condition": "C1",
            "sample_id": sample.sample_id,
            "lines": lines,
            "transcript": transcript,
            "request": response.request_path,
            "metrics": metrics,
            "score": quality_score(metrics),
        }
    except Exception as error:
        return {
            "condition": "C1",
            "sample_id": sample.sample_id,
            "request": response.request_path,
            "error": str(error),
        }


def run_c2(
    client: LunaClient,
    output_dir: Path,
    sample: Sample,
) -> dict[str, Any]:
    system_a, user_a = prompt_c2_a(sample)
    response_a = call_and_save(
        client,
        output_dir,
        "C2",
        sample,
        "correct",
        system_a,
        user_a,
    )
    if response_a.error:
        return {"condition": "C2", "sample_id": sample.sample_id, "error": response_a.error}
    try:
        corrected = corrected_text_from_response(response_a.parsed)
    except Exception as error:
        return {
            "condition": "C2",
            "sample_id": sample.sample_id,
            "request": response_a.request_path,
            "error": str(error),
        }

    system_b, user_b = prompt_c2_b(sample, corrected)
    response_b = call_and_save(
        client,
        output_dir,
        "C2",
        sample,
        "segment",
        system_b,
        user_b,
    )
    if response_b.error:
        return {
            "condition": "C2",
            "sample_id": sample.sample_id,
            "corrected_text": corrected,
            "request": response_b.request_path,
            "error": response_b.error,
        }
    try:
        lines = as_string_list(response_b.parsed, "lines")
        transcript = join_text(lines, sample.language)
        metrics = evaluate(
            sample,
            lines=lines,
            transcript=transcript,
            indexed=False,
        )
        metrics["cascade"] = {
            "segmentation_preserved_corrected_text": normalize_core(transcript)
            == normalize_core(corrected),
            "corrected_text_metrics": content_metrics(sample.source_text, corrected),
        }
        return {
            "condition": "C2",
            "sample_id": sample.sample_id,
            "corrected_text": corrected,
            "lines": lines,
            "transcript": transcript,
            "requests": [response_a.request_path, response_b.request_path],
            "metrics": metrics,
            "score": quality_score(metrics),
        }
    except Exception as error:
        return {
            "condition": "C2",
            "sample_id": sample.sample_id,
            "corrected_text": corrected,
            "request": response_b.request_path,
            "error": str(error),
        }


def run_indexed(
    client: LunaClient,
    output_dir: Path,
    sample: Sample,
    condition: str,
    include_pauses: bool,
) -> dict[str, Any]:
    system, user = prompt_c3(sample, include_pauses)
    response = call_and_save(
        client,
        output_dir,
        condition,
        sample,
        "operations",
        system,
        user,
    )
    if response.error:
        return {"condition": condition, "sample_id": sample.sample_id, "error": response.error}
    try:
        replacements, punctuation, break_after = operation_from_response(response.parsed)
        applied = apply_operations(sample, replacements, punctuation, break_after)
        if not applied["valid"]:
            metrics = evaluate(
                sample,
                lines=[],
                transcript="",
                indexed=True,
                operation_valid=False,
                break_after=break_after,
            )
            metrics["operation_errors"] = applied["errors"]
            return {
                "condition": condition,
                "sample_id": sample.sample_id,
                "operations": response.parsed,
                "request": response.request_path,
                "metrics": metrics,
                "score": quality_score(metrics),
                "error": "; ".join(applied["errors"]),
            }
        lines = [cue["text"] for cue in applied["cues"]]
        metrics = evaluate(
            sample,
            lines=lines,
            transcript=applied["transcript"],
            indexed=True,
            operation_valid=True,
            break_after=break_after,
        )
        return {
            "condition": condition,
            "sample_id": sample.sample_id,
            "operations": response.parsed,
            "corrected_transcript": applied["transcript"],
            "lines": lines,
            "cues": applied["cues"],
            "request": response.request_path,
            "metrics": metrics,
            "score": quality_score(metrics),
        }
    except Exception as error:
        return {
            "condition": condition,
            "sample_id": sample.sample_id,
            "request": response.request_path,
            "error": str(error),
        }


def run_c5(
    client: LunaClient,
    output_dir: Path,
    sample: Sample,
) -> dict[str, Any]:
    system_a, user_a = prompt_c3(sample, include_pauses=True)
    response_a = call_and_save(
        client,
        output_dir,
        "C5",
        sample,
        "correct_punctuate",
        system_a.replace(
            "Use break_after for the last word id of every subtitle cue, including the final word id. ",
            "Do not return break_after in this step. ",
        ),
        user_a
        + "\nThis is the first pass. Return only replace and punct_after; "
        "return an empty break_after array.",
    )
    if response_a.error:
        return {"condition": "C5", "sample_id": sample.sample_id, "error": response_a.error}
    try:
        replacements, punctuation, _ = operation_from_response(response_a.parsed)
        applied = apply_operations(
            sample,
            replacements,
            punctuation,
            list(range(sample.words[-1].word_id + 1)),
        )
        if not applied["valid"]:
            raise ExperimentError("; ".join(applied["errors"]))
    except Exception as error:
        return {
            "condition": "C5",
            "sample_id": sample.sample_id,
            "request": response_a.request_path,
            "error": str(error),
        }

    system_b, user_b = prompt_c5_b(sample, replacements, punctuation)
    response_b = call_and_save(
        client,
        output_dir,
        "C5",
        sample,
        "segment",
        system_b,
        user_b,
    )
    if response_b.error:
        return {
            "condition": "C5",
            "sample_id": sample.sample_id,
            "requests": [response_a.request_path, response_b.request_path],
            "error": response_b.error,
        }
    try:
        if (
            not isinstance(response_b.parsed, dict)
            or not isinstance(response_b.parsed.get("break_after"), list)
        ):
            raise ExperimentError("Expected JSON object with break_after array.")
        break_after = response_b.parsed["break_after"]
        if not all(isinstance(item, int) for item in break_after):
            raise ExperimentError("break_after must contain integer ids.")
        unpunctuated_breaks = [
            word_id
            for word_id in break_after[:-1]
            if word_id not in punctuation
        ]
        if unpunctuated_breaks:
            raise ExperimentError(
                "break_after contains unpunctuated cue boundaries: "
                + ", ".join(str(item) for item in unpunctuated_breaks)
            )
        final_mark = punctuation.get(sample.words[-1].word_id)
        if final_mark not in terminal_punctuation_for(sample.language):
            raise ExperimentError("The final word has no terminal punctuation.")
        applied = apply_operations(sample, replacements, punctuation, break_after)
        if not applied["valid"]:
            raise ExperimentError("; ".join(applied["errors"]))
        lines = [cue["text"] for cue in applied["cues"]]
        metrics = evaluate(
            sample,
            lines=lines,
            transcript=applied["transcript"],
            indexed=True,
            operation_valid=True,
            break_after=break_after,
        )
        return {
            "condition": "C5",
            "sample_id": sample.sample_id,
            "operations": {
                "replace": replacements,
                "punct_after": punctuation,
                "break_after": break_after,
            },
            "corrected_transcript": applied["transcript"],
            "lines": lines,
            "cues": applied["cues"],
            "requests": [response_a.request_path, response_b.request_path],
            "metrics": metrics,
            "score": quality_score(metrics),
        }
    except Exception as error:
        return {
            "condition": "C5",
            "sample_id": sample.sample_id,
            "requests": [response_a.request_path, response_b.request_path],
            "error": str(error),
        }


def run_condition(
    condition: str,
    client: LunaClient,
    output_dir: Path,
    samples: list[Sample],
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for sample in samples:
        print(f"{condition} {sample.sample_id}", flush=True)
        if condition == "C1":
            result = run_c1(client, output_dir, sample)
        elif condition == "C2":
            result = run_c2(client, output_dir, sample)
        elif condition == "C3":
            result = run_indexed(client, output_dir, sample, "C3", False)
        elif condition == "C4":
            result = run_indexed(client, output_dir, sample, "C4", True)
        elif condition == "C5":
            result = run_c5(client, output_dir, sample)
        else:
            raise ExperimentError(f"Unknown condition {condition}.")
        results.append(result)
    return results


def aggregate_condition(results: list[dict[str, Any]]) -> dict[str, Any]:
    valid = [item for item in results if "metrics" in item and "score" in item]
    if not valid:
        return {
            "sample_count": len(results),
            "valid_count": 0,
            "errors": [item.get("error", "unknown") for item in results],
        }
    metrics = [item["metrics"] for item in valid]
    content = [item["content"] for item in metrics]
    punctuation = [item["punctuation"] for item in metrics]
    approximate_alignment = [
        item["alignment"]["approximate_monotonic_content_match"]
        for item in metrics
        if "approximate_monotonic_content_match" in item["alignment"]
    ]
    scores = [item["score"]["penalty"] for item in valid]
    return {
        "sample_count": len(results),
        "valid_count": len(valid),
        "error_count": len(results) - len(valid),
        "mean_penalty": round(statistics.mean(scores), 3),
        "mean_edit_rate": round(
            statistics.mean(item["edit_rate"] for item in content),
            4,
        ),
        "mean_sequence_similarity": round(
            statistics.mean(item["sequence_similarity"] for item in content),
            4,
        ),
        "mean_punctuation_coverage": round(
            statistics.mean(
                item["line_punctuation_coverage"] for item in punctuation
            ),
            3,
        ),
        "mean_longest_unpunctuated_run": round(
            statistics.mean(
                item["longest_unpunctuated_run"] for item in punctuation
            ),
            2,
        ),
        "mean_maximum_line_length": round(
            statistics.mean(item["maximum_line_length"] for item in punctuation),
            2,
        ),
        "lines_over_maximum": sum(
            item["lines_over_maximum"] for item in punctuation
        ),
        "stranded_bound_particle_count": sum(
            item["stranded_bound_particle"] for item in punctuation
        ),
        "foreign_punctuation_count": sum(
            len(item["foreign_punctuation"]) for item in punctuation
        ),
        "terminal_punctuation_count": sum(
            item["terminal_punctuation"] for item in punctuation
        ),
        "operation_invalid_count": sum(
            not item.get("operation_valid", True) for item in metrics
        ),
        "word_index_contract_rate": round(
            statistics.mean(
                item["alignment"]["word_index_contract"] for item in metrics
            ),
            3,
        ),
        "timestamp_anchor_rate": round(
            statistics.mean(
                item["alignment"]["timestamp_anchor"] for item in metrics
            ),
            3,
        ),
        "mean_approximate_source_match_ratio": round(
            statistics.mean(
                item["source_match_ratio"] for item in approximate_alignment
            ),
            4,
        )
        if approximate_alignment
        else None,
        "mean_approximate_output_match_ratio": round(
            statistics.mean(
                item["output_match_ratio"] for item in approximate_alignment
            ),
            4,
        )
        if approximate_alignment
        else None,
    }


def write_summary(
    output_dir: Path,
    task_id: str,
    language: str,
    samples: list[Sample],
    condition_results: dict[str, list[dict[str, Any]]],
) -> dict[str, Any]:
    aggregates = {
        condition: aggregate_condition(results)
        for condition, results in condition_results.items()
    }
    ranked = sorted(
        (
            (
                condition,
                data.get("word_index_contract_rate", 0),
                data.get("mean_penalty"),
            )
            for condition, data in aggregates.items()
            if data.get("valid_count", 0) > 0
        ),
        key=lambda item: (-item[1], item[2]),
    )
    summary = {
        "model": MODEL,
        "task_id": task_id,
        "language": language,
        "sample_ids": [sample.sample_id for sample in samples],
        "conditions": CONDITION_NAMES,
        "aggregates": aggregates,
        "ranking_by_quantitative_penalty": [
            {
                "condition": condition,
                "mean_penalty": penalty,
                "word_index_contract_rate": contract_rate,
            }
            for condition, contract_rate, penalty in ranked
        ],
        "human_review_required": True,
        "interpretation": (
            "Metrics measure content preservation, punctuation coverage, "
            "subtitle constraints, and timestamp-independent boundary signals. "
            "They do not establish whether a specific ASR correction is true; "
            "review raw outputs before changing production."
        ),
    }
    (output_dir / "results.json").write_text(
        json.dumps(condition_results, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    (output_dir / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return summary


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run independent gpt-5.6-luna ASR post-processing conditions."
    )
    parser.add_argument("--workbench", type=Path, required=True)
    parser.add_argument("--task-id", required=True)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="Defaults to /tmp/voxella-asr-llm-experiment/<timestamp>.",
    )
    parser.add_argument(
        "--conditions",
        default=",".join(CONDITION_NAMES),
        help="Comma-separated subset of C1,C2,C3,C4,C5.",
    )
    parser.add_argument("--sample-limit", type=int, default=0)
    parser.add_argument(
        "--api-key-env",
        default="OPENAI_API_KEY",
        help="Environment variable containing the API key.",
    )
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    parser.add_argument("--timeout-seconds", type=float, default=180.0)
    parser.add_argument("--max-attempts", type=int, default=2)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    conditions = tuple(
        value.strip().upper()
        for value in args.conditions.split(",")
        if value.strip()
    )
    invalid_conditions = set(conditions) - set(CONDITION_NAMES)
    if invalid_conditions:
        raise ExperimentError(
            f"Unknown conditions: {', '.join(sorted(invalid_conditions))}"
        )
    api_key = os.environ.get(args.api_key_env, "")
    if not api_key:
        raise ExperimentError(
            f"Set {args.api_key_env}; the harness never reads or writes credentials."
        )
    language, samples = load_samples(args.workbench, args.task_id)
    if args.sample_limit > 0:
        samples = samples[: args.sample_limit]
    if not samples:
        raise ExperimentError("No samples selected.")

    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_dir = args.output_dir or Path("/tmp") / "voxella-asr-llm-experiment" / timestamp
    output_dir.mkdir(parents=True, exist_ok=True)
    input_snapshot = {
        "model": MODEL,
        "task_id": args.task_id,
        "language": language,
        "source": "workbench.json raw timed words",
        "pause_threshold_seconds": PAUSE_THRESHOLD_SECONDS,
        "samples": [
            {
                "sample_id": sample.sample_id,
                "speaker": sample.speaker,
                "context_before": sample.context_before,
                "context_after": sample.context_after,
                "words": [dataclasses.asdict(word) for word in sample.words],
            }
            for sample in samples
        ],
    }
    (output_dir / "input_snapshot.json").write_text(
        json.dumps(input_snapshot, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    (output_dir / "run_config.json").write_text(
        json.dumps(
            {
                "model": MODEL,
                "endpoint": args.endpoint,
                "conditions": conditions,
                "sample_limit": args.sample_limit,
                "pause_threshold_seconds": PAUSE_THRESHOLD_SECONDS,
                "line_limits": {
                    "minimum": MINIMUM_LINE_CHARACTERS,
                    "preferred": PREFERRED_LINE_CHARACTERS,
                    "maximum": MAX_LINE_CHARACTERS,
                },
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )

    client = LunaClient(
        api_key=api_key,
        endpoint=args.endpoint,
        timeout_seconds=args.timeout_seconds,
        max_attempts=args.max_attempts,
    )
    condition_results: dict[str, list[dict[str, Any]]] = {}
    for condition in conditions:
        condition_results[condition] = run_condition(
            condition,
            client,
            output_dir,
            samples,
        )
    summary = write_summary(
        output_dir,
        args.task_id,
        language,
        samples,
        condition_results,
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"RESULT_DIR={output_dir}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ExperimentError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
