# Evaluation samples and sources

Audio is not committed. The audio is re-derivable from the sources below.

| id | speakers (ref) | language | source | license |
| --- | --- | --- | --- | --- |
| en_gyomp | 5 | en | VoxConverse test, `ggfox00000/dia-voxconverse-test` (`audio/test/gyomp.wav`, RTTM from `joonson/voxconverse` test) | CC BY 4.0 |
| en_kpjud | 8 | en | same | CC BY 4.0 |
| en_erslt | 7 | en | same | CC BY 4.0 |
| en_lubpm | 2 | en | same | CC BY 4.0 |
| en_eucfa | 4 | en | same | CC BY 4.0 |
| zh_S_R004S04C01 | 5 | zh | AISHELL-4 test, `ggfox00000/dia-aishell4-test` (channel-averaged to mono) | Apache-2.0 per mirror card; upstream AISHELL-4 is listed CC BY-SA 4.0 — check before any redistribution |
| zh_L_R004S01C01 | 7 | zh | same | same |

Reference RTTMs: `refs/` (recording URIs rewritten to the ids above).
Diarization timeline hypotheses (Nemotron 3 engine, `speechRanges` = full file, auto speaker count): `timeline/`.
App end-to-end hypotheses (word-level speaker labels from the app, `Speaker N` mapped to `spkN`): `app-words/`.
Scores: `scores/` (pyannote.metrics via tools/diarization_eval, overlap included, no UEM, collar 0 and 0.25).

Caveat: `app-words/` is limited by ASR word coverage and cannot represent overlapping speech, so its DER mixes ASR misses into the diarization score. Use `timeline/` for diarization quality.
