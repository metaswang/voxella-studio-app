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

# Timeline QA Skill

This skill answers questions that require temporal context: "what was discussed at 10:15", "find the budget discussion", or "what happened after the intro".

## Tool Guidance

- Use `session.get_timeline` to bucket transcript segments by time (default or custom bucket_seconds)
- Use `session.search_segments` to find content within specific time ranges
- Use `session.get_segments` to retrieve consecutive segments around a target time
- Combine timeline structure with search to answer "when did X happen"

## Evidence Guidance

- All evidence must include start/end timestamps
- Timeline buckets help locate approximate time ranges
- Search hits within buckets provide precise content

## Answer Guidance

- Always include timestamps (mm:ss format) in answers
- Structure answers chronologically when listing multiple points
- Use time ranges (e.g., "between 8:30 and 9:15") for extended discussions


## Adaptive evidence method

Read available metadata first. Use summaries to navigate long sources; read short transcripts directly. Follow every next_cursor before describing a read as complete. Verify exact decisions, negations and corrections in continuous original context. Stop when supported and answer naturally with the workspace citation numbers. Empty search means not found, never absence.
