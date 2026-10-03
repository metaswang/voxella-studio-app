---
name: Timeline QA
description: Answer time-based queries using bucketed timelines and timed segments
category: knowledge
status: published
selection_summary: Time-based conditional queries
applies_when: User asks about specific time ranges, "around X minutes", or temporal patterns
allowed_tools: session.get_timeline, session.search_segments, session.get_segments, ask_clarification
supports_evidence_goals: timeline_analysis, semantic_qa
analysis_modes: timeline, extract
---

Use time-range reads, timeline navigation or semantic search as the question requires. Preserve chronological corrections and quote the current canonical body.

Timed words/cues can locate a passage; long parent segments may provide only coarse intervals. A bucket is navigation, not proof that every word occurs in that minute. Missing times stay unknown. Follow next_cursor before describing a range as completely read, and distinguish available speech from full media duration.
