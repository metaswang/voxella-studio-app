---
name: Session Inventory
description: List and filter sessions by metadata (date, type, duration, origin)
category: knowledge
status: published
selection_summary: Metadata queries and session listing
applies_when: User asks "how many", "which sessions", "list all X", or metadata-based filters
allowed_tools: session.list, knowledge.get_session_metadata, ask_clarification
supports_evidence_goals: metadata_summary
analysis_modes: classify, summarize
---

# Session Inventory Skill

This skill answers questions about session metadata: counts, lists, types, dates, durations, and origins.

## Tool Guidance

- Use `session.list` to filter sessions by query, type, origin, or date range
- Use `knowledge.get_session_metadata` to retrieve detailed metadata for specific sessions
- Return structured lists or counts as evidence

## Evidence Guidance

- Session cards (title, type, date, duration, origin) are the primary evidence
- Counts and filtered lists are acceptable evidence
- No transcript content is needed for metadata queries

## Answer Guidance

- Provide clear counts and lists
- Include relevant metadata (e.g., "3 meetings from last week, total 2h 15m")
- Use bullet points or tables for readability


## Adaptive evidence method

Read available metadata first. Use summaries to navigate long sources; read short transcripts directly. Follow every next_cursor before describing a read as complete. Verify exact decisions, negations and corrections in continuous original context. Stop when supported and answer naturally with the workspace citation numbers. Empty search means not found, never absence.

Use `session.aggregate` for exact metadata counts, grouping, duration sums and sorting. Unknown duration remains unknown. Dates default to source creation/import, not recording dates. Semantic search hits are not an exhaustive population.
