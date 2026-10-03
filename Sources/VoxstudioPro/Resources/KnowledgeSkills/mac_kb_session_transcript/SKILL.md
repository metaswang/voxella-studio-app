---
name: Session Transcript QA
description: Deep-dive question answering within a single selected session transcript
category: knowledge
status: published
selection_summary: Single-session transcript deep-dive
applies_when: User is asking about content within one specific selected session
allowed_tools: session.get_segments, session.search_segments, session.get_timeline, ask_clarification
supports_evidence_goals: semantic_qa, timeline_analysis
analysis_modes: extract, timeline
---

Keep reads and searches within the selected source. Choose search, continuous time-range reads or a full short read to fit the question. Follow next_cursor only when claiming a complete read.

The readable body is current Transcript, with marked same-source subtitle fallback when Transcript is unavailable. Quote the selected original text and known speaker labels. Coarse parent times are ranges, not exact phrase timestamps; missing timing stays unknown. Report coverage limits rather than filling transcript gaps from subtitles, translations or linked voiceovers.
