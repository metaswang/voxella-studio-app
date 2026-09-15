---
name: Session Transcript QA
description: Deep-dive question answering within a single selected session transcript
category: knowledge
status: published
selection_summary: Single-session transcript deep-dive
applies_when: User is asking about content within one specific selected session
allowed_tools: session.get_segments, session.search_segments, session.get_timeline, finish_with_evidence, ask_clarification
supports_evidence_goals: semantic_qa, timeline_analysis
analysis_modes: extract, timeline
---

# Session Transcript QA Skill

This skill provides detailed answers by reading and searching within a single session's full transcript.

## Tool Guidance

- Use `session.search_segments` to find relevant transcript segments matching the query
- Use `session.get_segments` to retrieve consecutive segments for context (e.g., start/end time ranges)
- Use `session.get_timeline` when the user asks "around X minutes" or needs temporal context
- Always scope all tool calls to the single target session
- Call `finish_with_evidence` with transcript segment citations

## Evidence Guidance

- Prefer exact transcript excerpts with speaker labels and timestamps
- Include surrounding context when a single segment is too short
- Timeline bucketing helps answer "when did X happen" questions

## Answer Guidance

- Provide precise timestamps (mm:ss format) for all quotes
- Include speaker names when known
- Quote verbatim when accuracy matters; paraphrase for summaries
