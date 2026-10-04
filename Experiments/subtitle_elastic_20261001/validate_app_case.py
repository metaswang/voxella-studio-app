"""Read-only verification of the opt-in Workbench copy and its actual UI exports.

Run from any directory with python3. Never edits Workbench or the original case.
The native audio replay lives in ProductionSubtitleReplayTests.swift.
"""
import collections
import datetime
import json
import math
from pathlib import Path

FOLDER = Path(__file__).resolve().parent
CASE_ID = "2AE0FBF5-CDD5-446B-9C35-F7016D42F4DF"
ORIGINAL_ID = "5A5B0854-C2C6-4E0C-BC90-E000211B4E25"
workbench = json.loads((Path.home() / "Library/Application Support/VoxStudio/workbench.json").read_text())
job = next(item for item in workbench["transcriptions"] if item["id"] == CASE_ID)
original = next(item for item in workbench["transcriptions"] if item["id"] == ORIGINAL_ID)
words = job["result"]["words"]
source = job["subtitleTrack"]
english = next(item["track"] for item in job["translationTracks"] if item["track"]["language"].startswith("en"))
coverage = [index for cue in source["cues"] for index in cue["sourceIDs"]]
assert coverage == list(range(len(words))), "Source words must occur once and in order"
for track in (source, english):
    assert track["processingVersion"] == "elastic-v1"
    for cue in track["cues"]:
        assert math.isfinite(cue["start"]) and math.isfinite(cue["end"])
        assert cue["end"] > cue["start"] >= 0
        assert len(cue.get("displayLineBreaks", [])) <= 1
assert all(cue["timingQuality"] == "estimated" for cue in english["cues"])
assert "unknown" not in collections.Counter(word.get("timingQuality", "unknown") for word in words)
phrases = ["打开之后你的骨头慢慢就可以归位", "比较加重的时候", "就这么简单", "那谢谢吴医生"]
phrase_cues = {}
for phrase in phrases:
    cue = next(cue for cue in source["cues"] if phrase in cue["text"])
    phrase_cues[phrase] = {key: cue[key] for key in ("id", "text", "start", "end", "speaker", "timingQuality")}
na_cue = next(cue for cue in source["cues"] if "那谢谢吴医生" in cue["text"])
na_word = words[na_cue["sourceIDs"][0]]
assert na_word["text"] == "那" and na_word["timingQuality"] == "aligned"
assert abs(na_word["start"] - 301.344) < 0.2
assert na_cue["start"] == na_word["start"]
assert na_cue["speaker"] == "Speaker 1" and na_cue["boundaryBefore"] == "hard"
assert phrase_cues["就这么简单"]["speaker"] == "Speaker 2"
assert len(original["result"]["words"]) == 2389
assert len(original["subtitleTrack"]["cues"]) == 214
assert len(original["translationTracks"][0]["track"]["cues"]) == 129
assert abs(original["result"]["words"][1411]["start"] - 300.00811767578125) < 0.01

srt = (FOLDER / "app-source-after.srt").read_text()
vtt = (FOLDER / "app-english-after.vtt").read_text()
source_blocks = srt.strip().split("\n\n")
target_blocks = vtt.strip().split("\n\n")[1:]
assert len(source_blocks) == len(source["cues"])
assert len(target_blocks) == len(english["cues"])
assert "00:05:01,344 --> 00:05:03,424\n那谢谢吴医生" in srt
assert all(1 <= len(block.splitlines()[1:]) <= 2 for block in target_blocks)
two_line_exports = sum(len(block.splitlines()) == 3 for block in target_blocks)
assert two_line_exports > 0
assert "long-distance" in vtt and "problems—roughly" in vtt and "......" in vtt
for name, track in (("app-source-after", source), ("app-english-after", english)):
    (FOLDER / (name + ".json")).write_text(json.dumps(track, ensure_ascii=False, indent=2) + "\n")
quality = collections.Counter(word["timingQuality"] for word in words)
report = {
    "verifiedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "caseID": CASE_ID,
    "title": job.get("title", "脊椎侧弯运动与日常注意事项 · 弹性字幕新构建验证"),
    "scope": "Actual non-MAS app copy: full local ASR/alignment, then final source resegmentation and existing configured English translation requests. Original case retained. Exports were saved through the app UI.",
    "wordCount": len(words), "timingQuality": dict(quality),
    "estimatedFraction": quality["estimated"] / len(words),
    "originalEstimatedFractionFromDiagnostic": 1923 / 2389,
    "originalNaStart": original["result"]["words"][1411]["start"],
    "newNaWordStart": na_word["start"], "newNaCueStart": na_cue["start"],
    "referenceNaStart": 301.344,
    "referenceProvenance": "Original decoded-audio forced-alignment replay; repeated fresh-ASR replay agrees. Not an independent human word-boundary annotation.",
    "sourceWordsCoveredExactlyOnce": True,
    "sourceCueCount": len(source["cues"]), "englishCueCount": len(english["cues"]),
    "englishTwoLineExportCount": two_line_exports,
    "sourceCuesAbove8Seconds": sum(cue["end"] - cue["start"] > 8 for cue in source["cues"]),
    "englishCuesAbove8Seconds": sum(cue["end"] - cue["start"] > 8 for cue in english["cues"]),
    "phrases": phrase_cues,
    "uiVerification": ["Chinese host cue at 05:01 displayed on the original video with Speaker 1", "English cue at 04:28 displayed on two lines", "Source SRT and translated VTT saved from Export dialog"],
    "exportOptions": "Subtitles; no speaker prefixes; app default trailing punctuation removal. Canonical JSON retains punctuation and internal whitespace.",
    "regressionTests": {"passed": 176, "suites": 28, "traits": "BundledSpeech", "filter": "ElasticSubtitleTests|MediaFlow|Subtitle|Caption|LongFormAlignmentRecoveryTests|TranscriptionQualityProcessorTests|ASROwnership"},
    "limitations": ["356 words still estimated and explicitly labeled", "Translated cue timing projected from source audio, not target-language forced alignment", "Duration above 8 seconds is diagnostic and soft, not a mandatory cut", "Multilingual benchmark is synthetic, not human gold", "Broad SparkleUpdates test configuration has an existing unrelated AppUpdaterTests initializer mismatch; targeted BundledSpeech tests and signed app build pass"],
}
(FOLDER / "app-validation.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({key: report[key] for key in ("wordCount", "timingQuality", "sourceCueCount", "englishCueCount", "newNaCueStart", "englishTwoLineExportCount")}, ensure_ascii=False))
